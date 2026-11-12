// 写路径第 14 步的成本验收：发命令前的 Drift 预读、同一批笔记的重复物化、彻底清除的逐条命令。
//
// 量的是每种操作经 Drift 执行器送进内核的语句数（`srsDebugReadCommands`，第 13 步之后只可能是只读
// 查询）与内核命令数（`debugCoreCommands`）。改动前的数字（第 13 步的代码上跑同一份测试，Mac，2026-11-12）：
//
// | 操作 | 改前（语句, 命令） | 改后 |
// | --- | --- | --- |
// | editFields（值变了） | (1, 1) | (0, 1) |
// | editFields（值没变） | (1, 0) | (0, 1) |
// | editFieldsBatch（3 张卡） | (1, 1) | (0, 1) |
// | writeEdits（3 条笔记） | (1, 1) | (0, 1) |
// | createNote | (1, 1) | (0, 1) |
// | changeNoteType（6 条笔记） | (7, 1) | (5, 1)：少现值预读 2 条（笔记、卡片各一条） |
// | migrateLegacyLapis（6 条笔记） | (15, 1) | (11, 1)：少第二遍物化 2 条 + 现值预读 2 条 |
// | applyLapisBackfill（2 条要补） | (9, 1) | (8, 1)：少现值预读 1 条 |
// | srsPurgeNotesNow（5 条 / 205 条笔记） | (0, 5) / (0, 205) | (0, 1) / (0, 2) |
//
// 「值没变就不写」现在由内核在落库的那一笔里判（native/fushi_fsrs/src/store/sync2/changing.rs `drop_noops`）：值没变的
// 写入仍是一条命令，但它什么都不落——不占序号、旧版时钟不走、修订号不动（用例里一并核对）。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_purge.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_bulk_fixture.dart';
import 'package:fushi_engine/srs/srs_reads.dart';

typedef _Cost = ({int statements, int core});

/// 跑一次 [op]，返回它送进内核的语句数与内核命令数（量完当场打印，改动前后对照用）。
Future<_Cost> _cost(
  SrsDbStore store,
  String name,
  Future<void> Function() op,
) async {
  final int core = store.debugCoreCommands;
  srsDebugReadCommands = 0;
  await op();
  final _Cost cost = (
    statements: srsDebugReadCommands,
    core: store.debugCoreCommands - core,
  );
  // ignore: avoid_print
  print('PREREAD_COST $name: statements=${cost.statements} core=${cost.core}');
  return cost;
}

