import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:hibiki/src/utils/misc/local_audio_db.dart';

void main() {
  late Directory dir;
  late String dbPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hibiki_local_audio');
    dbPath = '${dir.path}/audio.db';
    final Database db = sqlite3.open(dbPath);
    db.execute(
        'CREATE TABLE entries (expression TEXT, reading TEXT, file TEXT, source TEXT)');
    db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
    db.execute("INSERT INTO entries VALUES ('勉強','べんきょう','a.mp3','src1')");
    final PreparedStatement stmt =
        db.prepare('INSERT INTO android (file, source, data) VALUES (?,?,?)');
    stmt.execute(<Object?>[
      'a.mp3',
      'src1',
      Uint8List.fromList(<int>[1, 2, 3, 4, 5])
    ]);
    stmt.dispose();
    db.dispose();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('extracts the matching blob to an .mp3 file', () {
    final String? path = LocalAudioDb.queryAndExtract(
      dbPaths: <String>[dbPath],
      expression: '勉強',
      reading: 'べんきょう',
      cacheDir: dir,
    );
    expect(path, isNotNull);
    expect(path!.endsWith('.mp3'), isTrue);
    expect(File(path).readAsBytesSync(), <int>[1, 2, 3, 4, 5]);
  });

  test('falls back to an expression-only match when the reading differs', () {
    final String? path = LocalAudioDb.queryAndExtract(
      dbPaths: <String>[dbPath],
      expression: '勉強',
      reading: 'WRONG',
      cacheDir: dir,
    );
    expect(path, isNotNull);
    expect(File(path!).readAsBytesSync(), <int>[1, 2, 3, 4, 5]);
  });

  test('returns null when the expression is absent', () {
    expect(
      LocalAudioDb.queryAndExtract(
        dbPaths: <String>[dbPath],
        expression: 'なし',
        reading: '',
        cacheDir: dir,
      ),
      isNull,
    );
  });

  test('returns null for a non-existent db path without throwing', () {
    expect(
      LocalAudioDb.queryAndExtract(
        dbPaths: <String>['/no/such/audio.db'],
        expression: '勉強',
        reading: '',
        cacheDir: dir,
      ),
      isNull,
    );
  });

  test('listSources returns the distinct sources in the db', () {
    final Database db = sqlite3.open(dbPath);
    db.execute("INSERT INTO entries VALUES ('猫','ねこ','c.mp3','nhk16')");
    db.execute("INSERT INTO entries VALUES ('猫','ねこ','d.mp3','forvo')");
    db.dispose();

    final List<String> sources = LocalAudioDb.listSources(dbPath);
    expect(sources.toSet(), <String>{'src1', 'nhk16', 'forvo'});
  });

  test('queryMeta honors the source priority order', () {
    final Database db = sqlite3.open(dbPath);
    // 同一词在两个来源下都有音频。
    db.execute("INSERT INTO entries VALUES ('猫','ねこ','nhk.mp3','nhk16')");
    db.execute("INSERT INTO entries VALUES ('猫','ねこ','forvo.mp3','forvo')");
    db.dispose();

    // forvo 优先 → 选 forvo
    expect(
      LocalAudioDb.queryMeta(dbPath, '猫', 'ねこ',
          order: <String>['forvo', 'nhk16'])?.source,
      'forvo',
    );
    // nhk16 优先 → 选 nhk16
    expect(
      LocalAudioDb.queryMeta(dbPath, '猫', 'ねこ',
          order: <String>['nhk16', 'forvo'])?.source,
      'nhk16',
    );
  });

  test('queryMeta skips sources absent from order (disabled)', () {
    final Database db = sqlite3.open(dbPath);
    db.execute("INSERT INTO entries VALUES ('猫','ねこ','nhk.mp3','nhk16')");
    db.execute("INSERT INTO entries VALUES ('猫','ねこ','forvo.mp3','forvo')");
    db.dispose();

    // 只启用 nhk16（forvo 禁用，不在 order）→ 即便 forvo 也命中，也只返回 nhk16
    expect(
      LocalAudioDb.queryMeta(dbPath, '猫', 'ねこ', order: <String>['nhk16'])
          ?.source,
      'nhk16',
    );
    // 所有命中来源都不在 order → null
    expect(
      LocalAudioDb.queryMeta(dbPath, '猫', 'ねこ', order: <String>['oald10']),
      isNull,
    );
  });

  test('queryMeta with empty order keeps first-match behavior', () {
    expect(
      LocalAudioDb.queryMeta(dbPath, '勉強', 'べんきょう')?.source,
      'src1',
    );
  });

  test('uses the .opus extension when the file name ends in .opus', () {
    final Database db = sqlite3.open(dbPath);
    db.execute("INSERT INTO entries VALUES ('opusword','','b.opus','src1')");
    final PreparedStatement stmt =
        db.prepare('INSERT INTO android (file, source, data) VALUES (?,?,?)');
    stmt.execute(<Object?>[
      'b.opus',
      'src1',
      Uint8List.fromList(<int>[9, 9, 9])
    ]);
    stmt.dispose();
    db.dispose();

    final String? path = LocalAudioDb.queryAndExtract(
      dbPaths: <String>[dbPath],
      expression: 'opusword',
      reading: '',
      cacheDir: dir,
    );
    expect(path, isNotNull);
    expect(path!.endsWith('.opus'), isTrue);
  });
}
