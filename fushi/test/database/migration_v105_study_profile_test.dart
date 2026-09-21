import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v105：统计按 Profile 隔离——`study_segments` / `galgame_sessions` 加 `profile_id`，
/// `study_segment_tombstones` 主键并入 `profile_id`（重建表），存量行全部归到升级
/// 那一刻激活的 Profile，legacy 家族的归属记进偏好 `stats_legacy_profile_id`。
///
/// 下面钉住：「旧行零丢失且全部归到激活 Profile」「碑重建后 PK 带 profile」
/// 「legacy 归属偏好写下」「升级后新建的 Profile 看不到旧历史、旧 Profile 仍看得到」
/// 「没有任何 Profile 的库升级时补建 Default 认领历史」。
void main() {
  /// 造一个 v104 形态的库：先用当前代码建全表并写入统计行，再把 v105 的产物
  /// 拆掉（DROP COLUMN / 按旧形态重建碑表）、版本号写回 104。
  Future<({String path, int activeId, int otherId})> seedV104Database(
    Directory directory, {
    bool withProfiles = true,
  }) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    int activeId = 0;
    int otherId = 0;
    if (withProfiles) {
      otherId = await original.insertProfile(
        ProfilesCompanion.insert(name: '英语', createdAt: 1, updatedAt: 1),
      );
      activeId = await original.insertProfile(
        ProfilesCompanion.insert(name: '日语', createdAt: 2, updatedAt: 2),
      );
      await original.setPref(kActiveProfileIdPrefKey, activeId.toString());
    }
    await original.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'g1',
        name: 'Game',
        exePath: r'D:\g\g.exe',
        workdir: r'D:\g',
        addedAt: 1,
      ),
    );
    await original.close();

    final sqlite3.Database raw = sqlite3.sqlite3.open(path);
    try {
      raw.execute('DROP INDEX IF EXISTS idx_study_segments_profile_date');
      raw.execute('DROP INDEX IF EXISTS idx_galgame_sessions_profile_date');
      raw.execute('ALTER TABLE study_segments DROP COLUMN profile_id');
      raw.execute('ALTER TABLE galgame_sessions DROP COLUMN profile_id');
      raw.execute('DROP TABLE study_segment_tombstones');
      raw.execute('''
        CREATE TABLE study_segment_tombstones (
          media_kind TEXT NOT NULL,
          media_key TEXT NOT NULL,
          deleted_at INTEGER NOT NULL,
          PRIMARY KEY (media_kind, media_key))''');
      // v104 形态的存量统计行（没有 profile_id 列）。
      raw.execute(
        'INSERT INTO study_segments (uid, device_id, media_kind, media_key, '
        'format, title, start_at, end_at, date_key, hour, duration_ms, chars, '
        'pages, updated_at) VALUES '
        "('s1', 'dev', 'book', 'b1', 'epub', 'T', 100, 200, '2026-09-01', 10, "
        '60000, 300, 0, 1000), '
        "('s2', 'dev', 'video', 'v1', '', 'V', 100, 200, '2026-09-02', 11, "
        '30000, 0, 0, 1000)',
      );
      raw.execute(
        'INSERT INTO study_segment_tombstones (media_kind, media_key, '
        "deleted_at) VALUES ('book', 'b9', 500)",
      );
      raw.execute(
        'INSERT INTO galgame_sessions (game_id, start_ms, end_ms, '
        "duration_seconds, date_key) VALUES ('g1', 100, 200, 90, '2026-09-01')",
      );
      raw.execute('PRAGMA user_version = 104');
    } finally {
      raw.dispose();
    }
    return (path: path, activeId: activeId, otherId: otherId);
  }

  test('v104 → v105：存量段 / 碑 / 游玩会话全部归到升级时激活的 Profile', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'study_profile_v105',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final ({String path, int activeId, int otherId}) seed =
        await seedV104Database(directory);

    final FushiDatabase upgraded = FushiDatabase.atFile(
      seed.path,
      isMainProcess: false,
    );
    addTearDown(upgraded.close);

    expect(
      (await upgraded.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      upgraded.schemaVersion,
    );
    expect(upgraded.schemaVersion, 112);

    // 激活 Profile 认领全部旧历史（Never break userspace：升级前后它看到的一样）。
    expect(await upgraded.resolveActiveProfileId(), seed.activeId);
    final List<StudySegmentRow> mine = await upgraded.getStudySegments();
    expect(mine.map((StudySegmentRow r) => r.uid).toSet(), <String>{
      's1',
      's2',
    });
    expect(
      mine.every((StudySegmentRow r) => r.profileId == seed.activeId),
      isTrue,
    );
    final List<StudySegmentTombstoneRow> tombs = await upgraded
        .getStudySegmentTombstones();
    expect(tombs.single.profileId, seed.activeId);
    expect(tombs.single.mediaKey, 'b9');
    expect(tombs.single.deletedAt, 500);
    final List<GalgameSessionRow> sessions = await upgraded
        .getRecentGalgameSessions();
    expect(sessions.single.profileId, seed.activeId);
    expect(sessions.single.durationSeconds, 90);
    expect(
      await upgraded.getStatLegacyProfileId(),
      seed.activeId,
      reason: 'legacy 家族的归属 Profile 必须一次性写下',
    );

    // 另一个既有 Profile 看不到这些历史；新建的 Profile 也看不到。
    expect(await upgraded.getStudySegments(profileId: seed.otherId), isEmpty);
    expect(
      await upgraded.getRecentGalgameSessions(profileId: seed.otherId),
      isEmpty,
    );
    expect(await upgraded.legacyStatsVisibleTo(seed.otherId), isFalse);
    expect(await upgraded.legacyStatsVisibleTo(seed.activeId), isTrue);

    // 碑表 PK 带 profile_id：同身份不同 Profile 各立各的碑。
    await upgraded.upsertStudySegmentTombstone(
      mediaKind: kActivityMediaBook,
      mediaKey: 'b9',
      deletedAt: 700,
      profileId: seed.otherId,
    );
    final List<StudySegmentTombstoneRow> both = await upgraded
        .getStudySegmentTombstones();
    expect(both, hasLength(2));
    expect(
      both.map((StudySegmentTombstoneRow t) => (t.profileId, t.deletedAt)),
      unorderedEquals(<(int, int)>[(seed.activeId, 500), (seed.otherId, 700)]),
    );
  });

  test('v105 迁移路径上分区索引一并建出（_ensureIndexes 不跑升级路径）', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'study_profile_v105_idx',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final ({String path, int activeId, int otherId}) seed =
        await seedV104Database(directory);

    final FushiDatabase upgraded = FushiDatabase.atFile(
      seed.path,
      isMainProcess: false,
    );
    // drift 惰性打开：先发一条真查询才跑迁移。
    expect(await upgraded.getStudySegments(), hasLength(2));
    await upgraded.close();

    final sqlite3.Database probe = sqlite3.sqlite3.open(seed.path);
    try {
      final Set<String> names = probe
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND tbl_name IN ('study_segments', 'galgame_sessions')",
          )
          .map((sqlite3.Row r) => r['name'] as String)
          .toSet();
      expect(names, contains('idx_study_segments_profile_date'));
      expect(names, contains('idx_galgame_sessions_profile_date'));
      final Set<String> pk = probe
          .select("PRAGMA table_info('study_segment_tombstones')")
          .where((sqlite3.Row r) => (r['pk'] as int) > 0)
          .map((sqlite3.Row r) => r['name'] as String)
          .toSet();
      expect(pk, <String>{'profile_id', 'media_kind', 'media_key'});
    } finally {
      probe.dispose();
    }
  });

  test('库里没有任何 Profile 时升级补建 Default 认领历史、并设为激活', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'study_profile_v105_noprof',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final ({String path, int activeId, int otherId}) seed =
        await seedV104Database(directory, withProfiles: false);

    final FushiDatabase upgraded = FushiDatabase.atFile(
      seed.path,
      isMainProcess: false,
    );
    addTearDown(upgraded.close);

    final List<ProfileRow> profiles = await upgraded.getAllProfiles();
    expect(profiles.single.name, 'Default');
    expect(
      await upgraded.getPref(kActiveProfileIdPrefKey),
      profiles.single.id.toString(),
    );
    expect(await upgraded.resolveActiveProfileId(), profiles.single.id);
    final List<StudySegmentRow> rows = await upgraded.getStudySegments();
    expect(rows, hasLength(2));
    expect(
      rows.every((StudySegmentRow r) => r.profileId == profiles.single.id),
      isTrue,
      reason: '没有 Profile 的库升级后旧历史不能悬空成 0',
    );
    expect(await upgraded.getStatLegacyProfileId(), profiles.single.id);
  });

  test('升级后写入按当前激活 Profile 盖戳，切 Profile 后各看各的', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'study_profile_v105_write',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final ({String path, int activeId, int otherId}) seed =
        await seedV104Database(directory);

    final FushiDatabase upgraded = FushiDatabase.atFile(
      seed.path,
      isMainProcess: false,
    );
    addTearDown(upgraded.close);

    await upgraded.setPref(kActiveProfileIdPrefKey, seed.otherId.toString());
    await upgraded.upsertStudySegment(
      StudySegmentsCompanion.insert(
        uid: 'n1',
        deviceId: 'dev',
        mediaKind: kActivityMediaBook,
        mediaKey: 'b1',
        title: 'T',
        startAt: 900,
        endAt: 1000,
        dateKey: '2026-09-03',
        hour: 9,
        durationMs: const Value(1000),
        updatedAt: 2000,
      ),
    );
    final List<StudySegmentRow> other = await upgraded.getStudySegments();
    expect(other.single.uid, 'n1');
    expect(other.single.profileId, seed.otherId);
    // 切回原 Profile：只看到自己的两条，看不到 n1。
    await upgraded.setPref(kActiveProfileIdPrefKey, seed.activeId.toString());
    expect(
      (await upgraded.getStudySegments())
          .map((StudySegmentRow r) => r.uid)
          .toSet(),
      <String>{'s1', 's2'},
    );
  });
}
