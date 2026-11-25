import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'ankiconnect/ankiconnect_harness.dart';
import 'support/srs_sync2_peers.dart';
import 'support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000d5';

String _dictCss(String dict) => List<String>.generate(
  60,
  (int i) =>
      '.yomitan-glossary [data-dictionary="$dict"] .gloss-sc-$i'
      '{margin:${i}px;color:#${(i * 4099 % 0xffffff).toRadixString(16)};}',
).join('\n');

String _glossary(String word, List<String> dicts) => <String>[
  '<div style="text-align: left;" class="yomitan-glossary"><ol>',
  for (final String d in dicts)
    '<li data-dictionary="$d"><i>($d)</i> <span>$word の意味</span>'
        '<style>${_dictCss(d)}</style></li>',
  '</ol></div>',
].join();

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fushi_srs_style_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String fid(String key) => srsFushiCardFieldId(kProfile, key);

  Future<SrsDbStore> open(
    SrsStorage storage,
    String device, {
    String? styleDir,
  }) => SrsDbStore.open(
    core: storage.core,
    profileUid: kProfile,
    deviceId: device,
    styles: styleDir == null
        ? null
        : SrsStyleStore(Directory(p.join(tmp.path, styleDir))),
  );

  Future<SrsStorage> memDb() => openTestSrsStorage();

  Map<String, String> noteFields(String word, List<String> dicts) =>
      <String, String>{
        fid('Expression'): word,
        fid('MainDefinition'): _glossary(word, dicts.take(1).toList()),
        fid('Glossary'): _glossary(word, dicts),
      };

  Future<String> addNote(SrsDbStore s, String word, List<String> dicts) =>
      s.createNote(
        noteTypeId: s.fushiCardNoteTypeId,
        fieldsById: noteFields(word, dicts),
      );

  Future<(String, String)> render(SrsDbStore s, String noteId) async {
    final SrsCardCacheRow c = (await s.cardsOfNote(
      noteId,
    )).firstWhere((SrsCardCacheRow c) => !c.hidden);
    final SrsRenderedCard r = (await s.renderCard(c.id))!;
    return (r.question, r.answer);
  }

  // 落库形态只有原始通道看得到（对外读一律展开）：新代真相表 `ops` 的操作体（native/fushi_fsrs/src/store/gen4/
  // schema.rs）。协议 3 查的是修改记录表的 JSON 列；新代的 `ops` 还收身份记录（内置笔记类型带整套模板 / CSS，两个库
  // 一样大），所以字节数只数修改记录（种类 2 = Edit），与协议 3 同口径。
  Future<int> editBytes(SrsStorage db) async =>
      db.core
              .debugSelectRaw(
                'SELECT COALESCE(SUM(LENGTH(body)), 0) AS n FROM ops WHERE kind = 2',
              )
              .single['n']!
          as int;

  // 落库形态（对外读一律展开）：内核 `events` 读出的修改记录是不展开的原值，数其中带内联 `<style>` 的条数。以前直接在
  // 新代 `ops` 的操作体上 instr，但够大的操作体本机按 zstd 存（`gen4/pack.rs`），内联样式在压缩字节里查不到，「有一条」
  // 永远数成 0、「没有」恒真。
  Future<int> rawStyleRows(SrsDbStore s) async =>
      (await s.exportAll()).whereType<SrsEditEvent>().where((SrsEditEvent e) {
        final Object? v = e.edit.value;
        return v is String && v.contains('<style>');
      }).length;

  const List<String> dicts = <String>['JMdict', '大辞林', '明鏡'];

  test('落库去重：字段存引用行、样式落共享文件；对外读展开逐字节还原；渲染与去重前一致', () async {
    final SrsStorage plainDb = await memDb();
    final SrsStorage dedupDb = await memDb();
    final SrsDbStore plain = await open(plainDb, 'plain');
    final SrsDbStore s = await open(dedupDb, 'dev', styleDir: 'media');
    final Map<String, String> original = noteFields('雪', dicts);
    final String a = await addNote(plain, '雪', dicts);
    final String b = await addNote(s, '雪', dicts);

    final SrsNoteView stored = (await s.note(b))!;
    final String glossary = stored.field(fid('Glossary'));
    expect(glossary, isNot(contains('<style>')));
    expect(srsStyleRefsIn(glossary), hasLength(3));
    expect(await rawStyleRows(s), 0);
    for (final String name in srsStyleRefsIn(glossary)) {
      expect(File(p.join(tmp.path, 'media', name)).existsSync(), isTrue);
    }
    for (final MapEntry<String, String> f in original.entries) {
      expect(await s.expandStyles(stored.field(f.key)), f.value);
    }
    // 答案面确实带着释义里的词典样式（比较不是空对空）。
    expect((await render(plain, a)).$2, contains(_dictCss('大辞林')));
    expect(await render(s, b), await render(plain, a));
    expect(await editBytes(dedupDb), lessThan(await editBytes(plainDb) ~/ 3));

    // 把原文再写一遍：同值 no-op，不产生修改记录。
    final List<SrsFieldEdit>? written = await s
        .editFields(SrsEntityKind.note, b, <String, Object?>{
          for (final MapEntry<String, String> f in original.entries)
            SrsFieldKeys.noteField(f.key): f.value,
        });
    expect(written, isEmpty);
    await plainDb.close();
    await dedupDb.close();
  });

  test('同步：对端收到引用行 + 媒体同步拿到样式文件后完整还原；两端同值不冲突', () async {
    final SrsLocationStore loc = SrsAssetLocationStore(
      store: LocalDirectoryAssetStore(
        Directory(p.join(tmp.path, 'remote'))..createSync(),
      ),
      profileUid: kProfile,
    );
    final SrsStorage dbA = await memDb();
    final SrsStorage dbB = await memDb();
    final SrsStorage dbC = await memDb();
    final SrsDbStore a = await open(dbA, 'a', styleDir: 'a');
    final SrsDbStore b = await open(dbB, 'b', styleDir: 'b');
    // C 没装样式库（例如旧版本）：原样写内联样式。
    final SrsDbStore c = await open(dbC, 'c');
    final Map<String, String> original = noteFields('雨', dicts);
    final String id = await addNote(a, '雨', dicts);
    Future<void> sync(SrsDbStore s) => srsSyncOnce(s, loc);
    await sync(a);
    expect(
      (await srsSyncMedia(
        location: loc,
        store: a,
        mediaRoot: Directory(p.join(tmp.path, 'a')),
      )).uploaded,
      3,
    );
    // 名字 → 内容的绑定是操作：A 再同步一次，B 才知道这些样式文件是哪份内容。
    await sync(a);
    await sync(b);
    // 媒体还没到：渲染时去掉引用行（不请求相对地址），回读保留引用行。
    final (String q0, String a0) = await render(b, id);
    expect(a0, isNot(contains('_fushi_style_')));
    expect(
      (await srsSyncMedia(
        location: loc,
        store: b,
        mediaRoot: Directory(p.join(tmp.path, 'b')),
      )).downloaded,
      3,
    );
    final SrsNoteView onB = (await b.note(id))!;
    for (final MapEntry<String, String> f in original.entries) {
      expect(await b.expandStyles(onB.field(f.key)), f.value);
    }
    expect(await render(b, id), await render(a, id));
    expect(q0, (await render(b, id)).$1);

    // A（引用行）与 C（内联原文）并发写同一内容：同值，不进待裁决。
    await sync(c);
    final String newGloss = _glossary('雨', <String>['明鏡', 'JMdict']);
    await a.updateNote(
      id,
      fieldsById: <String, String>{fid('Glossary'): newGloss},
    );
    await c.updateNote(
      id,
      fieldsById: <String, String>{fid('Glossary'): newGloss},
    );
    await sync(a);
    await sync(c);
    await sync(b);
    await sync(a);
    for (final SrsDbStore s in <SrsDbStore>[a, b, c]) {
      final SrsNoteView n = (await s.note(id))!;
      expect(n.hasPendingDecision, isFalse);
      expect(
        n.edits[SrsFieldKeys.noteField(fid('Glossary'))]!.conflicted,
        isFalse,
      );
    }
    // 同步 v2：操作不可变，C 发来的内联原文按原样落进 B 的投影（本机写的才在落库前换成引用行）。
    // 存量去重（compactStoredStyles）随协议 3 一起删了（G7-5）。
    expect(await rawStyleRows(b), 1);
    expect(await render(b, id), await render(a, id));
    await dbA.close();
    await dbB.close();
    await dbC.close();
  });

  test('导出 .apkg 自包含（内联样式、不带共享样式文件）；Fushi 回导重新去重', () async {
    final SrsStorage db = await memDb();
    final SrsDbStore s = await open(db, 'dev', styleDir: 'media');
    final Map<String, String> original = noteFields('風', dicts);
    final String id = await addNote(s, '風', dicts);
    final Uint8List pkg = await exportAnkiPackage(
      store: s,
      loadMedia: (String name) async =>
          File(p.join(tmp.path, 'media', name)).readAsBytes(),
    );
    final SrsAnkiPackage parsed = SrsAnkiPackage.open(
      pkg,
      zstd: (Uint8List b) => null,
    );
    final SrsAnkiCollection col = await SrsAnkiCollection.open(
      parsed.collectionBytes,
    );
    final String flds;
    try {
      flds = col.db.select('SELECT flds FROM notes').single['flds'] as String;
    } finally {
      await col.close();
    }
    expect(flds, isNot(contains('_fushi_style_')));
    expect(flds, contains(original[fid('Glossary')]));
    expect(flds, contains(original[fid('MainDefinition')]));
    expect(
      await parsed.mediaBytes(srsStyleMediaName(_dictCss('JMdict'))),
      isNull,
    );

    final SrsStorage db2 = await memDb();
    final SrsDbStore other = await open(db2, 'other', styleDir: 'other');
    await importAnkiPackage(
      store: other,
      bytes: pkg,
      storeMedia: (String name, Uint8List b) async => name,
      zstdDecompress: (Uint8List b) => null,
    );
    final SrsNoteView back = (await other.note(id))!;
    expect(back.field(fid('Glossary')), isNot(contains('<style>')));
    for (final MapEntry<String, String> f in original.entries) {
      expect(await other.expandStyles(back.field(f.key)), f.value);
    }
    expect(await render(other, id), await render(s, id));
    await db.close();
    await db2.close();
  });

  test('导入带引用行 + 共享样式文件的包：按包内文件展开后重新去重', () async {
    final SrsStorage db = await memDb();
    final SrsDbStore s = await open(db, 'dev', styleDir: 'media');
    final Map<String, String> original = noteFields('霧', dicts);
    final String id = await addNote(s, '霧', dicts);
    final Uint8List pkg = await exportAnkiPackage(store: s);
    // 改成「没展开就导出」的形状：字段里是引用行，媒体里带样式文件。
    final Archive zip = ZipDecoder().decodeBytes(pkg);
    final Archive out = Archive();
    final File colFile = File(p.join(tmp.path, 'c.anki21'));
    for (final ArchiveFile f in zip.files) {
      if (f.name == 'collection.anki21') {
        colFile.writeAsBytesSync(f.content as List<int>);
      } else if (f.name != 'media') {
        out.addFile(f);
      }
    }
    final Database raw = sqlite3.open(colFile.path);
    final String flds =
        raw.select('SELECT flds FROM notes').single['flds'] as String;
    final SrsStyleDedup d = srsDedupStyles(flds);
    raw.execute('UPDATE notes SET flds = ?', <Object?>[d.html]);
    raw.dispose();
    final List<int> colBytes = colFile.readAsBytesSync();
    out.addFile(ArchiveFile('collection.anki21', colBytes.length, colBytes));
    final Map<String, String> mediaJson = <String, String>{};
    int i = 0;
    for (final MapEntry<String, String> e in d.styles.entries) {
      final List<int> b = utf8.encode(e.value);
      out.addFile(ArchiveFile('$i', b.length, b));
      mediaJson['$i'] = e.key;
      i++;
    }
    final List<int> m = utf8.encode(jsonEncode(mediaJson));
    out.addFile(ArchiveFile('media', m.length, m));
    final Uint8List legacy = Uint8List.fromList(ZipEncoder().encode(out)!);

    final SrsStorage db2 = await memDb();
    final SrsDbStore other = await open(db2, 'other', styleDir: 'other');
    await importAnkiPackage(
      store: other,
      bytes: legacy,
      storeMedia: (String name, Uint8List b) async => name,
      zstdDecompress: (Uint8List b) => null,
    );
    final SrsNoteView back = (await other.note(id))!;
    for (final MapEntry<String, String> f in original.entries) {
      expect(await other.expandStyles(back.field(f.key)), f.value);
    }
    expect(await rawStyleRows(other), 0);
    await db.close();
    await db2.close();
  });

  test('AnkiConnect：加卡 / 改卡落库去重，notesInfo 原样读回；同内容改卡不产生记录', () async {
    final AcHarness h = await AcHarness.create(
      styles: SrsStyleStore(Directory(p.join(tmp.path, 'ac'))),
    );
    final String gloss = _glossary('食べる', dicts);
    final Map<String, Object?> note = yomitanNote('食べる', reading: 'たべる');
    (note['fields']! as Map<String, Object?>)['Glossary'] = gloss;
    final int nid =
        (await h.ok('addNote', <String, Object?>{'note': note}))! as int;
    final String noteId = (await h.store.noteIdForAnkiNumericId(nid))!;
    final String fieldId = srsLapisFieldId(kAcProfile, 'Glossary');
    expect(
      (await h.store.note(noteId))!.field(fieldId),
      isNot(contains('<style>')),
    );
    Future<String> readBack() async {
      final List<Object?> info =
          (await h.ok('notesInfo', <String, Object?>{
                'notes': <int>[nid],
              }))!
              as List;
      final Map<Object?, Object?> fields =
          (info.single! as Map)['fields']! as Map;
      return (fields['Glossary']! as Map)['value']! as String;
    }

    expect(await readBack(), gloss);
    Future<String> editId() async => (await h.store.note(
      noteId,
    ))!.edits[SrsFieldKeys.noteField(fieldId)]!.live.single.id;
    final String before = await editId();
    await h.ok('updateNoteFields', <String, Object?>{
      'note': <String, Object?>{
        'id': nid,
        'fields': <String, Object?>{'Glossary': gloss},
      },
    });
    expect(await editId(), before, reason: '同内容改卡是 no-op');
    final String gloss2 = _glossary('食べる', <String>['明鏡']);
    await h.ok('updateNoteFields', <String, Object?>{
      'note': <String, Object?>{
        'id': nid,
        'fields': <String, Object?>{'Glossary': gloss2},
      },
    });
    expect(await readBack(), gloss2);
  });
}
