import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_engine/srs/srs_note_batch_edit.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart'
    show opCustomUndo, opUndoStrings;

/// 复习（SRS）：牌组 / 笔记查询、统计、sync v2 冲突、重复笔记合并的操作描述（spec §4）。
///
/// 撤销统一按撤销凭据走（`package:fushi_engine/srs/srs_edit_undo.dart`，[_editUndo]）：路由在
/// [SrsDbStore.undoable] 里写入、记下每个被改字段键的改前 / 改后值与修改记录的 dot；撤销时内核按库里的修改记录
/// 裁决，只还原之后没被别人动过的键（同步拉进来的别的设备的修改、AI / 别处又改过的保留现值），撤销结果按
/// 全部 / 部分 / 一处都没撤成报 done / partial / superseded，没撤成的键列在 message 里（[srsUndoOutcome]）：
/// - 被扣住的删除选「删除」：内核追加 `deleted = <时刻>`，笔记 / 卡 / 牌组只是墓碑；撤销 = 写回 `deleted = null`。
/// - 标志 / 设置类冲突：撤销 = 写回裁决前生效的值（被覆盖的候选不会重新出现在冲突中心）。
/// - 重复笔记合并：撤销 = 保留笔记被补上的字段 / 标签、保留卡上新挂的前身链接（`historyFrom/<被吸收卡>`）、
///   被吸收笔记的删除各自写回原值。
/// - 「不是重复」：撤销 = 把写上的 `notDup/<对方>` 改回原值。
/// - 批量改笔记：撤销 = 实际写下的字段写回原值。
///
/// 撤销不了、标 irreversible：被扣住的删除选「保留」——另一台设备的删除作废、冲突项消失，
/// 内核没有「重新扣住」的操作，回不到「待定」状态。
List<OpDescription> describeSrsOps(OpDescribeKit kit) {
  final SrsCtlDeps deps = srsCtlDeps(kit.context);
  // 与路由同一个模块门（[SrsCtlDeps.moduleEnabled] = AppModel.moduleEnabled(ModuleId.srs)）。
  OpAvailability srsOn() => deps.moduleEnabled()
      ? const OpAvailability.available()
      : OpAvailability.unavailable('module_disabled', ModuleId.srs.name);
  return <OpDescription>[
    OpDescription(
      id: 'srs.decks.list',
      method: 'GET',
      pattern: '$kSrsCtlRoot/decks',
      summary:
          'List review decks (parents first) with today\'s new / learning / due '
          'counts, same as the deck list page.',
      availability: srsOn,
    ),
    OpDescription(
      id: 'srs.notes.search',
      method: 'GET',
      pattern: '$kSrsCtlRoot/notes',
      summary:
          'Search review notes or cards like the browse page. q uses Anki search '
          'syntax (e.g. "deck:Japanese", "tag:n5", "is:due", "Expression:魚*"); '
          'or give field + q to match "field contains q" without syntax.',
      availability: srsOn,
      params: const <OpParam>[
        OpParam.string('q', description: 'Search text / Anki search query.'),
        OpParam.string(
          'field',
          description:
              'Field name to search in (q = text it must contain); omit to use '
              'q as a full Anki query.',
        ),
        OpParam.string(
          'deck',
          description: 'Only this deck (full name, includes sub-decks).',
        ),
        OpParam.string(
          'mode',
          description: 'notes (default, one row per note) or cards.',
          enumValues: <String>['notes', 'cards'],
        ),
        OpParam.integer('limit', description: 'Max rows (default 50).'),
        OpParam.integer('offset', description: 'Rows to skip.'),
      ],
    ),
    OpDescription(
      id: 'srs.note.get',
      method: 'GET',
      pattern: '$kSrsCtlRoot/notes/:id',
      summary:
          'One review note: note type, all fields by name, tags and its cards '
          '(deck, queue, due, reps, lapses).',
      availability: srsOn,
      params: const <OpParam>[
        OpParam.string(
          'id',
          description: 'Note id (from srs.notes.search).',
          required: true,
          inPath: true,
        ),
      ],
    ),
    OpDescription(
      id: 'srs.stats',
      method: 'GET',
      pattern: '$kSrsCtlRoot/stats',
      summary:
          'Review statistics from the same source as the statistics page: '
          'today\'s reviews and answer buttons, due today / tomorrow / overdue, '
          'card counts by state, 30-day true retention, desired retention, streak.',
      availability: srsOn,
      params: const <OpParam>[
        OpParam.string(
          'deck',
          description: 'Only this deck subtree (deck id or full name).',
        ),
      ],
    ),
    OpDescription(
      id: 'srs.conflicts.list',
      method: 'GET',
      pattern: '$kSrsCtlRoot/conflicts',
      summary:
          'Review sync conflict center: held deletions (deleted on one device '
          'while edited / reviewed / moved on another), overwritten flag or '
          'setting values, notes with field conflicts, and likely duplicate notes.',
      availability: srsOn,
    ),
    OpDescription(
      id: 'srs.conflict.held.delete',
      method: 'POST',
      pattern: '$kSrsCtlRoot/conflicts/held/:id/delete',
      summary:
          'Resolve a held deletion in favour of deleting (the item becomes a '
          'tombstone, its content and review history stay in the log). Undo '
          'revives it.',
      availability: srsOn,
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'id',
          description: 'Held conflict id (from srs.conflicts.list held[].id).',
          required: true,
          inPath: true,
        ),
      ],
      undo: _heldDeleteUndo(deps),
    ),
    OpDescription(
      id: 'srs.conflict.held.keep',
      method: 'POST',
      pattern: '$kSrsCtlRoot/conflicts/held/:id/keep',
      summary:
          'Resolve a held deletion by keeping the item: the other device\'s '
          'deletion is discarded on all devices and the conflict cannot be '
          'reopened.',
      availability: srsOn,
      risk: OpRisk.irreversible,
      params: const <OpParam>[
        OpParam.string(
          'id',
          description: 'Held conflict id (from srs.conflicts.list held[].id).',
          required: true,
          inPath: true,
        ),
        OpParam.userGate(
          'confirm',
          description:
              'User confirmed discarding the other device\'s deletion.',
        ),
      ],
    ),
    OpDescription(
      id: 'srs.conflict.field.resolve',
      method: 'POST',
      pattern: '$kSrsCtlRoot/conflicts/fields/resolve',
      summary:
          'Resolve an overwritten flag / setting value from srs.conflicts.list '
          'fields[]: keep=current confirms the value in effect, keep=replaced '
          'restores the overwritten one. Undo writes the previous value back.',
      availability: srsOn,
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'kind',
          description: 'Entity kind (fields[].kind).',
          required: true,
          enumValues: <String>['profile', 'deck', 'notetype', 'note', 'card'],
        ),
        OpParam.string(
          'entity',
          description: 'Entity id (fields[].entity).',
          required: true,
        ),
        OpParam.string(
          'key',
          description: 'Field key (fields[].key).',
          required: true,
        ),
        OpParam.string(
          'keep',
          description: 'current or replaced.',
          required: true,
          enumValues: <String>['current', 'replaced'],
        ),
      ],
      undo: _fieldResolveUndo(deps),
    ),
    OpDescription(
      id: 'srs.duplicates.merge',
      method: 'POST',
      pattern: '$kSrsCtlRoot/duplicates/merge',
      summary:
          'Merge duplicate notes (same note type): absorbed notes\' review '
          'history joins the kept note\'s matching cards, empty fields are '
          'filled, tags are united, absorbed notes are deleted. Undo splits '
          'them again.',
      availability: srsOn,
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'keep',
          description: 'Note id to keep (duplicates[].notes[0] is suggested).',
          required: true,
        ),
        OpParam.stringList(
          'absorb',
          description: 'Note ids merged into keep.',
          required: true,
        ),
      ],
      undo: _mergeUndo(deps),
    ),
    OpDescription(
      id: 'srs.duplicates.dismiss',
      method: 'POST',
      pattern: '$kSrsCtlRoot/duplicates/dismiss',
      summary:
          'Mark notes as "not duplicates" so the merge suggestion stops '
          'appearing (syncs to all devices). Undo brings the suggestion back.',
      availability: srsOn,
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.stringList(
          'notes',
          description: 'Two or more note ids from one duplicates[] group.',
          required: true,
        ),
      ],
      undo: _dismissUndo(deps),
    ),
    OpDescription(
      id: 'srs.notes.card-type',
      method: 'POST',
      pattern: '$kSrsCtlRoot/notes/batch/card-type',
      summary:
          'Batch-set the card type of Lapis / Fushi-card notes (the four '
          'Is*Card front switches): word (front shows the word only), sentence, '
          'word-and-sentence (word + example sentence, the default for new '
          'cards), click (tap to reveal the sentence) or audio. Notes whose type '
          'has no such switches are skipped. Targets: notes (ids) or a search '
          '(q / field / deck, same as srs.notes.search), max $kSrsCtlBatchNoteLimit '
          'notes. Use dryRun first to preview. Undo writes the old values back.',
      availability: srsOn,
      risk: OpRisk.write,
      params: <OpParam>[
        OpParam.string(
          'type',
          description: 'Card type.',
          required: true,
          enumValues: <String>[
            for (final SrsCardType t in SrsCardType.values) t.wire,
          ],
        ),
        ..._noteBatchTargetParams,
      ],
      undo: _noteBatchUndo(deps, SrsCtlNoteBatch.cardType),
    ),
    OpDescription(
      id: 'srs.notes.set-field',
      method: 'POST',
      pattern: '$kSrsCtlRoot/notes/batch/set-field',
      summary:
          'Batch-set one field (by name, resolved per note type) to a value; an '
          'empty value clears it. Notes whose type has no such field are skipped. '
          'Targets: notes (ids) or a search (q / field / deck), max '
          '$kSrsCtlBatchNoteLimit notes. Use dryRun first. Undo writes the old '
          'values back.',
      availability: srsOn,
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'targetField',
          description: 'Field name to set (e.g. "Hint", "IsClickCard").',
          required: true,
        ),
        OpParam.string(
          'value',
          description: 'New value (HTML allowed); empty / omitted clears it.',
        ),
        ..._noteBatchTargetParams,
      ],
      undo: _noteBatchUndo(deps, SrsCtlNoteBatch.setField),
    ),
    OpDescription(
      id: 'srs.notes.find-replace',
      method: 'POST',
      pattern: '$kSrsCtlRoot/notes/batch/find-replace',
      summary:
          'Batch find & replace in note fields (like Anki\'s Find and Replace), '
          'on the raw field HTML. targetField limits it to one field (default: '
          'all fields). With regex, find is a regular expression and replace may '
          'use \$1 / \${name}. Targets: notes (ids) or a search (q / field / '
          'deck), max $kSrsCtlBatchNoteLimit notes. Use dryRun first. Undo '
          'writes the old values back.',
      availability: srsOn,
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'find',
          description: 'Text / regex to find.',
          required: true,
        ),
        OpParam.string('replace', description: 'Replacement (may be empty).'),
        OpParam.string(
          'targetField',
          description: 'Only this field (name); omit for all fields.',
        ),
        OpParam.boolean('regex', description: 'find is a regular expression.'),
        OpParam.boolean(
          'caseSensitive',
          description: 'Case-sensitive match (default true).',
        ),
        ..._noteBatchTargetParams,
      ],
      undo: _noteBatchUndo(deps, SrsCtlNoteBatch.findReplace),
    ),
  ];
}