/// 一组键（内容 / 牌组树 / RWKV / 统计）与操作日志、修改记录的条数：值没变的写入之后都不该动。
List<Object?> _signals(SrsDbStore s) => <Object?>[
  s.contentFingerprint,
  s.deckTreeKey,
  s.rwkvScoresKey,
  s.statsFingerprint,
  s.core.debugSelectRaw('SELECT COUNT(*) AS n FROM sync2_ops').single['n'],
  s.core
      .debugSelectRaw('SELECT COUNT(*) AS n FROM srs_field_edits')
      .single['n'],
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('改字段 / 建笔记：发命令前不再经 Drift 读现值，值没变的写入什么都不落', () async {
    final BulkFixture f = await BulkFixture.open(notes: 6);
    final SrsDbStore s = f.store;
    final SrsNoteTypeView basic = (await s.noteType(basicTypeId(s)))!;
    final String front = SrsFieldKeys.noteField(basic.fields[0].id);
    final String back = SrsFieldKeys.noteField(basic.fields[1].id);
    final List<String> cards = <String>[
      for (final SrsCardCacheRow c in await s.allCardRows()) c.id,
    ]..sort();
    final List<String> notes = await s.noteIdsOfType(basic.id);
    final Map<String, _Cost> costs = <String, _Cost>{};

    late List<SrsFieldEdit>? wrote;
    costs['editFields'] = await _cost(s, 'editFields', () async {
      wrote = await s.editFields(
        SrsEntityKind.note,
        notes[0],
        <String, Object?>{front: 'x', back: 'y'},
      );
    });
    expect(wrote!.map((SrsFieldEdit e) => e.fieldKey), <String>[front, back]);
    expect(wrote!.map((SrsFieldEdit e) => e.value), <String>['x', 'y']);

    // 值没变：一条不落。同一次写入里一半变、一半没变：只落变了的那条，返回的也只有它。
    final List<Object?> before = _signals(s);
    costs['editFields(no-op)'] = await _cost(s, 'editFields(no-op)', () async {
      wrote = await s.editFields(
        SrsEntityKind.note,
        notes[0],
        <String, Object?>{front: 'x', back: 'y'},
      );
    });
    expect(wrote, isEmpty);
    expect(_signals(s), before, reason: '值没变的写入不占序号、不推进任何刷新信号');
    wrote = await s.editFields(SrsEntityKind.note, notes[0], <String, Object?>{
      front: 'x',
      back: 'y2',
    });
    expect(wrote!.map((SrsFieldEdit e) => e.fieldKey), <String>[back]);
    expect((await s.note(notes[0]))!.fields[basic.fields[1].id], 'y2');

    late List<SrsFieldEdit> batch;
    costs['editFieldsBatch'] = await _cost(s, 'editFieldsBatch', () async {
      batch = await s.editFieldsBatch(<SrsFieldChange>[
        for (final String c in cards.take(3))
          SrsFieldChange(SrsEntityKind.card, c, SrsFieldKeys.flag, 2),
      ]);
    });
    expect(batch, hasLength(3));
    // 三张里两张已经是这个值：只落第三张。
    batch = await s.editFieldsBatch(<SrsFieldChange>[
      for (final String c in cards.skip(1).take(3))
        SrsFieldChange(SrsEntityKind.card, c, SrsFieldKeys.flag, 2),
    ]);
    expect(batch.map((SrsFieldEdit e) => e.entityId), <String>[cards[3]]);

    costs['writeEdits'] = await _cost(s, 'writeEdits', () async {
      batch = await s.writeEdits(<SrsEditSpec>[
        for (final String n in notes.take(3))
          SrsEditSpec(SrsEntityKind.note, n, back, 'bulk'),
      ]);
    });
    expect(batch, hasLength(3));
    expect(
      await s.writeEdits(<SrsEditSpec>[
        for (final String n in notes.take(3))
          SrsEditSpec(SrsEntityKind.note, n, back, 'bulk'),
      ]),
      isEmpty,
    );

    int created = 0;
    late String made;
    costs['createNote'] = await _cost(s, 'createNote', () async {
      made = await s.createNote(
        noteTypeId: basic.id,
        fieldsById: <String, String>{
          basic.fields[0].id: 'front ${created++}',
          basic.fields[1].id: 'back',
        },
        guid: 'preread-cost',
      );
    });
    expect((await s.note(made))!.fields[basic.fields[1].id], 'back');
    // 同一个 guid 再建一次、内容相同：字段值没变，修改记录一条不落（身份记录那一项照旧交给内核，不归这里管）。
    final Object? editsBefore = (_signals(s)).last;
    await s.createNote(
      noteTypeId: basic.id,
      fieldsById: <String, String>{
        basic.fields[0].id: 'front 0',
        basic.fields[1].id: 'back',
      },
      guid: 'preread-cost',
    );
    expect((_signals(s)).last, editsBefore);

    expect(costs, <String, _Cost>{
      'editFields': (statements: 0, core: 1),
      'editFields(no-op)': (statements: 0, core: 1),
      'editFieldsBatch': (statements: 0, core: 1),
      'writeEdits': (statements: 0, core: 1),
      'createNote': (statements: 0, core: 1),
    });
  });

  test('旧 Lapis 迁移 / 补迁 / 换笔记类型：同一批笔记只物化一次', () async {
    final BulkFixture f = await BulkFixture.open(notes: 6);
    final SrsDbStore s = f.store;
    String lapis(String key) => srsLapisFieldId(kBulkUid, key);
    String fushi(String key) => srsFushiCardFieldId(kBulkUid, key);
    final Map<String, _Cost> costs = <String, _Cost>{};

    // ---- 换笔记类型：Basic → Basic 的副本，6 条笔记。
    final SrsNoteTypeView basic = (await s.noteType(basicTypeId(s)))!;
    final String copyId = await s.cloneNoteType(basic.id, 'Basic copy');
    final SrsNoteTypeView copy = (await s.noteType(copyId))!;
    final List<String> basicNotes = await s.noteIdsOfType(basic.id);
    expect(basicNotes, hasLength(6));
    costs['changeNoteType'] = await _cost(
      s,
      'changeNoteType',
      () => s.changeNoteType(
        noteIds: basicNotes,
        targetTypeId: copy.id,
        fieldMap: <String, String?>{
          for (int i = 0; i < copy.fields.length; i++)
            copy.fields[i].id: basic.fields[i].id,
        },
        templateMap: <String, String?>{
          for (int i = 0; i < copy.templates.length; i++)
            copy.templates[i].id: basic.templates[i].id,
        },
      ),
    );
    expect(await s.noteIdsOfType(copy.id), hasLength(6));

    // ---- 旧 Lapis 迁移：6 条内置 Lapis 笔记，带一个用户自加的来源字段（迁移时走补迁那一段）。
    final String src = await s.addField(s.lapisNoteTypeId, 'SourceInfo');
    final List<String> lapisNotes = <String>[
      for (int i = 0; i < 6; i++)
        await s.createNote(
          noteTypeId: s.lapisNoteTypeId,
          fieldsById: <String, String>{
            lapis('Expression'): '語$i',
            src: 'Book $i',
          },
        ),
    ];
    late int migrated;
    costs['migrateLegacyLapis'] = await _cost(
      s,
      'migrateLegacyLapis',
      () async {
        migrated = await s.migrateLegacyLapis(s.lapisNoteTypeId);
      },
    );
    expect(migrated, 6);
    for (int i = 0; i < 6; i++) {
      final SrsNoteView n = (await s.note(lapisNotes[i]))!;
      expect(n.noteTypeId, s.fushiCardNoteTypeId);
      expect(n.field(fushi('Expression')), '語$i');
      expect(n.field(fushi('MiscInfo')), 'Book $i', reason: '补迁与换类型同一笔');
    }

    // ---- 遗漏字段补迁：按旧办法（只认同名）迁过的两条笔记，来源字段没带过来。
    final List<String> old = <String>[
      for (int i = 0; i < 2; i++)
        await s.createNote(
          noteTypeId: s.lapisNoteTypeId,
          fieldsById: <String, String>{
            lapis('Expression'): '旧$i',
            src: 'Old $i',
          },
        ),
    ];
    final SrsNoteTypeView from = (await s.noteType(s.lapisNoteTypeId))!;
    final SrsNoteTypeView to = (await s.noteType(s.fushiCardNoteTypeId))!;
    await s.changeNoteType(
      noteIds: old,
      targetTypeId: to.id,
      fieldMap: <String, String?>{
        for (final SrsFieldDef x in to.fields)
          x.id: from.fields
              .where(
                (SrsFieldDef y) =>
                    y.name.toLowerCase() ==
                    FushiCardFields.legacyNameOf(x.name).toLowerCase(),
              )
              .firstOrNull
              ?.id,
      },
      templateMap: <String, String?>{
        to.templates.single.id: from.templates.single.id,
      },
    );
    expect((await s.note(old[0]))!.field(fushi('MiscInfo')), '');
    late int filled;
    costs['applyLapisBackfill'] = await _cost(
      s,
      'applyLapisBackfill',
      () async {
        filled = await s.applyLapisBackfill();
      },
    );
    expect(filled, 2);
    expect((await s.note(old[1]))!.field(fushi('MiscInfo')), 'Old 1');
    expect(await s.applyLapisBackfill(), 0);

    for (final _Cost c in costs.values) {
      expect(c.core, 1, reason: '读完算好，一条命令落库');
    }
    expect(
      costs.map((String k, _Cost c) => MapEntry<String, int>(k, c.statements)),
      <String, int>{
        'changeNoteType': kChangeNoteTypeStatements,
        'migrateLegacyLapis': kMigrateLegacyLapisStatements,
        'applyLapisBackfill': kApplyLapisBackfillStatements,
      },
    );
  });

  test('彻底清除：一批笔记一条命令，每 200 条一块', () async {
    final BulkFixture f = await BulkFixture.open(notes: 6);
    final SrsDbStore s = f.store;
    final SrsNoteTypeView basic = (await s.noteType(basicTypeId(s)))!;
    Future<List<String>> make(int n, String tag) async {
      final List<SrsEventDraft> drafts = <SrsEventDraft>[];
      final List<String> ids = <String>[];
      for (int i = 0; i < n; i++) {
        final String guid = 'purge-$tag-$i';
        ids.add(SrsIds.note(kBulkUid, guid));
        drafts.addAll(
          s.newNoteDrafts(
            noteTypeId: basic.id,
            fieldsById: <String, String>{
              basic.fields[0].id: 'f $tag $i',
              basic.fields[1].id: 'b',
            },
            guid: guid,
          ),
        );
      }
      await s.importDrafts(drafts);
      return ids;
    }

    int purged() =>
        s.core
                .debugSelectRaw('SELECT COUNT(*) AS n FROM sync2_purged')
                .single['n']!
            as int;

    final List<String> five = await make(5, 'a');
    final List<String> many = await make(205, 'b');
    final Map<String, _Cost> costs = <String, _Cost>{};
    final int opsBefore = (await s.sync2Status())['ops']! as int;
    // 空的一批：一条命令都不发。
    expect(
      await _cost(s, 'purge(0)', () => srsPurgeNotesNow(s, const <String>[])),
      (statements: 0, core: 0),
    );
    late SrsPurgeReport report;
    costs['purge(5)'] = await _cost(s, 'purge(5)', () async {
      report = await srsPurgeNotesNow(s, five);
    });
    expect(report.notes, 5);
    expect(purged(), 5);
    expect(
      (await s.sync2Status())['ops'],
      opsBefore + 10,
      reason: '每条笔记一条删除 + 一条 Purge，与逐条发相同',
    );
    costs['purge(205)'] = await _cost(s, 'purge(205)', () async {
      report = await srsPurgeNotesNow(s, many);
    });
    expect(report.notes, 205);
    expect(purged(), 210);
    expect((await s.sync2Status())['ops'], opsBefore + 420);

    expect(costs, <String, _Cost>{
      'purge(5)': (statements: 0, core: 1),
      'purge(205)': (statements: 0, core: 2),
    });
  });
}

/// 这三条路径改动后的 Drift 语句数（只读查询；每条是什么见各自的实现）。改动前各多：换笔记类型 2 条（现值预读：
/// 笔记、卡片两类实体各一条）、旧 Lapis 迁移 4 条（第二遍物化的 2 条 + 现值预读 2 条）、补迁 1 条（现值预读，只有笔记）。
const int kChangeNoteTypeStatements = 5;
const int kMigrateLegacyLapisStatements = 11;
const int kApplyLapisBackfillStatements = 8;
