import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';

// v105 统计按 Profile 隔离：`study_segments` / `study_segment_tombstones` /
// `galgame_sessions` 都带 `profile_id`，DAO 写入时按 `active_profile_id` 偏好盖戳、
// 读取 / 删除 / 清空只看当前 Profile。本测试锁定 DAO 契约：
//  * 盖戳只在插入时发生，同 uid 冲突更新不改归属；
//  * 读取 / 最近观看 / 游玩会话按 Profile 过滤，`allProfiles: true` 是同步导出专用；
//  * 删某媒体 / 清空 / 按天写零只动当前 Profile，碑也只压当前 Profile；
//  * legacy 家族只对归属 Profile 露出，别的 Profile 的「清空全部」不连带删它；
//  * 没有任何 Profile 的库（纯 DB 测试）写 0 读 0 自洽。

Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

Future<(int a, int b)> _twoProfiles(FushiDatabase db) async {
  final int a = await db.insertProfile(
    ProfilesCompanion.insert(name: 'A', createdAt: 1, updatedAt: 1),
  );
  final int b = await db.insertProfile(
    ProfilesCompanion.insert(name: 'B', createdAt: 2, updatedAt: 2),
  );
  await db.setPref(kActiveProfileIdPrefKey, a.toString());
  return (a, b);
}

Future<void> _activate(FushiDatabase db, int profileId) =>
    db.setPref(kActiveProfileIdPrefKey, profileId.toString());

StudySegmentsCompanion _seg(
  String uid, {
  String kind = kActivityMediaBook,
  String key = 'b1',
  String dateKey = '2026-09-01',
  int ms = 60000,
  int chars = 0,
  int startAt = 1000,
  int endAt = 2000,
  int updatedAt = 1000,
  int? profileId,
}) => StudySegmentsCompanion.insert(
  uid: uid,
  deviceId: 'dev',
  mediaKind: kind,
  mediaKey: key,
  title: 'T',
  startAt: startAt,
  endAt: endAt,
  dateKey: dateKey,
  hour: 12,
  durationMs: Value(ms),
  chars: Value(chars),
  updatedAt: updatedAt,
  profileId: profileId == null ? const Value.absent() : Value(profileId),
);