/// 批量改笔记的目标与预演参数（三条路由共用）。
const List<OpParam> _noteBatchTargetParams = <OpParam>[
  OpParam.stringList(
    'notes',
    description: 'Note ids to edit (from srs.notes.search). Or give q instead.',
  ),
  OpParam.string(
    'q',
    description:
        'Anki search selecting the notes to edit (e.g. "deck:Japanese '
        'IsWordAndSentenceCard: IsClickCard:").',
  ),
  OpParam.string(
    'field',
    description: 'With q: match notes whose this field contains q (no syntax).',
  ),
  OpParam.string('deck', description: 'With q: only this deck (full name).'),
  OpParam.boolean(
    'dryRun',
    description: 'Only preview: count, skipped notes and sample changes.',
  ),
];

// ─────────────────────────────────────────────────────────────────────────
// 撤销
// ─────────────────────────────────────────────────────────────────────────

/// 撤销结果 → 操作目录的撤销结果：全部撤回 = done；一处都没撤成 = superseded；撤回了一部分 = partial。
/// 没撤成的字段键（之后被别处改过、保留了现值）列进 message，AI / 操作记录 / `fushi_cli ai undo` 都看得到。
OpUndoOutcome srsUndoOutcome(SrsEditUndoResult r) {
  if (r.complete) return const OpUndoOutcome.done();
  const int shown = 20;
  final String kept = <String>[
    for (final SrsEditUndoKept k in r.kept.take(shown))
      '${k.kind.wire}/${k.entityId} ${k.key} = ${jsonEncode(k.current)}',
    if (r.kept.length > shown) '……另 ${r.kept.length - shown} 处',
  ].join('；');
  final String message = '${r.kept.length} 处之后被别处改过，保留了现值：$kept';
  return r.reverted == 0
      ? OpUndoOutcome.superseded(message)
      : OpUndoOutcome.partial(message);
}

