// BUG-1647：内置 torrent session 可以因历史 resume 常驻，但无真实下载/允许做种
// 工作时，DHT/LSD/UPnP/NAT-PMP 必须全部关闭。否则空闲 session 仍会持续广播、
// 映射端口并产生小包流量，家用路由器会表现为周期性网关 ping 抖动。
//
// 本测试用 Pointer.fromFunction 伪造 C ABI，不依赖随包 native DLL，直接锁住：
// - 空闲与活跃工作对应的四个协议位；
// - add 前先唤醒、失败后立即收回；
// - 暂停、做种达限、删除最后任务后立即收回；
// - 重复 reconcile 与嵌套 wake 不重复下发 FFI。

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/embedded_torrent_host.dart';
import 'package:fushi_torrent/fushi_torrent.dart';

final Pointer<Void> _fakeSession = Pointer<Void>.fromAddress(0x1645);
final List<String> _calls = <String>[];

String _torrentsJson = '[]';
String _addResultJson =
    jsonEncode(<String, Object>{'ok': false, 'error': 'synthetic add failure'});
bool _removeSucceeds = true;
bool _listReadFails = false;
String _loadResumeResultJson =
    jsonEncode(<String, Object>{'ok': true, 'ids': <String>[]});

Pointer<Void> _fakeSessionCreate(Pointer<Char> listen, int enableDht) {
  _calls.add('create:$enableDht');
  return _fakeSession;
}

int _fakeApplySessionSettings(
  Pointer<Void> session,
  int listenPort,
  int enableDht,
  int enableLsd,
  int enableUpnp,
  int enableNatpmp,
  int encPolicy,
  int anonymousMode,
  int activeDownloads,
  int activeSeeds,
  int maxUploadSlots,
) {
  _calls.add('settings:$enableDht$enableLsd$enableUpnp$enableNatpmp');
  return 1;
}

Pointer<Char> _fakeListTorrents(Pointer<Void> session) => (_listReadFails
        ? jsonEncode(<String, Object>{'error': 'synthetic list failure'})
        : _torrentsJson)
    .toNativeUtf8()
    .cast<Char>();

Pointer<Char> _fakeAddMagnet(
  Pointer<Void> session,
  Pointer<Char> magnet,
  Pointer<Char> savePath,
  int sequential,
) {
  _calls.add('add');
  return _addResultJson.toNativeUtf8().cast<Char>();
}

Pointer<Char> _fakeLoadResumeDir(
  Pointer<Void> session,
  Pointer<Char> resumeDir,
) {
  _calls.add('restore');
  return _loadResumeResultJson.toNativeUtf8().cast<Char>();
}

int _fakeRemoveTorrent(
  Pointer<Void> session,
  Pointer<Char> infoHash,
  int deleteFiles,
) {
  _calls.add('remove');
  if (_removeSucceeds) _torrentsJson = '[]';
  return _removeSucceeds ? 1 : 0;
}

int _fakeSetUploadMode(
  Pointer<Void> session,
  Pointer<Char> infoHash,
  int enabled,
) {
  _calls.add('upload-mode:$enabled');
  return 1;
}

int _fakeSetUnchokeSlots(Pointer<Void> session, int slots) {
  _calls.add('unchoke:$slots');
  return 1;
}

int _fakePauseTorrent(
  Pointer<Void> session,
  Pointer<Char> infoHash,
  int pause,
) {
  final String id = infoHash.cast<Utf8>().toDartString();
  _calls.add('pause:$id:$pause');
  return 1;
}

void _fakeFreeString(Pointer<Char> string) {
  if (string != nullptr) malloc.free(string);
}