void main() {
  group('写入盖戳', () {
    test('缺席 profileId 的段盖当前激活 Profile；切 Profile 后各看各的', () async {
      final FushiDatabase db = await _openDb();
      final (int a, int b) = await _twoProfiles(db);
      await db.upsertStudySegment(_seg('sa'));
      await _activate(db, b);
      await db.upsertStudySegment(_seg('sb', key: 'b2'));

      expect(await db.resolveActiveProfileId(), b);
      expect((await db.getStudySegments()).single.uid, 'sb');
      expect((await db.getStudySegments(profileId: a)).single.uid, 'sa');
      expect((await db.getStudySegments(profileId: a)).single.profileId, a);
      expect(
        (await db.getStudySegments(
          allProfiles: true,
        )).map((StudySegmentRow r) => r.uid).toSet(),
        <String>{'sa', 'sb'},
        reason: 'allProfiles 只给同步导出用：整库全部段',
      );
    });

    test('同 uid 冲突更新不改归属：开段时的 Profile 定死', () async {
      final FushiDatabase db = await _openDb();
      final (int a, int b) = await _twoProfiles(db);
      await db.upsertStudySegment(_seg('s', ms: 1000, updatedAt: 1));
      // 时钟还在跑，用户中途切了 Profile：下一 tick 的绝对值回写落到同一 uid。
      await _activate(db, b);
      await db.upsertStudySegment(_seg('s', ms: 5000, updatedAt: 2));
      final StudySegmentRow row = (await db.getStudySegments(
        profileId: a,
      )).single;
      expect(row.durationMs, 5000, reason: '值照常更新');
      expect(row.profileId, a, reason: '归属不随冲突更新漂到 B');
      expect(await db.getStudySegments(profileId: b), isEmpty);

      // 同步落地的 LWW 也不改归属。
      await db.upsertStudySegmentsIfNewer(<StudySegmentsCompanion>[
        _seg('s', ms: 9000, updatedAt: 3, profileId: b),
      ]);
      final StudySegmentRow after = (await db.getStudySegments(
        profileId: a,
      )).single;
      expect(after.durationMs, 9000);
      expect(after.profileId, a);
    });

    test('显式带 profileId 的行按给定值落（同步落地按名字解析后传入）', () async {
      final FushiDatabase db = await _openDb();
      final (int a, int b) = await _twoProfiles(db);
      await db.upsertStudySegmentsIfNewer(<StudySegmentsCompanion>[
        _seg('remote', profileId: b),
      ]);
      expect(await db.getStudySegments(profileId: a), isEmpty);
      expect((await db.getStudySegments(profileId: b)).single.uid, 'remote');
    });

    test(
      'resolveActiveProfileId：偏好指向已删 Profile 时退到最早建的；无 Profile 为 0',
      () async {
        final FushiDatabase db = await _openDb();
        expect(await db.resolveActiveProfileId(), 0);
        await db.upsertStudySegment(_seg('zero'));
        expect(
          (await db.getStudySegments()).single.profileId,
          0,
          reason: '纯 DB 测试：写 0 读 0 自洽',
        );

        final (int a, int b) = await _twoProfiles(db);
        await db.setPref(kActiveProfileIdPrefKey, '999');
        expect(
          await db.resolveActiveProfileId(),
          a,
          reason: '悬空的激活 id 退到 createdAt 最早的 Profile',
        );
        await db.setPref(kActiveProfileIdPrefKey, b.toString());
        expect(await db.resolveActiveProfileId(), b);
      },
    );
  });

  group('删除 / 清空 / 墓碑按 Profile 分区', () {
    test('删某媒体只删当前 Profile 的段、只立当前 Profile 的碑', () async {
      final FushiDatabase db = await _openDb();
      final (int a, int b) = await _twoProfiles(db);
      await db.upsertStudySegment(_seg('sa', startAt: 100));
      await _activate(db, b);
      await db.upsertStudySegment(_seg('sb', startAt: 100));

      final int removed = await db.deleteStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: 'b1',
      );
      expect(removed, 1);
      expect(await db.getStudySegments(profileId: b), isEmpty);
      expect(
        (await db.getStudySegments(profileId: a)).single.uid,
        'sa',
        reason: 'A 的同一本书历史不动',
      );
      final StudySegmentTombstoneRow tomb =
          (await db.getStudySegmentTombstones()).single;
      expect(tomb.profileId, b);

      // B 的碑不压 A 的写入：A 再写一条 startAt < deletedAt 的段照常落地。
      await _activate(db, a);
      await db.upsertStudySegment(_seg('sa2', startAt: 100));
      expect(
        (await db.getStudySegments(
          profileId: a,
        )).map((StudySegmentRow r) => r.uid).toSet(),
        <String>{'sa', 'sa2'},
      );
      // 换成 B 写同样的旧段：被 B 自己的碑压制。
      await _activate(db, b);
      await db.upsertStudySegment(_seg('sb2', startAt: 100));
      expect(await db.getStudySegments(profileId: b), isEmpty);
    });

    test('清空某种类只清当前 Profile；逐身份立碑也只立当前 Profile 的', () async {
      final FushiDatabase db = await _openDb();
      final (int a, int b) = await _twoProfiles(db);
      await db.upsertStudySegment(_seg('a1', key: 'b1'));
      await db.upsertStudySegment(_seg('a2', key: 'b2'));
      await _activate(db, b);
      await db.upsertStudySegment(_seg('b1', key: 'b1'));

      expect(await db.clearStudySegments(kActivityMediaBook), 1);
      expect(await db.getStudySegments(profileId: b), isEmpty);
      expect(await db.getStudySegments(profileId: a), hasLength(2));
      final List<StudySegmentTombstoneRow> tombs = await db
          .getStudySegmentTombstones();
      expect(tombs.single.profileId, b);
      expect(tombs.single.mediaKey, 'b1');
    });

    test('按天写零 / 时段明细删除只动当前 Profile', () async {
      final FushiDatabase db = await _openDb();
      final (int a, int b) = await _twoProfiles(db);
      await db.upsertStudySegment(_seg('a1', ms: 5000));
      await _activate(db, b);
      await db.upsertStudySegment(_seg('b1', ms: 7000));

      expect(
        await db.zeroStudySegmentsOnDays(
          mediaKind: kActivityMediaBook,
          mediaKey: 'b1',
          dateKeys: <String>{'2026-09-01'},
        ),
        1,
      );
      expect((await db.getStudySegments(profileId: b)).single.durationMs, 0);
      expect((await db.getStudySegments(profileId: a)).single.durationMs, 5000);
    });

    test('applyStudySegmentTombstone（同步落地）只压给定 Profile 的段', () async {
      final FushiDatabase db = await _openDb();
      final (int a, int b) = await _twoProfiles(db);
      await db.upsertStudySegment(_seg('a1', startAt: 100));
      await _activate(db, b);
      await db.upsertStudySegment(_seg('b1', startAt: 100));

      await db.applyStudySegmentTombstone(
        mediaKind: kActivityMediaBook,
        mediaKey: 'b1',
        deletedAt: 500,
        profileId: a,
      );
      expect(await db.getStudySegments(profileId: a), isEmpty);
      expect((await db.getStudySegments(profileId: b)).single.uid, 'b1');
    });
  });

  group('读取面', () {
    test('最近观看只看当前 Profile 的段', () async {
      final FushiDatabase db = await _openDb();
      final (int a, int b) = await _twoProfiles(db);
      await db.upsertStudySegment(
        _seg('a1', kind: kActivityMediaVideo, key: 'v1', endAt: 500),
      );
      await _activate(db, b);
      expect(await db.getLatestStudyEndAtByMedia(kActivityMediaVideo), isEmpty);
      await _activate(db, a);
      expect(
        await db.getLatestStudyEndAtByMedia(kActivityMediaVideo),
        <String, int>{'v1': 500},
      );
    });

    test('loadStatFacts：段与游玩会话只取当前 Profile', () async {
      final FushiDatabase db = await _openDb();
      final (int a, int b) = await _twoProfiles(db);
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'Game',
          exePath: r'D:\g\g.exe',
          workdir: r'D:\g',
          addedAt: 1,
        ),
      );
      await db.upsertStudySegment(_seg('a1', ms: 5000, chars: 100));
      await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: 100,
          endMs: 200,
          durationSeconds: 90,
          dateKey: '2026-09-01',
        ),
      );
      await _activate(db, b);
      await db.upsertStudySegment(_seg('b1', ms: 7000, chars: 200));

      final StatFacts forB = await loadStatFacts(db, activityLimit: 0);
      expect(forB.segments.map((StudySegmentRow r) => r.uid), <String>['b1']);
      expect(forB.dailyGames, isEmpty, reason: 'A 的游玩会话不进 B 的日面');
      expect(forB.recentGameSessions, isEmpty);
      expect(forB.sessions.map((s) => s.title), <String>['T']);

      final StatFacts forA = await loadStatFacts(db, activityLimit: 0);
      // 显式传 profileId 也可以，与激活态无关。
      final StatFacts explicitA = await loadStatFacts(
        db,
        activityLimit: 0,
        profileId: a,
      );
      expect(forA.segments.map((StudySegmentRow r) => r.uid), <String>['b1']);
      expect(explicitA.segments.map((StudySegmentRow r) => r.uid), <String>[
        'a1',
      ]);
      expect(explicitA.dailyGames.single.ms, 90 * 1000);
      expect(explicitA.recentGameSessions.single.profileId, a);
      expect(
        await db.getGalgamePlayTotals(),
        isEmpty,
        reason: '库页的游玩汇总同样按当前 Profile（B）',
      );
    });

    test('legacy 家族只对归属 Profile 露出；无归属时对所有 Profile 露出', () async {
      final FushiDatabase db = await _openDb();
      final (int a, int b) = await _twoProfiles(db);
      await db.setReadingStatistic(
        ReadingStatisticsCompanion.insert(
          title: 'Old',
          dateKey: '2026-07-05',
          charactersRead: 100,
          readingTimeMs: 6000,
          lastStatisticModified: 1,
        ),
      );
      await db.addActivityEvent(
        eventType: kActivityRead,
        mediaType: kActivityMediaBook,
        title: 'Old',
        dateKey: '2026-07-05',
        timestampMs: 10,
      );
      await db.addActivityEvent(
        eventType: kActivityAdded,
        mediaType: kActivityMediaBook,
        title: 'Imported',
        dateKey: '2026-07-06',
        timestampMs: 20,
      );

      // 没写归属：两个 Profile 都看得到（fresh 库里 legacy 行只可能经旧端同步 /
      // 备份进来，本就无从归属）。
      expect(await db.getStatLegacyProfileId(), isNull);
      expect((await loadStatFacts(db, profileId: b)).daily, hasLength(1));

      await db.setPref(kStatLegacyProfileIdPrefKey, a.toString());
      final StatFacts forA = await loadStatFacts(db, profileId: a);
      expect(forA.daily.single.title, 'Old');
      expect(forA.legacyActivity.map((e) => e.eventType).toSet(), <String>{
        kActivityRead,
        kActivityAdded,
      });

      final StatFacts forB = await loadStatFacts(db, profileId: b);
      expect(forB.daily, isEmpty, reason: 'legacy 日行不归 B');
      expect(
        forB.legacyActivity.map((e) => e.eventType).toList(),
        <String>[kActivityAdded],
        reason: '库事件（导入）不分 Profile，学习行（read）只给归属 Profile',
      );
    });

    test('别的 Profile 的「清空全部阅读统计」不连带删 legacy 历史', () async {
      final FushiDatabase db = await _openDb();
      final (int a, int b) = await _twoProfiles(db);
      await db.setReadingStatistic(
        ReadingStatisticsCompanion.insert(
          title: 'Old',
          dateKey: '2026-07-05',
          charactersRead: 100,
          readingTimeMs: 6000,
          lastStatisticModified: 1,
        ),
      );
      await db.setPref(kStatLegacyProfileIdPrefKey, a.toString());
      await db.upsertStudySegment(_seg('a1'));
      await _activate(db, b);
      await db.upsertStudySegment(_seg('b1'));

      await db.clearAllReadingStatistics();
      expect(await db.getStudySegments(profileId: b), isEmpty);
      expect(await db.getStudySegments(profileId: a), hasLength(1));
      expect(
        await db.getAllReadingStatistics(),
        hasLength(1),
        reason: 'B 看不见的 legacy 行不能被 B 的清空抹掉',
      );

      await _activate(db, a);
      await db.clearAllReadingStatistics();
      expect(
        await db.getAllReadingStatistics(),
        isEmpty,
        reason: '归属 Profile 自己清空时 legacy 一起清',
      );
    });
  });
}
