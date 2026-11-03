// 复习（SRS）批量改笔记操作（`srs.notes.card-type` / `set_field` / `find_replace`）：经
// [OpInvoker] 以模型身份执行 → 写穿真 SrsDbStore → 撤销写回原值；预演不写；之后又被改过的
// 字段撤销时不覆盖。撤销载荷先过一遍 JSON 往返（与持久化进 ai_agent_actions 同口径）。
//
// 场景取自真实问题：从旧 Lapis 迁到 Fushi 卡片的笔记四个卡型开关全空 → 卡面当单词卡、正面
// 不显示例句；用「开关全空且有例句」的查询一次设成「单词 + 例句」。
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi/src/srs/srs_fushi_card_plan.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_batch_edit.dart';
import 'package:fushi_srs/fushi_srs.dart';

import '../srs/srs_test_support.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('复习操作不应访问 ref（依赖经 debugOverrideSrsCtlDeps 注入）');
}

String _fc(String field) =>
    srsBuiltinFieldId(kSrsTestProfile, kSrsBuiltinFushiCardKey, field);

/// 一条 Fushi 卡片笔记（[flags] = 开关字段名 → 值）。
Future<String> _addFushiCard(
  SrsDbStore s,
  String term, {
  String sentence = '',
  Map<String, String> flags = const <String, String>{},
}) => s.createNote(
  noteTypeId: srsBuiltinNoteTypeId(kSrsTestProfile, kSrsBuiltinFushiCardKey),
  fieldsById: <String, String>{
    _fc('Term'): term,
    if (sentence.isNotEmpty) _fc('Sentence'): sentence,
    for (final MapEntry<String, String> f in flags.entries) _fc(f.key): f.value,
  },
);

/// 卡面看到的字段（名字 → 值），喂给 [srsFushiFrontKind]。
Future<Map<String, String>> _byName(SrsDbStore s, String noteId) async {
  final SrsNoteView n = (await s.note(noteId))!;
  final SrsNoteTypeView t = (await s.noteType(n.noteTypeId))!;
  return <String, String>{
    for (final SrsFieldDef f in t.fields) f.name: n.field(f.id),
  };
}

class _Ops {
  _Ops(SrsDbStore store) {
    final OpContext context = OpContext(ref: _UnusedRef());
    debugOverrideSrsCtlDeps(
      context,
      SrsCtlDeps(
        store: () async => store,
        moduleEnabled: () => true,
        changed: () => changed++,
      ),
    );
    catalog = buildAppOpCatalog(context, buildDomainOpRoutes(context));
    invoker = OpInvoker(catalog);
  }

  late final OpCatalog catalog;
  late final OpInvoker invoker;
  int changed = 0;

  Future<(Map<String, Object?>, OpUndoRecord)> run(
    String id,
    Map<String, Object?> args,
  ) async {
    final OpInvocation done = await invoker.invoke(
      id,
      args,
      caller: OpCaller.model,
      captureUndo: true,
    );
    expect(done.undo, isNotNull, reason: '$id 应返回撤销载荷');
    return (done.result! as Map<String, Object?>, done.undo!);
  }

  Future<OpUndoStatus> undo(String id, OpUndoRecord record) async {
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(record.payload)) as Map<String, Object?>;
    return (await catalog[id]!.undo!.revert(payload)).status;
  }
}

