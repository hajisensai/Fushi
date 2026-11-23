import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v165：`video_content_fingerprints`——视频内容指纹（搬家识别）。纯建表、幂等；设备
/// 本地缓存不挂外键；删视频同事务清掉；孤儿行可清。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_v165_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  bool tableExists(sqlite.Database db, String name) => db.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[name],
  ).isNotEmpty;

  VideoContentFingerprintsCompanion fp(String uid, {String value = 'osh:1'}) =>
      VideoContentFingerprintsCompanion.insert(
        bookUid: uid,
        fileSizeBytes: 10,
        fileModifiedAt: 1,
        fingerprint: value,
        computedAt: 2,
      );

  Future<void> addVideo(FushiDatabase db, String uid) => db.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(uid),
      videoPath: Value<String>('/v/$uid.mkv'),
    ),
  );

  test('v164 → v165 建表；重跑不报错不清数据；无外键', () async {
    final String path = p.join(tmp.path, 'fushi.db');
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE video_content_fingerprints');
    raw.execute('PRAGMA user_version = 164');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, kFushiDbSchemaVersion);
    await migrated.upsertVideoContentFingerprint(fp('video/a'));
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(
      probe.select('PRAGMA user_version').first.values.first,
      kFushiDbSchemaVersion,
    );
    expect(tableExists(probe, 'video_content_fingerprints'), isTrue);
    expect(
      probe.select('PRAGMA foreign_key_list(video_content_fingerprints)'),
      isEmpty,
      reason: '设备本地缓存不挂外键',
    );
    probe.execute('PRAGMA user_version = 164');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(reopened.close);
    expect(
      (await reopened.allVideoContentFingerprints())['video/a']?.fingerprint,
      'osh:1',
    );
  });

  test('同键覆盖；删视频同事务清掉；孤儿行可清', () async {
    final FushiDatabase db = FushiDatabase.atFile(
      p.join(tmp.path, 'fushi.db'),
      isMainProcess: false,
    );
    addTearDown(db.close);
    await addVideo(db, 'video/a');
    await addVideo(db, 'video/b');
    await db.upsertVideoContentFingerprint(fp('video/a'));
    await db.upsertVideoContentFingerprint(fp('video/a', value: 'osh:2'));
    await db.upsertVideoContentFingerprint(fp('video/b'));
    await db.upsertVideoContentFingerprint(fp('video/gone'));
    expect(
      (await db.allVideoContentFingerprints())['video/a']!.fingerprint,
      'osh:2',
    );

    expect(await db.pruneOrphanVideoContentFingerprints(), 1);
    await db.deleteVideoBooks(<String>['video/b']);
    expect((await db.allVideoContentFingerprints()).keys, <String>['video/a']);
  });
}
