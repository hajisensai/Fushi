// 「遗漏字段补迁」预演（previewLapisBackfill / legacyLapisPendingCounts 的角标）的规模守卫与
// 新旧实现等价性。
//
// 笔记类型页一打开、Anki 迁移完成提示都会算这个角标。修前它把**全部** Fushi 卡片笔记的修改记录
// 读出来逐条物化（内置 Lapis 永远在，所以哪怕用户从没用过 Lapis，只要有 Fushi 卡片笔记就全量
// 物化），读回的行数与语句数都随笔记数线性增长。修后先在 SQL 里按「旧 Lapis 字段有非空修改记录、
// 同语义的目标字段没有任何修改记录」筛出候选，只物化候选。
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_query_counter.dart';
import 'support/srs_test_storage.dart';

const String kUid = '01928c3e-0000-7000-8000-0000000b1a51';

/// 内存库 + 语句计数 + [notes] 条 Basic 笔记（成批落库，不走 Anki 包导入）。
class ScaleFixture {
  ScaleFixture._(this.store, this.counter, this.basicTypeId);

  final SrsDbStore store;
  final CountingInterceptor counter;
  final String basicTypeId;

  static Future<ScaleFixture> open({required int notes}) async {
    final CountingInterceptor counter = CountingInterceptor();
    final Directory tmp = Directory.systemTemp.createTempSync('srs_scale_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final TestSrs srs = await openTestSrsAt(
      '${tmp.path}/srs.db',
      interceptor: counter,
    );
    final SrsDbStore s = await SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: kUid,
      deviceId: 'dev',
      engine: const FakeFsrsEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => 1780272000000,
        bootClockMs: () => 1780272000000,
        bootId: 'scale',
      ),
      fallbackRolloverHour: () => 4,
    );
    final String basic = await s.createStockNoteType(
      SrsStockNoteType.basic,
      'Basic',
    );
    final SrsNoteTypeView bv = (await s.noteType(basic))!;
    for (int i = 0; i < notes; i += 500) {
      await s.importDrafts(<SrsEventDraft>[
        for (int j = i; j < min(i + 500, notes); j++)
          ...s.newNoteDrafts(
            noteTypeId: basic,
            fieldsById: <String, String>{
              bv.fields[0].id: 'front $j',
              bv.fields[1].id: 'back $j',
            },
            guid: 'scale-$j',
          ),
      ]);
    }
    return ScaleFixture._(s, counter, basic);
  }
}

/// 修前的实现原样搬过来当参照（只用公开 API）：全部 Fushi 卡片笔记逐条物化后判。
Future<Map<String, Map<String, String>>> referenceBackfill(
  SrsDbStore s, {
  List<String>? noteIds,
}) async {
  final SrsNoteTypeView? to = await s.noteType(s.fushiCardNoteTypeId);
  if (to == null || to.deletedAt != null) {
    return <String, Map<String, String>>{};
  }
  final List<String> typeIds =
      (await (s.db.select(s.db.srsEntities)..where(
                (t) =>
                    t.profileUid.equals(s.profileUid) &
                    t.kind.equals(SrsEntityKind.noteType.wire),
              ))
              .get())
          .map((r) => r.id)
          .toList();
  final Map<String, SrsLapisFieldCandidate> owners =
      <String, SrsLapisFieldCandidate>{};
  for (final SrsNoteTypeView? t in (await s.noteTypesById(typeIds)).values) {
    if (t == null || t.id == to.id || srsDetectLapisVariant(t) == null) {
      continue;
    }
    for (final SrsFieldDef f in t.fields) {
      owners[f.id] = SrsLapisFieldCandidate(
        type: t,
        field: f,
        slot: srsLapisFieldSlot(s.profileUid, t, f),
      );
    }
  }
  final Map<String, Map<String, String>> fills =
      <String, Map<String, String>>{};
  if (owners.isEmpty) return fills;
  final List<String> ids = noteIds ?? await s.noteIdsOfType(to.id);
  final Map<String, SrsNoteView?> views = await s.notes(ids);
  for (final String id in ids) {
    final SrsNoteView? n = views[id];
    if (n == null || n.deletedAt != null || n.noteTypeId != to.id) continue;
    final Map<String, String> fill = srsPlanLapisFieldFill(
      profileUid: s.profileUid,
      target: to,
      current: n.fields,
      values: <SrsLapisFieldValue>[
        for (final MapEntry<String, String> e in n.fields.entries)
          if (owners[e.key] case final SrsLapisFieldCandidate c)
            SrsLapisFieldValue(c, e.value),
      ],
      authored: <String>{
        for (final SrsFieldDef f in to.fields)
          if (n.edits[SrsFieldKeys.noteField(f.id)] != null) f.id,
      },
    );
    if (fill.isNotEmpty) fills[id] = fill;
  }
  return fills;
}

