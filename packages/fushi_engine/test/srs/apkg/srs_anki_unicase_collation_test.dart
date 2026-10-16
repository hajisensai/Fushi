// BUG-3417：真实 Anki schema 18 的 notetypes / fields / templates / decks / config
// 把名字列声明成 `COLLATE unicase`。导入方不注册这条排序规则时，SQLite 在 prepare
// `SELECT ... FROM fields` 就报 「no such collation sequence: unicase」。

import 'dart:typed_data';

import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'apkg_test_support.dart';

/// 照 Anki rslib schema 15+ 的 DDL（名字列带 COLLATE unicase + 唯一索引）。
const String _ankiSchema18Unicase = '''
CREATE TABLE notetypes (id integer NOT NULL PRIMARY KEY,
  name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL,
  usn integer NOT NULL, config blob NOT NULL);
CREATE UNIQUE INDEX idx_notetypes_name ON notetypes (name);
CREATE TABLE fields (ntid integer NOT NULL, ord integer NOT NULL,
  name text NOT NULL COLLATE unicase, config blob NOT NULL,
  PRIMARY KEY (ntid, ord)) without rowid;
CREATE UNIQUE INDEX idx_fields_name_ntid ON fields (name, ntid);
CREATE TABLE templates (ntid integer NOT NULL, ord integer NOT NULL,
  name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL,
  usn integer NOT NULL, config blob NOT NULL, PRIMARY KEY (ntid, ord)) without rowid;
CREATE UNIQUE INDEX idx_templates_name_ntid ON templates (name, ntid);
CREATE TABLE decks (id integer PRIMARY KEY NOT NULL,
  name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL,
  usn integer NOT NULL, common blob NOT NULL, kind blob NOT NULL);
CREATE UNIQUE INDEX idx_decks_name ON decks (name);
CREATE TABLE deck_config (id integer PRIMARY KEY NOT NULL,
  name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL,
  usn integer NOT NULL, config blob NOT NULL);
CREATE TABLE config (KEY text NOT NULL PRIMARY KEY COLLATE unicase,
  usn integer NOT NULL, mtime_secs integer NOT NULL, val blob NOT NULL) without rowid;
''';

Uint8List _buildUnicaseCollection() => buildSqlite((Database db) {
  // 造库这一侧扮演 Anki：它自己注册了 unicase。
  db.createCollation(name: 'unicase', function: ankiUnicaseCompare);
  db.execute(legacySchema);
  db.execute(_ankiSchema18Unicase);
  db.execute("INSERT INTO col VALUES (1,0,0,0,18,0,0,0,'','','','','')");
  db.execute("INSERT INTO notetypes VALUES (5000,'Vocab',0,0,?)", <Object?>[
    (PbWriter()..varint(1, 0)).toBytes(),
  ]);
  db.execute("INSERT INTO fields VALUES (5000,0,'Word',?)", <Object?>[
    (PbWriter()..varint(9, 9001)).toBytes(),
  ]);
  db.execute("INSERT INTO fields VALUES (5000,1,'Meaning',?)", <Object?>[
    (PbWriter()..varint(9, 9002)).toBytes(),
  ]);
  db.execute(
    "INSERT INTO templates VALUES (5000,0,'Recognition',0,0,?)",
    <Object?>[
      (PbWriter()
            ..string(1, '{{Word}}')
            ..string(2, '{{Meaning}}'))
          .toBytes(),
    ],
  );
  db.execute("INSERT INTO decks VALUES (1,'Default',0,0,x'',?)", <Object?>[
    (PbWriter()..message(1, PbWriter()..varint(1, 1))).toBytes(),
  ]);
  db.execute("INSERT INTO deck_config VALUES (1,'Default',0,0,?)", <Object?>[
    (PbWriter()..packedFloats(1, <double>[1, 10])).toBytes(),
  ]);
});

void main() {
  test('schema 18 名字列带 COLLATE unicase 的集合能打开并读出笔记类型 / 牌组', () async {
    final SrsAnkiCollection col = await SrsAnkiCollection.open(
      _buildUnicaseCollection(),
    );
    try {
      expect(col.newSchema, isTrue);
      final SrsAnkiNoteType? vocab = col.noteTypes[5000];
      expect(vocab, isNotNull);
      expect(vocab!.fields.map((SrsAnkiField f) => f.name), <String>[
        'Word',
        'Meaning',
      ]);
      expect(col.decks[1]?.name, 'Default');
      // 走一次真正用到排序规则的比较：按名字（忽略大小写）查得到。
      expect(
        col.db.select("SELECT ord FROM fields WHERE name = 'word'"),
        hasLength(1),
      );
    } finally {
      await col.close();
    }
  });

  test('ankiUnicaseCompare：只差大小写视为相等，其余按字典序', () {
    expect(ankiUnicaseCompare('Front', 'front'), 0);
    expect(ankiUnicaseCompare('Ä', 'ä'), 0);
    expect(ankiUnicaseCompare('a', 'B'), lessThan(0));
    expect(ankiUnicaseCompare('b', 'A'), greaterThan(0));
    expect(ankiUnicaseCompare(null, null), 0);
    expect(ankiUnicaseCompare(null, 'a'), lessThan(0));
  });
}