/// 开关全空、有例句的笔记（不依赖「空字段」搜索：没写过值的字段可能不在搜索枚举里）。
const String _noFlagsWithSentence =
    '-IsSentenceCard:_* -IsWordAndSentenceCard:_* -IsClickCard:_* '
    '-IsAudioCard:_* Sentence:_*';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('描述：三条批量改笔记都是可撤销的写操作', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    addTearDown(db.close);
    final _Ops ops = _Ops(store);
    for (final String id in <String>[
      'srs.notes.card-type',
      'srs.notes.set-field',
      'srs.notes.find-replace',
    ]) {
      expect(ops.catalog[id]!.risk, OpRisk.write, reason: id);
      expect(ops.catalog[id]!.undo, isNotNull, reason: id);
    }
  });

  test('卡型：查询选中开关全空的笔记 → 预演不写 → 设成单词 + 例句 → 撤销', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    addTearDown(db.close);
    final _Ops ops = _Ops(store);
    final String broken = await _addFushiCard(
      store,
      '肩透かし',
      sentence: 'それが<b>肩透かし</b>に終わった',
    );
    final String click = await _addFushiCard(
      store,
      '梢',
      sentence: '<b>梢</b>が揺れる',
      flags: <String, String>{'IsClickCard': 'x'},
    );
    final String noSentence = await _addFushiCard(store, '藍');
    expect(
      srsFushiFrontKind(await _byName(store, broken)),
      SrsFushiFrontKind.word,
    );

    final (Map<String, Object?> preview, _) = await ops.run(
      'srs.notes.card-type',
      <String, Object?>{
        'type': 'word-and-sentence',
        'q': _noFlagsWithSentence,
        'dryRun': true,
      },
    );
    expect(preview['notes'], 1);
    expect(preview['dryRun'], isTrue);
    expect(ops.changed, 0);
    expect(
      srsFushiFrontKind(await _byName(store, broken)),
      SrsFushiFrontKind.word,
    );

    final (Map<String, Object?> done, OpUndoRecord record) = await ops.run(
      'srs.notes.card-type',
      <String, Object?>{'type': 'word-and-sentence', 'q': _noFlagsWithSentence},
    );
    expect(done['notes'], 1);
    expect(
      srsFushiFrontKind(await _byName(store, broken)),
      SrsFushiFrontKind.wordAndSentence,
    );
    // 查询外的笔记不动：点击卡仍是点击卡，没例句的仍是单词卡。
    expect(
      srsFushiFrontKind(await _byName(store, click)),
      SrsFushiFrontKind.click,
    );
    expect(
      srsFushiFrontKind(await _byName(store, noSentence)),
      SrsFushiFrontKind.word,
    );

    expect(await ops.undo('srs.notes.card-type', record), OpUndoStatus.done);
    expect(
      srsFushiFrontKind(await _byName(store, broken)),
      SrsFushiFrontKind.word,
    );
  });

  test('卡型：设成例句卡会关掉其余开关；未知卡型 / 不给目标 → 400', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    addTearDown(db.close);
    final _Ops ops = _Ops(store);
    final String n = await _addFushiCard(
      store,
      '梢',
      sentence: 's',
      flags: <String, String>{'IsClickCard': 'x', 'IsWordAndSentenceCard': 'x'},
    );
    await ops.run('srs.notes.card-type', <String, Object?>{
      'type': 'sentence',
      'notes': <String>[n],
    });
    final Map<String, String> f = await _byName(store, n);
    expect(f['IsSentenceCard'], 'x');
    expect(f['IsClickCard'], '');
    expect(f['IsWordAndSentenceCard'], '');

    Matcher bad() => throwsA(
      isA<CtlFailure>().having((CtlFailure e) => e.status, 'status', 400),
    );
    expect(
      () => ops.invoker.invoke('srs.notes.card-type', <String, Object?>{
        'type': 'nope',
        'notes': <String>[n],
      }, caller: OpCaller.model),
      bad(),
    );
    expect(
      () => ops.invoker.invoke('srs.notes.card-type', <String, Object?>{
        'type': 'word',
      }, caller: OpCaller.model),
      bad(),
    );
  });

  test('设置字段 / 查找替换（正则分组）→ 撤销；之后又改过的字段撤销不覆盖', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    addTearDown(db.close);
    final _Ops ops = _Ops(store);
    final String a = await _addFushiCard(store, '魚', sentence: '魚を食べる');
    final String b = await _addFushiCard(store, '肉', sentence: '肉を食べる');

    final (Map<String, Object?> set, OpUndoRecord setUndo) = await ops.run(
      'srs.notes.set-field',
      <String, Object?>{
        'targetField': 'Hint',
        'value': ' 食べ物 ',
        'notes': <String>[a, b],
      },
    );
    expect(set['notes'], 2);
    expect((await _byName(store, a))['Hint'], ' 食べ物 ');

    final (_, OpUndoRecord frUndo) = await ops.run(
      'srs.notes.find-replace',
      <String, Object?>{
        'find': r'(\S)を食べる',
        'replace': r'<b>$1</b>を飲む',
        'regex': true,
        'targetField': 'Sentence',
        'notes': <String>[a, b],
      },
    );
    expect((await _byName(store, a))['Sentence'], '<b>魚</b>を飲む');
    expect((await _byName(store, b))['Sentence'], '<b>肉</b>を飲む');

    // b 的例句之后被手动改过：撤销查找替换只恢复 a。
    await store.updateNote(
      b,
      fieldsById: <String, String>{_fc('Sentence'): '手改'},
    );
    expect(await ops.undo('srs.notes.find-replace', frUndo), OpUndoStatus.done);
    expect((await _byName(store, a))['Sentence'], '魚を食べる');
    expect((await _byName(store, b))['Sentence'], '手改');

    expect(await ops.undo('srs.notes.set-field', setUndo), OpUndoStatus.done);
    expect((await _byName(store, a))['Hint'], '');

    expect(
      () => ops.invoker.invoke('srs.notes.find-replace', <String, Object?>{
        'find': '(',
        'regex': true,
        'notes': <String>[a],
      }, caller: OpCaller.model),
      throwsA(
        isA<CtlFailure>().having((CtlFailure e) => e.status, 'status', 400),
      ),
    );
  });

  test('落库是条件写：计划之后字段又被改过的笔记不覆盖、计 conflicts，撤销载荷只含实际写下的', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    addTearDown(db.close);
    final _Ops ops = _Ops(store);
    final String a = await _addFushiCard(store, '魚', sentence: '魚を食べる');
    final String b = await _addFushiCard(store, '肉', sentence: '肉を食べる');

    final SrsNoteFieldPlan plan = await srsPlanSetField(
      store,
      <String>[a, b],
      'Hint',
      'h',
    );
    expect(plan.noteCount, 2);
    // 计划与确认之间 b 被别处改了（同步拉下 / 并发写）。
    await store.updateNote(b, fieldsById: <String, String>{_fc('Hint'): '别处'});
    final SrsNoteFieldApplied applied = await srsApplyNoteFieldPlan(
      store,
      plan,
    );
    expect(applied.conflicts, 1);
    expect(applied.noteCount, 1);
    expect((await _byName(store, a))['Hint'], 'h');
    expect((await _byName(store, b))['Hint'], '别处');
    expect(await applied.outcome.revert!(store), 0);
    expect((await _byName(store, a))['Hint'], '');

    // 经操作目录：撤销载荷 = 实际写下的改动（不在执行前另算一遍计划）。
    final (Map<String, Object?> done, OpUndoRecord record) = await ops.run(
      'srs.notes.set-field',
      <String, Object?>{
        'targetField': 'Hint',
        'value': 'z',
        'notes': <String>[a],
      },
    );
    expect(done['notes'], 1);
    expect(done.containsKey('conflicts'), isFalse);
    final List<Object?> changes = record.payload['changes']! as List<Object?>;
    expect(changes, hasLength(1));
    expect((changes.single! as Map<String, Object?>)['after'], 'z');
  });

  test('CLI 经 /ops/call 执行：撤销记录落进操作记录，按记录能撤销', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    addTearDown(db.close);
    final _Ops ops = _Ops(store);
    final String a = await _addFushiCard(store, '魚', sentence: '魚を食べる');
    final List<CtlRoute> routes = buildOpCatalogRoutes(
      () => ops.invoker,
      recordUndo: (FushiOp op, Map<String, Object?> args, OpUndoRecord undo) =>
          recordCliOpUndo(db, op, args, undo),
    );
    final CtlRoute call = routes.singleWhere(
      (CtlRoute r) => r.method == 'POST' && r.pattern == kCtlOpsCallPath,
    );
    final Object? result = await call.handler(
      CtlCall(
        method: 'POST',
        path: kCtlOpsCallPath,
        body: <String, Object?>{
          'id': 'srs.notes.card-type',
          'args': <String, Object?>{
            'type': 'word-and-sentence',
            'notes': <String>[a],
          },
        },
      ),
    );
    final Map<String, Object?> data = result! as Map<String, Object?>;
    expect(data['notes'], 1);
    final int actionId = data[kCtlOpsUndoActionIdKey]! as int;
    expect(
      srsFushiFrontKind(await _byName(store, a)),
      SrsFushiFrontKind.wordAndSentence,
    );

    final AiAgentActionRow row = (await db.getAiAgentAction(actionId))!;
    expect(row.sessionId, kCliOpSessionId);
    expect(row.opId, 'srs.notes.card-type');
    expect(row.confirmation, 'user');
    final Map<String, Object?> payload =
        jsonDecode(row.undoPayloadJson!) as Map<String, Object?>;
    expect(
      (await ops.catalog[row.opId]!.undo!.revert(payload)).status,
      OpUndoStatus.done,
    );
    expect(srsFushiFrontKind(await _byName(store, a)), SrsFushiFrontKind.word);
  });

  test('CLI 卡型值域与引擎 SrsCardType.wire 一致', () {
    expect(kSrsCardTypes, <String>[
      for (final SrsCardType t in SrsCardType.values) t.wire,
    ]);
  });
}
