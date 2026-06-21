import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/preferences_repository.dart';

/// TODO-559 守卫：远端（在线）视频断点恢复。
///
/// 回归根因（commit a1b4dc67f 远端功能诞生即如此）：
/// - 恢复侧 `_initRemote` 硬编码 `initialPositionMs: 0`，不读任何存储；
/// - 保存侧 `onPositionWrite = _isRemote ? null : _persistPosition`，远端为 null
///   永不落库。
/// 远端在线视频在 client 本地 DB 没有 VideoBooks 行（书架不收录远端在线视频），
/// 故本地的 `VideoBooks.lastPositionMs` 链路对远端不可用。修复改用与 speed/volume
/// 同款 per-book prefs（key `video_remote_position_<bookUid>`，落 Drift preferences
/// 表跨重启保留），按稳定的 `RemoteVideoInfo.id` 存取。
///
/// 两层守卫：
/// 1. 行为往返：用真 [PreferencesRepository] 验「保存远端位置 → 重开读回到该位置」，
///    模拟修复的 [_persistRemotePosition] 写 + [_readPersistedRemotePosition] 读。
/// 2. 源码守卫：断言 `_initRemote` 读 prefs 而非硬编码 0、`onPositionWrite` 远端走
///    `_persistRemotePosition` 而非 null。撤任一修复即转红。

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 远端位置 prefs key（与 video_hibiki_page.dart 的同一公式，单一真相）。
String remotePositionPrefKey(String bookUid) =>
    'video_remote_position_$bookUid';

void main() {
  group('TODO-559 remote video resume — behavioral round-trip', () {
    late HibikiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('saved remote position persists across reopen (was always 0)',
        () async {
      const String bookUid = 'video/remote-movie';
      // 远端在线视频从无 VideoBooks 行：未存过时默认 0（从头），与修复前行为一致。
      expect(
        repo.getPref(remotePositionPrefKey(bookUid), defaultValue: 0),
        0,
        reason: 'a never-watched remote video must start at 0',
      );

      // _persistRemotePosition：播放到 73210ms 时落库。
      await repo.setPref(remotePositionPrefKey(bookUid), 73210);

      // 重开：跨 PreferencesRepository 实例 reload，模拟 app 重启后再次打开。
      final PreferencesRepository repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      addTearDown(repo2.dispose);

      // _readPersistedRemotePosition：恢复到上次位置，而不是 0。
      final int restored =
          repo2.getPref(remotePositionPrefKey(bookUid), defaultValue: 0) as int;
      expect(
        restored,
        73210,
        reason: 'remote resume must read back the persisted position, not 0',
      );
    });

    test('two remote videos keep independent positions (keyed by bookUid)',
        () async {
      await repo.setPref(remotePositionPrefKey('video/a'), 1000);
      await repo.setPref(remotePositionPrefKey('video/b'), 2000);

      final PreferencesRepository repo2 = PreferencesRepository(db);
      await repo2.loadFromDb();
      addTearDown(repo2.dispose);

      expect(repo2.getPref(remotePositionPrefKey('video/a'), defaultValue: 0),
          1000);
      expect(repo2.getPref(remotePositionPrefKey('video/b'), defaultValue: 0),
          2000);
    });
  });

  group('TODO-559 remote video resume — source guards', () {
    final File page =
        File('lib/src/pages/implementations/video_hibiki_page.dart');
    late String src;

    setUpAll(() {
      expect(page.existsSync(), isTrue);
      src = page.readAsStringSync();
    });

    String region(String startSig, String endSig) {
      final int start = src.indexOf(startSig);
      expect(start, isNonNegative, reason: 'missing region start: $startSig');
      final int end = src.indexOf(endSig, start);
      expect(end, isNonNegative, reason: 'missing region end: $endSig');
      return src.substring(start, end);
    }

    test('_initRemote restores from persisted/synced position, not hardcoded 0',
        () {
      final String initRemote = region(
        'Future<void> _initRemote() async {',
        'String get _speedPrefKey',
      );
      // TODO-653：恢复改走 _resolveRemoteInitialPositionMs(info)——它在 host 真相
      // （info.positionMs，随清单带回）与本地 prefs 之间取较新者（跨设备同步），仍
      // 绝不硬编码 0（TODO-559 回归守卫保留）。
      expect(
        initRemote
            .contains('initialPositionMs: _resolveRemoteInitialPositionMs('),
        isTrue,
        reason: 'remote restore must resolve persisted vs host-synced position',
      );
      expect(
        initRemote.contains('initialPositionMs: 0'),
        isFalse,
        reason: 'remote restore must NOT hardcode 0 (the regression)',
      );
    });

    test('onPositionWrite is wired for remote (not null)', () {
      final String region2 = region(
        'controller.setPauseAtSubtitleEnd',
        'if (!mounted)',
      );
      expect(
        region2.contains(
          '_isRemote ? _persistRemotePosition : _persistPosition',
        ),
        isTrue,
        reason: 'remote save must go through _persistRemotePosition',
      );
      expect(
        region2.contains('_isRemote ? null'),
        isFalse,
        reason: 'remote save must NOT be disabled (the regression)',
      );
    });

    test('remote position helpers use the stable bookUid key', () {
      // 读侧 key getter（TODO-653：改用单一真相源函数 videoRemotePositionPrefKey，
      // 与 host service / 测试共用同一公式，消除散落的字面量漂移）。
      expect(src.contains('String get _remotePositionPrefKey'), isTrue);
      expect(
        src.contains('videoRemotePositionPrefKey(widget.bookUid)'),
        isTrue,
        reason: 'read-side key must derive from the stable bookUid',
      );
      // 写侧（_persistRemotePosition）用回调透传的同一 bookUid 构造 key。
      expect(
        src.contains('videoRemotePositionPrefKey(uid)'),
        isTrue,
        reason: 'write-side key must use the same bookUid passed by controller',
      );
    });

    test('TODO-653: remote position is uploaded to host for cross-device sync',
        () {
      final String persist = region(
        'Future<void> _persistRemotePosition(String uid, int posMs) async {',
        'Future<void> _persistPosition',
      );
      // 写侧仍落本地 prefs（离线可用）。
      expect(
        persist.contains('videoRemotePositionPrefKey(uid)'),
        isTrue,
        reason: 'must still persist locally for offline restore',
      );
      // 且 best-effort 上报到 host（跨设备真相源），失败不抛。
      expect(
        persist.contains('client.putRemoteVideoPosition('),
        isTrue,
        reason: 'remote position must be uploaded to host (TODO-653)',
      );
    });
  });
}
