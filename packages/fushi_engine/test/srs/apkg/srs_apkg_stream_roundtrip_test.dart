// .apkg 流式导出 / 按文件导入（BUG-3734）：
// - 导出到文件 → 按文件导入到另一份库，笔记 / 卡片 / 日志 / 牌组 / 媒体逐字段一致；
// - 已有笔记重导入：写入攒批落库，事务数与笔记数无关；
// - 新格式 collection.anki21b 经排程内核文件到文件解 zstd。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_bulk_fixture.dart';
import '../support/srs_query_counter.dart';
import '../support/srs_test_storage.dart';
import 'apkg_test_support.dart';
import 'srs_apkg_import_test.dart'
    show
        crtSecs,
        kFullOptions,
        legacyDconf,
        legacyDecks,
        legacyModels,
        fixtureNotes;

/// 测试临时目录（用完删）。
Directory _tmp() {
  final Directory d = Directory.systemTemp.createTempSync('srs_stream_');
  addTearDown(() {
    try {
      d.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  });
  return d;
}

/// 一份空库（与 [BulkFixture] 同 profile、同固定时钟）。
Future<(SrsDbStore, CountingInterceptor)> _emptyStore(String deviceId) async {
  final CountingInterceptor counter = CountingInterceptor();
  final Directory dir = _tmp();
  final TestSrs srs = await openTestSrsAt(
    '${dir.path}/srs.db',
    interceptor: counter,
  );
  final SrsDbStore store = await SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: kBulkUid,
    deviceId: deviceId,
    engine: const FakeFsrsEngine(),
    trustedClock: fixedTrustedClock(),
    fallbackRolloverHour: () => 4,
  );
  return (store, counter);
}