/// 导入的 Basic (and reversed) 笔记 [ids] 换到 [toId]，字段按 [fieldMap]（目标 → 源）映射。
Future<void> changeTo(
  SrsDbStore s,
  List<String> ids,
  String toId,
  Map<String, String?> fieldMap,
) async {
  if (ids.isEmpty) return;
  final SrsNoteTypeView from = await s.sourceTypeOf(ids);
  final SrsNoteTypeView to = (await s.noteType(toId))!;
  await s.changeNoteType(
    noteIds: ids,
    targetTypeId: toId,
    fieldMap: <String, String?>{
      for (final SrsFieldDef f in to.fields) f.id: fieldMap[f.id],
    },
    templateMap: <String, String?>{
      to.templates.first.id: from.templates.first.id,
    },
  );
}

/// 旧版迁移的形状：Lapis 变体 → Fushi 卡片只按同名映射（自加的「Source」等整列丢失）。
Future<void> oldStyleMigrate(SrsDbStore s, List<String> ids) async {
  if (ids.isEmpty) return;
  final SrsNoteTypeView from = await s.sourceTypeOf(ids);
  final SrsNoteTypeView to = (await s.noteType(s.fushiCardNoteTypeId))!;
  await changeTo(s, ids, to.id, <String, String?>{
    for (final SrsFieldDef f in to.fields)
      f.id: from.fields
          .where(
            (SrsFieldDef x) => x.name.toLowerCase() == f.name.toLowerCase(),
          )
          .firstOrNull
          ?.id,
  });
}

/// 按名字找字段；Fushi 卡片的 9 个字段改过名（FushiCardFields），旧名作别名也认。
String fieldNamed(SrsNoteTypeView v, String name) {
  final String alias = FushiCardFields.canonical(name);
  return v.fields
      .firstWhere((SrsFieldDef f) => f.name == name || f.name == alias)
      .id;
}