FushiTorrentBindings _fakeBindings() {
  Pointer<T> lookup<T extends NativeType>(String symbol) {
    switch (symbol) {
      case 'ht_session_create':
        return Pointer.fromFunction<Pointer<Void> Function(Pointer<Char>, Int)>(
          _fakeSessionCreate,
        ).cast<T>();
      case 'ht_apply_session_settings':
        return Pointer.fromFunction<
            Int Function(Pointer<Void>, Int, Int, Int, Int, Int, Int, Int, Int,
                Int, Int)>(
          _fakeApplySessionSettings,
          0,
        ).cast<T>();
      case 'ht_list_torrents':
        return Pointer.fromFunction<Pointer<Char> Function(Pointer<Void>)>(
          _fakeListTorrents,
        ).cast<T>();
      case 'ht_add_magnet':
        return Pointer.fromFunction<
            Pointer<Char> Function(
                Pointer<Void>, Pointer<Char>, Pointer<Char>, Int)>(
          _fakeAddMagnet,
        ).cast<T>();
      case 'ht_remove_torrent':
        return Pointer.fromFunction<
            Int Function(Pointer<Void>, Pointer<Char>, Int)>(
          _fakeRemoveTorrent,
          0,
        ).cast<T>();
      case 'ht_load_resume_dir':
        return Pointer.fromFunction<
            Pointer<Char> Function(Pointer<Void>, Pointer<Char>)>(
          _fakeLoadResumeDir,
        ).cast<T>();
      case 'ht_set_upload_mode':
        return Pointer.fromFunction<
            Int Function(Pointer<Void>, Pointer<Char>, Int)>(
          _fakeSetUploadMode,
          0,
        ).cast<T>();
      case 'ht_set_unchoke_slots':
        return Pointer.fromFunction<Int Function(Pointer<Void>, Int)>(
          _fakeSetUnchokeSlots,
          0,
        ).cast<T>();
      case 'ht_pause_torrent':
        return Pointer.fromFunction<
            Int Function(Pointer<Void>, Pointer<Char>, Int)>(
          _fakePauseTorrent,
          0,
        ).cast<T>();
      case 'ht_free_string':
        return Pointer.fromFunction<Void Function(Pointer<Char>)>(
          _fakeFreeString,
        ).cast<T>();
    }
    throw ArgumentError("Failed to lookup symbol '$symbol'");
  }

  return FushiTorrentBindings.fromLookup(lookup);
}

late Directory _tempDir;

EmbeddedTorrentHost _host({int clockMs = 1000000}) {
  final EmbeddedTorrentEngine engine =
      EmbeddedTorrentEngine.fromBindings(_fakeBindings());
  final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(engine);
  expect(session, isNotNull);
  return EmbeddedTorrentHost.forTesting(
    engine: engine,
    session: session!,
    baseSavePath: '${_tempDir.path}${Platform.pathSeparator}content',
    resumeDir: '${_tempDir.path}${Platform.pathSeparator}resume',
    clockMs: () => clockMs,
  );
}

const QbConnectionConfig _protocolConfig = QbConnectionConfig(
  enableDht: true,
  enableLsd: false,
  enableUpnp: true,
  enableNatpmp: false,
);

QbConnectionConfig _seedingConfig({
  double ratioLimit = 0,
  int timeLimitMinutes = 0,
}) =>
    QbConnectionConfig(
      uploadEnabled: true,
      seedRatioLimit: ratioLimit,
      seedTimeLimitMinutes: timeLimitMinutes,
      enableDht: _protocolConfig.enableDht,
      enableLsd: _protocolConfig.enableLsd,
      enableUpnp: _protocolConfig.enableUpnp,
      enableNatpmp: _protocolConfig.enableNatpmp,
    );

String _torrent({
  required String id,
  required bool finished,
  int uploaded = 0,
  int downloaded = 100,
  int seedingDurationSeconds = -1,
}) {
  return jsonEncode(<String, Object>{
    'id': id,
    'name': id,
    'progress': finished ? 1.0 : 0.5,
    'state': finished ? 'seeding' : 'downloading',
    'save_path': '${_tempDir.path}${Platform.pathSeparator}content',
    'content_path': '',
    'total': 100,
    'done': finished ? 100 : 50,
    'left': finished ? 0 : 50,
    'down_rate': 0,
    'up_rate': 0,
    'uploaded': uploaded,
    'downloaded': downloaded,
    'num_peers': 0,
    'has_metadata': true,
    'is_finished': finished,
    'is_seeding': finished,
    'sequential': false,
    'seeding_duration': seedingDurationSeconds,
  });
}

List<String> get _settingsCalls => _calls
    .where((String call) => call.startsWith('settings:'))
    .toList(growable: false);

