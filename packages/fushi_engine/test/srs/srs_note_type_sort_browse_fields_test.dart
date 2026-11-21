// 笔记类型的排序字段（Anki `sortf`）与浏览副字段（应用内反馈 0n_h51OOE-：第三方牌组第一个字段不是单词，浏览
// 预览固定放大第一个字段就乱了）：浏览行的主字段 / 副字段跟笔记类型设置走；删字段时设置跟着收拾；克隆带过去；
// Anki 导入取来源的 sortf，导出写回 sortf。
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000d7';
const int kMid = 1700000000123;
const int kDeck = 1700000000010;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 11, 21, 12).millisecondsSinceEpoch;

  setUp(() => t = DateTime.utc(2026, 11, 21, 12).millisecondsSinceEpoch);

  Future<SrsDbStore> open() =>
      openTestStore(profileUid: kProfile, deviceId: 'a', now: () => t);

  Future<List<SrsBrowseRow>> rows(SrsDbStore s) async {
    final SrsBrowseSession b = SrsBrowseSession(s);
    try {
      return await (await b.query(
        query: '',
        sort: const SrsBrowseSort(
          column: SrsBrowseSortColumn.created,
          ascending: true,
        ),
        mode: SrsBrowseMode.notes,
      )).all();
    } finally {
      await b.close();
    }
  }

  /// 字段 Id / Word / Meaning / Extra 的自建类型 + 一条笔记；返回 (类型 id, 字段名 → id)。
  Future<(String, Map<String, String>)> seed(SrsDbStore s) async {
    final String typeId = await s.createStockNoteType(
      SrsStockNoteType.basic,
      'Deck pack',
    );
    final Map<String, String> ids = <String, String>{};
    final SrsNoteTypeView v = (await s.noteType(typeId))!;
    await s.renameField(typeId, v.fields[0].id, 'Id');
    await s.renameField(typeId, v.fields[1].id, 'Word');
    ids['Id'] = v.fields[0].id;
    ids['Word'] = v.fields[1].id;
    ids['Meaning'] = await s.addField(typeId, 'Meaning');
    ids['Extra'] = await s.addField(typeId, 'Extra');
    t += 1000;
    await s.createNote(
      noteTypeId: typeId,
      fieldsById: <String, String>{
        ids['Id']!: '0042',
        ids['Word']!: '<b>猫</b>',
        ids['Meaning']!: 'cat',
        ids['Extra']!: 'n5',
      },
    );
    return (typeId, ids);
  }

  test('默认：主字段 = 第一个字段，副字段 = 之后的前两个非空字段', () async {
    final SrsDbStore s = await open();
    final (String typeId, Map<String, String> ids) = await seed(s);
    final SrsNoteTypeView v = (await s.noteType(typeId))!;
    expect(v.sortFieldId, isNull);
    expect(v.effectiveSortFieldId, ids['Id']);
    expect(v.browseFieldIds, isNull);
    final SrsBrowseRow r = (await rows(s)).single;
    expect(r.sortText, '0042');
    expect(r.fieldPreview, <String>['猫', 'cat']);
    expect(r.fieldPreviewNames, <String>['Word', 'Meaning']);
  });

  test('设排序字段：主字段换成它，自动副字段跳过它；排序字段排序列也跟着', () async {
    final SrsDbStore s = await open();
    final (String typeId, Map<String, String> ids) = await seed(s);
    await s.setSortField(typeId, ids['Word']);
    final SrsNoteTypeView v = (await s.noteType(typeId))!;
    expect(v.sortFieldId, ids['Word']);
    expect(v.effectiveSortFieldId, ids['Word']);
    final SrsBrowseRow r = (await rows(s)).single;
    expect(r.sortText, '猫');
    expect(r.fieldPreview, <String>['0042', 'cat']);

    // 清回去：第一个字段。
    await s.setSortField(typeId, null);
    expect((await rows(s)).single.sortText, '0042');
  });

  test('选副字段：按字段顺序只露出选的（最多 2 个）；删字段时两项设置都收拾', () async {
    final SrsDbStore s = await open();
    final (String typeId, Map<String, String> ids) = await seed(s);
    await s.setSortField(typeId, ids['Word']);
    await s.setBrowseFields(typeId, <String>[ids['Extra']!, ids['Meaning']!]);
    SrsNoteTypeView v = (await s.noteType(typeId))!;
    expect(v.browseFieldIds, <String>[ids['Meaning']!, ids['Extra']!]);
    SrsBrowseRow r = (await rows(s)).single;
    expect(r.sortText, '猫');
    expect(r.fieldPreview, <String>['cat', 'n5']);
    expect(r.fieldPreviewNames, <String>['Meaning', 'Extra']);

    await s.deleteField(typeId, ids['Extra']!);
    await s.deleteField(typeId, ids['Word']!);
    v = (await s.noteType(typeId))!;
    expect(v.sortFieldId, isNull, reason: '删了排序字段：显式设置清掉');
    expect(v.effectiveSortFieldId, ids['Id']);
    expect(v.browseFieldIds, <String>[ids['Meaning']!]);
    r = (await rows(s)).single;
    expect(r.sortText, '0042');
    expect(r.fieldPreview, <String>['cat']);
  });

  test('选过的副字段一个都不剩（删掉 / 选成了排序字段）：回到自动，不变成「不显示副字段」', () async {
    final SrsDbStore s = await open();
    final (String typeId, Map<String, String> ids) = await seed(s);
    await s.setBrowseFields(typeId, <String>[ids['Word']!]);
    await s.setSortField(typeId, ids['Word']);
    SrsNoteTypeView v = (await s.noteType(typeId))!;
    expect(v.browseFieldIds, isNull, reason: '唯一的副字段成了排序字段');
    SrsBrowseRow r = (await rows(s)).single;
    expect(r.fieldPreview, <String>['0042', 'cat']);

    await s.setSortField(typeId, null);
    await s.setBrowseFields(typeId, <String>[ids['Meaning']!]);
    await s.deleteField(typeId, ids['Meaning']!);
    v = (await s.noteType(typeId))!;
    expect(v.browseFieldIds, isNull, reason: '删了唯一的副字段');
    expect(v.edits[SrsFieldKeys.browseFields]?.value, isNull);
    r = (await rows(s)).single;
    expect(r.fieldPreview, <String>['猫', 'n5']);
  });

  test('克隆笔记类型：排序字段与副字段指向克隆出的对应字段', () async {
    final SrsDbStore s = await open();
    final (String typeId, Map<String, String> ids) = await seed(s);
    await s.setSortField(typeId, ids['Word']);
    await s.setBrowseFields(typeId, <String>[ids['Extra']!]);
    final String cloneId = await s.cloneNoteType(typeId, 'Copy');
    final SrsNoteTypeView c = (await s.noteType(cloneId))!;
    String nameOf(String? id) => c.fieldById(id!)!.name;
    expect(nameOf(c.sortFieldId), 'Word');
    expect(
      <String>[for (final String id in c.browseFieldIds!) nameOf(id)],
      <String>['Extra'],
    );
  });

  test('排序字段与副字段是设置类（最后修改生效、不按内容冲突）', () {
    expect(
      srsFieldClassOf(SrsEntityKind.noteType, SrsFieldKeys.sortField),
      SrsFieldClass.setting,
    );
    expect(
      srsFieldClassOf(SrsEntityKind.noteType, SrsFieldKeys.browseFields),
      SrsFieldClass.setting,
    );
  });

  Uint8List apkg({required int sortf}) => zipOf(<String, List<int>>{
    'collection.anki21': buildLegacyCollection(
      crtSecs: DateTime.utc(2026).millisecondsSinceEpoch ~/ 1000,
      conf: <String, Object?>{'rollover': 4, 'localOffset': 0},
      models: <String, Object?>{
        '$kMid': <String, Object?>{
          'id': kMid,
          'name': 'Egg roll',
          'type': 0,
          'css': '',
          'sortf': sortf,
          'flds': <Object?>[
            for (final (int i, String n) in <String>[
              'Id',
              'Word',
              'Meaning',
            ].indexed)
              <String, Object?>{'name': n, 'ord': i, 'id': 9000 + i},
          ],
          'tmpls': <Object?>[
            <String, Object?>{
              'name': 'Card 1',
              'ord': 0,
              'qfmt': '{{Word}}',
              'afmt': '{{Meaning}}',
              'id': 9100,
            },
          ],
        },
      },
      decks: <String, Object?>{
        '1': <String, Object?>{'id': 1, 'name': 'Default', 'dyn': 0, 'conf': 1},
        '$kDeck': <String, Object?>{
          'id': kDeck,
          'name': 'Egg',
          'dyn': 0,
          'conf': 1,
        },
      },
      dconf: <String, Object?>{
        '1': <String, Object?>{'id': 1, 'name': 'Default'},
      },
      notes: <FxNote>[
        FxNote(
          id: 1700000001000,
          guid: 'g0',
          mid: kMid,
          fields: const <String>['0001', '犬', 'dog'],
          cards: <FxCard>[FxCard(id: 100, ord: 0, did: kDeck)],
        ),
      ],
    ),
    'media': utf8.encode('{}'),
  });

  Future<SrsImportReport> imp(SrsDbStore s, Uint8List bytes) =>
      importAnkiPackage(
        store: s,
        bytes: bytes,
        storeMedia: (String n, Uint8List b) async => 'h_$n',
        options: const SrsAnkiImportOptions(),
        zstdDecompress: (Uint8List b) => null,
      );

  test('Anki 导入取来源 sortf；本机设过的不被重导覆盖；导出写回 sortf', () async {
    final SrsDbStore s = await open();
    await imp(s, apkg(sortf: 1));
    final String typeId = s.kernelIds.noteType(kMid);
    SrsNoteTypeView v = (await s.noteType(typeId))!;
    expect(v.fieldById(v.sortFieldId!)!.name, 'Word');
    final SrsBrowseRow r = (await rows(s)).single;
    expect(r.sortText, '犬');
    expect(r.fieldPreview, <String>['0001', 'dog']);

    // 导出：sortf 指向生效的排序字段。
    final SrsAnkiPackage pkg = SrsAnkiPackage.open(
      await exportAnkiPackage(store: s),
      zstd: (Uint8List b) => null,
    );
    final SrsAnkiCollection col = await SrsAnkiCollection.open(
      pkg.collectionBytes,
    );
    try {
      final SrsAnkiNoteType egg = col.noteTypes.values.singleWhere(
        (SrsAnkiNoteType n) => n.name == 'Egg roll',
      );
      expect(egg.sortFieldOrd, 1);
    } finally {
      await col.close();
    }

    // 本机改选过（清回第一个字段）：重导不覆盖。
    await s.setSortField(typeId, null);
    t += 1000;
    await imp(s, apkg(sortf: 1));
    v = (await s.noteType(typeId))!;
    expect(v.sortFieldId, isNull);
    expect((await rows(s)).single.sortText, '0001');
  });
}
