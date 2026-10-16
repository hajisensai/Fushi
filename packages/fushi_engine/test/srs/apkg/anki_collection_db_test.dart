// BUG-3428：新格式 Anki 集合的 fields / notetypes / decks… 用 COLLATE unicase，
// 读包前不注册该排序规则会在第一条查询报 no such collation sequence。
// 只测「打开集合库 → 读配置表」这一层，不依赖 fushi_fsrs 原生库与 zstd。
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/apkg/anki_collection_db.dart';
import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'apkg_test_support.dart';

Uint8List _schema18Collection() => buildSqlite((Database db) {
  db.execute(legacySchema);
  db.execute(schema18Extra);
  db.execute("INSERT INTO col VALUES (1,0,0,0,18,0,0,0,'','','','','')");
  db.execute("INSERT INTO notetypes VALUES (5000,'Vocab',0,0,?)", <Object?>[
    (PbWriter()..varint(1, 0)).toBytes(),
  ]);
  db.execute("INSERT INTO fields VALUES (5000,1,'Meaning',?)", <Object?>[
    (PbWriter()..varint(9, 9002)).toBytes(),
  ]);
  db.execute("INSERT INTO fields VALUES (5000,0,'Word',?)", <Object?>[
    (PbWriter()..varint(9, 9001)).toBytes(),
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
  db.execute("INSERT INTO tags VALUES ('Verb',0,0,NULL)");
});

void main() {
  test('夹具忠实：裸 sqlite3 打开 schema 18 集合读 fields 报 no such collation', () {
    final Directory dir = Directory.systemTemp.createTempSync('fx_unicase_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final File f = File('${dir.path}${Platform.pathSeparator}c.db')
      ..writeAsBytesSync(_schema18Collection());
    final Database raw = sqlite3.open(f.path, mode: OpenMode.readOnly);
    try {
      expect(
        () => raw.select('SELECT ntid, ord, name, config FROM fields'),
        throwsA(
          isA<SqliteException>().having(
            (SqliteException e) => e.toString(),
            'message',
            contains('no such collation sequence: unicase'),
          ),
        ),
      );
    } finally {
      raw.close();
    }

    final Database db = openAnkiCollectionDb(f.path);
    try {
      expect(
        db
            .select('SELECT name FROM fields ORDER BY ord')
            .map((Row r) => r['name']),
        <String>['Word', 'Meaning'],
      );
      // unicase 下 tags 主键大小写不敏感：与 Anki 一致。
      expect(
        db.select("SELECT tag FROM tags WHERE tag = 'verb'").single['tag'],
        'Verb',
      );
    } finally {
      db.close();
    }
  });

  test('SrsAnkiCollection.open 读得出 schema 18 的笔记类型 / 牌组 / 预设', () async {
    final SrsAnkiCollection col = await SrsAnkiCollection.open(
      _schema18Collection(),
    );
    try {
      expect(col.newSchema, isTrue);
      final SrsAnkiNoteType nt = col.noteTypes[5000]!;
      expect(nt.name, 'Vocab');
      expect(nt.fields.map((SrsAnkiField f) => f.name), <String>[
        'Word',
        'Meaning',
      ]);
      expect(nt.templates.single.name, 'Recognition');
      expect(col.decks[1]!.name, 'Default');
      expect(col.presets.containsKey(1), isTrue);
    } finally {
      await col.close();
    }
  });

  test('unicase 比较：大小写折叠后相等，否则按折叠串定序', () {
    expect(ankiUnicaseCompare('Basic', 'basic'), 0);
    expect(ankiUnicaseCompare('Straße', 'STRASSE'), 0);
    expect(ankiUnicaseCompare('apple', 'Banana'), lessThan(0));
    expect(ankiUnicaseCompare('Banana', 'apple'), greaterThan(0));
    expect(ankiUnicaseCompare(null, null), 0);
    expect(ankiUnicaseCompare(null, 'a'), lessThan(0));

    // 唯一索引按 unicase 判重：与 Anki 一样，Basic / basic 不能并存。
    final Database db = sqlite3.openInMemory();
    try {
      registerAnkiCollations(db);
      db.execute(schema18Extra);
      db.execute("INSERT INTO notetypes VALUES (1,'Basic',0,0,x'')");
      expect(
        () => db.execute("INSERT INTO notetypes VALUES (2,'basic',0,0,x'')"),
        throwsA(isA<SqliteException>()),
      );
    } finally {
      db.close();
    }
  });
}
