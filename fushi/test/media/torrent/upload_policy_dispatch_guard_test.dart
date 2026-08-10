// BUG-1493 守卫：上传策略的 FFI 下发链 —— **不需要 native DLL**。
//
// 事故本体：旧实现把「关上传」（默认配置 uploadEnabled=false）翻译成给每个
// 种子置 libtorrent 的 `torrent_flags::upload_mode`，而该 flag 的真实语义是
// 「不再发出任何 piece 请求」= 只上不下、停止下载 —— 所有种子在 add 后一个
// tick 内下载速率归零，用户报「内置引擎速度几乎为 0」。
//
// 本守卫用 `Pointer.fromFunction` 伪造 C ABI（与 apply_limits_local_peers_test
// 同范式），经 `FushiTorrentBindings.fromLookup` + `EmbeddedTorrentHost.forTesting`
// 断言整条 sweepUploadPolicy → session → C 入参：
// ① 关上传绝不下发 upload_mode=0（那是停止下载）；
// ② 关上传走会话级 unchoke 槽位清零；
// ③ 只有已完成（做种）的种子会被 pause，下载中的绝不 pause；
// ④ 老 DLL（无新符号）整体降级为不动作，绝不回退到 upload_mode。
//
// 要 DLL 的行为闭环（unchoke=0 时下载仍推进）在
// packages/fushi_torrent/test/upload_off_download_test.dart（缺 DLL skip）。

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/embedded_torrent_host.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi_torrent/fushi_torrent.dart';

final Pointer<Void> _fakeSession = Pointer<Void>.fromAddress(0xF00D);

/// 进入 C ABI 的调用记录（symbol + 关键入参）。
final List<String> _calls = <String>[];

/// ht_list_torrents 每次返回的 JSON（测试逐场景设置）。
String _torrentsJson = '[]';

Pointer<Void> _fakeSessionCreate(Pointer<Char> listen, int enableDht) =>
    _fakeSession;

Pointer<Char> _fakeListTorrents(Pointer<Void> session) =>
    _torrentsJson.toNativeUtf8().cast<Char>();

void _fakeFreeString(Pointer<Char> s) {
  if (s != nullptr) malloc.free(s);
}

int _fakeSetUploadMode(
    Pointer<Void> session, Pointer<Char> infoHash, int enabled) {
  _calls.add('ht_set_upload_mode('
      '${infoHash == nullptr ? '' : infoHash.cast<Utf8>().toDartString()},'
      '$enabled)');
  return 1;
}

int _fakeSetUnchokeSlots(Pointer<Void> session, int slots) {
  _calls.add('ht_set_unchoke_slots($slots)');
  return 1;
}

int _fakePauseTorrent(
    Pointer<Void> session, Pointer<Char> infoHash, int pause) {
  _calls.add('ht_pause_torrent('
      '${infoHash == nullptr ? '' : infoHash.cast<Utf8>().toDartString()},'
      '$pause)');
  return 1;
}

/// [withUploadControl] = false 精确复刻「Dart 更新了、随包预编译 DLL 还是旧的」
/// 部署形态（查不到 ht_set_unchoke_slots / ht_pause_torrent）。
FushiTorrentBindings _fakeBindings({required bool withUploadControl}) {
  Pointer<T> lookup<T extends NativeType>(String symbol) {
    switch (symbol) {
      case 'ht_session_create':
        return Pointer.fromFunction<Pointer<Void> Function(Pointer<Char>, Int)>(
                _fakeSessionCreate)
            .cast<T>();
      case 'ht_list_torrents':
        return Pointer.fromFunction<Pointer<Char> Function(Pointer<Void>)>(
                _fakeListTorrents)
            .cast<T>();
      case 'ht_free_string':
        return Pointer.fromFunction<Void Function(Pointer<Char>)>(
                _fakeFreeString)
            .cast<T>();
      case 'ht_set_upload_mode':
        return Pointer.fromFunction<
            Int Function(Pointer<Void>, Pointer<Char>, Int)>(
          _fakeSetUploadMode,
          0,
        ).cast<T>();
      case 'ht_set_unchoke_slots':
        if (!withUploadControl) {
          throw ArgumentError("Failed to lookup symbol '$symbol'");
        }
        return Pointer.fromFunction<Int Function(Pointer<Void>, Int)>(
          _fakeSetUnchokeSlots,
          0,
        ).cast<T>();
      case 'ht_pause_torrent':
        if (!withUploadControl) {
          throw ArgumentError("Failed to lookup symbol '$symbol'");
        }
        return Pointer.fromFunction<
            Int Function(Pointer<Void>, Pointer<Char>, Int)>(
          _fakePauseTorrent,
          0,
        ).cast<T>();
    }
    throw ArgumentError("Failed to lookup symbol '$symbol'");
  }

  return FushiTorrentBindings.fromLookup(lookup);
}