void main() {
  setUp(() {
    _tempDir = Directory.systemTemp.createTempSync('torrent_idle_discovery_');
    _calls.clear();
    _torrentsJson = '[]';
    _addResultJson = jsonEncode(
        <String, Object>{'ok': false, 'error': 'synthetic add failure'});
    _removeSucceeds = true;
    _listReadFails = false;
    _loadResumeResultJson =
        jsonEncode(<String, Object>{'ok': true, 'ids': <String>[]});
  });

  tearDown(() {
    try {
      _tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶发句柄释放滞后；临时目录交给系统清理。
    }
  });

  group('BUG-1647 空闲 torrent session 关闭网络发现协议', () {
    test('空 session 或完成且禁止做种时都显式下发 0000', () {
      final EmbeddedTorrentHost host = _host();

      expect(host.applySessionSettings(_protocolConfig), isTrue);
      expect(_settingsCalls.last, 'settings:0000');

      _torrentsJson = '[${_torrent(id: 'completed', finished: true)}]';
      _calls.clear();
      expect(host.applySessionSettings(_protocolConfig), isTrue);

      expect(_settingsCalls.last, 'settings:0000');
    });

    test('下载中与允许做种时逐项恢复用户配置', () {
      final EmbeddedTorrentHost downloading = _host();
      _torrentsJson = '[${_torrent(id: 'download', finished: false)}]';

      expect(downloading.applySessionSettings(_protocolConfig), isTrue);
      expect(_settingsCalls.last, 'settings:1010');

      final EmbeddedTorrentHost seeding = _host();
      _torrentsJson = '[${_torrent(id: 'seed', finished: true)}]';
      final QbConnectionConfig config = _seedingConfig();
      expect(seeding.applySessionSettings(config), isTrue);
      _calls.clear();

      seeding.setUploadPolicy(config);

      expect(_settingsCalls.last, 'settings:1010');
    });

    test('用户暂停最后一个下载后立即关闭四个协议', () async {
      final EmbeddedTorrentHost host = _host();
      _torrentsJson = '[${_torrent(id: 'paused', finished: false)}]';
      expect(host.applySessionSettings(_protocolConfig), isTrue);
      _calls.clear();

      expect(await host.backendView().pauseTorrent('PAUSED'), isTrue);

      expect(_calls, contains('pause:paused:1'));
      expect(_settingsCalls, <String>['settings:0000']);
    });

    test('做种达到分享率上限后暂停并关闭四个协议', () {
      final EmbeddedTorrentHost host = _host();
      final QbConnectionConfig config = _seedingConfig(ratioLimit: 1.0);
      _torrentsJson =
          '[${_torrent(id: 'limited', finished: true, uploaded: 10)}]';
      expect(host.applySessionSettings(config), isTrue);
      host.setUploadPolicy(config);
      expect(_settingsCalls.last, 'settings:1010', reason: '前置：仍在允许做种');
      _calls.clear();

      _torrentsJson =
          '[${_torrent(id: 'limited', finished: true, uploaded: 100)}]';
      host.sweepUploadPolicy();

      expect(_calls, contains('pause:limited:1'));
      expect(_settingsCalls, <String>['settings:0000']);
    });

    test('fastResume 已累计到做种时限时不得重启计时或重开协议', () {
      final EmbeddedTorrentHost host = _host();
      final QbConnectionConfig config = _seedingConfig(timeLimitMinutes: 1);
      _torrentsJson =
          '[${_torrent(id: 'timed', finished: true, seedingDurationSeconds: 60)}]';
      expect(host.applySessionSettings(config), isTrue);
      expect(_settingsCalls.last, 'settings:0000');
      _calls.clear();

      host.setUploadPolicy(config);

      expect(_calls, contains('pause:timed:1'));
      expect(_settingsCalls, isEmpty,
          reason: '跨 fastResume 的累计时长已达限，不能重新开启 discovery');
    });

    test('老 DLL 无累计时长字段时也持久化起点，重启不重新计时', () {
      final QbConnectionConfig config = _seedingConfig(timeLimitMinutes: 1);
      _torrentsJson = '[${_torrent(id: 'legacy', finished: true)}]';
      final EmbeddedTorrentHost first = _host();
      expect(first.applySessionSettings(config), isTrue);
      first.setUploadPolicy(config);
      expect(_settingsCalls.last, 'settings:1010');

      _calls.clear();
      final EmbeddedTorrentHost restarted = _host(clockMs: 1060000);
      expect(restarted.applySessionSettings(config), isTrue);
      expect(_settingsCalls.last, 'settings:0000');
      _calls.clear();

      restarted.setUploadPolicy(config);

      expect(_calls, contains('pause:legacy:1'));
      expect(_settingsCalls, isEmpty,
          reason: '老 DLL fallback 也必须从落盘起点累计，不能按进程重置');
    });

    test('删除最后一个任务后 backend 立即触发关闭', () async {
      final EmbeddedTorrentHost host = _host();
      _torrentsJson = '[${_torrent(id: 'deleted', finished: false)}]';
      expect(host.applySessionSettings(_protocolConfig), isTrue);
      _calls.clear();

      expect(await host.backendView().removeTorrent('deleted'), isTrue);

      expect(_calls, contains('remove'));
      expect(_settingsCalls, <String>['settings:0000']);
    });

    test('add 在 native 调用前唤醒，失败后立即回到 0000', () async {
      final EmbeddedTorrentHost host = _host();
      expect(host.applySessionSettings(_protocolConfig), isTrue);
      _calls.clear();

      expect(
        await host.backendView().addTorrent(
              'magnet:?xt=urn:btih:deadbeef',
              category: 'fushi',
            ),
        isFalse,
      );

      expect(
        _settingsCalls,
        <String>['settings:1010', 'settings:0000'],
      );
      expect(_calls.indexOf('settings:1010'), lessThan(_calls.indexOf('add')),
          reason: 'native add 发出前必须已经唤醒发现协议');
      expect(_calls.indexOf('add'), lessThan(_calls.indexOf('settings:0000')),
          reason: '失败 add 结束后才能收回发现协议');
    });

    test('add 成功后状态读取失败时保持唤醒，不把错误当空 session', () async {
      final EmbeddedTorrentHost host = _host();
      expect(host.applySessionSettings(_protocolConfig), isTrue);
      _calls.clear();
      _addResultJson = jsonEncode(
        <String, Object>{'ok': true, 'id': 'active'},
      );
      _listReadFails = true;

      expect(
        await host.backendView().addTorrent(
              'magnet:?xt=urn:btih:active',
              category: 'fushi',
            ),
        isTrue,
      );

      expect(_settingsCalls, <String>['settings:1010']);
      expect(_calls, contains('add'));
    });

    test('延迟 restore 会先唤醒并使旧空快照失效', () {
      final EmbeddedTorrentHost host = _host();
      expect(host.applySessionSettings(_protocolConfig), isTrue);
      _calls.clear();
      _loadResumeResultJson = jsonEncode(
        <String, Object>{
          'ok': true,
          'ids': <String>['restored']
        },
      );
      _listReadFails = true;

      expect(host.restoreFromResume(<String>{'restored'}), 1);

      expect(_calls, contains('restore'));
      expect(_settingsCalls, <String>['settings:1010'],
          reason: '恢复后首次状态读取失败也必须保留 restore wake，不能复用旧空快照');
    });

    test('重复 reconcile 与嵌套 wake 幂等，不重复下发 FFI', () {
      final EmbeddedTorrentHost host = _host();
      expect(host.applySessionSettings(_protocolConfig), isTrue);
      _calls.clear();

      host.reconcileNetworkDiscoveryState();
      host.reconcileNetworkDiscoveryState();
      expect(_settingsCalls, isEmpty, reason: '目标仍为 0000，不应重复下发');

      host.beginNetworkWake();
      host.beginNetworkWake();
      host.endNetworkWake();
      expect(_settingsCalls, <String>['settings:1010'],
          reason: '嵌套 wake 中途结束一层仍需保持开启');

      host.endNetworkWake();
      host.endNetworkWake();
      host.reconcileNetworkDiscoveryState();
      expect(
        _settingsCalls,
        <String>['settings:1010', 'settings:0000'],
        reason: '深度归零只关闭一次，额外 end/reconcile 不得重复 FFI',
      );
    });
  });
}
