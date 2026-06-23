import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/local_audio_db.dart';
import 'package:sqlite3/sqlite3.dart';

/// TODO-744: extractBlob 的输出文件名是 (file,source) 的稳定 hash，已存在即同字节，
/// 必须跳过开库 + 读 blob + 写盘。这一守卫确认「已存在跳过重写」的行为。
void main() {
  late Directory tmp;
  late Directory cacheDir;
  late String dbPath;

  int dbSeq = 0;

  String makeDb(Uint8List bytes,
      {String file = 'nhk_001.mp3', String source = 'NHK'}) {
    final String p = '${tmp.path}/local_audio_${dbSeq++}.sqlite';
    final File f = File(p);
    if (f.existsSync()) f.deleteSync();
    final Database db = sqlite3.open(p);
    db.execute('CREATE TABLE android(file TEXT, source TEXT, data BLOB)');
    final PreparedStatement stmt =
        db.prepare('INSERT INTO android(file, source, data) VALUES(?, ?, ?)');
    stmt.execute(<Object?>[file, source, bytes]);
    stmt.dispose();
    db.dispose();
    return p;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hibiki_local_audio_test');
    cacheDir = Directory('${tmp.path}/cache')..createSync(recursive: true);
    dbPath = makeDb(Uint8List.fromList(<int>[1, 2, 3, 4, 5]));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('first extract writes the blob; output path is a stable hash name', () {
    final String? path = LocalAudioDb.extractBlob(
      dbPath: dbPath,
      file: 'nhk_001.mp3',
      source: 'NHK',
      cacheDir: cacheDir,
    );
    expect(path, isNotNull);
    final File out = File(path!);
    expect(out.existsSync(), isTrue);
    expect(out.readAsBytesSync(), <int>[1, 2, 3, 4, 5]);
    expect(out.path.contains('local_audio_'), isTrue);
  });

  test('existing output is reused WITHOUT reopening the DB (skip rewrite)', () {
    final String? first = LocalAudioDb.extractBlob(
      dbPath: dbPath,
      file: 'nhk_001.mp3',
      source: 'NHK',
      cacheDir: cacheDir,
    );
    expect(first, isNotNull);
    final File out = File(first!);
    final DateTime firstModified = out.statSync().modified;

    // Delete the source DB entirely: a correct skip path must NOT touch it.
    File(dbPath).deleteSync();

    final String? second = LocalAudioDb.extractBlob(
      dbPath: dbPath, // gone now
      file: 'nhk_001.mp3',
      source: 'NHK',
      cacheDir: cacheDir,
    );
    // Without the existing-file fast path this would return null (DB missing).
    expect(second, first,
        reason: 'existing cache file must be returned without the DB');
    expect(out.statSync().modified, firstModified,
        reason: 'the file must not be rewritten on the second call');
  });

  test('different (file,source) yields a different cache file', () {
    final String secondDb = makeDb(
      Uint8List.fromList(<int>[9, 8, 7]),
      file: 'jpod_002.mp3',
      source: 'JPod',
    );
    final String? a = LocalAudioDb.extractBlob(
      dbPath: dbPath,
      file: 'nhk_001.mp3',
      source: 'NHK',
      cacheDir: cacheDir,
    );
    final String? b = LocalAudioDb.extractBlob(
      dbPath: secondDb,
      file: 'jpod_002.mp3',
      source: 'JPod',
      cacheDir: cacheDir,
    );
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(a, isNot(b));
  });
}
