// 导出 Anki 包的三个开关（[SrsAnkiExportOptions]）：学习进度 / 牌组预设 / 兼容 Anki。
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/apkg/srs_export_options.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;

  /// 一条复习过、一张暂停的卡，默认牌组期望保留率改成 0.85。
  Future<SrsDbStore> seeded() async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    // 复习过的卡要留在学习队列：RWKV 牌组缺省不用步长，这里写上步长。
    await s.editFields(SrsEntityKind.deck, s.defaultDeckId, <String, Object?>{
      SrsFieldKeys.deckSteps: <String, Object?>{
        'learn': <double>[1, 10],
        'relearn': <double>[10],
      },
    });
    final String reviewed = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '食べる',
      },
    );
    final String suspended = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '見る',
      },
    );
    t += 60000;
    await s.answer((await s.cardsOfNote(reviewed)).single.id, 3);
    await s.setSuspended((await s.cardsOfNote(suspended)).single.id, true);
    await s.editFields(SrsEntityKind.deck, s.defaultDeckId, <String, Object?>{
      SrsFieldKeys.deckRetention: 0.85,
    });
    t += 86400000;
    return s;
  }

  Future<T> withCollection<T>(
    Uint8List pkg,
    T Function(SrsAnkiPackage p, Database db) body,
  ) async {
    final SrsAnkiPackage p = SrsAnkiPackage.open(
      pkg,
      zstd: (Uint8List b) => null,
    );
    final SrsAnkiCollection col = await SrsAnkiCollection.open(
      p.collectionBytes,
    );
    try {
      return body(p, col.db);
    } finally {
      await col.close();
    }
  }

  double retentionOf(Database db) {
    final Map<String, Object?> dconf =
        (jsonDecode(
                  db.select('SELECT dconf FROM col').single['dconf'] as String,
                )
                as Map)
            .cast<String, Object?>();
    final Map<String, Object?> d1 = (dconf['1']! as Map)
        .cast<String, Object?>();
    return (d1['desiredRetention']! as num).toDouble();
  }

  test('默认选项 = 原有导出：带进度、带预设、附带 fushi-ext', () async {
    expect(const SrsAnkiExportOptions().withScheduling, isTrue);
    expect(const SrsAnkiExportOptions().withDeckConfigs, isTrue);
    expect(const SrsAnkiExportOptions().ankiCompatible, isFalse);
    final SrsDbStore s = await seeded();
    final Uint8List pkg = await exportAnkiPackage(store: s);
    await withCollection(pkg, (SrsAnkiPackage p, Database db) {
      expect(p.fushiExt, isNotNull);
      expect((p.fushiExt!['logs']! as List).length, greaterThan(0));
      expect(db.select('SELECT id FROM revlog'), hasLength(1));
      expect(
        db.select('SELECT queue FROM cards').map((Row r) => r['queue']),
        containsAll(<int>[-1, 1]),
        reason: '暂停卡 queue=-1，复习过的卡在学习队列',
      );
      expect(retentionOf(db), closeTo(0.85, 1e-9));
    });
  });

  test('不带学习进度：全部新卡、无 revlog、去掉暂停，fushi-ext 不带日志', () async {
    final SrsDbStore s = await seeded();
    final Uint8List pkg = await exportAnkiPackage(
      store: s,
      options: const SrsAnkiExportOptions(withScheduling: false),
    );
    await withCollection(pkg, (SrsAnkiPackage p, Database db) {
      expect(db.select('SELECT id FROM revlog'), isEmpty);
      final List<Row> cards = db
          .select('SELECT type, queue, due, ivl, reps FROM cards ORDER BY due')
          .toList();
      expect(cards, hasLength(2));
      for (final Row c in cards) {
        expect(c['type'], 0);
        expect(c['queue'], 0);
        expect(c['ivl'], 0);
        expect(c['reps'], 0);
      }
      expect(cards.map((Row c) => c['due']), <int>[0, 1]);
      expect(p.fushiExt!['logs'], isEmpty);
      // 预设仍随包。
      expect(retentionOf(db), closeTo(0.85, 1e-9));
    });
  });

  test('不带牌组预设：Anki 默认预设，fushi-ext 不带牌组设置', () async {
    final SrsDbStore s = await seeded();
    final Uint8List pkg = await exportAnkiPackage(
      store: s,
      options: const SrsAnkiExportOptions(withDeckConfigs: false),
    );
    await withCollection(pkg, (SrsAnkiPackage p, Database db) {
      expect(retentionOf(db), closeTo(0.9, 1e-9));
      expect(p.fushiExt!['decks'], isEmpty);
      // 进度仍随包。
      expect(db.select('SELECT id FROM revlog'), hasLength(1));
    });
  });

  test('兼容 Anki：不附带 fushi-ext，Anki 内容照旧', () async {
    final SrsDbStore s = await seeded();
    final Uint8List pkg = await exportAnkiPackage(
      store: s,
      options: const SrsAnkiExportOptions(ankiCompatible: true),
    );
    await withCollection(pkg, (SrsAnkiPackage p, Database db) {
      expect(p.fushiExt, isNull);
      expect(db.select('SELECT id FROM revlog'), hasLength(1));
      expect(retentionOf(db), closeTo(0.85, 1e-9));
    });
  });

  test('选项 JSON 往返；缺项 / 坏值回落默认', () {
    const SrsAnkiExportOptions o = SrsAnkiExportOptions(
      withScheduling: false,
      withDeckConfigs: false,
      ankiCompatible: true,
    );
    expect(SrsAnkiExportOptions.fromJson(o.toJson()), o);
    expect(
      SrsAnkiExportOptions.fromJson(const <String, Object?>{
        'withScheduling': 'x',
      }),
      const SrsAnkiExportOptions(),
    );
  });
}