/// SRS 写操作的统一撤销（语义见 `package:fushi_engine/srs/srs_edit_undo.dart`）：路由在
/// [SrsDbStore.undoable] 里写入、把撤销凭据挂在 [srsCtlUndo]；载荷 = `undo`（凭据，含每个键的改前 / 改后与
/// dot）+ [show] 给人看的字段；撤销 = [SrsDbStore.revertEdits]，只还原之后没被别人动过的键。
///
/// [legacy]：这一版之前记下的载荷（没有 `undo` 键）换成没有 dot 的凭据，内核只能按值核对。
OpUndo _editUndo(
  SrsCtlDeps deps, {
  required Map<String, Object?> Function(CtlCall call, Object? result) show,
  required String Function(Map<String, Object?> payload) describe,
  Future<SrsEditUndo> Function(SrsDbStore store, Map<String, Object?> payload)?
  legacy,
}) => opCustomUndo(
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
      <String, Object?>{
        ...show(call, result),
        'undo': (srsCtlUndo[call] ?? SrsEditUndo.empty).toJson(),
      },
  describe: describe,
  revert: (Map<String, Object?> payload) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final SrsEditUndo undo = payload.containsKey('undo')
        ? SrsEditUndo.fromJson(payload['undo'])
        : await legacy?.call(store, payload) ?? SrsEditUndo.empty;
    if (undo.isEmpty) return const OpUndoOutcome.done();
    final SrsEditUndoResult r = await store.revertEdits(undo);
    deps.changed();
    return srsUndoOutcome(r);
  },
);

