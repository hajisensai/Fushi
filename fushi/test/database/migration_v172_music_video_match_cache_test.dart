import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v172：本地 MV 自动匹配的两张缓存 `music_video_prints` / `music_video_match_checks`。
/// 纯建表、幂等、无外键；声纹按文件版本（大小 + 修改时刻）失效。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_v172_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  bool tableExists(sqlite.Database db, String name) => db.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[name],
  ).isNotEmpty;

  test('v171 → v172 建表；重跑不报错不清数据；无外键', () async {
    final String path = p.join(tmp.path, 'fushi.db');
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE music_video_prints');
    raw.execute('DROP TABLE music_video_match_checks');
    raw.execute('PRAGMA user_version = 171');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 172);
    await migrated.putMusicVideoPrint(
      '/bd/00001.m2ts',
      fileSizeBytes: 10,
      fileModifiedAt: 1,
      print: Uint8List.fromList(<int>[1, 0, 0, 0]),
      computedAt: 2,
    );
    await migrated.putMusicVideoMatchCheck(
      trackUid: 't',
      videoPath: '/bd/00001.m2ts',
      fileSizeBytes: 10,
      fileModifiedAt: 1,
      checkedAt: 2,
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 172);
    for (final String t in <String>[
      'music_video_prints',
      'music_video_match_checks',
    ]) {
      expect(tableExists(probe, t), isTrue);
      expect(
        probe.select('PRAGMA foreign_key_list($t)'),
        isEmpty,
        reason: '设备本地缓存不挂外键',
      );
    }
    probe.execute('PRAGMA user_version = 171');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(reopened.close);
    expect(
      await reopened.getMusicVideoPrint(
        '/bd/00001.m2ts',
        fileSizeBytes: 10,
        fileModifiedAt: 1,
      ),
      Uint8List.fromList(<int>[1, 0, 0, 0]),
      reason: '重跑迁移不清数据',
    );
    expect(
      await reopened.getMusicVideoPrint(
        '/bd/00001.m2ts',
        fileSizeBytes: 11,
        fileModifiedAt: 1,
      ),
      isNull,
      reason: '文件换了（大小变）声纹失效',
    );
    expect((await reopened.allMusicVideoMatchChecks()).keys, <(String, String)>[
      ('t', '/bd/00001.m2ts'),
    ]);
  });
}
