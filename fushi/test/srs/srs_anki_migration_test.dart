// 「从 Anki 迁移」逻辑层：两种来源（本机集合快照 / 导出的包）都只经 runSrsAnkiMigration，
// 迁移固定带排程与牌组预设；先迁本机集合、再导同一集合导出的包不出重复；平台能力判据。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_anki_migration_page.dart';
import 'package:fushi/src/srs/srs_anki_migration.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import '../../../packages/fushi_engine/test/srs/apkg/apkg_test_support.dart';
import 'srs_test_support.dart';

const int _kBasic = 1700000000001;
const int _kDeck = 1700000000010;

Uint8List _collection() => buildLegacyCollection(
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
      'conf': 1,
    },
  },
  dconf: <String, Object?>{
    '1': <String, Object?>{
      'id': 1,
      'name': 'JP preset',
      'new': <String, Object?>{
        'delays': <double>[1, 10],
        'perDay': 7,
      },
      'lapse': <String, Object?>{
        'delays': <double>[10],
      },
      'rev': <String, Object?>{'perDay': 200, 'maxIvl': 36500},
    },
  },
  notes: <FxNote>[
    FxNote(
      id: DateTime.utc(2026, 2, 28).millisecondsSinceEpoch,
      guid: 'g1',
      mid: _kBasic,
      fields: <String>['猫<img src="a.png">', 'cat'],
      cards: <FxCard>[
        FxCard(
          id: 11,
          ord: 0,
          did: _kDeck,
          type: 2,
          queue: 2,
          due: 70,
          ivl: 10,
          factor: 2500,
          reps: 1,
          data: '{"s":12.5,"d":5.1}',
          revlog: <FxRevlog>[
            FxRevlog(
              DateTime.utc(2026, 3, 1, 10).millisecondsSinceEpoch,
              type: 1,
              ease: 3,
              ivl: 10,
            ),
          ],
        ),
      ],
    ),
  ],
);

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SrsDbStore store;
  late SrsMediaStore media;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_srs_migrate_');
    (db, store) = await openSrsTestStore();
    media = SrsMediaStore(Directory('${tmp.path}/media'));
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放。
    }
  });

  test('迁移选项：带排程与复习记录、带牌组预设', () {
    expect(kSrsAnkiMigrationOptions.withScheduling, isTrue);
    expect(kSrsAnkiMigrationOptions.withDeckConfigs, isTrue);
    expect(kSrsAnkiMigrationOptions.mergeNoteTypes, isFalse);
  });

  test('本机集合：快照 → 迁移（排程 / 日志 / 媒体 / 预设）；再导同一集合的包不出重复', () async {
    final Directory profile = Directory('${tmp.path}/Anki2/User 1')
      ..createSync(recursive: true);
    final File col = File('${profile.path}/collection.anki2')
      ..writeAsBytesSync(_collection());
    final Directory mediaDir = Directory('${profile.path}/collection.media')
      ..createSync();
    File('${mediaDir.path}/a.png').writeAsBytesSync(<int>[1, 2, 3]);

    final AnkiDiscovery found = await discoverAnkiProfiles(<AnkiDataRoot>[
      AnkiDataRoot('${tmp.path}/Anki2', AnkiDataRootKind.desktop),
    ]);
    expect(found.profiles.single.name, 'User 1');

    final AnkiCollectionSnapshot snap = await snapshotAnkiCollection(
      collection: found.profiles.single.collection,
      mediaDir: found.profiles.single.mediaDir,
      tempParent: Directory('${tmp.path}/work'),
    );
    final List<double> progress = <double>[];
    final SrsImportReport report;
    try {
      expect(snap.stats.notes, 1);
      expect(snap.stats.reviews, 1);
      report = await runSrsAnkiMigration(
        store: store,
        media: media,
        source: SrsAnkiMigrationFromCollection(snap),
        onProgress: progress.add,
      );
    } finally {
      await snap.discard();
    }
    expect(report.notesAdded, 1);
    expect(report.cardsAdded, 1);
    expect(report.reviewLogsImported, 1);
    expect(report.mediaStored, 1);
    expect(progress.last, 1);

    final String stored = SrsMediaStore.contentName('a.png', <int>[1, 2, 3]);
    expect(await media.load(stored), <int>[1, 2, 3]);
    final String nt = SrsIds.noteType(kSrsTestProfile, _kBasic);
    final String noteId = SrsIds.note(kSrsTestProfile, 'g1');
    expect(
      (await store.note(noteId))!.field(SrsIds.field(nt, 111)),
      '猫<img src="$stored">',
    );
    final String cardId = SrsIds.card(noteId, SrsIds.template(nt, 333), 0);
    final SrsCardCacheRow card = (await store.cardRow(cardId))!;
    expect(card.queue, SrsQueue.review.wire);
    expect(card.dueDay, srsDateToDay(2026, 1, 1) + 70);
    final SrsDeckTree tree = await store.deckTree();
    final SrsDeckView jp = tree.decks.firstWhere(
      (SrsDeckView d) => tree.fullName(d.id) == 'JP',
    );
    expect(jp.newPerDay, 7, reason: '迁移带牌组预设');

    // 用户之后又在 Anki 里导出了 .colpkg 再导一次：身份只由来源决定，不重复。
    final File colpkg = File('${tmp.path}/all.colpkg')
      ..writeAsBytesSync(
        zipOf(<String, List<int>>{
          'collection.anki2': col.readAsBytesSync(),
          'media': utf8.encode(jsonEncode(<String, String>{'0': 'a.png'})),
          '0': <int>[1, 2, 3],
        }),
      );
    final SrsImportReport again = await runSrsAnkiMigration(
      store: store,
      media: media,
      source: SrsAnkiMigrationFromPackage(colpkg),
    );
    expect(again.notesAdded, 0);
    expect(again.cardsAdded, 0);
    expect((await store.history(cardId)).all, hasLength(2), reason: '日志 + 锚点');
  });

  test('平台能力：桌面三端与 Android 能扫本机，iOS 只能选文件', () {
    for (final String os in <String>['windows', 'macos', 'linux', 'android']) {
      expect(srsAnkiMigrationCanScan(os), isTrue, reason: os);
    }
    expect(srsAnkiMigrationCanScan('ios'), isFalse);
  });

  test('快照失败的每种原因都有各自的提示', () {
    final Set<String> texts = <String>{
      for (final AnkiSnapshotFailure r in AnkiSnapshotFailure.values)
        srsAnkiSnapshotErrorText(r),
    };
    expect(texts, hasLength(AnkiSnapshotFailure.values.length));
    expect(
      srsAnkiSnapshotErrorText(AnkiSnapshotFailure.changedDuringCopy),
      t.srs_anki_migrate_error_changed,
    );
  });
}
