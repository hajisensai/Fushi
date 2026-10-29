// 笔记引用的媒体（srs.db schema v4 的 srs_notes_cache.media_refs，缓存修订号 3）：
// srsReferencedMedia 读这一列而不再解析全部字段值；新建 / 改字段 / 删除 / 存量样式去重改写字段后
// 都随笔记缓存刷新；老库（修订号 < 3）打开时补齐。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000de';

/// 与 srs_style_dedup_test 同形的 Yomitan 释义（每本词典一段内联样式，够大才会被换成共享样式文件）。
String _glossary(String word, List<String> dicts) => <String>[
  '<div style="text-align: left;" class="yomitan-glossary"><ol>',
  for (final String d in dicts)
    '<li data-dictionary="$d"><i>($d)</i> <span>$word の意味</span><style>'
        '${List<String>.generate(60, (int i) => '.yomitan-glossary [data-dictionary="$d"] .gloss-sc-$i{margin:${i}px;}').join('\n')}'
        '</style></li>',
  '</ol></div>',
].join();

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late SrsStorage st;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_srs_media_refs_');
    st = await openTestSrsStorage();
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  });

  Future<SrsDbStore> open({String? styleDir}) => SrsDbStore.open(
    db: st.db,
    core: st.core,
    profileUid: kProfile,
    deviceId: 'dev',
    styles: styleDir == null
        ? null
        : SrsStyleStore(Directory(p.join(tmp.path, styleDir))),
  );

  String lapis(String key) => srsLapisFieldId(kProfile, key);

  test('字段里的 <img> 与 [sound:] 进引用集；改字段去掉、删笔记后都不再算', () async {
    final SrsDbStore s = await open();
    final String n = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        lapis('Expression'): '猫',
        lapis('Picture'): '<img src="a.png">',
        lapis('ExpressionAudio'): '[sound:b.mp3]',
      },
    );
    final String keep = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        lapis('Expression'): '犬',
        lapis('Picture'): '<img src="c.png">',
      },
    );
    expect(
      await srsReferencedMedia(s),
      containsAll(<String>['a.png', 'b.mp3']),
    );
    expect(await srsReferencedMedia(s), contains('c.png'));

    await s.updateNote(
      n,
      fieldsById: <String, String>{
        lapis('Picture'): '',
        lapis('ExpressionAudio'): '[sound:b.mp3]',
      },
    );
    Set<String> refs = await srsReferencedMedia(s);
    expect(refs, isNot(contains('a.png')));
    expect(refs, contains('b.mp3'));

    await s.deleteNote(n);
    refs = await srsReferencedMedia(s);
    expect(refs, isNot(contains('b.mp3')), reason: '已删除的笔记不算当前引用');
    expect(refs, contains('c.png'), reason: '别的笔记不受影响');
    expect((await s.note(keep))!.deletedAt, isNull);
  });

  test('存量样式去重改写字段后，共享样式文件名进引用集', () async {
    const List<String> dicts = <String>['JMdict', '大辞林'];
    final SrsDbStore plain = await open();
    final String fid = srsFushiCardFieldId(kProfile, 'Glossary');
    final String n = await plain.createNote(
      noteTypeId: plain.fushiCardNoteTypeId,
      fieldsById: <String, String>{
        srsFushiCardFieldId(kProfile, 'Expression'): '雪',
        fid: _glossary('雪', dicts),
      },
    );
    expect((await plain.note(n))!.field(fid), contains('<style>'));

    final SrsDbStore s = await open(styleDir: 'media');
    expect(await s.compactStoredStyles(), greaterThan(0));
    final String stored = (await s.note(n))!.field(fid);
    expect(stored, isNot(contains('<style>')));
    final Set<String> styleFiles = srsStyleRefsIn(stored);
    expect(styleFiles, hasLength(dicts.length));
    expect(await srsReferencedMedia(s), containsAll(styleFiles));
  });

  test('老库（缓存修订号 2、media_refs 为空）打开时补齐', () async {
    final SrsDbStore s = await open();
    await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        lapis('Expression'): '猫',
        lapis('Picture'): '<img src="a.png">',
        lapis('ExpressionAudio'): '[sound:b.mp3]',
      },
    );
    final Set<String> want = await srsReferencedMedia(s);
    expect(want, containsAll(<String>['a.png', 'b.mp3']));

    await st.db.customStatement("UPDATE srs_notes_cache SET media_refs = ''");
    await st.db.customStatement(
      "UPDATE srs_local_state SET json = json_set(json, '\$.cacheRev', 2)",
    );
    expect(await srsReferencedMedia(s), isNot(contains('a.png')));

    final SrsDbStore reopened = await open();
    expect(await srsReferencedMedia(reopened), want);
    final String json =
        (await st.db
                .customSelect('SELECT json FROM srs_local_state')
                .getSingle())
            .read<String>('json');
    expect((jsonDecode(json) as Map)['cacheRev'], 7);
  });
}
