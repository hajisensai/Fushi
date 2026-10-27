import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart'
    show opCustomUndo, opUndoStrings;

/// 复习（SRS）：牌组 / 笔记查询、统计、sync v2 冲突、重复笔记合并的操作描述（spec §4）。
///
/// 撤销（spec §5.2「SRS 冲突里选『删除』：墓碑带快照，撤销即复活」）：
/// - 被扣住的删除选「删除」：内核追加的是 `deleted = <时刻>` 修改记录，笔记 / 卡 / 牌组只是墓碑，
///   内容与复习日志都还在日志里。撤销 = 追加一条 `deleted = null`（与「保留」写的是同一种记录），
///   实体复活；撤销前当前删除记录已不是这次写的（之后又被恢复 / 再删）就报 superseded。
/// - 标志 / 设置类冲突：撤销 = 把当时生效的值写回（被覆盖的候选不会重新出现在冲突中心，
///   低价值标量按设计本来就自动决胜，历史里可查）。
/// - 重复笔记合并：撤销 = 保留笔记被补上的字段 / 标签写回原值、保留卡上新挂的前身链接
///   （`historyFrom/<被吸收卡>`）改成 false（血统只认 true）、被吸收的笔记恢复。
/// - 「不是重复」：撤销 = 把写上的 `notDup/<对方>` 改回原值。
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
  ];
}

// ─────────────────────────────────────────────────────────────────────────
// 撤销
// ─────────────────────────────────────────────────────────────────────────

Map<String, Object?> _map(Object? raw) => raw is Map
    ? <String, Object?>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          '${e.key}': e.value,
      }
    : <String, Object?>{};

/// 键顺序无关的 JSON 相等（载荷经过 JSON 往返）。
bool _same(Object? a, Object? b) =>
    jsonEncode(_canon(a)) == jsonEncode(_canon(b));

Object? _canon(Object? v) {
  if (v is Map) {
    final List<String> keys = <String>[for (final Object? k in v.keys) '$k']
      ..sort();
    return <String, Object?>{for (final String k in keys) k: _canon(v[k])};
  }
  if (v is List) return <Object?>[for (final Object? x in v) _canon(x)];
  return v;
}

SrsEntityKind _kindOf(Map<String, Object?> payload, String key) =>
    srsCtlEntityKind('${payload[key]}');

/// 被扣住的删除选「删除」→ 撤销 = 追加 `deleted = null`（复活）。
OpUndo _heldDeleteUndo(SrsCtlDeps deps) => opCustomUndo(
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
      <String, Object?>{
        'entityKind': _map(result)['entityKind'],
        'entity': _map(result)['entity'],
        'deletedAt': _map(result)['deletedAt'],
      },
  describe: (Map<String, Object?> p) => '已删除 ${p['entityKind']}/${p['entity']}',
  revert: (Map<String, Object?> payload) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final SrsEntityKind kind = _kindOf(payload, 'entityKind');
    final String entity = '${payload['entity']}';
    final Object? current = (await store.entityEdits(
      kind,
      entity,
    )).value(SrsFieldKeys.deleted);
    if (current == null || !_same(current, payload['deletedAt'])) {
      return const OpUndoOutcome.superseded('之后已被恢复或重新删除');
    }
    await store.editField(kind, entity, SrsFieldKeys.deleted, null);
    deps.changed();
    return const OpUndoOutcome.done();
  },
);

/// 标志 / 设置类冲突 → 撤销 = 写回当时生效的值。
OpUndo _fieldResolveUndo(SrsCtlDeps deps) => opCustomUndo(
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
      _map(result),
  describe: (Map<String, Object?> p) =>
      '${p['kind']}/${p['entity']} ${p['key']}：${jsonEncode(p['previous'])} → ${jsonEncode(p['value'])}',
  revert: (Map<String, Object?> payload) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final SrsEntityKind kind = _kindOf(payload, 'kind');
    final String entity = '${payload['entity']}';
    final String key = '${payload['key']}';
    final Object? current = (await store.entityEdits(kind, entity)).value(key);
    if (!_same(current, payload['value'])) {
      return const OpUndoOutcome.superseded('之后又被改过');
    }
    if (!_same(payload['value'], payload['previous'])) {
      await store.resolveConflict(kind, entity, key, payload['previous']);
      deps.changed();
    }
    return const OpUndoOutcome.done();
  },
);

/// 合并前的快照：保留笔记的字段 / 标签、两边的卡、保留卡上已有的前身链接、被吸收笔记的删除状态。
Future<Map<String, Object?>> _captureMerge(
  SrsCtlDeps deps,
  CtlCall call,
) async {
  final SrsDbStore store = await requireSrsCtlStore(deps);
  final String keep = call.optString('keep') ?? '';
  final List<String> absorb = <String>[
    for (final String id in call.stringList('absorb'))
      if (id != keep) id,
  ];
  final SrsNoteView? kept = await store.note(keep);
  if (kept == null) return const <String, Object?>{};
  final List<String> keepCards = <String>[
    for (final SrsCardCacheRow c in await store.cardsOfNote(keep)) c.id,
  ];
  final List<String> absorbCards = <String>[
    for (final String id in absorb)
      for (final SrsCardCacheRow c in await store.cardsOfNote(id)) c.id,
  ];
  final Map<String, Object?> priorLinks = <String, Object?>{};
  for (final String kc in keepCards) {
    final SrsEntityEdits edits = await store.entityEdits(
      SrsEntityKind.card,
      kc,
    );
    for (final String ac in absorbCards) {
      final String key = SrsFieldKeys.cardHistoryFrom(ac);
      if (edits[key] != null) priorLinks['$kc/$ac'] = edits.value(key);
    }
  }
  final Map<String, SrsNoteView?> views = await store.notes(absorb);
  return <String, Object?>{
    'keep': keep,
    'absorb': absorb,
    'keepFields': kept.fields,
    'keepTags': kept.tags,
    'keepCards': keepCards,
    'absorbCards': absorbCards,
    'priorLinks': priorLinks,
    'alreadyDeleted': <String>[
      for (final String id in absorb)
        if (views[id]?.deletedAt != null) id,
    ],
  };
}

