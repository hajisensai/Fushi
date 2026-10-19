// BUG-3571：内置 libtorrent 宿主必须跑在专用工作 isolate，UI isolate 不得被
// libtorrent 的同步往返卡住 —— **不需要 native DLL**。
//
// 事故本体（用户机 hang dump，2026-10-19）：启动 58 秒后看门狗记下
// `main thread unresponsive >=10000 ms`，主线程栈是
//   Dart（UI isolate）→ ht_set_upload_mode → session_handle::get_torrents
//   → _Cnd_wait
// —— `sweepUploadPolicy` 首轮「清 upload_mode 残留」在 UI isolate 上同步等网络
// 线程交回种子列表，而网络线程正忙着加载 fastResume。本机 7 份 hang dump 里 4 份
// 停在同一个条件变量上。
//
// 这里用 `Pointer.fromFunction` 在**工作 isolate 里**伪造 C ABI（与
// upload_policy_dispatch_guard_test 同范式；工厂是顶层函数，送进工作 isolate
// 才执行，回调指针因此属于工作 isolate），让 `ht_set_upload_mode` 同步阻塞
// 1.5 秒，断言：
// ① 阻塞期间 UI isolate 的事件循环照常跑（定时器最大间隔远小于阻塞时长）；
// ② 命令按发送顺序执行（原生桥无锁、依赖调用方串行）；
// ③ 后端代理往返：列表 / 用户暂停覆写显示态 / close 后兜底；
// ④ 工作 isolate 里的 `[torrent]` 诊断日志回放到 UI isolate 的装配点；
// ⑤ 退出 flush 用退出预算存 resume、不关 session；
// ⑥ 宿主打不开 → open 返回 null；关闭后命令以 Closed 失败、代理按不可用作答。

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host_client.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_worker.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_torrent/fushi_torrent.dart';

// ── 以下全局状态都活在**工作 isolate**里（每个 isolate 一份）。─────────────

final Pointer<Void> _fakeSession = Pointer<Void>.fromAddress(0xF00D);

/// 进入 C ABI 的调用记录（工作 isolate 侧）。
final List<String> _calls = <String>[];

/// `ht_set_upload_mode` 同步阻塞多久（模拟网络线程忙于加载 fastResume）。
int _uploadModeBlockMs = 0;

const String _torrentId = 'aa11';

const String _torrentsJson =
    '[{"id":"$_torrentId","name":"ep01",'
    '"progress":0.5,"state":"downloading","save_path":"/tmp/content/anime",'
    '"content_path":"","total":100,"done":50,"left":50,"down_rate":0,'
    '"up_rate":0,"uploaded":0,"downloaded":50,"num_peers":0,'
    '"has_metadata":true,"is_finished":false,"is_seeding":false,'
    '"sequential":false}]';

Pointer<Void> _sessionCreate(Pointer<Char> listen, int enableDht) =>
    _fakeSession;

void _sessionDestroy(Pointer<Void> session) => _calls.add('destroy');

Pointer<Char> _listTorrents(Pointer<Void> session) =>
    _torrentsJson.toNativeUtf8().cast<Char>();

void _freeString(Pointer<Char> s) {
  if (s != nullptr) malloc.free(s);
}

int _setUploadMode(Pointer<Void> session, Pointer<Char> infoHash, int on) {
  if (_uploadModeBlockMs > 0) {
    sleep(Duration(milliseconds: _uploadModeBlockMs));
  }
  _calls.add('upload_mode($on)');
  return 1;
}

int _setUnchokeSlots(Pointer<Void> session, int slots) {
  _calls.add('unchoke($slots)');
  return 1;
}

int _pauseTorrent(Pointer<Void> session, Pointer<Char> infoHash, int pause) {
  _calls.add('pause(${infoHash.cast<Utf8>().toDartString()},$pause)');
  return 1;
}

Pointer<Char> _saveResumeData(
  Pointer<Void> session,
  Pointer<Char> dir,
  int timeoutMs,
) {
  _calls.add('save_resume($timeoutMs)');
  return '{"ok":true,"saved":1,"failed":0}'.toNativeUtf8().cast<Char>();
}

