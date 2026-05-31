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