/// 重复笔记合并 → 撤销 = 拆开（见库注释）。
OpUndo _mergeUndo(SrsCtlDeps deps) => opCustomUndo(
  capture: (CtlCall call) => _captureMerge(deps, call),
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
      <String, Object?>{
        ...before,
        'newFields': _map(result)['fields'],
        'newTags': _map(result)['tags'],
      },
  describe: (Map<String, Object?> p) =>
      '${opUndoStrings(p['absorb']).join(', ')} → ${p['keep']}',
  revert: (Map<String, Object?> payload) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final String keep = '${payload['keep']}';
    final List<String> absorb = opUndoStrings(payload['absorb']);
    final SrsNoteView? kept = await store.note(keep);
    if (kept == null || kept.deletedAt != null) {
      return const OpUndoOutcome.superseded('保留的笔记已不在');
    }
    if (!_same(kept.fields, payload['newFields']) ||
        !_same(kept.tags, payload['newTags'])) {
      return const OpUndoOutcome.superseded('保留的笔记合并后又被改过');
    }
    final Set<String> alreadyDeleted = opUndoStrings(
      payload['alreadyDeleted'],
    ).toSet();
    final Map<String, SrsNoteView?> views = await store.notes(absorb);
    for (final String id in absorb) {
      if (alreadyDeleted.contains(id)) continue;
      if (views[id]?.deletedAt == null) {
        return const OpUndoOutcome.superseded('被并进去的笔记已被恢复或不存在');
      }
    }
    // ① 保留笔记：被补上的字段写回原值、标签写回原集合。
    final Map<String, Object?> oldFields = _map(payload['keepFields']);
    final Map<String, Object?> newFields = _map(payload['newFields']);
    final Map<String, String> revertFields = <String, String>{
      for (final String k in <String>{...oldFields.keys, ...newFields.keys})
        if ('${oldFields[k] ?? ''}' != '${newFields[k] ?? ''}')
          k: '${oldFields[k] ?? ''}',
    };
    final List<String> oldTags = opUndoStrings(payload['keepTags']);
    final bool tagsChanged = !_same(oldTags, payload['newTags']);
    if (revertFields.isNotEmpty || tagsChanged) {
      await store.updateNote(
        keep,
        fieldsById: revertFields.isEmpty ? null : revertFields,
        tags: tagsChanged ? oldTags : null,
      );
    }
    // ② 合并新挂的前身链接改成 false（内核的血统只认 true）。
    final Map<String, Object?> prior = _map(payload['priorLinks']);
    final List<SrsEditSpec> unlink = <SrsEditSpec>[];
    for (final String kc in opUndoStrings(payload['keepCards'])) {
      final SrsEntityEdits edits = await store.entityEdits(
        SrsEntityKind.card,
        kc,
      );
      for (final String ac in opUndoStrings(payload['absorbCards'])) {
        final String key = SrsFieldKeys.cardHistoryFrom(ac);
        final Object? before = prior['$kc/$ac'];
        if (edits.value(key) == true && before != true) {
          unlink.add(SrsEditSpec(SrsEntityKind.card, kc, key, before ?? false));
        }
      }
    }
    if (unlink.isNotEmpty) await store.writeEdits(unlink);
    // ③ 被吸收的笔记恢复（合并前就已删除的不动）。
    for (final String id in absorb) {
      if (!alreadyDeleted.contains(id)) await store.restoreNote(id);
    }
    deps.changed();
    return const OpUndoOutcome.done();
  },
);

/// 「不是重复」→ 撤销 = notDup 记录写回原值。
OpUndo _dismissUndo(SrsCtlDeps deps) => opCustomUndo(
  capture: (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final List<String> notes = call.stringList('notes').toSet().toList();
    final Map<String, SrsEntityEdits> edits = await store.entityEditsMany(
      SrsEntityKind.note,
      notes,
    );
    return <String, Object?>{
      'notes': notes,
      'prior': <String, Object?>{
        for (final String a in notes)
          for (final String b in notes)
            if (a != b)
              '$a/$b': edits[a]?.value(SrsDuplicateNotes.notDuplicateKey(b)),
      },
    };
  },
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
      before,
  describe: (Map<String, Object?> p) =>
      '不是重复：${opUndoStrings(p['notes']).join(', ')}',
  revert: (Map<String, Object?> payload) async {
    final SrsDbStore store = await requireSrsCtlStore(deps);
    final List<String> notes = opUndoStrings(payload['notes']);
    final Map<String, Object?> prior = _map(payload['prior']);
    final Map<String, SrsEntityEdits> edits = await store.entityEditsMany(
      SrsEntityKind.note,
      notes,
    );
    final List<SrsEditSpec> specs = <SrsEditSpec>[];
    for (final String a in notes) {
      for (final String b in notes) {
        if (a == b) continue;
        final String key = SrsDuplicateNotes.notDuplicateKey(b);
        if (edits[a]?.value(key) != true) {
          return const OpUndoOutcome.superseded('之后又被改过');
        }
        final Object? before = prior['$a/$b'];
        if (before != true) {
          specs.add(SrsEditSpec(SrsEntityKind.note, a, key, before ?? false));
        }
      }
    }
    if (specs.isNotEmpty) await store.writeEdits(specs);
    deps.changed();
    return const OpUndoOutcome.done();
  },
);