FushiTorrentBindings _bindings({required bool withUploadControl}) {
  Pointer<T> lookup<T extends NativeType>(String symbol) {
    switch (symbol) {
      case 'ht_session_create':
        return Pointer.fromFunction<Pointer<Void> Function(Pointer<Char>, Int)>(
          _sessionCreate,
        ).cast<T>();
      case 'ht_session_destroy':
        return Pointer.fromFunction<Void Function(Pointer<Void>)>(
          _sessionDestroy,
        ).cast<T>();
      case 'ht_list_torrents':
        return Pointer.fromFunction<Pointer<Char> Function(Pointer<Void>)>(
          _listTorrents,
        ).cast<T>();
      case 'ht_free_string':
        return Pointer.fromFunction<Void Function(Pointer<Char>)>(
          _freeString,
        ).cast<T>();
      case 'ht_set_upload_mode':
        return Pointer.fromFunction<
              Int Function(Pointer<Void>, Pointer<Char>, Int)
            >(_setUploadMode, 0)
            .cast<T>();
      case 'ht_save_resume_data':
        return Pointer.fromFunction<
              Pointer<Char> Function(Pointer<Void>, Pointer<Char>, Int)
            >(_saveResumeData)
            .cast<T>();
      case 'ht_set_unchoke_slots':
        if (withUploadControl) {
          return Pointer.fromFunction<Int Function(Pointer<Void>, Int)>(
            _setUnchokeSlots,
            0,
          ).cast<T>();
        }
      case 'ht_pause_torrent':
        if (withUploadControl) {
          return Pointer.fromFunction<
                Int Function(Pointer<Void>, Pointer<Char>, Int)
              >(_pauseTorrent, 0)
              .cast<T>();
        }
    }
    throw ArgumentError("Failed to lookup symbol '$symbol'");
  }

  return FushiTorrentBindings.fromLookup(lookup);
}

EmbeddedTorrentHost _buildHost(
  EmbeddedTorrentHostOpenArgs args, {
  required bool withUploadControl,
}) {
  final EmbeddedTorrentEngine engine = EmbeddedTorrentEngine.fromBindings(
    _bindings(withUploadControl: withUploadControl),
  );
  return EmbeddedTorrentHost.forTesting(
    engine: engine,
    session: EmbeddedTorrentSession.open(engine)!,
    baseSavePath: args.baseSavePath,
    resumeDir: args.resumeDir,
    clockMs: () => 1000,
  );
}

// ── 工厂（顶层函数，送进工作 isolate 执行）────────────────────────────────

EmbeddedTorrentHost? _plainHostFactory(EmbeddedTorrentHostOpenArgs args) =>
    _buildHost(args, withUploadControl: true);

EmbeddedTorrentHost? _blockingHostFactory(EmbeddedTorrentHostOpenArgs args) {
  _uploadModeBlockMs = 1500;
  return _buildHost(args, withUploadControl: true);
}

EmbeddedTorrentHost? _oldDllHostFactory(EmbeddedTorrentHostOpenArgs args) =>
    _buildHost(args, withUploadControl: false);

EmbeddedTorrentHost? _failingHostFactory(EmbeddedTorrentHostOpenArgs args) =>
    null;

List<String> _readCalls(EmbeddedTorrentWorkerState state) =>
    List<String>.of(_calls);

// ── UI isolate 侧 ───────────────────────────────────────────────────────

