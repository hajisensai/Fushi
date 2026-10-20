import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/media/collections/collection_merge.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';

/// 把裁决出的改动落库，并逐处写进本机整理记录（spec §5.3 / §12）。
///
/// 全部走自动路径（`userIntent: false`）：整理器改自己的合集不算用户接手；往用户合集
/// 里加散条目也不改它的来源。目标合集里用户移出过的成员一律跳过（加成员会清墓碑，
/// 等于替用户撤销移出）。返回动过的合集 id（交给 AI 排序自动路径）。
Future<Set<int>> applyOrganizeActions(
  FushiDatabase db, {
  required int runId,
  required List<OrganizeAction> actions,
}) async {
  final Set<int> touched = <int>{};
  // 先移出、再合并、最后加 / 建 / 打标签：移出腾地方，合并决定胜方，加入落到胜方。
  final List<OrganizeAction> ordered = <OrganizeAction>[
    for (final OrganizeActionKind k in const <OrganizeActionKind>[
      OrganizeActionKind.evict,
      OrganizeActionKind.merge,
      OrganizeActionKind.add,
      OrganizeActionKind.create,
      OrganizeActionKind.tag,
    ])
      ...actions.where((OrganizeAction a) => a.kind == k),
  ];
  for (final OrganizeAction a in ordered) {
    switch (a.kind) {
      case OrganizeActionKind.evict:
        final MediaCollectionRow? c =
            await db.getMediaCollectionById(a.targetCollectionId!);
        if (c == null) continue;
        final List<OrganizeMemberRow> removed = <OrganizeMemberRow>[];
        final Set<String> present = <String>{
          for (final MediaCollectionItemRow i in await db.getCollectionItems(c.id))
            '${i.mediaType}\u0000${i.entryKey}',
        };
        for (final OrganizeEntry e in a.entries) {
          for (final OrganizeMemberRow r in e.rows) {
            if (!present.contains('${r.mediaType}\u0000${r.entryKey}')) continue;
            await db.removeFromCollectionRaw(
              c.id,
              r.mediaType,
              r.entryKey,
              userIntent: false,
            );
            removed.add(r);
          }
        }
        if (removed.isEmpty) continue;
        touched.add(c.id);
        await _record(db, runId, a, c.name, c.collectionType, c.organizeKey,
            <String, Object?>{'members': _rowsJson(removed)});
      case OrganizeActionKind.merge:
        final MediaCollectionRow? target =
            await db.getMediaCollectionById(a.targetCollectionId!);
        if (target == null) continue;
        final Set<String> before = <String>{
          for (final MediaCollectionItemRow i
              in await db.getCollectionItems(target.id))
            '${i.mediaType}\u0000${i.entryKey}',
        };
        final List<Map<String, Object?>> sources = <Map<String, Object?>>[];
        for (final int id in a.sourceCollectionIds) {
          final MediaCollectionRow? s = await db.getMediaCollectionById(id);
          if (s == null) continue;
          sources.add(<String, Object?>{
            'name': s.name,
            'type': s.collectionType,
            'origin': s.origin,
            'key': s.organizeKey,
            'aliases': s.organizeAliases,
            'members': <Map<String, String>>[
              for (final MediaCollectionItemRow i in await db.getCollectionItems(id))
                <String, String>{'t': i.mediaType, 'k': i.entryKey},
            ],
          });
        }
        final int merged = await mergeMediaCollectionsInto(
          db,
          targetId: target.id,
          sourceIds: a.sourceCollectionIds,
          userIntent: false,
          skipTombstonedInTarget: true,
        );
        if (merged == 0) continue;
        touched.add(target.id);
        await _record(
          db,
          runId,
          a,
          target.name,
          target.collectionType,
          target.organizeKey,
          <String, Object?>{
            'sources': sources,
            'targetBefore': before.toList()..sort(),
          },
        );
      case OrganizeActionKind.add:
        final MediaCollectionRow? c =
            await db.getMediaCollectionById(a.targetCollectionId!);
        if (c == null) continue;
        final List<OrganizeMemberRow> added = await _addRows(db, c, a.entries);
        if (added.isEmpty) continue;
        touched.add(c.id);
        await _record(db, runId, a, c.name, c.collectionType, c.organizeKey,
            <String, Object?>{'members': _rowsJson(added)});
      case OrganizeActionKind.create:
        final int id = await db.createMediaCollection(
          a.name!,
          collectionType: a.collectionType,
          origin: a.source == 'rule' ? CollectionOrigin.rule : CollectionOrigin.ai,
          organizeKey: a.organizeKey,
        );
        final MediaCollectionRow c = (await db.getMediaCollectionById(id))!;
        final List<OrganizeMemberRow> added = await _addRows(db, c, a.entries);
        if (added.isEmpty) {
          // 成员全被用户移出过：不留空合集。
          if ((await db.getCollectionItems(id)).isEmpty) {
            await db.deleteMediaCollectionRaw(id);
          }
          continue;
        }
        touched.add(id);
        await _record(db, runId, a, c.name, c.collectionType, c.organizeKey,
            <String, Object?>{'members': _rowsJson(added)});
      case OrganizeActionKind.tag:
        final int tagId = await db.getOrCreateTagByName(a.name!);
        final List<String> hosts = <String>[];
        for (final OrganizeEntry e in a.entries) {
          if (e.mediaType != MediaKind.video.dbValue) continue;
          await db.addTagToVideoBook(e.entryKey, tagId);
          hosts.add(e.entryKey);
        }
        if (hosts.isEmpty) continue;
        await _record(db, runId, a, a.name!, 'tag', a.organizeKey,
            <String, Object?>{'tagName': a.name, 'videos': hosts});
    }
  }
  return touched;
}