/// 一份库里与写入者 / 本机无关的物化内容：笔记（字段、标签、首选牌组、出处、删除态）、
/// 卡片缓存行、全部日志、牌组全名与设置。
Future<Map<String, Object?>> _materialized(SrsDbStore s) async {
  final SrsDeckTree tree = await s.deckTree();
  final List<String> noteIds = (await s.entityIds(SrsEntityKind.note)).toList()
    ..sort();
  final Map<String, SrsNoteView?> notes = await s.notes(noteIds);
  final Map<String, List<String>> dump = await dumpSrsState(s.db);
  String deckName(String? id) => id == null
      ? '-'
      : tree[id] == null
      ? id
      : tree.fullName(id);
  return <String, Object?>{
    'notes': <String>[
      for (final String id in noteIds)
        <Object?>[
          id,
          notes[id]!.guid,
          notes[id]!.noteTypeId,
          notes[id]!.createdAt,
          deckName(notes[id]!.deckId),
          notes[id]!.deletedAt,
          notes[id]!.tags,
          notes[id]!.source?.toJson(),
          <String, String>{
            for (final SrsFieldDef f in (await s.noteType(
              notes[id]!.noteTypeId,
            ))!.fields)
              f.name: notes[id]!.field(f.id),
          },
        ].toString(),
    ],
    // 缓存行里的牌组 ID 换成全名（两份库的默认牌组 ID 各自派生）。
    'cards': <String>[
      for (final SrsCardCacheRow c
          in await (s.db.select(s.db.srsCardsCache)
                ..orderBy(<OrderClauseGenerator<$SrsCardsCacheTable>>[
                  ($SrsCardsCacheTable t) => OrderingTerm(expression: t.id),
                ]))
              .get())
        <Object?>[
          c.id,
          c.noteId,
          c.templateId,
          c.clozeOrd,
          deckName(c.deckId),
          c.suspended,
          c.buriedUntilDay,
          c.flag,
          c.hidden,
          c.queue,
          c.dueDay,
          c.dueAt,
          c.scheduledDays,
          c.reps,
          c.lapses,
          c.stability,
          c.difficulty,
          c.lastReviewedAt,
          c.lastLogId,
        ].toString(),
    ],
    'logs': dump['logs'],
    'decks': <String>[
      for (final SrsDeckView d in tree.decks)
        <Object?>[
          tree.fullName(d.id),
          d.newPerDay,
          d.reviewsPerDay,
          d.learnSteps,
          d.relearnSteps,
          d.desiredRetention,
          d.maxIntervalDays,
        ].toString(),
    ]..sort(),
  };
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('导出到文件 → 按文件导入另一份库：逐字段一致（含媒体、fushi-ext）', () async {
    final Directory tmp = _tmp();
    final BulkFixture src = await BulkFixture.open(notes: 60);
    final SrsDbStore a = src.store;
    // 几条笔记带媒体引用；一张卡暂停、一张卡挪牌组、一条笔记改标签：导出 / 导入都要带上。
    final List<String> ids = (await a.entityIds(SrsEntityKind.note)).toList()
      ..sort();
    final SrsNoteTypeView basic = (await a.noteType(basicTypeId(a)))!;
    for (int i = 0; i < 5; i++) {
      await a.updateNote(
        ids[i],
        fieldsById: <String, String>{
          basic.fields[1].id: '例<img src="m$i.png"> [sound:s$i.mp3]',
        },
        tags: <String>['bench', 'media'],
      );
    }
    final List<String> cards = <String>[
      for (final SrsCardCacheRow c
          in await a.db.select(a.db.srsCardsCache).get())
        c.id,
    ]..sort();
    await a.setSuspended(cards[3], true);
    // 挪第二张卡（Lang → Lang::JP）。笔记的首选牌组 apkg 里没有对应字段，导入取首张卡的牌组：
    // 挪首张卡会让回导的笔记首选牌组跟着变（格式本身的限制，不是导出 / 导入的错）。
    final String second = basic.templates[1].id;
    final String moved = (await a.db.select(a.db.srsCardsCache).get())
        .where((SrsCardCacheRow c) => c.templateId == second)
        .map((SrsCardCacheRow c) => c.id)
        .reduce((String x, String y) => x.compareTo(y) < 0 ? x : y);
    await a.moveCard(moved, await deckId(a, 'Lang::JP'));
    final Map<String, Uint8List> media = <String, Uint8List>{
      for (int i = 0; i < 5; i++) ...<String, Uint8List>{
        // 一个可压缩、一个不可压缩（STORE 条目）。
        'm$i.png': Uint8List.fromList(List<int>.filled(4096 + i, i)),
        's$i.mp3': Uint8List.fromList(
          List<int>.generate(3000 + i, (int k) => (k * 7919 + i) & 0xff),
        ),
      },
    };

    final File pkg = File('${tmp.path}/out.apkg');
    await exportAnkiPackageFile(
      store: a,
      file: pkg,
      loadMedia: (String name) async => media[name],
    );
    expect(File('${pkg.path}.part').existsSync(), isFalse);
    // 包是标准 zip：集合、媒体清单、fushi-ext 都在。
    final Archive zip = ZipDecoder().decodeBytes(pkg.readAsBytesSync());
    expect(
      zip.files.map((ArchiveFile f) => f.name).toSet(),
      containsAll(<String>['collection.anki21', 'media', 'fushi-ext']),
    );

    final (SrsDbStore b, _) = await _emptyStore('dev2');
    final Map<String, Uint8List> stored = <String, Uint8List>{};
    final SrsImportReport rep = await importAnkiPackageFile(
      store: b,
      file: pkg,
      options: kFullOptions,
      storeMedia: (String name, Uint8List bytes) async {
        stored[name] = bytes;
        return name;
      },
    );
    expect(rep.notesAdded, 60);
    expect(rep.cardsAdded, 120);
    expect(stored.keys.toSet(), media.keys.toSet());
    for (final String name in media.keys) {
      expect(stored[name], media[name], reason: name);
    }

    final Map<String, Object?> ma = await _materialized(a);
    final Map<String, Object?> mb = await _materialized(b);
    for (final String k in ma.keys) {
      expect(mb[k], ma[k], reason: k);
    }
  });

  test('exportAnkiPackage（字节）与写文件的包内容相同', () async {
    final Directory tmp = _tmp();
    final BulkFixture src = await BulkFixture.open(notes: 10);
    final File f = File('${tmp.path}/x.apkg');
    await exportAnkiPackageFile(store: src.store, file: f);
    final Uint8List bytes = await exportAnkiPackage(store: src.store);
    Map<String, List<int>> entries(Uint8List b) => <String, List<int>>{
      for (final ArchiveFile e in ZipDecoder().decodeBytes(b).files)
        e.name: e.content as List<int>,
    };
    final Map<String, List<int>> x = entries(f.readAsBytesSync());
    final Map<String, List<int>> y = entries(bytes);
    expect(y.keys, x.keys);
    // 集合 SQLite 每次导出各自生成（页内容相同但不保证字节一致），只比其余条目。
    for (final String k in x.keys.where(
      (String k) => k != 'collection.anki21',
    )) {
      expect(y[k], x[k], reason: k);
    }
  });

  test('已有笔记重导入：修改攒批落库，事务数与笔记数无关', () async {
    final Directory tmp = _tmp();
    const int notes = 300;
    final BulkFixture src = await BulkFixture.open(notes: notes);
    final SrsAnkiImportOptions update = kFullOptions.copyWith(
      updateNotes: SrsImportUpdateCondition.ifNewer,
    );
    final SrsDbStore a = src.store;
    // 导出 → 包里改每条笔记的第一个字段、改卡片暂停态 → 导回同一份库：每条笔记都要更新。
    final File pkg = File('${tmp.path}/out.apkg');
    await exportAnkiPackageFile(store: a, file: pkg);
    final Archive zip = ZipDecoder().decodeBytes(pkg.readAsBytesSync());
    final ArchiveFile col = zip.findFile('collection.anki21')!;
    final Uint8List patched = patchSqlite(
      Uint8List.fromList(col.content as List<int>),
      (db) {
        db.execute(
          "UPDATE notes SET flds = 'new-' || flds, mod = mod + 100000",
        );
        db.execute('UPDATE cards SET queue = -1, mod = mod + 100000');
      },
    );
    final File edited = File('${tmp.path}/edited.apkg')
      ..writeAsBytesSync(
        zipOf(<String, List<int>>{
          for (final ArchiveFile f in zip.files)
            f.name: f.name == 'collection.anki21'
                ? patched
                : f.content as List<int>,
        }),
      );

    src.counter.reset();
    final SrsImportReport rep = await importAnkiPackageFile(
      store: a,
      file: edited,
      options: update,
      storeMedia: (String name, Uint8List b) async => name,
    );
    expect(rep.notesUpdated, notes);
    expect(rep.notesAdded, 0);
    // ignore: avoid_print
    print('REIMPORT notes=$notes ${src.counter.summary()}');
    // 以前每条已有笔记的内容一个事务、每张卡的暂停一个事务（300 条笔记 ≥ 900 个事务）。
    expect(
      src.counter.transactions,
      lessThan(20),
      reason: src.counter.summary(),
    );

    final SrsNoteTypeView basic = (await a.noteType(basicTypeId(a)))!;
    final Map<String, SrsNoteView?> after = await a.notes(
      await a.entityIds(SrsEntityKind.note),
    );
    for (final SrsNoteView? n in after.values) {
      expect(n!.field(basic.fields.first.id), startsWith('new-'));
    }
    final List<SrsCardCacheRow> cards = await a.db
        .select(a.db.srsCardsCache)
        .get();
    expect(cards, hasLength(notes * 2));
    expect(cards.every((SrsCardCacheRow c) => c.suspended), isTrue);

    // 同一个包再导一遍：全部 no-op，不写任何修改记录。
    final int editsBefore =
        (await a.db.select(a.db.srsFieldEdits).get()).length;
    final SrsImportReport again = await importAnkiPackageFile(
      store: a,
      file: edited,
      options: update,
      storeMedia: (String name, Uint8List b) async => name,
    );
    expect(again.notesUpdated, 0);
    expect(again.notesSkipped, notes);
    expect((await a.db.select(a.db.srsFieldEdits).get()).length, editsBefore);
  });

  group('新格式 collection.anki21b（按文件导入）', () {
    Uint8List latestPackage(List<int> collectionEntry) =>
        zipOf(<String, List<int>>{
          'collection.anki21b': collectionEntry,
          'media': '{}'.codeUnits,
        });

    Uint8List legacyCollection() => buildLegacyCollection(
      crtSecs: crtSecs,
      conf: <String, Object?>{'rollover': 4, 'localOffset': 0, 'fsrs': true},
      models: legacyModels(),
      decks: legacyDecks(),
      dconf: legacyDconf(),
      notes: fixtureNotes(kBulkNowMs),
    );

    test('排程内核文件到文件解 zstd，结果与旧格式包相同', () async {
      final FushiFsrs? lib = FushiFsrs.tryLoad(
        libraryPath: fushiFsrsPrebuiltPath(),
      );
      if (lib == null) fail('fushi_fsrs native library unavailable');
      final Directory tmp = _tmp();
      final Uint8List col = legacyCollection();
      final File latest = File('${tmp.path}/latest.apkg')
        ..writeAsBytesSync(latestPackage(zstdRawFrame(col)));
      final File legacy = File('${tmp.path}/legacy.apkg')
        ..writeAsBytesSync(
          zipOf(<String, List<int>>{
            'collection.anki21': col,
            'media': '{}'.codeUnits,
          }),
        );

      final (SrsDbStore x, _) = await _emptyStore('x');
      final (SrsDbStore y, _) = await _emptyStore('y');
      final SrsImportReport rx = await importAnkiPackageFile(
        store: x,
        file: latest,
        options: kFullOptions,
        storeMedia: (String name, Uint8List b) async => name,
        zstdDecompressFile: (String i, String o) =>
            switch (FfiFsrsEngine.zstdDecompressFile(i, o, library: lib)) {
              null => null,
              SrsZstdFileResult.ok => true,
              _ => false,
            },
      );
      final SrsImportReport ry = await importAnkiPackageFile(
        store: y,
        file: legacy,
        options: kFullOptions,
        storeMedia: (String name, Uint8List b) async => name,
      );
      expect(rx.latestFormat, isTrue);
      expect(rx.notesAdded, ry.notesAdded);
      expect(rx.notesAdded, greaterThan(0));
      expect(await _materialized(x), await _materialized(y));

      // 截断的帧：数据非法（不是「内核不可用」）。
      final Uint8List frame = zstdRawFrame(col);
      final File bad = File('${tmp.path}/bad.apkg')
        ..writeAsBytesSync(
          latestPackage(Uint8List.sublistView(frame, 0, frame.length ~/ 2)),
        );
      await expectLater(
        importAnkiPackageFile(
          store: x,
          file: bad,
          options: kFullOptions,
          storeMedia: (String name, Uint8List b) async => name,
          zstdDecompressFile: (String i, String o) =>
              FfiFsrsEngine.zstdDecompressFile(i, o, library: lib) ==
              SrsZstdFileResult.ok,
        ),
        throwsA(
          isA<SrsImportException>().having(
            (SrsImportException e) => e.code,
            'code',
            SrsImportException.corrupt,
          ),
        ),
      );
    });

    test('排程内核不可用：明确报 needsKernel，不留临时目录', () async {
      final Directory tmp = _tmp();
      final File f = File('${tmp.path}/latest.apkg')
        ..writeAsBytesSync(
          latestPackage(<int>[0x28, 0xB5, 0x2F, 0xFD, 0, 0, 0]),
        );
      final (SrsDbStore s, _) = await _emptyStore('z');
      await expectLater(
        importAnkiPackageFile(
          store: s,
          file: f,
          storeMedia: (String name, Uint8List b) async => name,
          zstdDecompressFile: (String i, String o) => null,
        ),
        throwsA(
          isA<SrsImportException>().having(
            (SrsImportException e) => e.code,
            'code',
            SrsImportException.needsKernel,
          ),
        ),
      );
    });
  });
}