Map<String, Object?> _map(Object? raw) => raw is Map
    ? <String, Object?>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          '${e.key}': e.value,
      }
    : <String, Object?>{};

SrsEntityKind _kindOf(Map<String, Object?> payload, String key) =>
    srsCtlEntityKind('${payload[key]}');

/// 批量改笔记：撤销 = 实际写下的字段写回原值（之后又被改过的保留现值）。
OpUndo _noteBatchUndo(SrsCtlDeps deps, SrsCtlNoteBatch op) => _editUndo(
  deps,
  show: (CtlCall call, Object? result) => <String, Object?>{
    'notes': (srsCtlUndo[call] ?? SrsEditUndo.empty).entityCount,
  },
  describe: (Map<String, Object?> p) => '${op.wire}：${p['notes'] ?? 0} 条笔记',
  legacy: (SrsDbStore store, Map<String, Object?> p) async =>
      srsLegacyNoteFieldUndo(<SrsNoteFieldChange>[
        if (p['changes'] case final List<Object?> raw)
          for (final Object? c in raw) ?SrsNoteFieldChange.fromJson(c),
      ]),
);

/// 被扣住的删除选「删除」→ 撤销 = 写回 `deleted = null`（复活）；之后已被恢复 / 重新删除的不动。
OpUndo _heldDeleteUndo(SrsCtlDeps deps) => _editUndo(
  deps,
  show: (CtlCall call, Object? result) => <String, Object?>{
    'entityKind': _map(result)['entityKind'],
    'entity': _map(result)['entity'],
  },
  describe: (Map<String, Object?> p) => '已删除 ${p['entityKind']}/${p['entity']}',
  legacy: (SrsDbStore store, Map<String, Object?> p) async =>
      SrsEditUndo(<SrsEditUndoItem>[
        SrsEditUndoItem(
          kind: _kindOf(p, 'entityKind'),
          entityId: '${p['entity']}',
          key: SrsFieldKeys.deleted,
          before: null,
          after: p['deletedAt'],
        ),
      ]),
);

/// 标志 / 设置类冲突 → 撤销 = 写回裁决前生效的值。
OpUndo _fieldResolveUndo(SrsCtlDeps deps) => _editUndo(
  deps,
  show: (CtlCall call, Object? result) => _map(result),
  describe: (Map<String, Object?> p) =>
      '${p['kind']}/${p['entity']} ${p['key']}：${jsonEncode(p['previous'])} → ${jsonEncode(p['value'])}',
  legacy: (SrsDbStore store, Map<String, Object?> p) async =>
      SrsEditUndo(<SrsEditUndoItem>[
        SrsEditUndoItem(
          kind: _kindOf(p, 'kind'),
          entityId: '${p['entity']}',
          key: '${p['key']}',
          before: p['previous'],
          after: p['value'],
        ),
      ]),
);

