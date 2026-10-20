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
// ⑥ 宿主打不开 → open 返回 null；关闭后命令以 Closed 失败、代理按不可用作答；
// ⑦ 工作 isolate 意外退出（未捕获异步错误 / 结果不可发送）前先关 session，主
//    isolate 的客户端报 closed，槽位摘下失效客户端、下次 ensure 重建；
// ⑧ 投递式命令（post）失败只进 engineLog，不产生 zone 未处理异步错误。

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host_client.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host_slot.dart';
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

/// 设了就在 session 销毁时往这个目录写 `session_destroyed`（工作 isolate 死后
/// 它的内存读不到了，只能落盘给主 isolate 看）。
String? _destroyMarkerDir;

void _sessionDestroy(Pointer<Void> session) {
  _calls.add('destroy');
  final String? dir = _destroyMarkerDir;
  if (dir != null) {
    File('$dir/session_destroyed')
      ..createSync(recursive: true)
      ..writeAsStringSync('x', mode: FileMode.append);
  }
}

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

EmbeddedTorrentHost? _markedHostFactory(EmbeddedTorrentHostOpenArgs args) {
  _destroyMarkerDir = args.resumeDir;
  return _buildHost(args, withUploadControl: true);
}

/// 命令本身正常返回，但随后抛出一个谁也接不住的异步错误（宿主内部回调出错
/// 的形态）。默认 errorsAreFatal 下它会当场打死工作 isolate。
Object? _crashWithUncaughtAsyncError(EmbeddedTorrentWorkerState state) {
  Timer.run(() => throw StateError('boom in worker'));
  return null;
}

/// 结果不可发送：回应答时 `SendPort.send` 同步抛出，落在命令 try/catch 之外。
Object? _unsendableResult(EmbeddedTorrentWorkerState state) =>
    ReceivePort()..close();

Object? _throwingCommand(EmbeddedTorrentWorkerState state) =>
    throw StateError('command failed');

int _destroyMarks(Directory dir) {
  final File marker = File('${dir.path}/resume/session_destroyed');
  return marker.existsSync() ? marker.readAsStringSync().length : 0;
}

class _RecordingEngineLog implements EngineLogSink {
  final List<String> errors = <String>[];
  final List<String> diagnostics = <String>[];

  @override
  void log(String source, Object error, [StackTrace? stack]) =>
      errors.add('$source: $error');

  @override
  void logDiagnostic(String source, Object info) =>
      diagnostics.add('$source: $info');

