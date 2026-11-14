// 收掉 Dart 写路径第 10 步的意图命令（内核自己读现值、自己判、自己写）在 `SrsDbStore` 这一层的行为：
// - `editNoteFieldsIf`（`note_fields_if`）：落计划按整条笔记拒绝、撤销逐项拒绝；
// - `mergeNotesInto`（`merge_notes`）：出错什么都不落、错误文案；
// - `liveMediaRefs`（`media_live_refs`）：与以前 Dart 里那份「存活引用」口径逐项相同；
// - `answerAndStudy` 的 `expectBase`（`apply` 的 `expectLast`）：基准不成立什么都不落、不重读本机状态。
// 内核一侧的细节（分组、时钟、回滚、分批、缓存待刷新时推迟）在 native/fushi_fsrs 的测试里。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart' show srsMediaRefsIn;
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_note_batch_edit.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_purge.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_bulk_fixture.dart';

const int _day = 24 * 60 * 60 * 1000;

Future<int> _ops(SrsDbStore s) async =>
    (await s.db.customSelect('SELECT COUNT(*) AS n FROM sync2_ops').getSingle())
        .read<int>('n');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('条件写笔记字段：落计划按整条笔记拒绝，撤销逐项拒绝，值没变的不写', () async {
    final BulkFixture f = await BulkFixture.open(notes: 4);
    final SrsDbStore s = f.store;
    final SrsNoteTypeView basic = (await s.noteType(basicTypeId(s)))!;
    final String front = basic.fields[0].id;
    final String back = basic.fields[1].id;
    final List<String> notes = await s.noteIdsOfType(basic.id);
    final Map<String, SrsNoteView?> views = await s.notes(notes);
    String was(String note, String field) => views[note]!.field(field);
    await s.deleteNote(notes[3]);

    // 落计划：notes[1] 的第二项对不上 → 整条不写，连对得上的那一项也不写；已删除的、不存在的拒绝。
    const String gone = '0193a1b2-0000-7000-8000-0000000000ff';
    Set<String> rejected = await s.editNoteFieldsIf(<SrsNoteFieldWrite>[
      (
        noteId: notes[0],
        fieldId: front,
        expect: was(notes[0], front),
        value: 'F0',
      ),
      (
        noteId: notes[0],
        fieldId: back,
        expect: was(notes[0], back),
        value: 'B0',
      ),
      (
        noteId: notes[1],
        fieldId: front,
        expect: was(notes[1], front),
        value: 'F1',
      ),
      (noteId: notes[1], fieldId: back, expect: 'stale', value: 'B1'),
      (
        noteId: notes[3],
        fieldId: front,
        expect: was(notes[3], front),
        value: 'F3',
      ),
      (noteId: gone, fieldId: front, expect: '', value: 'x'),
    ], wholeNote: true);
    expect(rejected, <String>{notes[1], notes[3], gone});
    expect((await s.note(notes[0]))!.field(front), 'F0');
    expect((await s.note(notes[0]))!.field(back), 'B0');
    expect((await s.note(notes[1]))!.field(front), was(notes[1], front));
    expect((await s.note(notes[3]))!.field(front), was(notes[3], front));

    // 撤销：逐项。notes[0] 的正面之后又被改过 → 那一项不动、背面照写回；笔记计入拒绝。
    await s.updateNote(notes[0], fieldsById: <String, String>{front: 'later'});
    rejected = await s.editNoteFieldsIf(<SrsNoteFieldWrite>[
      (
        noteId: notes[0],
        fieldId: front,
        expect: 'F0',
        value: was(notes[0], front),
      ),
      (
        noteId: notes[0],
        fieldId: back,
        expect: 'B0',
        value: was(notes[0], back),
      ),
    ], wholeNote: false);
    expect(rejected, <String>{notes[0]});
    expect((await s.note(notes[0]))!.field(front), 'later');
    expect((await s.note(notes[0]))!.field(back), was(notes[0], back));

    // 值没变的不产生记录；修订号不动。
    final int ops = await _ops(s);
    final int revision = s.revision;
    expect(
      await s.editNoteFieldsIf(<SrsNoteFieldWrite>[
        (
          noteId: notes[2],
          fieldId: front,
          expect: was(notes[2], front),
          value: was(notes[2], front),
        ),
      ], wholeNote: true),
      isEmpty,
    );
    expect(await _ops(s), ops);
    expect(s.revision, revision);

    // srs_note_batch_edit.dart 的两个入口经它走。
    final SrsNoteFieldApplied applied = await srsApplyNoteFieldPlan(
      s,
      SrsNoteFieldPlan(
        changes: <SrsNoteFieldChange>[
          SrsNoteFieldChange(
            noteId: notes[2],
            fieldId: back,
            fieldName: basic.fields[1].name,
            before: was(notes[2], back),
            after: 'plan',
          ),
          SrsNoteFieldChange(
            noteId: notes[1],
            fieldId: back,
            fieldName: basic.fields[1].name,
            before: 'stale',
            after: 'plan',
          ),
        ],
        skipped: const <String>[],
        unchanged: 0,
        missing: const <String>[],
      ),
    );
    expect(applied.conflicts, 1);
    expect(applied.changes.map((SrsNoteFieldChange c) => c.noteId), <String>[
      notes[2],
    ]);
    expect(await srsRevertNoteFieldChanges(s, applied.changes), 0);
    expect((await s.note(notes[2]))!.field(back), was(notes[2], back));
  });

  test('合并重复笔记：笔记不存在报 not found、什么都不落；已删除的笔记照常参与', () async {
    final BulkFixture f = await BulkFixture.open(notes: 3);
    final SrsDbStore s = f.store;
    final List<String> notes = await s.noteIdsOfType(basicTypeId(s));
    const String gone = '0193a1b2-0000-7000-8000-0000000000ff';
    final int ops = await _ops(s);
    final int revision = s.revision;
    await expectLater(
      s.mergeNotes(keepId: notes[0], absorbIds: <String>[notes[1], gone]),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          'note $gone not found',
        ),
      ),
    );
    // 连还原点都没落（以前还原点之前就报错；现在整条命令一笔）。
    expect(await _ops(s), ops);
    expect(s.revision, revision);
    expect((await s.note(notes[1]))!.deletedAt, isNull);
    // 保留自己不算被吸收的。
    expect(
      (await s.mergeNotes(
        keepId: notes[0],
        absorbIds: <String>[notes[0]],
      )).linkedCards,
      0,
    );
    expect(await _ops(s), ops);
    // 已删除的笔记照常并进来（它的卡挂成前身）。
    await s.deleteNote(notes[2]);
    final SrsMergeReport r = await s.mergeNotes(
      keepId: notes[0],
      absorbIds: <String>[notes[2], notes[2]],
    );
    expect(r.linkedCards, 2);
    expect(r.unmatchedCards, 0);
  });

  test('存活引用：内核的口径与以前 Dart 里那份逐项相同', () async {
    final BulkFixture f = await BulkFixture.open(notes: 3);
    final SrsDbStore s = f.store;
    final SrsNoteTypeView basic = (await s.noteType(basicTypeId(s)))!;
    final String front = basic.fields[0].id;
    final String back = basic.fields[1].id;
    await s.saveTemplateEdits(
      basic.id,
      basic.templates[0].id,
      front:
          '${basic.templates[0].front}<img src="tpl.png">[sound:tpl.mp3]'
          '<script src="_helper.js"></script>',
      // 纯 CSS：没有 `<`，只有下划线开头的静态引用。
      css:
          '.card { color: red } @font-face { src: url("_font.woff") } '
          ".x { background: url( '_bg one.png' ) } .y { src: url(_plain.ttf) }",
    );
    Future<String> note(String html) => s.createNote(
      noteTypeId: basic.id,
      fieldsById: <String, String>{front: 'w ${html.length}', back: html},
    );
    await note(
      '<img src="live.png"><img src="c:colon.png"><img src="sub/x.png">',
    );
    await note('[sound:live.mp3]<img src="http://example.com/remote.png">');
    final String deleted = await note('<img src="Deleted.PNG">');
    await s.deleteNote(deleted);

    // 以前 Dart 的算法（srs_media_sync.dart `srsLiveMediaReferences`，第 10 步之前）。
    Future<Set<String>> dartLive(int cutoff) async {
      final Set<String> out = await s.noteMediaRefs(deletedAfterMs: cutoff);
      final Map<String, SrsNoteTypeView?> types = await s.noteTypesById(
        await s.entityIds(SrsEntityKind.noteType),
      );
      for (final SrsNoteTypeView? t in types.values) {
        if (t == null) continue;
        for (final SrsTemplateDef tpl in t.templates) {
          out.addAll(srsMediaRefsIn(tpl.front, includeStatic: true));
          out.addAll(srsMediaRefsIn(tpl.back, includeStatic: true));
        }
        out.addAll(srsMediaRefsIn(t.css, includeStatic: true));
      }
      return out.where(srsIsBareMediaName).toSet();
    }

    final int now = s.now().$1;
    for (final int cutoff in <int>[now - 90 * _day, now]) {
      final Set<String> kernel = await s.liveMediaRefs(aliveAfterMs: cutoff);
      expect(kernel, await dartLive(cutoff), reason: 'cutoff $cutoff');
      expect(
        kernel,
        containsAll(<String>[
          'tpl.png',
          'tpl.mp3',
          '_helper.js',
          '_font.woff',
          '_bg',
          '_plain.ttf',
          'live.png',
          'live.mp3',
          'c:colon.png',
        ]),
      );
      expect(kernel, isNot(contains('sub/x.png')));
      expect(kernel.contains('Deleted.PNG'), cutoff < now);
    }
    expect(
      await srsLiveMediaReferences(s),
      await s.liveMediaRefs(
        aliveAfterMs: now - kSrsMediaRetention.inMilliseconds,
      ),
    );
  });

  test('没有媒体目录的副本彻底清除笔记：不往待回收集合里记名字', () async {
    final BulkFixture f = await BulkFixture.open(notes: 1);
    final SrsDbStore s = f.store;
    final SrsNoteTypeView basic = (await s.noteType(basicTypeId(s)))!;
    final String id = await s.createNote(
      noteTypeId: basic.id,
      fieldsById: <String, String>{
        basic.fields[0].id: 'w',
        basic.fields[1].id: '<img src="x.png">',
      },
    );
    expect((await srsPurgeNotesNow(s, <String>[id])).notes, 1);
    expect(await s.pendingMediaGc(), isEmpty);
  });

  test('带基准的作答：基准不成立什么都不落、不重读本机状态；成立照常落', () async {
    final BulkFixture f = await BulkFixture.open(notes: 2);
    final SrsDbStore s = f.store;
    final List<String> cards = <String>[
      for (final SrsCardCacheRow c in await s.allCardRows()) c.id,
    ]..sort();
    final String card = cards.first;
    final String? base = (await s.cardRow(card))!.lastLogId;
    // 出题之后这张卡在别处被作答了。
    final SrsReviewLog first = await s.answer(card, 3);
    final int ops = await _ops(s);
    final int revision = s.revision;
    final int core = s.debugCoreCommands;
    SrsInlineExecutor.debugStatements = 0;
    await expectLater(
      s.answerAndStudy(card, 4, expectBase: (lastLogId: base)),
      throwsA(
        isA<SrsStaleCardError>().having(
          (SrsStaleCardError e) => e.cardId,
          'cardId',
          card,
        ),
      ),
    );
    // 预览 + 被拒的 `apply`；没有写失败后的重读（那是 Drift 读）。
    expect(s.debugCoreCommands - core, 2);
    expect(SrsInlineExecutor.debugStatements, 0);
    expect(await _ops(s), ops);
    expect(s.revision, revision);
    expect((await s.cardRow(card))!.lastLogId, first.id);
    // 卡不存在：同样是基准不成立。
    await expectLater(
      s.answerAndStudy(
        '0193a1b2-0000-7000-8000-0000000000ff',
        3,
        expectBase: (lastLogId: null),
      ),
      throwsA(isA<SrsStaleCardError>()),
    );
    // 基准成立：照常落一条日志。
    final SrsAnswerOutcome out = await s.answerAndStudy(
      card,
      4,
      expectBase: (lastLogId: first.id),
    );
    expect((await s.cardRow(card))!.lastLogId, out.log.id);
    expect(s.revision, greaterThan(revision));
  });
}