Future<List<OrganizeMemberRow>> _addRows(
  FushiDatabase db,
  MediaCollectionRow c,
  List<OrganizeEntry> entries,
) async {
  final Set<String> tombstoned = await db.collectionMemberTombstoneKeysFor(
    c.name,
    c.collectionType,
  );
  final Set<String> present = <String>{
    for (final MediaCollectionItemRow i in await db.getCollectionItems(c.id))
      '${i.mediaType}\u0000${i.entryKey}',
  };
  final List<OrganizeMemberRow> added = <OrganizeMemberRow>[];
  for (final OrganizeEntry e in entries) {
    // 一卷里主行被用户移出过就整卷不放回。
    if (tombstoned.contains(e.tombstoneKey)) continue;
    for (final OrganizeMemberRow r in e.rows) {
      if (present.contains('${r.mediaType}\u0000${r.entryKey}')) continue;
      if (tombstoned.contains(r.tombstoneKey)) continue;
      await db.addToCollectionRaw(
        c.id,
        r.mediaType,
        r.entryKey,
        userIntent: false,
      );
      added.add(r);
    }
  }
  return added;
}

List<Map<String, String>> _rowsJson(List<OrganizeMemberRow> rows) =>
    <Map<String, String>>[
      for (final OrganizeMemberRow r in rows)
        <String, String>{'t': r.mediaType, 'k': r.entryKey},
    ];

Future<void> _record(
  FushiDatabase db,
  int runId,
  OrganizeAction a,
  String collectionName,
  String collectionType,
  String? organizeKey,
  Map<String, Object?> payload,
) =>
    db.into(db.libraryOrganizeChanges).insert(
          LibraryOrganizeChangesCompanion.insert(
            runId: runId,
            kind: a.kind.name,
            collectionName: collectionName,
            collectionType: collectionType,
            organizeKey: Value<String?>(organizeKey ?? a.organizeKey),
            source: a.source,
            confidence: a.confidence.name,
            payloadJson: jsonEncode(payload),
          ),
        );