  @override
  void logFatal(String source, Object error, [StackTrace? stack]) =>
      errors.add('$source: $error');
}

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

  group('工作 isolate 意外退出', () {
    late _RecordingEngineLog logs;
    late EngineLogSink previousLog;

    setUp(() {
      previousLog = engineLog;
      logs = _RecordingEngineLog();
      engineLog = logs;
    });

    tearDown(() => engineLog = previousLog);

    test('未捕获异步错误：退出前关 session，客户端报 closed', () async {
      final EmbeddedTorrentHostClient client =
          (await EmbeddedTorrentHostClient.open(
            _args(dir),
            factory: _markedHostFactory,
          ))!;
      addTearDown(client.dispose);

      await client.runForTesting(_crashWithUncaughtAsyncError);
      await client.closed.timeout(const Duration(seconds: 10));

      expect(client.isClosed, isTrue);
      expect(client.exitedUnexpectedly, isTrue);
      expect(
        _destroyMarks(dir),
        1,
        reason: '工作 isolate 死前没关 session = 监听端口 / DHT 泄漏到进程退出',
      );
      await expectLater(
        client.sweepAntiLeech(),
        throwsA(isA<EmbeddedTorrentWorkerClosed>()),
      );
      expect(
        logs.errors.any((String e) => e.contains('boom in worker')),
        isTrue,
      );
      expect(
        logs.errors.any((String e) => e.contains('exited unexpectedly')),
        isTrue,
      );
    });

    test('结果不可发送（命令 try 之外的错误）：同样先关 session 再退出', () async {
      final EmbeddedTorrentHostClient client =
          (await EmbeddedTorrentHostClient.open(
            _args(dir),
            factory: _markedHostFactory,
          ))!;
      addTearDown(client.dispose);

      await expectLater(
        client.runForTesting(_unsendableResult),
        throwsA(isA<EmbeddedTorrentWorkerClosed>()),
      );
      await client.closed.timeout(const Duration(seconds: 10));
      expect(client.exitedUnexpectedly, isTrue);
      expect(_destroyMarks(dir), 1);
    });

    test('正常 dispose 只关一次 session，且不算意外退出', () async {
      final EmbeddedTorrentHostClient client =
          (await EmbeddedTorrentHostClient.open(
            _args(dir),
            factory: _markedHostFactory,
          ))!;
      await client.dispose(keepIds: <String>{_torrentId});
      // 关闭应答排在 session 真正关掉之后。
      expect(_destroyMarks(dir), 1);
      await client.closed.timeout(const Duration(seconds: 10));
      expect(client.exitedUnexpectedly, isFalse);
      expect(logs.errors, isEmpty);
    });

    test('槽位：并发 ensure 只起一个；意外退出后摘下、下次 ensure 重建', () async {
      final EmbeddedTorrentHostSlot slot = EmbeddedTorrentHostSlot();
      int opens = 0;
      int opened = 0;
      final List<EmbeddedTorrentHostClient> lost =
          <EmbeddedTorrentHostClient>[];
      final Completer<void> lostSignal = Completer<void>();
      Future<EmbeddedTorrentHostClient?> ensure() => slot.ensure(
        () {
          opens++;
          return EmbeddedTorrentHostClient.open(
            _args(dir),
            factory: _markedHostFactory,
          );
        },
        onOpened: (EmbeddedTorrentHostClient _) => opened++,
        onLost: (EmbeddedTorrentHostClient client) {
          lost.add(client);
          if (!lostSignal.isCompleted) lostSignal.complete();
        },
      );
      addTearDown(() async => (await slot.take())?.dispose());

      final List<EmbeddedTorrentHostClient?> first = await Future.wait(
        <Future<EmbeddedTorrentHostClient?>>[ensure(), ensure()],
      );
      expect(opens, 1, reason: '两个 session 会抢同一个监听端口');
      expect(opened, 1);
      final EmbeddedTorrentHostClient dead = first[0]!;
      expect(identical(first[1], dead), isTrue);
      expect(identical(slot.current, dead), isTrue);

      await dead.runForTesting(_crashWithUncaughtAsyncError);
      await lostSignal.future.timeout(const Duration(seconds: 10));
      expect(lost, <EmbeddedTorrentHostClient>[dead]);
      expect(slot.current, isNull);

      final EmbeddedTorrentHostClient rebuilt = (await ensure())!;
      expect(opens, 2);
      expect(opened, 2);
      expect(identical(rebuilt, dead), isFalse);
      expect(rebuilt.isClosed, isFalse);
      final EmbeddedTorrentBackendProxy backend = rebuilt.backendView();
      addTearDown(backend.close);
      expect(await backend.listTorrents(), hasLength(1));
    });

    test('槽位：主动 take 不算丢失，不回调 onLost', () async {
      final EmbeddedTorrentHostSlot slot = EmbeddedTorrentHostSlot();
      int lost = 0;
      final EmbeddedTorrentHostClient client = (await slot.ensure(
        () => EmbeddedTorrentHostClient.open(
          _args(dir),
          factory: _plainHostFactory,
        ),
        onLost: (EmbeddedTorrentHostClient _) => lost++,
      ))!;
      final EmbeddedTorrentHostClient? taken = await slot.take();
      expect(identical(taken, client), isTrue);
      expect(slot.current, isNull);
      await client.dispose();
      await client.closed;
      await Future<void>.delayed(Duration.zero);
      expect(lost, 0);
    });

    test('槽位：懒建途中被 take 撤下，落地的客户端交给 take 方、不挂回槽位', () async {
      final EmbeddedTorrentHostSlot slot = EmbeddedTorrentHostSlot();
      int opened = 0;
      final Future<EmbeddedTorrentHostClient?> opening = slot.ensure(
        () => EmbeddedTorrentHostClient.open(
          _args(dir),
          factory: _plainHostFactory,
        ),
        onOpened: (EmbeddedTorrentHostClient _) => opened++,
      );
      expect(slot.isOpening, isTrue);
      final EmbeddedTorrentHostClient? taken = await slot.take();
      expect(taken, isNotNull);
      expect(identical(await opening, taken), isTrue);
      expect(slot.current, isNull);
      expect(slot.isOpening, isFalse);
      expect(opened, 0);
      await taken!.dispose();
    });

    test('槽位：open 交 null（此刻建不了）不登记，下次再判', () async {
      final EmbeddedTorrentHostSlot slot = EmbeddedTorrentHostSlot();
      int opens = 0;
      Future<EmbeddedTorrentHostClient?>? cannot() {
        opens++;
        return null;
      }

      expect(await slot.ensure(cannot), isNull);
      expect(await slot.ensure(cannot), isNull);
      expect(opens, 2);
      expect(slot.isOpening, isFalse);
      expect(
        await slot.ensure(
          () => EmbeddedTorrentHostClient.open(
            _args(dir),
            factory: _failingHostFactory,
          ),
        ),
        isNull,
      );
      expect(slot.isOpening, isFalse);
      expect(slot.current, isNull);
    });

    test('post：命令失败与已关都只进 engineLog，不产生未处理异步错误', () async {
      final EmbeddedTorrentHostClient client =
          (await EmbeddedTorrentHostClient.open(
            _args(dir),
            factory: _plainHostFactory,
          ))!;
      final List<Object> uncaught = <Object>[];
      final Completer<void> settled = Completer<void>();
      runZonedGuarded(() {
        client.post('throwing', client.runForTesting(_throwingCommand));
        // 往返一次确保上一条的失败已经回到本端再判。
        client.runForTesting(_readCalls).then((_) => settled.complete());
      }, (Object error, StackTrace stack) => uncaught.add(error));
      await settled.future;
      await Future<void>.delayed(Duration.zero);
      expect(uncaught, isEmpty);
      expect(
        logs.errors.where(
          (String e) => e.startsWith('EmbeddedTorrentHostClient.throwing:'),
        ),
        hasLength(1),
      );

      await client.dispose();
      runZonedGuarded(() {
        for (int i = 0; i < 3; i++) {
          client.post('sweepAntiLeech', client.sweepAntiLeech());
          client.post('sweepUploadPolicy', client.sweepUploadPolicy());
        }
      }, (Object error, StackTrace stack) => uncaught.add(error));
      for (int i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(uncaught, isEmpty, reason: 'unawaited(client.xxx()) 的老形态');
      expect(
        logs.diagnostics.where((String d) => d.contains('worker is closed')),
        hasLength(1),
        reason: '已关只记一次，不每 tick 刷屏',
      );
    });
  });
}
