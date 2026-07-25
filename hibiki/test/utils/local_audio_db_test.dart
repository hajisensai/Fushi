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

  // BUG-779：导入把关。isUsableAudioSource 是唯一真值判据。
  group('isUsableAudioSource', () {
    test('accepts a real audio db (entries + android with a row)', () {
      expect(LocalAudioDb.isUsableAudioSource(dbPath), isTrue);
    });

    test('rejects a non-existent path', () {
      expect(LocalAudioDb.isUsableAudioSource('/no/such/audio.db'), isFalse);
    });

    test('rejects a non-sqlite file (a zip / backup zip / junk)', () {
      final String junk = '${dir.path}/junk.zip';
      // PK\x03\x04 = ZIP 魔数 + 垃圾字节：sqlite3 首个 query 会抛「not a database」。
      File(junk).writeAsBytesSync(
          Uint8List.fromList(<int>[0x50, 0x4b, 0x03, 0x04, 9, 9, 9, 9]));
      expect(LocalAudioDb.isUsableAudioSource(junk), isFalse);
    });

    test('rejects a valid sqlite db that lacks the audio schema', () {
      final String other = '${dir.path}/other.db';
      final Database db = sqlite3.open(other);
      db.execute('CREATE TABLE foo (a TEXT)');
      db.execute("INSERT INTO foo VALUES ('x')");
      db.dispose();
      expect(LocalAudioDb.isUsableAudioSource(other), isFalse);
    });

    test('rejects an audio db whose android table has no rows (empty)', () {
      final String empty = '${dir.path}/empty.db';
      final Database db = sqlite3.open(empty);
      db.execute('CREATE TABLE entries '
          '(expression TEXT, reading TEXT, file TEXT, source TEXT)');
      db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
      db.dispose(); // 结构对但没有任何音频行
      expect(LocalAudioDb.isUsableAudioSource(empty), isFalse);
    });
  });

  test('extractBlob keeps different local audio blobs on different paths', () {
    final Database db = sqlite3.open(dbPath);
    db.execute("INSERT INTO entries VALUES ('other','','b.mp3','src1')");
    final PreparedStatement stmt =
        db.prepare('INSERT INTO android (file, source, data) VALUES (?,?,?)');
    stmt.execute(<Object?>[
      'b.mp3',
      'src1',
      Uint8List.fromList(<int>[8, 7, 6])
    ]);
    stmt.dispose();
    db.dispose();

    final String? first = LocalAudioDb.extractBlob(
      dbPath: dbPath,
      file: 'a.mp3',
      source: 'src1',
      cacheDir: dir,
    );
    final String? second = LocalAudioDb.extractBlob(
      dbPath: dbPath,
      file: 'b.mp3',
      source: 'src1',
      cacheDir: dir,
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(first, isNot(second));
    expect(File(first!).readAsBytesSync(), <int>[1, 2, 3, 4, 5]);
    expect(File(second!).readAsBytesSync(), <int>[8, 7, 6]);
  });

  // 性能/并发根因守卫（索引挪到绑定期）：
  // * 索引由 ensureIndexes 在绑定库列表时一次性补齐（对齐 Android
  //   TtsChannelHandler 的做法），否则 WHERE expression=? 退回全表扫描
  //   （数十万行时每次查词几百 ms＝「查词发音特别慢」）。
  // * 查询路径（queryMeta / extractBlob）必须只读打开、零 DDL——否则与弹窗
  //   独立 isolate 并发时抢 readWrite 句柄，失败被 catch 吞成 null＝「暂无发音」。
  group('index creation lives in ensureIndexes, not the query path', () {
    bool hasIndex(String name) {
      final Database probe = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      try {
        return probe.select(
          "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
          <Object?>[name],
        ).isNotEmpty;
      } finally {
        probe.dispose();
      }
    }

    test('ensureIndexes builds both query indexes and is idempotent', () async {
      expect(hasIndex('idx_entries_expr_read'), isFalse,
          reason: 'setUp 建的库本无索引');
      expect(hasIndex('idx_android_file_source'), isFalse);
      await LocalAudioDb.ensureIndexes(dbPath);
      expect(hasIndex('idx_entries_expr_read'), isTrue,
          reason: 'entries(expression,reading) 索引必须被建，消除全表扫描');
      expect(hasIndex('idx_android_file_source'), isTrue);
      // 幂等：重复调用不抛、索引仍在（CREATE INDEX IF NOT EXISTS）。
      await LocalAudioDb.ensureIndexes(dbPath);
      expect(hasIndex('idx_entries_expr_read'), isTrue);
      expect(hasIndex('idx_android_file_source'), isTrue);
    });

    test('ensureIndexes tolerates a db missing one of the tables', () async {
      final String partial = '${dir.path}/android_only.db';
      final Database db = sqlite3.open(partial);
      db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
      db.dispose();
      await LocalAudioDb.ensureIndexes(partial); // entries 缺失：不抛
      final Database probe = sqlite3.open(partial, mode: OpenMode.readOnly);
      try {
        expect(
          probe.select(
            "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
            <Object?>['idx_android_file_source'],
          ).isNotEmpty,
          isTrue,
          reason: '另一条 DDL 不被缺表的那条牵连',
        );
      } finally {
        probe.dispose();
      }
    });

    test('ensureIndexes on a missing path is a no-op (no throw)', () async {
      await LocalAudioDb.ensureIndexes('${dir.path}/no_such.db');
      await LocalAudioDb.ensureIndexes('');
    });

    test('queryMeta / extractBlob never create indexes (read-only path)', () {
      expect(LocalAudioDb.queryMeta(dbPath, '勉強', 'べんきょう'), isNotNull,
          reason: '无索引的库查询仍必须成功（只是慢）');
      LocalAudioDb.extractBlob(
        dbPath: dbPath,
        file: 'a.mp3',
        source: 'src1',
        cacheDir: dir,
      );
      expect(hasIndex('idx_entries_expr_read'), isFalse,
          reason: '查询路径不得再有任何 DDL：索引只归 ensureIndexes 建');
      expect(hasIndex('idx_android_file_source'), isFalse);
    });

    test('query path succeeds after indexes exist (readOnly still works)',
        () async {
      await LocalAudioDb.ensureIndexes(dbPath);
      expect(LocalAudioDb.queryMeta(dbPath, '勉強', 'べんきょう')?.file, 'a.mp3');
    });
  });
}