/// 撤销整理记录里的若干处改动（spec §12）。撤销是**用户意图**：
/// - 新建：合集还归整理器管 → 删掉它，写「拒绝」（任何设备的 AI 都不再建这个分组）；
///   已被用户接手 → 只移出这次加的成员；
/// - 并入：移出这次加的成员（写成员墓碑，AI 不再放回）；
/// - 合并：按快照把败方重建成**用户的**合集、把它的成员从胜方移回，胜方也转成用户的
///   （用户说了这几个不是一个，收敛不会再合用户的合集）；
/// - 移出：把成员放回；
/// - 标签：摘掉这次打的标签。
/// 找不到目标（已被删 / 改名）的那一处跳过，不报错。返回实际撤销的处数。
Future<int> undoLibraryOrganizeChanges(
  FushiDatabase db,
  Iterable<int> changeIds,
) async {
  final List<LibraryOrganizeChangeRow> rows = await (db.select(
    db.libraryOrganizeChanges,
  )..where((t) => t.id.isIn(changeIds.toList()) & t.undoneAt.isNull()))
      .get();
  rows.sort((LibraryOrganizeChangeRow a, LibraryOrganizeChangeRow b) =>
      b.id.compareTo(a.id));
  int undone = 0;
  for (final LibraryOrganizeChangeRow r in rows) {
    final Map<String, Object?> payload =
        (jsonDecode(r.payloadJson) as Map<Object?, Object?>).cast<String, Object?>();
    final MediaCollectionRow? c = r.kind == OrganizeActionKind.tag.name
        ? null
        : await db.getMediaCollectionByNaturalKey(
            r.collectionName,
            r.collectionType,
          );
    bool did = false;
    switch (r.kind) {
      case 'create':
        if (c == null) break;
        if (CollectionOrigin.parse(c.origin).isOrganizerManaged) {
          await db.deleteMediaCollection(c.id);
        } else {
          for (final ({String t, String k}) m in _members(payload['members'])) {
            await db.removeFromCollectionRaw(c.id, m.t, m.k);
          }
        }
        did = true;
      case 'add':
        if (c == null) break;
        for (final ({String t, String k}) m in _members(payload['members'])) {
          await db.removeFromCollectionRaw(c.id, m.t, m.k, userIntent: false);
        }
        did = true;
      case 'evict':
        if (c == null) break;
        for (final ({String t, String k}) m in _members(payload['members'])) {
          await db.addToCollectionRaw(c.id, m.t, m.k, userIntent: false);
        }
        did = true;
      case 'merge':
        if (c == null) break;
        final Set<String> before = <String>{
          for (final Object? k in (payload['targetBefore'] as List<Object?>? ??
              const <Object?>[]))
            if (k is String) k,
        };
        for (final Object? raw in (payload['sources'] as List<Object?>? ??
            const <Object?>[])) {
          if (raw is! Map) continue;
          final Map<Object?, Object?> s = raw;
          final String name = s['name'] as String;
          final String type = s['type'] as String;
          final int id = await db.createMediaCollection(
            name,
            collectionType: type,
            origin: CollectionOrigin.user,
            organizeKey: s['key'] as String?,
          );
          for (final ({String t, String k}) m in _members(s['members'])) {
            await db.addToCollectionRaw(id, m.t, m.k, userIntent: false);
            if (!before.contains('${m.t}\u0000${m.k}')) {
              await db.removeFromCollectionRaw(c.id, m.t, m.k, userIntent: false);
            }
          }
        }
        final MediaCollectionRow? target = await db.getMediaCollectionById(c.id);
        if (target != null) {
          await db.setMediaCollectionOrganizeState(
            target.id,
            origin: CollectionOrigin.user,
            organizeKey: target.organizeKey,
            organizeAliases: decodeOrganizeAliases(target.organizeAliases),
          );
        }
        did = true;
      case 'tag':
        final String? tagName = payload['tagName'] as String?;
        if (tagName == null) break;
        final int tagId = await db.getOrCreateTagByName(tagName);
        for (final Object? v in (payload['videos'] as List<Object?>? ??
            const <Object?>[])) {
          if (v is String) await db.removeTagFromVideoBook(v, tagId);
        }
        did = true;
    }
    await (db.update(db.libraryOrganizeChanges)..where((t) => t.id.equals(r.id)))
        .write(LibraryOrganizeChangesCompanion(
      undoneAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
    ));
    if (did) undone++;
  }
  return undone;
}

List<({String t, String k})> _members(Object? raw) => <({String t, String k})>[
      if (raw is List)
        for (final Object? m in raw)
          if (m is Map && m['t'] is String && m['k'] is String)
            (t: m['t'] as String, k: m['k'] as String),
    ];

/// 一处改动的置信度字面量 → 枚举（整理记录页展示用）。
AiOrganizeConfidence organizeChangeConfidence(LibraryOrganizeChangeRow row) =>
    AiOrganizeConfidence.parse(row.confidence) ?? AiOrganizeConfidence.high;