/// 重复笔记合并 → 撤销 = 拆开：保留笔记被补上的字段写回原值、标签按差量撤、保留卡上新挂的前身链接
/// （`historyFrom/<被吸收卡>`）写回原值（血统只认 true）、被吸收的笔记恢复；之后被别处改过的键保留现值。
OpUndo _mergeUndo(SrsCtlDeps deps) => _editUndo(
  deps,
  show: (CtlCall call, Object? result) => <String, Object?>{
    'keep': _map(result)['keep'],
    'absorb': _map(result)['absorbed'],
  },
  describe: (Map<String, Object?> p) =>
      '${opUndoStrings(p['absorb']).join(', ')} → ${p['keep']}',
  legacy: _legacyMergeUndo,
);

/// 这一版之前记下的合并载荷（合并前快照 + 合并后的字段 / 标签，没有 dot）换成凭据。被吸收笔记的删除时刻与
/// 新挂的链接当时没记：按「现在仍是合并留下的状态」补上 after（仍删着 / 链接仍为 true），否则记成撤不成。
Future<SrsEditUndo> _legacyMergeUndo(
  SrsDbStore store,
  Map<String, Object?> p,
) async {
  final String keep = '${p['keep']}';
  final List<String> absorb = opUndoStrings(p['absorb']);
  final Map<String, Object?> oldFields = _map(p['keepFields']);
  final Map<String, Object?> newFields = _map(p['newFields']);
  final Map<String, Object?> prior = _map(p['priorLinks']);
  final Set<String> alreadyDeleted = opUndoStrings(p['alreadyDeleted']).toSet();
  final List<SrsEditUndoItem> items = <SrsEditUndoItem>[
    for (final String k in <String>{...oldFields.keys, ...newFields.keys})
      if ('${oldFields[k] ?? ''}' != '${newFields[k] ?? ''}')
        SrsEditUndoItem(
          kind: SrsEntityKind.note,
          entityId: keep,
          key: SrsFieldKeys.noteField(k),
          before: '${oldFields[k] ?? ''}',
          after: '${newFields[k] ?? ''}',
        ),
    SrsEditUndoItem(
      kind: SrsEntityKind.note,
      entityId: keep,
      key: SrsFieldKeys.noteTags,
      before: opUndoStrings(p['keepTags']),
      after: opUndoStrings(p['newTags']),
    ),
  ];
  for (final String kc in opUndoStrings(p['keepCards'])) {
    final SrsEntityEdits edits = await store.entityEdits(
      SrsEntityKind.card,
      kc,
    );
    for (final String ac in opUndoStrings(p['absorbCards'])) {
      final String key = SrsFieldKeys.cardHistoryFrom(ac);
      final Object? before = prior['$kc/$ac'];
      if (edits.value(key) == true && before != true) {
        items.add(
          SrsEditUndoItem(
            kind: SrsEntityKind.card,
            entityId: kc,
            key: key,
            before: before ?? false,
            after: true,
          ),
        );
      }
    }
  }
  final Map<String, SrsNoteView?> views = await store.notes(absorb);
  for (final String id in absorb) {
    if (alreadyDeleted.contains(id)) continue;
    items.add(
      SrsEditUndoItem(
        kind: SrsEntityKind.note,
        entityId: id,
        key: SrsFieldKeys.deleted,
        before: null,
        // 仍删着 = 仍是合并留下的状态；已恢复 / 不在了 = 被别处动过（按值核对必不成，记成撤不成）。
        after: views[id]?.deletedAt ?? true,
      ),
    );
  }
  return SrsEditUndo(items);
}

/// 「不是重复」→ 撤销 = notDup 记录写回原值（之后被改过的保留现值）。
OpUndo _dismissUndo(SrsCtlDeps deps) => _editUndo(
  deps,
  show: (CtlCall call, Object? result) => <String, Object?>{
    'notes': _map(result)['dismissed'],
  },
  describe: (Map<String, Object?> p) =>
      '不是重复：${opUndoStrings(p['notes']).join(', ')}',
  legacy: (SrsDbStore store, Map<String, Object?> p) async {
    final List<String> notes = opUndoStrings(p['notes']);
    final Map<String, Object?> prior = _map(p['prior']);
    return SrsEditUndo(<SrsEditUndoItem>[
      for (final String a in notes)
        for (final String b in notes)
          if (a != b && prior['$a/$b'] != true)
            SrsEditUndoItem(
              kind: SrsEntityKind.note,
              entityId: a,
              key: SrsDuplicateNotes.notDuplicateKey(b),
              before: prior['$a/$b'] ?? false,
              after: true,
            ),
    ]);
  },
);
