import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_lock.dart';
import 'package:fushi_engine/privacy/media_privacy.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v171：作品级「上锁」标记表 `media_locked_flags`（拍板台 qiqSbvdxrk）。
///
/// 迁移只建表、不动数据，重跑幂等；读写 API 与私密 / NSFW 标记同一套 LWW 时钟语义
/// （设 / 取消各推一只时钟、合并逐戳取大、相等取消胜）。上锁蕴含私密：
/// [MediaPrivacySnapshot] 把上锁的作品也当私密（排行榜 / 追踪推送不外泄）；
/// [MediaLockSnapshot] 随合集继承，成员离开上锁合集时锁落到成员自己身上。
void main() {
  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  test(
    'v170 → v171 建 media_locked_flags + media_lock_credentials；重跑幂等、不清数据',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'media_lock_v171',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = '${directory.path}/test.db';
      final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
      await db.getAllTags(); // 触发建库
      await db.close();

      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute('DROP TABLE media_locked_flags');
      raw.execute('DROP TABLE media_lock_credentials');
      raw.execute('PRAGMA user_version = 170');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, kFushiDbSchemaVersion);
      await migrated.setMediaLocked(TagHostKind.video, 'v1', true, at: 10);
      await migrated.setMediaLockCredential('digest', at: 10);
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      expect(
        probe.select('PRAGMA user_version').first.values.first,
        kFushiDbSchemaVersion,
      );
      expect(tableExists(probe, 'media_locked_flags'), isTrue);
      expect(tableExists(probe, 'media_lock_credentials'), isTrue);
      expect(
        <String>{
          for (final sqlite.Row row in probe.select(
            "PRAGMA table_info('media_locked_flags')",
          ))
            row['name'] as String,
        },
        <String>{'media_kind', 'entry_key', 'locked_at', 'cleared_at'},
      );
      probe.execute('PRAGMA user_version = 170');
      probe.dispose();

      final FushiDatabase reopened = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(await reopened.isMediaLocked(TagHostKind.video, 'v1'), isTrue);
      expect((await reopened.mediaLockCredential())?.verifier, 'digest');
      await reopened.close();
    },
  );

  group('上锁标记 API 与快照', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<void> video(String uid) => db
        .into(db.videoBooks)
        .insert(
          VideoBooksCompanion.insert(
            bookUid: uid,
            title: uid,
            videoPath: '/v/$uid.mkv',
            importedAt: const Value<int?>(0),
          ),
        );

    test('设 / 取消各推进一只时钟；取消过的保留时钟', () async {
      await db.setMediaLocked(TagHostKind.game, 'g1', true, at: 100);
      await db.setMediaLocked(TagHostKind.game, 'g2', true, at: 100);
      await db.setMediaLocked(TagHostKind.game, 'g2', false, at: 200);
      expect(await db.isMediaLocked(TagHostKind.game, 'g1'), isTrue);
      expect(await db.mediaLockClock(TagHostKind.game, 'g2'), (
        lockedAt: 100,
        clearedAt: 200,
      ));
      expect(await db.lockedEntryKeys(TagHostKind.game), <String>{'g1'});
      expect(
        (await db.allLockClocksForKind(TagHostKind.game)).keys.toSet(),
        <String>{'g1', 'g2'},
      );
      // 与私密 / NSFW 标记互不写穿。
      expect(await db.isMediaPrivate(TagHostKind.game, 'g1'), isFalse);
      expect(await db.isMediaNsfw(TagHostKind.game, 'g1'), isFalse);
    });

    test('合并逐戳取大；没变化不写库；相等取消胜', () async {
      await db.setMediaLocked(TagHostKind.epub, 'b', true, at: 100);
      expect(
        await db.mergeRemoteLockClock(TagHostKind.epub, 'b', (
          lockedAt: 50,
          clearedAt: null,
        )),
        isFalse,
      );
      expect(
        await db.mergeRemoteLockClock(TagHostKind.epub, 'b', (
          lockedAt: null,
          clearedAt: 100,
        )),
        isTrue,
      );
      expect(await db.isMediaLocked(TagHostKind.epub, 'b'), isFalse);
    });

    test('上锁合集的成员随合集上锁；上锁蕴含私密', () async {
      await video('v1');
      await video('v2');
      final int c = await db.createMediaCollection('锁');
      await db.addToCollection(c, MediaKind.video, 'v1');
      await db.setMediaLocked(
        TagHostKind.collection,
        collectionTagEntryKey(c),
        true,
      );
      await db.setMediaLocked(TagHostKind.video, 'v2', true);

      final MediaLockSnapshot lock = await MediaLockSnapshot.load(db);
      expect(lock.isCollectionLocked(c), isTrue);
      expect(lock.isVideoLocked('v1'), isTrue, reason: '合集继承');
      expect(lock.isVideoLocked('v2'), isTrue);
      expect(lock.isLocked(TagHostKind.video, 'v1'), isTrue);
      expect(lock.isEmpty, isFalse);
      expect(MediaLockSnapshot.none.isEmpty, isTrue);

      final MediaPrivacySnapshot privacy = await MediaPrivacySnapshot.load(db);
      expect(privacy.isVideoPrivate('v1'), isTrue, reason: '上锁合集 → 私密');
      expect(privacy.isVideoPrivate('v2'), isTrue, reason: '上锁 → 私密');
      expect(
        (await lockedCollectionsContaining(
          db,
          TagHostKind.video,
          'v1',
        )).map((MediaCollectionRow r) => r.id),
        <int>[c],
      );
    });

    test('删除上锁合集：锁落到成员自己身上（不 fail-open）', () async {
      await video('v1');
      final int c = await db.createMediaCollection('锁');
      await db.addToCollection(c, MediaKind.video, 'v1');
      await db.setMediaLocked(
        TagHostKind.collection,
        collectionTagEntryKey(c),
        true,
      );
      expect(await db.isMediaLocked(TagHostKind.video, 'v1'), isFalse);

      await db.deleteMediaCollection(c);

      expect(await db.isMediaLocked(TagHostKind.video, 'v1'), isTrue);
      expect((await MediaLockSnapshot.load(db)).isVideoLocked('v1'), isTrue);
    });
  });
}
