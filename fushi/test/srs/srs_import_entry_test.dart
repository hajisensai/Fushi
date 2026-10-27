// 导入 / 导出 / 制卡历史导入入口的逻辑部分（绕开文件选择与对话框）：
// - .apkg 导入：媒体经 SrsMediaStore 按内容哈希落盘、字段引用改写；报告翻成人话；
// - 导出 .apkg：FSRS-7 牌组需要提示；导出的包再导回另一个 profile 能还原笔记；
// - 制卡历史导入：Lapis 字段 + 出处，内容派生 guid 保证重复导入不重复。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_import_entry.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mined_history_import.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import '../../../packages/fushi_engine/test/srs/apkg/apkg_test_support.dart';
import 'srs_test_support.dart';

const int _kBasic = 1700000000001;
const int _kDeck = 1700000000010;

Uint8List _apkg() => zipOf(<String, List<int>>{
  'collection.anki21': buildLegacyCollection(
    crtSecs: DateTime.utc(2026, 1, 1, 4).millisecondsSinceEpoch ~/ 1000,
    conf: <String, Object?>{'rollover': 4, 'localOffset': 0, 'fsrs': true},
    models: <String, Object?>{
      '$_kBasic': <String, Object?>{
        'id': _kBasic,
        'name': 'Basic',
        'type': 0,
        'css': '',
        'flds': <Object?>[
          <String, Object?>{'name': 'Front', 'ord': 0, 'id': 111},
          <String, Object?>{'name': 'Back', 'ord': 1, 'id': 222},
        ],
        'tmpls': <Object?>[
          <String, Object?>{
            'name': 'Card 1',
            'ord': 0,
            'qfmt': '{{Front}}',
            'afmt': '{{FrontSide}}<hr id=answer>{{Back}}',
            'id': 333,
          },
        ],
      },
    },
    decks: <String, Object?>{
      '1': <String, Object?>{'id': 1, 'name': 'Default', 'dyn': 0, 'conf': 1},
      '$_kDeck': <String, Object?>{
        'id': _kDeck,
        'name': 'JP',
        'dyn': 0,
        'conf': 2,
      },
    },
    dconf: <String, Object?>{
      '1': <String, Object?>{
        'id': 1,
        'name': 'Default',
        'new': <String, Object?>{
          'delays': <double>[1, 10],
          'perDay': 20,
        },
        'lapse': <String, Object?>{
          'delays': <double>[10],
        },
        'rev': <String, Object?>{'perDay': 200, 'maxIvl': 36500},
      },
      '2': <String, Object?>{
        'id': 2,
        'name': 'JP preset',
        'new': <String, Object?>{
          'delays': <double>[1, 10, 1440],
          'perDay': 15,
        },
        'lapse': <String, Object?>{
          'delays': <double>[10],
        },
        'rev': <String, Object?>{'perDay': 150, 'maxIvl': 3650},
      },
    },
    notes: <FxNote>[
      FxNote(
        id: DateTime.utc(2026, 2, 28).millisecondsSinceEpoch,
        guid: 'g1',
        mid: _kBasic,
        fields: <String>['猫<img src="a.png">', 'cat'],
        cards: <FxCard>[FxCard(id: 11, ord: 0, did: _kDeck, due: 1)],
      ),
    ],
  ),
  'media': utf8.encode(jsonEncode(<String, String>{'0': 'a.png'})),
  '0': <int>[1, 2, 3],
});

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SrsDbStore store;
  late SrsMediaStore media;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_srs_import_');
    (db, store) = await openSrsTestStore();
    media = SrsMediaStore(Directory('${tmp.path}/media'));
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  test('.apkg 导入：媒体按内容哈希落盘、字段引用改写；报告人话列出被截步长', () async {
    final File file = File('${tmp.path}/deck.apkg')..writeAsBytesSync(_apkg());
    final List<double> progress = <double>[];
    final SrsImportReport report = await runSrsAnkiImport(
      store: store,
      media: media,
      file: file,
      // 默认（= Anki）不含预设与排程；这里要看被截步长，打开牌组预设。
      options: const SrsAnkiImportOptions(
        withScheduling: true,
        withDeckConfigs: true,
      ),
      onProgress: progress.add,
      zstdDecompress: (Uint8List b) => null,
    );
    expect(report.notesAdded, 1);
    expect(report.cardsAdded, 1);
    expect(report.mediaStored, 1);
    expect(report.truncatedSteps, isNotEmpty);

    final String stored = SrsMediaStore.contentName('a.png', <int>[1, 2, 3]);
    expect(await media.load(stored), <int>[1, 2, 3]);
    final String noteId = SrsIds.note(kSrsTestProfile, 'g1');
    final String front = SrsIds.field(
      SrsIds.noteType(kSrsTestProfile, _kBasic),
      111,
    );
    expect((await store.note(noteId))!.field(front), '猫<img src="$stored">');

    final List<String> lines = srsImportReportLines(report);
    expect(
      lines.first,
      t.srs_import_report_notes(added: 1, updated: 0, skipped: 0),
    );
    expect(lines, contains(t.srs_import_report_cards(n: 1)));
    expect(lines, contains(t.srs_import_report_media(n: 1)));
    expect(
      lines,
      contains(
        t.srs_import_report_steps_removed(preset: 'JP preset', removed: '1d'),
      ),
    );
    // 开了 FSRS 但预设没有参数：落到默认算法，报告里写明。
    expect(
      lines,
      contains(t.srs_import_report_default_algorithm(preset: 'JP preset')),
    );

    // 再导一次（默认不更新已有笔记）：没有新增。
    final SrsImportReport again = await runSrsAnkiImport(
      store: store,
      media: media,
      file: file,
      zstdDecompress: (Uint8List b) => null,
    );
    expect(again.notesAdded, 0);
    expect(again.notesSkipped, 1);
  });

  test('删掉笔记类型后重导：笔记类型恢复、笔记计恢复且看得见，报告写出恢复的笔记类型', () async {
    final File file = File('${tmp.path}/deck.apkg')..writeAsBytesSync(_apkg());
    await runSrsAnkiImport(
      store: store,
      media: media,
      file: file,
      zstdDecompress: (Uint8List b) => null,
    );
    final String ntId = SrsIds.noteType(kSrsTestProfile, _kBasic);
    await store.deleteNoteType(ntId);
    expect(await store.listNotes(), isEmpty);

    final SrsImportReport report = await runSrsAnkiImport(
      store: store,
      media: media,
      file: file,
      zstdDecompress: (Uint8List b) => null,
    );
    expect(report.notesAdded, 0);
    expect(report.notesRestored, 1);
    expect(report.noteTypesRestored, <String>['Basic']);
    expect(<String>[
      for (final SrsNoteTypeView v in await store.noteTypes()) v.id,
    ], contains(ntId));
    expect(await store.listNotes(), hasLength(1));
    expect(
      srsImportReportLines(report),
      containsAll(<String>[
        t.srs_import_report_restored(n: 1),
        t.srs_import_report_notetypes_restored(name: 'Basic'),
      ]),
    );
  });

  test('带 FSRS 参数导入：报告写明已改用 RWKV；「继续用 FSRS」只切回仍自己管参数的 RWKV 牌组', () async {
    final String imported = await store.createDeck('Imported');
    final String child = await store.createDeck('Child', parentId: imported);
    final String changed = await store.createDeck('User changed');
    await store.editFields(SrsEntityKind.deck, imported, <String, Object?>{
      SrsFieldKeys.deckAlgorithm: <String, Object?>{
        'alg': SrsAlgorithm.rwkv.wire,
        'auto': true,
      },
    });
    await store.editFields(SrsEntityKind.deck, child, <String, Object?>{
      SrsFieldKeys.deckParamsMode: 'inherit',
    });
    // 导入后用户自己在牌组设置里换成了 FSRS-7：不动。
    await store.editFields(SrsEntityKind.deck, changed, <String, Object?>{
      SrsFieldKeys.deckAlgorithm: <String, Object?>{
        'alg': SrsAlgorithm.fsrs7.wire,
        'auto': false,
      },
    });
    final SrsImportReport report = SrsImportReport()
      ..fsrsPresets['JP preset'] = SrsAlgorithm.fsrs6
      ..fsrsDecks.addAll(<String, SrsAlgorithm>{
        imported: SrsAlgorithm.fsrs6,
        child: SrsAlgorithm.fsrs6,
        changed: SrsAlgorithm.fsrs6,
        'gone': SrsAlgorithm.fsrs6,
      });
    expect(
      srsImportReportLines(report),
      contains(t.srs_import_report_fsrs(preset: 'JP preset', alg: 'FSRS-6')),
    );

    expect(await srsKeepImportedDecksOnFsrs(store, report.fsrsDecks), 1);
    final SrsDeckTree tree = await store.deckTree();
    expect(tree[imported]!.localAlgorithm, SrsAlgorithm.fsrs6);
    expect(tree[imported]!.algorithmAuto, isFalse);
    expect(tree.paramsOwner(child).localAlgorithm, SrsAlgorithm.fsrs6);
    expect(tree[changed]!.localAlgorithm, SrsAlgorithm.fsrs7);
    // 再点一次什么也不改。
    expect(await srsKeepImportedDecksOnFsrs(store, report.fsrsDecks), 0);
  });

  test('坏包：抛 SrsImportException（入口据此报失败而不是吞掉）', () async {
    final File file = File(
      '${tmp.path}/bad.apkg',
    )..writeAsBytesSync(zipOf(<String, List<int>>{'media': utf8.encode('{}')}));
    await expectLater(
      runSrsAnkiImport(
        store: store,
        media: media,
        file: file,
        zstdDecompress: (Uint8List b) => null,
      ),
      throwsA(isA<SrsImportException>()),
    );
  });

  test('导出 .apkg：FSRS-7 范围需要提示；导出的包导回另一个 profile 能还原', () async {
    final String noteId = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '雪',
        srsLapisFieldId(kSrsTestProfile, 'Picture'): '<img src="p.png">',
      },
    );
    await media.store('p.png', Uint8List.fromList(<int>[4, 2]));
    final SrsNoteView note = (await store.note(noteId))!;

    expect(await srsExportScopeUsesFsrs7(store), isTrue, reason: '默认算法 FSRS-7');
    final SrsAnkiExport export = await buildSrsAnkiExport(
      store: store,
      media: media,
      file: File('${tmp.path}/out.apkg'),
    );
    expect(export.usesFsrs7, isTrue);
    expect(export.file.lengthSync(), greaterThan(0));

    final (FushiDatabase db2, SrsDbStore other) = await openSrsTestStore(
      profileUid: '01928c3e-0000-7000-8000-0000000000ee',
      deviceId: 'other',
    );
    addTearDown(db2.close);
    final File file = export.file;
    final SrsImportReport back = await runSrsAnkiImport(
      store: other,
      media: SrsMediaStore(Directory('${tmp.path}/media2')),
      file: file,
      zstdDecompress: (Uint8List b) => null,
    );
    expect(back.notesAdded, 1);
    final String? id = await other.noteIdByGuid(note.guid);
    expect(id, isNotNull);
  });

  test('制卡历史导入：Lapis 字段 + 出处；重复导入不重复建卡', () async {
    final int t0 = DateTime.utc(2026, 9, 1).millisecondsSinceEpoch;
    await db
        .into(db.minedSentences)
        .insert(
          MinedSentencesCompanion.insert(
            expression: const Value<String>('雪'),
            reading: const Value<String>('ゆき'),
            glossary: const Value<String>('snow'),
            sentence: const Value<String>('雪が降る。'),
            source: 'book',
            documentTitle: const Value<String?>('Snow Country'),
            bookKey: const Value<String?>('snow-country'),
            sectionIndex: const Value<int?>(2),
            normCharOffset: const Value<int?>(40),
            normCharLength: const Value<int?>(1),
            dateKey: '2026-09-01',
            createdAt: t0,
          ),
        );
    await db
        .into(db.minedSentences)
        .insert(
          MinedSentencesCompanion.insert(
            expression: const Value<String>('雨'),
            reading: const Value<String>('あめ'),
            source: 'video',
            bookKey: const Value<String?>('video/ep1'),
            positionMs: const Value<int?>(5000),
            durationMs: const Value<int?>(1500),
            dateKey: '2026-09-02',
            createdAt: t0 + 1000,
          ),
        );
    await db
        .into(db.minedSentences)
        .insert(
          MinedSentencesCompanion.insert(
            source: 'book',
            dateKey: '2026-09-03',
            createdAt: t0 + 2000,
          ),
        );

    final SrsMinedHistoryImportResult r1 = await importMinedSentencesIntoSrs(
      db: db,
      store: store,
    );
    expect(r1.imported, 2);
    expect(r1.skipped, 1, reason: '词形为空的记录跳过');
    final SrsMinedHistoryImportResult r2 = await importMinedSentencesIntoSrs(
      db: db,
      store: store,
    );
    expect(r2.imported, 0);
    expect(r2.skipped, 3);

    final Map<String, SrsTermStatus> hit = await store.lookupTermStatus(
      const <SrsTermQuery>[SrsTermQuery('雪', 'ゆき'), SrsTermQuery('雨', 'あめ')],
    );
    final SrsNoteView snow = (await store.note(hit['雪']!.noteId))!;
    String f(String key) => snow.field(srsLapisFieldId(kSrsTestProfile, key));
    expect(f('MainDefinition'), 'snow');
    expect(f('Sentence'), '雪が降る。');
    expect(snow.createdAt, t0);
    expect(snow.deckId, store.defaultDeckId);
    expect(snow.source!.kind, SrsSourceKind.book);
    expect(snow.source!.data['bookKey'], 'snow-country');
    expect(snow.source!.data['section'], 2);
    expect(snow.source!.data['start'], 40);

    final SrsNoteView rain = (await store.note(hit['雨']!.noteId))!;
    expect(rain.source!.kind, SrsSourceKind.video);
    expect(rain.source!.data['mediaKey'], 'video/ep1');
    expect(rain.source!.data['startMs'], 5000);
    expect(rain.source!.data['endMs'], 6500);
  });
}