EmbeddedTorrentHostOpenArgs _args(Directory dir) => EmbeddedTorrentHostOpenArgs(
  baseSavePath: '${dir.path}/content',
  resumeDir: '${dir.path}/resume',
);

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fushi-torrent-worker-');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  test('native 同步阻塞 1.5s 时 UI isolate 的事件循环照常跑', () async {
    final EmbeddedTorrentHostClient? client =
        await EmbeddedTorrentHostClient.open(
          _args(dir),
          factory: _blockingHostFactory,
        );
    expect(client, isNotNull);
    addTearDown(() => client!.dispose());

    final Stopwatch sinceLastTick = Stopwatch()..start();
    int maxGapMs = 0;
    int ticks = 0;
    final Timer timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final int gap = sinceLastTick.elapsedMilliseconds;
      if (gap > maxGapMs) maxGapMs = gap;
      ticks++;
      sinceLastTick.reset();
    });
    final Stopwatch sweep = Stopwatch()..start();
    await client!.sweepUploadPolicy();
    sweep.stop();
    timer.cancel();

    // 阻塞真的发生了（在工作 isolate 里）……
    expect(sweep.elapsedMilliseconds, greaterThanOrEqualTo(1400));
    expect(await client.runForTesting(_readCalls), contains('upload_mode(1)'));
    // ……而 UI isolate 期间一直在跑：定时器几乎每 10ms 一跳。整段被冻住时
    // 这里只会有 1 跳、间隔 ≈1500ms。
    expect(ticks, greaterThan(50));
    expect(
      maxGapMs,
      lessThan(400),
      reason: 'BUG-3571 回归：libtorrent 同步往返又回到了 UI isolate',
    );
  });

  test('命令在工作 isolate 里按发送顺序逐条执行', () async {
    final EmbeddedTorrentHostClient client =
        (await EmbeddedTorrentHostClient.open(
          _args(dir),
          factory: _plainHostFactory,
        ))!;
    addTearDown(client.dispose);

    // 不互相 await：先后依赖只靠工作 isolate 的串行执行保证。
    final Future<bool> paused = client.pauseTorrentByUser(_torrentId);
    final Future<bool> resumed = client.resumeTorrentByUser(_torrentId);
    final Future<bool> pausedAgain = client.pauseTorrentByUser(_torrentId);
    expect(
      await Future.wait(<Future<bool>>[paused, resumed, pausedAgain]),
      <bool>[true, true, true],
    );

    final List<String> pauses = (await client.runForTesting(
      _readCalls,
    )).where((String c) => c.startsWith('pause(')).toList();
    expect(pauses, <String>[
      'pause($_torrentId,1)',
      'pause($_torrentId,0)',
      'pause($_torrentId,1)',
    ]);
  });

  test('后端代理：列表往返、用户暂停覆写显示态、close 后按不可用作答', () async {
    final EmbeddedTorrentHostClient client =
        (await EmbeddedTorrentHostClient.open(
          _args(dir),
          factory: _plainHostFactory,
        ))!;
    addTearDown(client.dispose);

    final EmbeddedTorrentBackendProxy backend = client.backendView();
    expect(backend.pauseControlAvailable, isTrue);
    expect(backend.detailAvailable, isFalse);

    final List<TorrentSnapshot> before = await backend.listTorrents();
    expect(before.map((TorrentSnapshot t) => t.hash), <String>[_torrentId]);
    expect(before.single.state, 'downloading');

    expect(await backend.pauseTorrent(_torrentId), isTrue);
    expect((await backend.listTorrents()).single.state, 'pausedDL');

    backend.close();
    expect(await backend.listTorrents(), isEmpty);
    // 关掉的只是视图：同一宿主派发的新视图照常可用。
    final EmbeddedTorrentBackendProxy next = client.backendView();
    addTearDown(next.close);
    expect(await next.listTorrents(), hasLength(1));
  });

  test('代理在宿主就绪前同步交出，方法里再等宿主', () async {
    final Completer<EmbeddedTorrentHostClient?> pending =
        Completer<EmbeddedTorrentHostClient?>();
    final EmbeddedTorrentBackendProxy backend = EmbeddedTorrentBackendProxy(
      host: pending.future,
      capabilities: const EmbeddedTorrentHostCapabilities(
        libtorrentVersion: '',
        supportsLocalPeerRateLimit: false,
        supportsPauseControl: true,
        supportsDetailInfo: false,
        supportsProxy: false,
        supportsProxyMode: false,
        supportsAddDhtNodes: false,
      ),
    );
    addTearDown(backend.close);
    final Future<List<TorrentSnapshot>> listing = backend.listTorrents();
    final EmbeddedTorrentHostClient client =
        (await EmbeddedTorrentHostClient.open(
          _args(dir),
          factory: _plainHostFactory,
        ))!;
    addTearDown(client.dispose);
    pending.complete(client);
    expect(await listing, hasLength(1));
  });

  test('工作 isolate 的诊断日志回放到 UI isolate 的装配点', () async {
    final List<String?> printed = <String?>[];
    final FushiDebugPrint previous = fushiDebugPrint;
    fushiDebugPrint = (String? message, {int? wrapWidth}) =>
        printed.add(message);
    addTearDown(() => fushiDebugPrint = previous);

    final EmbeddedTorrentHostClient client =
        (await EmbeddedTorrentHostClient.open(
          _args(dir),
          factory: _oldDllHostFactory,
        ))!;
    addTearDown(client.dispose);
    // 老 DLL 缺上传策略原语：宿主在工作 isolate 里记一条降级日志。
    await client.sweepUploadPolicy();
    // 日志与应答走不同端口；再往返一次确保日志已经落到 UI isolate。
    await client.runForTesting(_readCalls);
    expect(
      printed.whereType<String>().any(
        (String line) => line.contains('[torrent] upload policy skipped'),
      ),
      isTrue,
    );
  });

  test('退出 flush 用退出预算存 resume，且不关 session', () async {
    final EmbeddedTorrentHostClient client =
        (await EmbeddedTorrentHostClient.open(
          _args(dir),
          factory: _plainHostFactory,
        ))!;
    addTearDown(client.dispose);

    await client.flushResumeForExit(<String>{_torrentId});
    final List<String> calls = await client.runForTesting(_readCalls);
    expect(
      calls,
      contains('save_resume(${EmbeddedTorrentHost.exitFlushSaveTimeoutMs})'),
    );
    expect(calls, isNot(contains('destroy')));
    expect(client.isClosed, isFalse);
  });

  test('宿主打不开 → open 返回 null', () async {
    expect(
      await EmbeddedTorrentHostClient.open(
        _args(dir),
        factory: _failingHostFactory,
      ),
      isNull,
    );
  });

  test('dispose 后命令以 Closed 失败，已派发的代理按不可用作答', () async {
    final EmbeddedTorrentHostClient client =
        (await EmbeddedTorrentHostClient.open(
          _args(dir),
          factory: _plainHostFactory,
        ))!;
    final EmbeddedTorrentBackendProxy backend = client.backendView();
    expect(await backend.listTorrents(), hasLength(1));

    await client.dispose(keepIds: <String>{_torrentId});
    await client.dispose(); // 幂等
    expect(client.isClosed, isTrue);
    await expectLater(
      client.sweepAntiLeech(),
      throwsA(isA<EmbeddedTorrentWorkerClosed>()),
    );
    expect(await backend.listTorrents(), isEmpty);
    expect(await backend.pauseTorrent(_torrentId), isFalse);
    // 关闭后再刷退出 flush 是 no-op（关闭与退出竞发）。
    await client.flushResumeForExit(null);
  });

  test('对 config 的上传策略下发经工作 isolate 落到 C ABI', () async {
    final EmbeddedTorrentHostClient client =
        (await EmbeddedTorrentHostClient.open(
          _args(dir),
          factory: _plainHostFactory,
        ))!;
    addTearDown(client.dispose);
    await client.setUploadPolicy(const QbConnectionConfig());
    final List<String> calls = await client.runForTesting(_readCalls);
    // 默认关上传：会话级 unchoke 清零（BUG-1293），绝不下发 upload_mode=0。
    expect(calls, contains('unchoke(0)'));
    expect(calls, isNot(contains('upload_mode(0)')));
    expect(
      jsonEncode(calls),
      isNot(contains('pause($_torrentId,1)')),
      reason: '下载中的种子绝不 pause',
    );
  });
}