EmbeddedTorrentHost _host({required bool withUploadControl}) {
  final EmbeddedTorrentEngine engine = EmbeddedTorrentEngine.fromBindings(
      _fakeBindings(withUploadControl: withUploadControl));
  final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(engine);
  expect(session, isNotNull);
  return EmbeddedTorrentHost.forTesting(
    engine: engine,
    session: session!,
    baseSavePath: '/tmp/content',
    resumeDir: '/tmp/resume',
    clockMs: () => 1000,
  );
}

String _torrent({
  required String id,
  required bool finished,
  double progress = 0.5,
  int uploaded = 0,
  int downloaded = 1,
}) {
  return jsonEncode(<String, Object>{
    'id': id,
    'name': id,
    'progress': progress,
    'state': finished ? 'seeding' : 'downloading',
    'save_path': '/tmp/content/hibiki',
    'content_path': '',
    'total': 100,
    'done': finished ? 100 : 50,
    'left': finished ? 0 : 50,
    'down_rate': 0,
    'up_rate': 0,
    'uploaded': uploaded,
    'downloaded': downloaded,
    'num_peers': 1,
    'has_metadata': true,
    'is_finished': finished,
    'is_seeding': finished,
    'sequential': false,
  });
}

void main() {
  setUp(() {
    _calls.clear();
    _torrentsJson = '[]';
  });

  group('BUG-1493：关上传绝不下发 upload_mode（那是「停止下载」）', () {
    test('默认配置（uploadEnabled=false）+ 下载中种子：unchoke 清零、不碰种子', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: true);
      host.setUploadPolicy(const QbConnectionConfig());
      _torrentsJson = '[${_torrent(id: 'aaa', finished: false)}]';
      host.sweepUploadPolicy();

      // 靶心：把 sweep 改回旧的 setUploadMode(enabled: false) 这条必红。
      expect(_calls.where((String c) => c.endsWith(',0)')).toList(),
          isNot(contains('ht_set_upload_mode(aaa,0)')),
          reason: 'upload_mode=0 = 停止下载，绝不允许下发');
      expect(_calls, isNot(contains('ht_set_upload_mode(,0)')));
      expect(_calls, contains('ht_set_unchoke_slots(0)'),
          reason: '关上传的正确原语是会话级 unchoke 槽位清零');
      expect(
          _calls.where((String c) => c.startsWith('ht_pause_torrent')), isEmpty,
          reason: '下载中的种子绝不 pause（那才是真的掐死下载）');
    });

    test('关上传 + 已完成种子：pause（停止做种），不置 upload_mode', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: true);
      host.setUploadPolicy(const QbConnectionConfig());
      _torrentsJson = '[${_torrent(id: 'bbb', finished: true)}]';
      host.sweepUploadPolicy();

      expect(_calls, contains('ht_pause_torrent(bbb,1)'));
      expect(_calls, isNot(contains('ht_set_upload_mode(bbb,0)')));
    });

    test('开上传：unchoke 还原（maxUploadSlots 未设 → -1 = 引擎默认）', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: true);
      host.setUploadPolicy(const QbConnectionConfig(uploadEnabled: true));
      expect(_calls, contains('ht_set_unchoke_slots(-1)'));
      expect(_calls, isNot(contains('ht_set_unchoke_slots(0)')));
    });

    test('开上传 + maxUploadSlots=4：unchoke 还原为用户值', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: true);
      host.setUploadPolicy(
          const QbConnectionConfig(uploadEnabled: true, maxUploadSlots: 4));
      expect(_calls, contains('ht_set_unchoke_slots(4)'));
    });

    test('开上传 + 分享率达标的做种种子：pause；未达标不 pause', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: true);
      host.setUploadPolicy(const QbConnectionConfig(
        uploadEnabled: true,
        seedRatioLimit: 2.0,
      ));
      _torrentsJson = '['
          '${_torrent(id: 'hit', finished: true, uploaded: 200, downloaded: 100)},'
          '${_torrent(id: 'low', finished: true, uploaded: 10, downloaded: 100)}'
          ']';
      host.sweepUploadPolicy();

      expect(_calls, contains('ht_pause_torrent(hit,1)'));
      expect(_calls, isNot(contains('ht_pause_torrent(low,1)')));
    });

    test('状态不变时不重复下发（每 tick 幂等）', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: true);
      host.setUploadPolicy(const QbConnectionConfig());
      _torrentsJson = '[${_torrent(id: 'ccc', finished: true)}]';
      host.sweepUploadPolicy();
      final int after = _calls.length;
      host.sweepUploadPolicy();
      host.sweepUploadPolicy();
      expect(_calls.length, after, reason: '无状态变化不应再发 FFI');
    });
  });

  group('旧 DLL（无 ht_set_unchoke_slots / ht_pause_torrent 符号）降级', () {
    test('探针如实报告', () {
      final EmbeddedTorrentEngine engine = EmbeddedTorrentEngine.fromBindings(
          _fakeBindings(withUploadControl: false));
      final EmbeddedTorrentSession session =
          EmbeddedTorrentSession.open(engine)!;
      expect(session.supportsUploadControl, isFalse);
    });

    test('不崩、不动作，且绝不回退到 upload_mode=0', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: false);
      host.setUploadPolicy(const QbConnectionConfig());
      _torrentsJson = '[${_torrent(id: 'ddd', finished: false)}]';
      expect(host.sweepUploadPolicy(), 0);

      expect(
          _calls.where((String c) =>
              c.startsWith('ht_set_upload_mode') && c.endsWith(',0)')),
          isEmpty,
          reason: '老 DLL 的 upload_mode=0 会真的置 flag 掐死下载，绝不允许');
    });

    test('治愈调用照常发出（enabled=1 清历史残留 flag，新旧 DLL 都安全）', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: false);
      host.setUploadPolicy(const QbConnectionConfig());
      expect(_calls, contains('ht_set_upload_mode(,1)'));
    });
  });

  group('TODO-2481：用户暂停/恢复与策略 sweep 的边界', () {
    test('pauseTorrentByUser 下发 pause=1；isTorrentPausedForDisplay 置位', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: true);
      expect(host.pauseTorrentByUser('AAA'), isTrue);
      expect(_calls, contains('ht_pause_torrent(aaa,1)'),
          reason: 'infohash 统一小写下发');
      expect(host.isTorrentPausedForDisplay('aaa'), isTrue);
      expect(host.isTorrentPausedForDisplay('AAA'), isTrue,
          reason: '大小写只是书写差异');
    });

    test('靶心：sweep 绝不替用户 resume（把 skip 删掉这条必红）', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: true);
      // 开上传 + 无做种上限 → 策略对已完成种子的裁决是「继续做种」。
      host.setUploadPolicy(const QbConnectionConfig(uploadEnabled: true));
      _torrentsJson = '[${_torrent(id: 'bbb', finished: true)}]';
      expect(host.pauseTorrentByUser('bbb'), isTrue);
      _calls.clear();
      host.sweepUploadPolicy();
      host.sweepUploadPolicy();
      expect(
          _calls.where((String c) => c.startsWith('ht_pause_torrent')), isEmpty,
          reason: '用户暂停的种子策略既不重复 pause 也不 resume');
    });

    test('resumeTorrentByUser 下发 pause=0 并清除暂停显示态', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: true);
      expect(host.pauseTorrentByUser('ccc'), isTrue);
      expect(host.resumeTorrentByUser('ccc'), isTrue);
      expect(_calls, contains('ht_pause_torrent(ccc,0)'));
      expect(host.isTorrentPausedForDisplay('ccc'), isFalse);
    });

    test('用户恢复后策略重新裁决：关上传的已完成种子会被策略再次暂停', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: true);
      host.setUploadPolicy(const QbConnectionConfig()); // uploadEnabled=false
      _torrentsJson = '[${_torrent(id: 'ddd', finished: true)}]';
      host.sweepUploadPolicy();
      expect(_calls, contains('ht_pause_torrent(ddd,1)'),
          reason: '前置：策略先按关上传暂停了做种');
      // 用户手动恢复（清掉策略已下发记录）→ 下一轮 sweep 按策略重新暂停。
      expect(host.resumeTorrentByUser('ddd'), isTrue);
      _calls.clear();
      host.sweepUploadPolicy();
      expect(_calls, contains('ht_pause_torrent(ddd,1)'),
          reason: '策略语义使然：resume 清的是记录，不是豁免');
    });

    test('老 DLL：supportsPauseControl=false 且用户暂停如实失败', () {
      final EmbeddedTorrentHost host = _host(withUploadControl: false);
      expect(host.supportsPauseControl, isFalse);
      expect(host.pauseTorrentByUser('eee'), isFalse);
      expect(host.isTorrentPausedForDisplay('eee'), isFalse);
      expect(host.backendView().pauseControlAvailable, isFalse,
          reason: '能力位经 backendView 透传，UI 据此隐藏按钮');
    });

    test('backendView 快照：已知暂停的种子 state 覆写为 pausedDL/pausedUP', () async {
      final EmbeddedTorrentHost host = _host(withUploadControl: true);
      _torrentsJson = '['
          '${_torrent(id: 'dl1', finished: false)},'
          '${_torrent(id: 'up1', finished: true)}'
          ']';
      expect(host.pauseTorrentByUser('dl1'), isTrue);
      expect(host.pauseTorrentByUser('up1'), isTrue);
      final Map<String, String> stateByHash = <String, String>{
        for (final TorrentSnapshot s in await host.backendView().listTorrents())
          s.hash: s.state,
      };
      expect(stateByHash['dl1'], 'pausedDL',
          reason: 'native state_label 不导出 paused，覆写发生在快照层');
      expect(stateByHash['up1'], 'pausedUP',
          reason: 'pausedUP 属做种类，isComplete 判定不受暂停影响');

      // 恢复后回落 native 原词。
      expect(host.resumeTorrentByUser('dl1'), isTrue);
      final Map<String, String> after = <String, String>{
        for (final TorrentSnapshot s in await host.backendView().listTorrents())
          s.hash: s.state,
      };
      expect(after['dl1'], 'downloading');
    });
  });
}
