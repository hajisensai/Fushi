// 导出 .apkg / 捐赠包的后台 isolate 路径（srs_store_background.dart）：按句柄号在后台重开只读副本导出，
// 包与在当前 isolate 上导出逐条目逐字节相同（媒体按目录在后台重建读取器）。
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/apkg/srs_donation_export.dart';
import 'package:fushi_engine/srs/apkg/srs_export_options.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:test/test.dart';

import 'apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';
const int kVocabNt = 1700000000101;

int ms(int y, int m, int d, [int h = 0]) =>
    DateTime.utc(y, m, d, h).millisecondsSinceEpoch;

Uint8List _ankiApkg() => zipOf(<String, List<int>>{
  'collection.anki21': buildLegacyCollection(
    crtSecs: ms(2026, 1, 1, 4) ~/ 1000,
    conf: <String, Object?>{'rollover': 4, 'localOffset': 0, 'fsrs': true},
    models: <String, Object?>{
      '$kVocabNt': <String, Object?>{
        'id': kVocabNt,
        'name': 'Vocab',
        'type': 0,
        'css': '.x {}',
        'flds': <Object?>[
          <String, Object?>{'name': 'Expression', 'ord': 0},
          <String, Object?>{'name': 'Meaning', 'ord': 1},
        ],
        'tmpls': <Object?>[
          <String, Object?>{
            'name': 'Card 1',
            'ord': 0,
            'qfmt': '{{Expression}}',
            'afmt': '{{FrontSide}}<hr id=answer>{{Meaning}}',
          },
        ],
      },
    },
    decks: <String, Object?>{
      '1': <String, Object?>{'id': 1, 'name': 'Default', 'dyn': 0, 'conf': 1},
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
    },
    notes: <FxNote>[
      for (final (int i, String w) in <String>['猫', '犬'].indexed)
        FxNote(
          id: ms(2026, 8, 1 + i),
          guid: 'anki-$i',
          mid: kVocabNt,
          fields: <String>[w, 'meaning $i'],
          cards: <FxCard>[
            FxCard(
              id: 901 + i,
              ord: 0,
              did: 1,
              type: 2,
              queue: 2,
              due: 300,
              ivl: 3,
              factor: 2500,
              reps: 2,
              revlog: <FxRevlog>[
                FxRevlog(ms(2026, 9, 1 + i, 10), type: 0, ease: 3, ivl: 1),
                FxRevlog(ms(2026, 9, 4 + i, 10), type: 1, ease: 3, ivl: 3),
              ],
            ),
          ],
        ),
    ],
  ),
  'media': '{}'.codeUnits,
});

/// 包里每个条目的字节（按条目名）。
Map<String, List<int>> _entries(File apkg) {
  final Archive zip = ZipDecoder().decodeBytes(apkg.readAsBytesSync());
  return <String, List<int>>{
    for (final ArchiveFile f in zip.files)
      if (f.isFile) f.name: f.content as List<int>,
  };
}

void main() {
  late SrsDbStore s;
  late Directory tmp;
  late SrsMediaStore media;
  late String noteWithPicture;
  late String picturesDeck;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('apkg_bg_');
    media = SrsMediaStore(Directory('${tmp.path}/media'));
    s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => ms(2026, 10, 1, 12),
      localOffsetMin: () => 540,
    );
    await importAnkiPackage(
      store: s,
      bytes: _ankiApkg(),
      storeMedia: (String name, Uint8List b) async => name,
      options: const SrsAnkiImportOptions(
        mergeNoteTypes: true,
        updateNotes: SrsImportUpdateCondition.never,
        updateNoteTypes: SrsImportUpdateCondition.never,
        withScheduling: true,
        withDeckConfigs: true,
      ),
      zstdDecompress: (Uint8List b) => null,
    );
    picturesDeck = await s.createDeck('Pictures');
    noteWithPicture = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      deckId: picturesDeck,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '雪',
        srsLapisFieldId(kProfile, 'Picture'): '<img src="p.png">',
      },
    );
    await media.store('p.png', Uint8List.fromList(<int>[4, 2, 4, 2]));
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('普通导出：后台 isolate 与当前 isolate 出的包逐条目相同（含媒体）', () async {
    const SrsAnkiExportOptions options = SrsAnkiExportOptions(
      withScheduling: true,
      withDeckConfigs: true,
    );
    final File here = File('${tmp.path}/here.apkg');
    final File bg = File('${tmp.path}/bg.apkg');
    await exportAnkiPackageFile(
      store: s,
      file: here,
      loadMedia: media.load,
      options: options,
    );
    await exportAnkiPackageFileInBackground(
      store: s,
      file: bg,
      mediaDirectory: media.root.path,
      options: options,
    );
    final Map<String, List<int>> a = _entries(here);
    final Map<String, List<int>> b = _entries(bg);
    expect(b.keys.toSet(), a.keys.toSet());
    expect(a.length, greaterThan(2), reason: '集合 + 媒体清单 + 至少一个媒体文件');
    for (final String name in a.keys) {
      expect(b[name], a[name], reason: '条目 $name');
    }
    expect(File('${bg.path}.part').existsSync(), isFalse);
  });

  test('只导一个牌组：后台路径与当前 isolate 一样只导子树', () async {
    final File here = File('${tmp.path}/here.apkg');
    final File bg = File('${tmp.path}/bg.apkg');
    await exportAnkiPackageFile(
      store: s,
      file: here,
      deckId: picturesDeck,
      loadMedia: media.load,
    );
    await exportAnkiPackageFileInBackground(
      store: s,
      file: bg,
      deckId: picturesDeck,
      mediaDirectory: media.root.path,
    );
    final Map<String, List<int>> a = _entries(here);
    final Map<String, List<int>> b = _entries(bg);
    expect(b.keys.toSet(), a.keys.toSet());
    for (final String name in a.keys) {
      expect(b[name], a[name], reason: '条目 $name');
    }
  });

  test('捐赠包：后台 isolate 与当前 isolate 出的包逐条目相同', () async {
    final String donorId = srsDonationIdentity(kProfile).donorId;
    final File here = File('${tmp.path}/here.apkg');
    final File bg = File('${tmp.path}/bg.apkg');
    final Set<String> excluded = <String>{noteWithPicture};
    await exportSrsDonationFile(
      store: s,
      file: here,
      donorId: donorId,
      appVersion: '1.2.3',
      excludedNoteIds: excluded,
    );
    await exportSrsDonationFileInBackground(
      store: s,
      file: bg,
      donorId: donorId,
      appVersion: '1.2.3',
      excludedNoteIds: excluded,
    );
    final Map<String, List<int>> a = _entries(here);
    final Map<String, List<int>> b = _entries(bg);
    expect(b.keys.toSet(), a.keys.toSet());
    for (final String name in a.keys) {
      expect(b[name], a[name], reason: '条目 $name');
    }
  });
}