/// [notes] 条笔记：[lapisShare] 比例经「导入的 Lapis（带自加 Source 字段）」旧式迁到 Fushi 卡片
/// （MiscInfo 留空、待补迁），其余从 Basic 直接换到 Fushi 卡片（与 Lapis 无关）。
Future<ScaleFixture> scaleFixture(int notes, {double lapisShare = 0}) async {
  final ScaleFixture f = await ScaleFixture.open(notes: notes);
  final SrsDbStore s = f.store;
  final SrsNoteTypeView basic = (await s.noteType(f.basicTypeId))!;
  final List<String> all = await s.noteIdsOfType(basic.id);
  final int nLapis = (all.length * lapisShare).round();
  final List<String> viaLapis = all.sublist(0, nLapis);
  final List<String> direct = all.sublist(nLapis);
  if (viaLapis.isNotEmpty) {
    final String lapisId = await s.cloneNoteType(
      s.lapisNoteTypeId,
      'Lapis (Hibiki)',
    );
    final String source = await s.addField(lapisId, 'Source');
    final SrsNoteTypeView lv = (await s.noteType(lapisId))!;
    await changeTo(s, viaLapis, lapisId, <String, String?>{
      fieldNamed(lv, 'Expression'): basic.fields[0].id,
      source: basic.fields[1].id,
    });
    await oldStyleMigrate(s, viaLapis);
  }
  final SrsNoteTypeView fc = (await s.noteType(s.fushiCardNoteTypeId))!;
  await changeTo(s, direct, fc.id, <String, String?>{
    fieldNamed(fc, 'Expression'): basic.fields[0].id,
    fieldNamed(fc, 'MainDefinition'): basic.fields[1].id,
  });
  return f;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// 一次角标计算的语句数 / 读回行数 / 墙钟。
  Future<({int statements, int rows, int ms, int backfill})> badge(
    ScaleFixture f,
  ) async {
    f.counter.reset();
    final Stopwatch sw = Stopwatch()..start();
    final ({int migratable, int backfill}) c = await f.store
        .legacyLapisPendingCounts();
    final int ms = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print(
      '  badge statements=${f.counter.total} rows=${f.counter.rowsRead} '
      '${ms}ms backfill=${c.backfill} migratable=${c.migratable} '
      '${f.counter.summary()}',
    );
    return (
      statements: f.counter.total,
      rows: f.counter.rowsRead,
      ms: ms,
      backfill: c.backfill,
    );
  }

  test('没有待补迁的笔记时：角标的语句数与读回行数不随 Fushi 卡片笔记数增长', () async {
    // 一半笔记是从 Lapis 旧式迁来、已经补迁过的（旧 Lapis 字段的修改记录仍留在笔记上），一半与
    // Lapis 无关。修前两种都全量物化；补迁过的笔记目标字段已有修改记录，不能再算进候选。
    final ScaleFixture small = await scaleFixture(40, lapisShare: 0.5);
    final ScaleFixture large = await scaleFixture(320, lapisShare: 0.5);
    expect(await small.store.applyLapisBackfill(), 20);
    expect(await large.store.applyLapisBackfill(), 160);
    final ({int statements, int rows, int ms, int backfill}) a = await badge(
      small,
    );
    final ({int statements, int rows, int ms, int backfill}) b = await badge(
      large,
    );
    expect(a.backfill, 0);
    expect(b.backfill, 0);
    // 修前：每条 Fushi 卡片笔记的全部修改记录都读回来（320 条笔记 → 几千行），语句数按分块增长。
    expect(b.statements, a.statements);
    expect(b.rows, a.rows);
  });

  test('有待补迁的笔记时：只物化候选（读回行数只随候选数增长，不随全部笔记数增长）', () async {
    // 两份库的待补迁笔记数相同（各 20 条），只是与 Lapis 无关的 Fushi 卡片笔记多 8 倍。
    final ScaleFixture small = await scaleFixture(40, lapisShare: 0.5);
    final ScaleFixture large = await scaleFixture(320, lapisShare: 20 / 320);
    final ({int statements, int rows, int ms, int backfill}) a = await badge(
      small,
    );
    final ({int statements, int rows, int ms, int backfill}) b = await badge(
      large,
    );
    expect(a.backfill, 20);
    expect(b.backfill, 20);
    expect(b.statements, a.statements);
    expect(b.rows, a.rows);
    expect(
      (await small.store.previewLapisBackfill()).fills,
      await referenceBackfill(small.store),
    );
    expect(
      (await large.store.previewLapisBackfill()).fills,
      await referenceBackfill(large.store),
    );
  });

  test(
    '规模实测（FUSHI_SRS_BENCH=1 时跑，1 万条 Fushi 卡片笔记）',
    () async {
      for (final double share in <double>[0, 0.1]) {
        // ignore: avoid_print
        print('notes=10000 lapisShare=$share');
        final ScaleFixture f = await scaleFixture(10000, lapisShare: share);
        await badge(f);
        await badge(f);
        f.counter.reset();
        final Stopwatch sw = Stopwatch()..start();
        final int ref = (await referenceBackfill(f.store)).length;
        // ignore: avoid_print
        print(
          '  reference(full) statements=${f.counter.total} '
          'rows=${f.counter.rowsRead} ${sw.elapsedMilliseconds}ms '
          'backfill=$ref',
        );
      }
    },
    skip: Platform.environment['FUSHI_SRS_BENCH'] == '1' ? false : 'bench only',
    timeout: const Timeout(Duration(minutes: 20)),
  );

  group('与修前实现逐条等价（随机数据）', () {
    for (int seed = 1; seed <= 6; seed++) {
      test('seed $seed', () async {
        final Random rnd = Random(seed);
        final ScaleFixture f = await ScaleFixture.open(notes: 60);
        final SrsDbStore s = f.store;
        final SrsNoteTypeView basic = (await s.noteType(f.basicTypeId))!;
        final SrsNoteTypeView fc = (await s.noteType(s.fushiCardNoteTypeId))!;
        final List<String> all = await s.noteIdsOfType(basic.id)
          ..shuffle(rnd);

        // 三种来源：导入的 Lapis（带自加字段）、内置 Lapis（带自加字段）、Basic 直接换。
        final String imported = await s.cloneNoteType(
          s.lapisNoteTypeId,
          'Lapis import',
        );
        final String impSource = await s.addField(imported, 'Source');
        final String impTr = await s.addField(imported, '例句翻译');
        final String builtinSrc = await s.addField(s.lapisNoteTypeId, '出典');
        final SrsNoteTypeView iv = (await s.noteType(imported))!;
        final SrsNoteTypeView bv = (await s.noteType(s.lapisNoteTypeId))!;

        final List<String> viaImported = all.sublist(0, 20);
        final List<String> viaBuiltin = all.sublist(20, 35);
        final List<String> direct = all.sublist(35, 50);
        final List<String> stayLapis = all.sublist(50, 55);
        // 其余 5 条留在 Basic。

        await changeTo(
          s,
          <String>[...viaImported, ...stayLapis],
          imported,
          <String, String?>{fieldNamed(iv, 'Expression'): basic.fields[0].id},
        );
        await changeTo(s, viaBuiltin, s.lapisNoteTypeId, <String, String?>{
          fieldNamed(bv, 'Expression'): basic.fields[0].id,
        });

        // 旧 Lapis 字段的随机内容：空串 / 纯空白 / 换行 / 有内容 / 不写。
        const List<String?> values = <String?>[
          null,
          '',
          '   ',
          '\n',
          ' x ',
          'Book',
        ];
        String? pick() => values[rnd.nextInt(values.length)];
        final List<SrsEditSpec> pre = <SrsEditSpec>[];
        void put(String note, String fieldId, String? v) {
          if (v == null) return;
          pre.add(
            SrsEditSpec(
              SrsEntityKind.note,
              note,
              SrsFieldKeys.noteField(fieldId),
              v,
            ),
          );
        }

        for (final String n in <String>[...viaImported, ...stayLapis]) {
          put(n, impSource, pick());
          put(n, impTr, pick());
          put(n, fieldNamed(iv, 'MiscInfo'), pick());
          put(n, fieldNamed(iv, 'Sentence'), pick());
          put(n, fieldNamed(iv, 'PitchPosition'), pick());
        }
        for (final String n in viaBuiltin) {
          put(n, builtinSrc, pick());
          put(n, srsLapisFieldId(s.profileUid, 'MiscInfo'), pick());
          put(n, srsLapisFieldId(s.profileUid, 'SentenceTranslation'), pick());
        }
        await s.writeEdits(pre);

        await oldStyleMigrate(s, viaImported);
        await oldStyleMigrate(s, viaBuiltin);
        await changeTo(s, direct, fc.id, <String, String?>{
          fieldNamed(fc, 'Expression'): basic.fields[0].id,
        });

        // 迁移后用户对目标字段的随机修改（写内容 / 清空成空串），以及随机删笔记。
        final List<SrsEditSpec> post = <SrsEditSpec>[];
        for (final String n in <String>[
          ...viaImported,
          ...viaBuiltin,
          ...direct,
        ]) {
          for (final String key in <String>[
            'MiscInfo',
            'SentenceTranslation',
            'Sentence',
          ]) {
            switch (rnd.nextInt(4)) {
              case 0:
                post.add(
                  SrsEditSpec(
                    SrsEntityKind.note,
                    n,
                    SrsFieldKeys.noteField(fieldNamed(fc, key)),
                    '',
                  ),
                );
              case 1:
                post.add(
                  SrsEditSpec(
                    SrsEntityKind.note,
                    n,
                    SrsFieldKeys.noteField(fieldNamed(fc, key)),
                    'mine',
                  ),
                );
              default:
                break;
            }
          }
        }
        await s.writeEdits(post);
        for (final String n in all) {
          if (rnd.nextInt(10) == 0) await s.deleteNote(n);
        }
        if (rnd.nextBool()) await s.deleteNoteType(imported);

        final Map<String, Map<String, String>> want = await referenceBackfill(
          s,
        );
        expect(want, isNotEmpty, reason: 'seed $seed 应造出待补迁的笔记');
        expect((await s.previewLapisBackfill()).fills, want);
        final ({int migratable, int backfill}) counts = await s
            .legacyLapisPendingCounts();
        expect(counts.backfill, want.length);
        // 可迁移数（SQL 分组计数）与逐个变体读笔记 ID 求和一致。
        int migratable = 0;
        for (final SrsLegacyLapisSource src in await s.legacyLapisSources()) {
          migratable += src.noteIds.length;
        }
        expect(counts.migratable, migratable);
        // 指定笔记子集（含非 Fushi 卡片、已删除、不存在的 ID）。
        final List<String> subset = <String>[
          ...all.where((String _) => rnd.nextBool()),
          'missing-note-id',
        ];
        expect(
          (await s.previewLapisBackfill(noteIds: subset)).fills,
          await referenceBackfill(s, noteIds: subset),
        );
        // 补迁后两边都归零（幂等）。
        expect(await s.applyLapisBackfill(), want.length);
        expect(await referenceBackfill(s), isEmpty);
        expect((await s.previewLapisBackfill()).fills, isEmpty);
      });
    }
  });
}
