import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/media/collections/collection_asset_reclaim.dart';
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
  // 先移出 / 挪走、再合并、再加 / 建 / 打标签，最后改名：移出腾地方，合并决定胜方，
  // 加入落到胜方（挪走的去处在裁决时已改成合并胜方，胜方合并前后都在）；改名放最后，
  // 本批其它记录都按改名前的自然键记，整批倒序撤销时先改回原名、再撤其它。
  final List<OrganizeAction> ordered = <OrganizeAction>[
    for (final OrganizeActionKind k in const <OrganizeActionKind>[
      OrganizeActionKind.evict,
      OrganizeActionKind.move,
      OrganizeActionKind.merge,
      OrganizeActionKind.add,
      OrganizeActionKind.create,
      OrganizeActionKind.tag,
      OrganizeActionKind.rename,
    ])
      ...actions.where((OrganizeAction a) => a.kind == k),
  ];
  for (final OrganizeAction a in ordered) {
    switch (a.kind) {
      case OrganizeActionKind.evict:
        final MediaCollectionRow? c = await db.getMediaCollectionById(
          a.targetCollectionId!,
        );
        if (c == null) continue;
        final Map<String, Object?>? identity = await _identityIfEmptied(
          db,
          c.id,
          a.entries,
        );
        final List<OrganizeMemberRow> removed = <OrganizeMemberRow>[];
        final Set<String> present = <String>{
          for (final MediaCollectionItemRow i in await db.getCollectionItems(
            c.id,
          ))
            '${i.mediaType}\u0000${i.entryKey}',
        };
        for (final OrganizeEntry e in a.entries) {
          for (final OrganizeMemberRow r in e.rows) {
            if (!present.contains('${r.mediaType}\u0000${r.entryKey}')) {
              continue;
            }
            // 自动移出入口：用户亲手放进来 / 撤销过移出的成员（pinned）拒绝移出，
            // 不改合集所有权（AI 库管家设计稿 §7）。
            final CollectionAutoRemoveResult result = await db
                .removeFromCollectionAutomatically(
                  c.id,
                  r.mediaType,
                  r.entryKey,
                );
            if (result != CollectionAutoRemoveResult.removed) continue;
            removed.add(r);
          }
        }
        if (removed.isEmpty) continue;
        touched.add(c.id);
        await _record(
          db,
          runId,
          a,
          c.name,
          c.collectionType,
          c.organizeKey,
          <String, Object?>{
            'members': _rowsJson(removed),
            // 移空自删后撤销要按原来源重建（用户合集重建成用户的）。
            'origin': c.origin,
            // 移空自删了：记下合集身份，撤销按原 id 还原（BUG-5461）。
            if (identity != null &&
                await db.getMediaCollectionById(c.id) == null)
              'identity': identity,
            if (a.reason != null) 'reason': a.reason,
          },
        );
      case OrganizeActionKind.move:
        final MediaCollectionRow? from = await db.getMediaCollectionById(
          a.fromCollectionId!,
        );
        final MediaCollectionRow? to = await db.getMediaCollectionById(
          a.targetCollectionId!,
        );
        if (from == null || to == null || from.id == to.id) continue;
        final Map<String, Object?>? fromIdentity = await _identityIfEmptied(
          db,
          from.id,
          a.entries,
        );
        final Set<String> tombstoned = await db
            .collectionMemberTombstoneKeysFor(to.name, to.collectionType);
        final Set<String> inFrom = await _memberKeysOf(db, from.id);
        final Set<String> inTo = await _memberKeysOf(db, to.id);
        final List<OrganizeMemberRow> moved = <OrganizeMemberRow>[];
        final List<OrganizeMemberRow> added = <OrganizeMemberRow>[];
        for (final OrganizeEntry e in a.entries) {
          // 用户从去处移出过（整卷看主行）：不挪，留在原处——先移出再发现放不进去
          // 会让它变成散条目。
          if (tombstoned.contains(e.tombstoneKey)) continue;
          for (final OrganizeMemberRow r in e.rows) {
            final String key = '${r.mediaType}\u0000${r.entryKey}';
            if (!inFrom.contains(key) || tombstoned.contains(r.tombstoneKey)) {
              continue;
            }
            final CollectionAutoRemoveResult result = await db
                .removeFromCollectionAutomatically(
                  from.id,
                  r.mediaType,
                  r.entryKey,
                );
            if (result != CollectionAutoRemoveResult.removed) continue;
            moved.add(r);
            if (inTo.add(key)) {
              await db.addToCollectionRaw(
                to.id,
                r.mediaType,
                r.entryKey,
                userIntent: false,
              );
              added.add(r);
            }
          }
        }
        if (moved.isEmpty) continue;
        touched
          ..add(from.id)
          ..add(to.id);
        await _record(
          db,
          runId,
          a,
          to.name,
          to.collectionType,
          to.organizeKey,
          <String, Object?>{
            'from': <String, Object?>{
              'name': from.name,
              'type': from.collectionType,
              'origin': from.origin,
              'key': from.organizeKey,
              if (fromIdentity != null &&
                  await db.getMediaCollectionById(from.id) == null)
                'identity': fromIdentity,
            },
            // members = 从来处移出的；added = 这次才放进去处的（去处原本就有的不算，
            // 撤销时不从去处移出它）。
            'members': _rowsJson(moved),
            'added': _rowsJson(added),
            if (a.reason != null) 'reason': a.reason,
          },
        );
      case OrganizeActionKind.merge:
        final MediaCollectionRow? target = await db.getMediaCollectionById(
          a.targetCollectionId!,
        );
        if (target == null) continue;
        final Map<String, Object?> snapshot = await _mergeSnapshot(
          db,
          target.id,
          a.sourceCollectionIds,
        );
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
            ...snapshot,
            if (a.reason != null) 'reason': a.reason,
          },
        );
      case OrganizeActionKind.add:
        final MediaCollectionRow? c = await db.getMediaCollectionById(
          a.targetCollectionId!,
        );
        if (c == null) continue;
        final List<OrganizeMemberRow> added = await _addRows(db, c, a.entries);
        if (added.isEmpty) continue;
        touched.add(c.id);
        await _record(
          db,
          runId,
          a,
          c.name,
          c.collectionType,
          c.organizeKey,
          <String, Object?>{'members': _rowsJson(added)},
        );
      case OrganizeActionKind.create:
        // `createMediaCollection` 遇到同 (name, type) 的已有行会直接返回它的 id。
        // 查重与新建放进同一个事务，分清这次是真新建还是落进了已有合集：落进已有的
        // 一律按「并入」处理——空合集清理与撤销只能删这次真正建出来的合集。
        final ({int id, bool created}) made = await db.transaction(() async {
          final MediaCollectionRow? existing = await db
              .getMediaCollectionByNaturalKey(a.name!, a.collectionType);
          if (existing != null) return (id: existing.id, created: false);
          final int id = await db.createMediaCollection(
            a.name!,
            collectionType: a.collectionType,
            origin: a.source == 'rule'
                ? CollectionOrigin.rule
                : CollectionOrigin.ai,
            organizeKey: a.organizeKey,
          );
          return (id: id, created: true);
        });
        final MediaCollectionRow c = (await db.getMediaCollectionById(
          made.id,
        ))!;
        final List<OrganizeMemberRow> added = await _addRows(db, c, a.entries);
        if (added.isEmpty) {
          // 成员全被用户移出过：不留这次新建出来的空合集。
          if (made.created && (await db.getCollectionItems(made.id)).isEmpty) {
            await db.deleteMediaCollectionRaw(made.id);
          }
          continue;
        }
        touched.add(made.id);
        await _record(
          db,
          runId,
          a,
          c.name,
          c.collectionType,
          c.organizeKey,
          <String, Object?>{
            'members': _rowsJson(added),
            if (made.created) 'created': true,
          },
          kind: made.created
              ? OrganizeActionKind.create
              : OrganizeActionKind.add,
        );
      case OrganizeActionKind.tag:
        final int tagId = await db.getOrCreateTagByName(a.name!);
        final List<String> hosts = <String>[];
        for (final OrganizeEntry e in a.entries) {
          if (e.mediaType != MediaKind.video.dbValue) continue;
          await db.addTagToVideoBook(e.entryKey, tagId);
          hosts.add(e.entryKey);
        }
        if (hosts.isEmpty) continue;
        await _record(
          db,
          runId,
          a,
          a.name!,
          'tag',
          a.organizeKey,
          <String, Object?>{'tagName': a.name, 'videos': hosts},
        );
      case OrganizeActionKind.rename:
        final String? name = a.name;
        if (name == null || name.isEmpty) continue;
        // 查重与改名同一事务：目录合集（名字由磁盘目录决定）不改；新名字撞别的合集的
        // 自然键不改（同名两行会让合集同步永不收敛）。
        final MediaCollectionRow? before = await db.transaction(() async {
          final MediaCollectionRow? c = await db.getMediaCollectionById(
            a.targetCollectionId!,
          );
          if (c == null || c.sourceFolderPath != null || c.name == name) {
            return null;
          }
          if (await db.getMediaCollectionByNaturalKey(name, c.collectionType) !=
              null) {
            return null;
          }
          // userIntent: false——AI 改名不把合集转成用户的、不碰成员 pinned。
          await db.renameMediaCollection(c.id, name, userIntent: false);
          return c;
        });
        if (before == null) continue;
        touched.add(before.id);
        // 记录挂在新名字上（撤销按它找合集），原名在 payload.from。
        await _record(
          db,
          runId,
          a,
          name,
          before.collectionType,
          before.organizeKey,
          <String, Object?>{
            'from': before.name,
            if (a.reason != null) 'reason': a.reason,
          },
        );
    }
  }
  return touched;
}

/// 合并前的快照（撤销用）：胜方原有成员键 `targetBefore`，败方的名字 / 来源 / 分组
/// 身份与成员（连同 pinned）`sources`，以及胜方上会被作品图谱改挂动到的连接原状
/// `targetLinksBefore`。整理合并与用户接受的合并建议共用。
///
/// 合并把败方的作品图谱连接改挂到胜方（BUG-5457），撞同一身份时按 LWW 还会改写胜方
/// 原有的行；败方身份快照只记败方自己的连接，撤销插回它们还原不了胜方——同一对端会
/// 同时连着两边，被改写的内容也回不来，所以胜方一侧单独记原状。全部在合并之前取：
/// 多个败方连向同一对端时，后一个败方看到的已是前一个改挂后的胜方。
Future<Map<String, Object?>> _mergeSnapshot(
  FushiDatabase db,
  int targetId,
  Iterable<int> sourceIds,
) async {
  final Set<String> before = await _memberKeysOf(db, targetId);
  final List<Map<String, Object?>> sources = <Map<String, Object?>>[];
  final List<Map<String, Object?>> targetLinksBefore = <Map<String, Object?>>[];
  final MediaLinkEndpoint targetEndpoint = (
    kind: MediaLinkKind.videoCollection,
    key: collectionTagEntryKey(targetId),
  );
  for (final int id in sourceIds.toSet()) {
    if (id == targetId) continue;
    final MediaCollectionRow? s = await db.getMediaCollectionById(id);
    if (s == null) continue;
    targetLinksBefore.addAll(
      await db.captureMediaLinkRetargetPreimage(
        from: (
          kind: MediaLinkKind.videoCollection,
          key: collectionTagEntryKey(id),
        ),
        to: targetEndpoint,
      ),
    );
    sources.add(<String, Object?>{
      'name': s.name,
      'type': s.collectionType,
      'origin': s.origin,
      'key': s.organizeKey,
      'aliases': s.organizeAliases,
      // 败方合并后被删：撤销按原 id 还原它的身份（BUG-5461）。
      'identity': await db.captureMediaCollectionSnapshot(id),
      // pinned：用户亲手放进来 / 否决过移出的成员，撤销重建时照原样钉住
      // （缺字段的旧记录按 false）。
      'members': <Map<String, Object?>>[
        for (final MediaCollectionItemRow i in await db.getCollectionItems(id))
          <String, Object?>{
            't': i.mediaType,
            'k': i.entryKey,
            if (i.pinnedByUser) 'pinned': true,
          },
      ],
    });
  }
  return <String, Object?>{
    'sources': sources,
    'targetBefore': before.toList()..sort(),
    'targetLinksBefore': targetLinksBefore,
  };
}

/// 这次移出 / 挪走 [entries] 可能把合集 [collectionId] 移空（现有成员全在 [entries]
/// 里、且都没钉住）时，先记下它的身份快照
/// （[FushiDatabase.captureMediaCollectionSnapshot]）；不可能移空返回 null。移空会让
/// 合集随最后一个成员自删，挂在它 id 上的一切（作品图谱连接、标签、刮削资料……）都
/// 跟着没了，撤销要靠这份快照按原 id 还原（BUG-5461）。调用方移完后合集确实没了才
/// 把它写进记录。
Future<Map<String, Object?>?> _identityIfEmptied(
  FushiDatabase db,
  int collectionId,
  List<OrganizeEntry> entries,
) async {
  final Set<String> moving = <String>{
    for (final OrganizeEntry e in entries)
      for (final OrganizeMemberRow r in e.rows)
        '${r.mediaType}\u0000${r.entryKey}',
  };
  final bool empties = (await db.getCollectionItems(collectionId)).every(
    (MediaCollectionItemRow i) =>
        !i.pinnedByUser && moving.contains('${i.mediaType}\u0000${i.entryKey}'),
  );
  return empties ? db.captureMediaCollectionSnapshot(collectionId) : null;
}

/// 撤销时找回一个被整理删掉的合集，返回它的 id：
/// - 记录里有身份快照（[identity]）→ 按原 id 还原合集行与挂在它身上的一切
///   （[FushiDatabase.restoreMediaCollectionSnapshot]；同名合集已在就挂回它身上），
///   新插回的合集再清掉指向已不存在文件的封面 / 附加图（合并时已回收的资产）；
/// - 没有快照（旧记录）→ 同名合集还在就用它，否则 [recreate] 按名字新建。
Future<int> _reviveCollection(
  FushiDatabase db, {
  required Object? identity,
  required MediaCollectionRow? existing,
  required Future<int> Function() recreate,
}) async {
  if (identity is Map) {
    final int? id = await db.restoreMediaCollectionSnapshot(
      identity.cast<String, Object?>(),
    );
    if (id != null) {
      if (existing == null) await dropMissingCollectionAssetRefs(db, id);
      return id;
    }
  }
  return existing?.id ?? await recreate();
}

Future<Set<String>> _memberKeysOf(FushiDatabase db, int collectionId) async =>
    <String>{
      for (final MediaCollectionItemRow i in await db.getCollectionItems(
        collectionId,
      ))
        '${i.mediaType}\u0000${i.entryKey}',
    };

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
  Map<String, Object?> payload, {
  OrganizeActionKind? kind,
}) => db
    .into(db.libraryOrganizeChanges)
    .insert(
      LibraryOrganizeChangesCompanion.insert(
        runId: runId,
        kind: (kind ?? a.kind).name,
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
/// - 移出：把成员放回并钉住（pinned_by_user，AI 不再移它）；来处被移空自删了就按
///   记录的来源重建；
/// - 挪走：从去处移出这次放进去的成员（写成员墓碑，AI 不再放回；不钉住），放回来处
///   并钉住；
/// - 标签：摘掉这次打的标签；
/// - 改名：合集还叫这次改成的名字、原名也没被别的合集占着 → 改回原名（AI 身份，不转
///   所有权）；之后又被改过名 / 删掉的跳过。
/// 待确认建议（[kLibraryOrganizeProposalKind]）不是改动，不参与撤销。
/// 找不到目标（已被删 / 改名）的那一处跳过，不报错。返回实际撤销的处数。
Future<int> undoLibraryOrganizeChanges(
  FushiDatabase db,
  Iterable<int> changeIds,
) async {
  final List<LibraryOrganizeChangeRow> rows =
      await (db.select(db.libraryOrganizeChanges)..where(
            (t) =>
                t.id.isIn(changeIds.toList()) &
                t.undoneAt.isNull() &
                t.kind.equals(kLibraryOrganizeProposalKind).not(),
          ))
          .get();
  rows.sort(
    (LibraryOrganizeChangeRow a, LibraryOrganizeChangeRow b) =>
        b.id.compareTo(a.id),
  );
  int undone = 0;
  for (final LibraryOrganizeChangeRow r in rows) {
    final Map<String, Object?> payload =
        (jsonDecode(r.payloadJson) as Map<Object?, Object?>)
            .cast<String, Object?>();
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
        // 只删这次真正新建出来、仍归整理器管、分组键也对得上的那个合集；记录没有
        // 「新建」标记（落进了同名的已有合集）或自然键已换了主人，一律只移出这次加的
        // 成员，绝不删原本就在的合集。
        if (payload['created'] == true &&
            CollectionOrigin.parse(c.origin).isOrganizerManaged &&
            c.organizeKey == r.organizeKey) {
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
        // 移出最后一个成员时合集会被移空自删（不写合集墓碑）：按身份快照原 id 还原，
        // 旧记录没有快照就按记录重建。
        final int id = await _reviveCollection(
          db,
          identity: payload['identity'],
          existing: c,
          recreate: () => db.createMediaCollection(
            r.collectionName,
            collectionType: r.collectionType,
            origin: _originOr(payload['origin'], CollectionOrigin.ai),
            organizeKey: r.organizeKey,
          ),
        );
        // 撤销移出 = 用户否决这次移出：成员加回去并钉住（pinned），任何设备上的
        // AI 都不再移它；不接手合集所有权（AI 库管家设计稿 §7）。
        await _restorePinned(db, id, _members(payload['members']));
        did = true;
      case 'move':
        // 去处：只移出这次才放进去的（原本就在的不动），走自动入口语义但写墓碑。
        if (c != null) {
          for (final ({String t, String k}) m in _members(payload['added'])) {
            await db.removeFromCollectionRaw(c.id, m.t, m.k, userIntent: false);
          }
        }
        final Object? rawFrom = payload['from'];
        if (rawFrom is! Map ||
            rawFrom['name'] is! String ||
            rawFrom['type'] is! String) {
          break;
        }
        final String fromName = rawFrom['name'] as String;
        final String fromType = rawFrom['type'] as String;
        final MediaCollectionRow? from = await db
            .getMediaCollectionByNaturalKey(fromName, fromType);
        final int fromId = await _reviveCollection(
          db,
          identity: rawFrom['identity'],
          existing: from,
          recreate: () => db.createMediaCollection(
            fromName,
            collectionType: fromType,
            origin: _originOr(rawFrom['origin'], CollectionOrigin.ai),
            organizeKey: rawFrom['key'] as String?,
          ),
        );
        await _restorePinned(db, fromId, _members(payload['members']));
        did = true;
      case 'merge':
        if (c == null) break;
        await _undoMergeSnapshot(db, c, payload);
        did = true;
      case 'tag':
        final String? tagName = payload['tagName'] as String?;
        if (tagName == null) break;
        final int tagId = await db.getOrCreateTagByName(tagName);
        for (final Object? v
            in (payload['videos'] as List<Object?>? ?? const <Object?>[])) {
          if (v is String) await db.removeTagFromVideoBook(v, tagId);
        }
        did = true;
      case 'rename':
        final Object? oldName = payload['from'];
        if (c == null || oldName is! String || oldName.isEmpty) break;
        did = await db.transaction(() async {
          if (await db.getMediaCollectionByNaturalKey(
                oldName,
                r.collectionType,
              ) !=
              null) {
            return false;
          }
          await db.renameMediaCollection(c.id, oldName, userIntent: false);
          return true;
        });
    }
    // 目标已不在（被删 / 改名）的那一处没撤成：不标「已撤销」，记录里照实留着。
    if (!did) continue;
    await (db.update(
      db.libraryOrganizeChanges,
    )..where((t) => t.id.equals(r.id))).write(
      LibraryOrganizeChangesCompanion(
        undoneAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    undone++;
  }
  return undone;
}

/// 按合并快照（[_mergeSnapshot]）撤销一次合并：败方重建成**用户的**合集、成员从
/// 胜方 [c] 移回（胜方原有的不动），胜方也转成用户的并还回吸收的分组键。
Future<void> _undoMergeSnapshot(
  FushiDatabase db,
  MediaCollectionRow c,
  Map<String, Object?> payload,
) async {
  final Set<String> before = <String>{
    for (final Object? k
        in (payload['targetBefore'] as List<Object?>? ?? const <Object?>[]))
      if (k is String) k,
  };
  // 合并时目标吸收了败方的分组键与别名：撤销要一并还回去，否则这个系列以后
  // 还会按键被并进目标（用户刚说过「不是一个」）。
  final Set<String> returnedKeys = <String>{};
  for (final Object? raw
      in (payload['sources'] as List<Object?>? ?? const <Object?>[])) {
    if (raw is! Map) continue;
    final Map<Object?, Object?> s = raw;
    final String name = s['name'] as String;
    final String type = s['type'] as String;
    final int id = await _reviveCollection(
      db,
      identity: s['identity'],
      existing: await db.getMediaCollectionByNaturalKey(name, type),
      recreate: () => db.createMediaCollection(
        name,
        collectionType: type,
        origin: CollectionOrigin.user,
        organizeKey: s['key'] as String?,
      ),
    );
    final Set<String> sourceAliases = decodeOrganizeAliases(
      s['aliases'] as String?,
    );
    returnedKeys
      ..addAll(sourceAliases)
      ..addAll(<String>[if (s['key'] is String) s['key'] as String]);
    await db.setMediaCollectionOrganizeState(
      id,
      origin: CollectionOrigin.user,
      organizeKey: s['key'] as String?,
      organizeAliases: sourceAliases,
    );
    for (final ({String t, String k, bool pinned}) m in _membersWithPin(
      s['members'],
    )) {
      await db.addToCollectionRaw(
        id,
        m.t,
        m.k,
        userIntent: false,
        pinnedByUser: m.pinned,
      );
      if (!before.contains('${m.t}\u0000${m.k}')) {
        await db.removeFromCollectionRaw(c.id, m.t, m.k, userIntent: false);
      }
    }
  }
  final MediaCollectionRow? target = await db.getMediaCollectionById(c.id);
  if (target != null) {
    // 胜方上改挂进来的连接删掉、被 LWW 改写的写回原状（败方自己的连接已随身份快照
    // 回到败方）。胜方已不在就不动：写回会留下端点不存在的死连接。缺字段的旧记录
    // 什么也不做。
    await db.restoreMediaLinkRetargetPreimage(
      payload['targetLinksBefore'] as List<Object?>? ?? const <Object?>[],
    );
    await db.setMediaCollectionOrganizeState(
      target.id,
      origin: CollectionOrigin.user,
      organizeKey: target.organizeKey,
      organizeAliases: decodeOrganizeAliases(target.organizeAliases)
        ..removeAll(returnedKeys),
    );
  }
}

/// 撤销移出 / 挪走：成员放回 [collectionId] 并钉住（用户否决了这次移出，但不接手
/// 合集所有权）。只钉这次被移出的那几行，合集里其它成员的 pinned 不动。
Future<void> _restorePinned(
  FushiDatabase db,
  int collectionId,
  List<({String t, String k})> members,
) async {
  for (final ({String t, String k}) m in members) {
    await db.addToCollectionRaw(
      collectionId,
      m.t,
      m.k,
      userIntent: false,
      pinnedByUser: true,
    );
  }
}

CollectionOrigin _originOr(Object? raw, CollectionOrigin fallback) =>
    raw is String ? CollectionOrigin.parse(raw) : fallback;

/// 本机整理记录里 AI 自动从合集移出、且还没撤销的条目键，按合集自然键 + 媒体类型
/// 索引：`evict`（移出 / 拆散，记在来处合集名下）与 `move`（挪走，来处记在
/// `payload.from`）。用户同意的待确认建议（`proposal`）是用户意图，不算。
///
/// 每个键带那次运行（`library_organize_runs`，按 `runId` 关联）的结束时刻，作 AI
/// 写下的成员墓碑 `deletedAt` 的上界：收养入口只清不晚于它的墓碑，用户之后（加回
/// 又）亲手移出写下的更新墓碑照常拦（BUG-5016）。还没结束（`finishedAt` 为空）的
/// 运行给不出上界，不算——宁可照旧拦，也不误清用户的移出。
///
/// 收养入口据此分辨「AI 移出留下的成员墓碑」与「用户自己移出的」：前者在用户亲手
/// 再加入这部作品时清掉（BUG-5518）。一次「加入媒体库」只读一次整理记录
/// （[load]），逐集查 [keysFor]。整理记录设备本地、不同步，所以只认得本机 AI 做的
/// 移出；别的设备上 AI 移出、同步过来的墓碑仍照常拦。
class OrganizerRemovals {
  const OrganizerRemovals._(this._keys);

  /// 什么都没移出过（被动收养不查整理记录时用）。
  static const OrganizerRemovals none = OrganizerRemovals._(
    <(String, String, String), Map<String, int>>{},
  );

  final Map<(String, String, String), Map<String, int>> _keys;

  /// 读一次整理记录（连同所属运行的结束时刻），只收 [collectionNames] 这些合集的
  /// 移出（`evict` 在 SQL 里按合集名筛；`move` 的来处在载荷里，解码后筛）。
  static Future<OrganizerRemovals> load(
    FushiDatabase db, {
    required Set<String> collectionNames,
  }) async {
    if (collectionNames.isEmpty) return none;
    final String evict = OrganizeActionKind.evict.name;
    final String move = OrganizeActionKind.move.name;
    final $LibraryOrganizeChangesTable c = db.libraryOrganizeChanges;
    final $LibraryOrganizeRunsTable r = db.libraryOrganizeRuns;
    final List<TypedResult> rows =
        await (db.select(c).join(<Join>[innerJoin(r, r.id.equalsExp(c.runId))])
              ..where(
                c.undoneAt.isNull() &
                    r.finishedAt.isNotNull() &
                    (c.kind.equals(move) |
                        (c.kind.equals(evict) &
                            c.collectionName.isIn(collectionNames))),
              ))
            .get();
    final Map<(String, String, String), Map<String, int>> keys =
        <(String, String, String), Map<String, int>>{};
    for (final TypedResult row in rows) {
      final LibraryOrganizeChangeRow change = row.readTable(c);
      final int until = row.readTable(r).finishedAt!;
      final Map<String, Object?>? payload = _decode(change.payloadJson);
      if (payload == null) continue;
      final String name;
      final String type;
      if (change.kind == evict) {
        (name, type) = (change.collectionName, change.collectionType);
      } else if (payload['from'] case {
        'name': final String n,
        'type': final String t,
      }) {
        (name, type) = (n, t);
      } else {
        continue;
      }
      if (!collectionNames.contains(name)) continue;
      for (final ({String t, String k}) m in _members(payload['members'])) {
        final Map<String, int> byKey = keys[(name, type, m.t)] ??=
            <String, int>{};
        final int? prev = byKey[m.k];
        if (prev == null || until > prev) byKey[m.k] = until;
      }
    }
    return OrganizerRemovals._(keys);
  }

  /// [mediaType] 是 `MediaKind.dbValue`。返回条目键 → AI 移出墓碑 `deletedAt` 的上界。
  Map<String, int> keysFor({
    required String collectionName,
    required String collectionType,
    required String mediaType,
  }) =>
      _keys[(collectionName, collectionType, mediaType)] ??
      const <String, int>{};
}

/// 撤销一次整理里还没撤销的全部改动（待确认建议不算改动，不动）。
Future<int> undoLibraryOrganizeRun(FushiDatabase db, int runId) async {
  final List<LibraryOrganizeChangeRow> rows = await (db.select(
    db.libraryOrganizeChanges,
  )..where((t) => t.runId.equals(runId) & t.undoneAt.isNull())).get();
  return undoLibraryOrganizeChanges(db, <int>[
    for (final LibraryOrganizeChangeRow r in rows)
      if (r.kind != kLibraryOrganizeProposalKind) r.id,
  ]);
}

// ── 待确认的合集级建议（AI 库管家设计稿 §8）────────────────────────────────
//
// 动用户合集（`origin == user`）的改动——收敛把同键的用户合集并掉、导入器从用户合集
// 移出成员——一律走这里等用户逐条决定（用户 2026-11-24 拍板取消「整理器永不移出
// 用户合集成员 / 永不并掉用户合集」的硬禁令：「用户的合集整理器永远不能往外移成员
// 取消这个设定吧，我觉得让用户显式同意就行了吧，用户可以永远拒绝」）。

/// 整理记录里「待确认建议」行的 kind。与改动同表（设备本地、不同步），但不计入改动
/// 数、不出现在整理记录的改动列表、不参与整次撤销（接受后的撤销走
/// [undoLibraryOrganizeProposal]）。
const String kLibraryOrganizeProposalKind = 'proposal';

/// 「这次不」的暂缓期：期内同一条建议（同签名）不再记、列表里不显示；到期后可再提。
/// 暂缓是**设备本地**的（整理记录表不同步）：别的设备照常会提同一条。
const Duration kOrganizeProposalDeferDuration = Duration(days: 7);

/// 一条建议当前的状态。
enum OrganizeProposalState {
  pending,
  accepted,

  /// 用户点了「永远不」。merge / removeMembers 同时把相关成员钉住
  /// （`pinned_by_user`，随合集同步各端一致），任何设备都不再提。
  rejected,

  /// 涉及的合集已不在 / 新名字被占 / 要移出的成员都不在了：没法照原样执行。
  stale,

  /// 用户点了「这次不」：设备本地暂缓到 `deferredUntil`（[kOrganizeProposalDeferDuration]）。
  deferred;

  static OrganizeProposalState parse(Object? raw) {
    for (final OrganizeProposalState s in OrganizeProposalState.values) {
      if (s.name == raw) return s;
    }
    return OrganizeProposalState.pending;
  }
}

/// 用户对一条待确认建议的决定。
enum OrganizeProposalDecision {
  /// 同意：以用户身份执行，可经 [undoLibraryOrganizeProposal] 撤销。
  accept,

  /// 这次不：设备本地暂缓 [kOrganizeProposalDeferDuration]。
  defer,

  /// 永远不：记为拒绝，并钉住相关成员（跨端生效）。
  rejectForever,
}

/// removeMembers 建议里的一个成员（标题是记录时的快照，展示用）。
class OrganizeProposalMember {
  const OrganizeProposalMember({
    required this.mediaType,
    required this.entryKey,
    required this.title,
  });

  final String mediaType;
  final String entryKey;
  final String title;

  Map<String, Object?> toJson() => <String, Object?>{
    'mediaType': mediaType,
    'entryKey': entryKey,
    'title': title,
  };
}

/// 一条待确认建议（给确认卡 / 路由用）。合集按记录时的自然键（名字 + 类型）指认。
class LibraryOrganizeProposalView {
  const LibraryOrganizeProposalView({
    required this.id,
    required this.runId,
    required this.kind,
    required this.state,
    required this.targetName,
    required this.targetType,
    required this.sourceNames,
    required this.confidence,
    this.newName,
    this.reason,
    this.members = const <OrganizeProposalMember>[],
    this.reasonCode,
    this.deferredUntil,
  });

  final int id;
  final int runId;
  final OrganizeProposalKind kind;
  final OrganizeProposalState state;

  /// merge：并进哪个合集；rename：改哪个合集的名字；removeMembers：从哪个合集移出。
  final String targetName;
  final String targetType;

  /// merge 的败方合集名（同类型）。
  final List<String> sourceNames;

  /// rename 的新名字。
  final String? newName;
  final AiOrganizeConfidence confidence;
  final String? reason;

  /// removeMembers 要移出的成员。
  final List<OrganizeProposalMember> members;

  /// removeMembers 的原因码（[MemberRemovalProposal.reasonCode]）。
  final String? reasonCode;

  /// deferred：暂缓到何时（毫秒时间戳）。
  final int? deferredUntil;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'runId': runId,
    'kind': kind.name,
    'state': state.name,
    'collection': targetName,
    'collectionType': targetType,
    if (kind == OrganizeProposalKind.merge) 'sources': sourceNames,
    if (newName != null) 'newName': newName,
    if (kind == OrganizeProposalKind.removeMembers) ...<String, Object?>{
      'members': <Object?>[
        for (final OrganizeProposalMember m in members) m.toJson(),
      ],
      'reasonCode': reasonCode,
    },
    'confidence': confidence.name,
    if (reason != null) 'reason': reason,
    if (deferredUntil != null) 'deferredUntil': deferredUntil,
  };
}

/// 去重签名：(kind, 合集自然键, 排序后的败方名 / 成员键, 新名字)。
String _proposalSignature(
  OrganizeProposalKind kind,
  String targetName,
  String type,
  List<String> parts,
  String? newName,
) => <String>[
  kind.name,
  type,
  targetName,
  ...(List<String>.of(parts)..sort()),
  newName ?? '',
].join('\u0000');

String _memberSigPart(String mediaType, String entryKey) =>
    '$mediaType\u0001$entryKey';

/// 已有、会挡住同签名再记的建议：等确认 / 拒绝过 / 失效 / 还在暂缓期内。已接受的
/// （以及撤销后回到 pending 之前的）与暂缓到期的不挡。
Future<Set<String>> _blockingProposalSignatures(
  FushiDatabase db,
  int nowMs,
) async => <String>{
  for (final LibraryOrganizeChangeRow r in await (db.select(
    db.libraryOrganizeChanges,
  )..where((t) => t.kind.equals(kLibraryOrganizeProposalKind))).get())
    if (_decode(r.payloadJson) case final Map<String, Object?> p)
      if (p['sig'] case final String sig)
        if (switch (OrganizeProposalState.parse(p['state'])) {
          OrganizeProposalState.accepted => false,
          OrganizeProposalState.deferred =>
            ((p['deferredUntil'] as num?)?.toInt() ?? 0) > nowMs,
          _ => true,
        })
          sig,
};

/// 一条待写入的建议行。
class _ProposalDraft {
  const _ProposalDraft({
    required this.sig,
    required this.collection,
    required this.source,
    required this.confidence,
    required this.payload,
  });

  final String sig;
  final MediaCollectionRow collection;
  final String source;
  final AiOrganizeConfidence confidence;
  final Map<String, Object?> payload;
}

/// 把 [drafts] 里没被挡住的写进整理记录。[runIdOf] 在第一条真要写时才调（没有新建议
/// 就不建空的运行记录）。返回新记条数。
Future<int> _writeProposalDrafts(
  FushiDatabase db,
  List<_ProposalDraft> drafts,
  Future<int> Function() runIdOf,
) async {
  if (drafts.isEmpty) return 0;
  final Set<String> known = await _blockingProposalSignatures(
    db,
    DateTime.now().millisecondsSinceEpoch,
  );
  int? runId;
  int recorded = 0;
  for (final _ProposalDraft d in drafts) {
    if (!known.add(d.sig)) continue;
    runId ??= await runIdOf();
    await db
        .into(db.libraryOrganizeChanges)
        .insert(
          LibraryOrganizeChangesCompanion.insert(
            runId: runId,
            kind: kLibraryOrganizeProposalKind,
            collectionName: d.collection.name,
            collectionType: d.collection.collectionType,
            organizeKey: Value<String?>(d.collection.organizeKey),
            source: d.source,
            confidence: d.confidence.name,
            payloadJson: jsonEncode(<String, Object?>{
              ...d.payload,
              'state': OrganizeProposalState.pending.name,
              'sig': d.sig,
            }),
          ),
        );
    recorded++;
  }
  return recorded;
}

/// 只装待确认建议的一次运行（收敛 / 导入器这类不在整理运行里的调用方）。
Future<int> _createProposalRun(FushiDatabase db, String trigger) {
  final int now = DateTime.now().millisecondsSinceEpoch;
  return db
      .into(db.libraryOrganizeRuns)
      .insert(
        LibraryOrganizeRunsCompanion.insert(
          domain: 'all',
          trigger: trigger,
          startedAt: now,
          finishedAt: Value<int?>(now),
          status: 'done',
        ),
      );
}

Future<List<_ProposalDraft>> _mergeRenameDrafts(
  FushiDatabase db,
  List<OrganizeProposal> proposals,
) async {
  final List<_ProposalDraft> out = <_ProposalDraft>[];
  for (final OrganizeProposal p in proposals) {
    if (p.kind == OrganizeProposalKind.removeMembers) continue;
    final MediaCollectionRow? target = await db.getMediaCollectionById(
      p.targetCollectionId,
    );
    if (target == null) continue;
    final List<String> sources = <String>[
      for (final int id in p.sourceCollectionIds)
        if (await db.getMediaCollectionById(id) case final MediaCollectionRow s
            when s.collectionType == target.collectionType)
          s.name,
    ];
    if (p.kind == OrganizeProposalKind.merge && sources.isEmpty) continue;
    if (p.kind == OrganizeProposalKind.rename && p.newName == null) continue;
    out.add(
      _ProposalDraft(
        sig: _proposalSignature(
          p.kind,
          target.name,
          target.collectionType,
          sources,
          p.newName,
        ),
        collection: target,
        source: p.source,
        confidence: p.confidence,
        payload: <String, Object?>{
          'proposal': p.kind.name,
          if (p.kind == OrganizeProposalKind.merge) 'sources': sources,
          if (p.newName != null) 'newName': p.newName,
          if (p.reason != null) 'reason': p.reason,
        },
      ),
    );
  }
  return out;
}

/// 把合并 / 改名建议记进整理运行 [runId]（按此刻的合集自然键快照）。同一条建议已在
/// 等确认、拒绝过、失效、或还在「这次不」的暂缓期内的不再记（不反复打扰）。返回新记
/// 的条数。removeMembers 走 [recordMemberRemovalProposals]。
Future<int> recordOrganizeProposals(
  FushiDatabase db, {
  required int runId,
  required List<OrganizeProposal> proposals,
}) async => _writeProposalDrafts(
  db,
  await _mergeRenameDrafts(db, proposals),
  () async => runId,
);

/// [recordOrganizeProposals] 的自建运行版：有新建议要记时才建一条
/// `library_organize_runs`（[trigger] 如 `convergence`）。
Future<int> recordOrganizeProposalsInNewRun(
  FushiDatabase db, {
  required String trigger,
  required List<OrganizeProposal> proposals,
}) async => _writeProposalDrafts(
  db,
  await _mergeRenameDrafts(db, proposals),
  () => _createProposalRun(db, trigger),
);

/// 记「从合集移出成员」的待确认建议。有新建议要记时自建一条 `library_organize_runs`
/// （[trigger] 由调用方给，如 `disc_import` / `convergence`）。
///
/// 每条只留**此刻仍在合集里、且没被用户钉住**（`pinned_by_user`）的成员——钉住 =
/// 用户亲手放进来或否决过移出；剔空就不记。去重签名 = (kind, 合集自然键, 排序后的
/// 成员键)：同签名已在等确认 / 被拒绝 / 失效的不再记，「这次不」的在暂缓期内不再记。
/// 返回新记条数。
Future<int> recordMemberRemovalProposals(
  FushiDatabase db, {
  required String trigger,
  required List<MemberRemovalProposal> proposals,
}) async {
  final List<_ProposalDraft> drafts = <_ProposalDraft>[];
  for (final MemberRemovalProposal p in proposals) {
    final MediaCollectionRow? c = await db.getMediaCollectionById(
      p.collectionId,
    );
    if (c == null) continue;
    final Map<String, MediaCollectionItemRow> present =
        <String, MediaCollectionItemRow>{
          for (final MediaCollectionItemRow i in await db.getCollectionItems(
            c.id,
          ))
            _memberSigPart(i.mediaType, i.entryKey): i,
        };
    final List<Map<String, Object?>> members = <Map<String, Object?>>[];
    final Set<String> seen = <String>{};
    for (final CollectionMemberKey m in p.members) {
      final String part = _memberSigPart(m.mediaType, m.entryKey);
      final MediaCollectionItemRow? row = present[part];
      if (row == null || row.pinnedByUser || !seen.add(part)) continue;
      members.add(<String, Object?>{
        't': m.mediaType,
        'k': m.entryKey,
        'title': await _memberTitle(db, m.mediaType, m.entryKey),
      });
    }
    if (members.isEmpty) continue;
    drafts.add(
      _ProposalDraft(
        sig: _proposalSignature(
          OrganizeProposalKind.removeMembers,
          c.name,
          c.collectionType,
          seen.toList(),
          null,
        ),
        collection: c,
        source: 'rule',
        confidence: AiOrganizeConfidence.high,
        payload: <String, Object?>{
          'proposal': OrganizeProposalKind.removeMembers.name,
          'members': members,
          'reasonCode': p.reasonCode,
          if (p.reason != null) 'reason': p.reason,
        },
      ),
    );
  }
  return _writeProposalDrafts(
    db,
    drafts,
    () => _createProposalRun(db, trigger),
  );
}

/// 成员的显示标题（记建议时快照，之后条目被删也能照常展示）。认不出的种类回落到
/// entryKey。
Future<String> _memberTitle(
  FushiDatabase db,
  String mediaType,
  String entryKey,
) async {
  final String? title = switch (MediaKind.tryParse(mediaType)) {
    MediaKind.epub => (await db.getEpubBookByUid(entryKey))?.title,
    MediaKind.srt => (await db.getSrtBookByUid(entryKey))?.title,
    MediaKind.video => (await db.getVideoBookByBookUid(entryKey))?.title,
    MediaKind.game => (await db.getGalgame(entryKey))?.name,
    null => null,
  };
  return title == null || title.trim().isEmpty ? entryKey : title;
}

/// 列出待确认建议（新的在前）。[pendingOnly] 为 false 时连已处理 / 暂缓的一起列。
Future<List<LibraryOrganizeProposalView>> loadLibraryOrganizeProposals(
  FushiDatabase db, {
  bool pendingOnly = true,
}) async {
  final List<LibraryOrganizeChangeRow> rows =
      await (db.select(db.libraryOrganizeChanges)
            ..where((t) => t.kind.equals(kLibraryOrganizeProposalKind))
            ..orderBy(<OrderClauseGenerator<$LibraryOrganizeChangesTable>>[
              (t) => OrderingTerm.desc(t.id),
            ]))
          .get();
  return <LibraryOrganizeProposalView>[
    for (final LibraryOrganizeChangeRow r in rows)
      if (_proposalView(r) case final LibraryOrganizeProposalView v)
        if (!pendingOnly || v.state == OrganizeProposalState.pending) v,
  ];
}

LibraryOrganizeProposalView? _proposalView(LibraryOrganizeChangeRow r) {
  final Map<String, Object?>? p = _decode(r.payloadJson);
  if (p == null) return null;
  OrganizeProposalKind? kind;
  for (final OrganizeProposalKind k in OrganizeProposalKind.values) {
    if (k.name == p['proposal']) kind = k;
  }
  if (kind == null) return null;
  return LibraryOrganizeProposalView(
    id: r.id,
    runId: r.runId,
    kind: kind,
    state: OrganizeProposalState.parse(p['state']),
    targetName: r.collectionName,
    targetType: r.collectionType,
    sourceNames: <String>[
      if (p['sources'] is List)
        for (final Object? s in p['sources']! as List<Object?>)
          if (s is String) s,
    ],
    newName: p['newName'] as String?,
    confidence: organizeChangeConfidence(r),
    reason: p['reason'] as String?,
    members: <OrganizeProposalMember>[
      if (p['members'] is List)
        for (final Object? m in p['members']! as List<Object?>)
          if (m is Map && m['t'] is String && m['k'] is String)
            OrganizeProposalMember(
              mediaType: m['t'] as String,
              entryKey: m['k'] as String,
              title: m['title'] is String
                  ? m['title'] as String
                  : m['k'] as String,
            ),
    ],
    reasonCode: p['reasonCode'] as String?,
    deferredUntil: (p['deferredUntil'] as num?)?.toInt(),
  );
}

Future<LibraryOrganizeChangeRow?> _proposalRow(
  FushiDatabase db,
  int proposalId,
) =>
    (db.select(db.libraryOrganizeChanges)..where(
          (t) =>
              t.id.equals(proposalId) &
              t.kind.equals(kLibraryOrganizeProposalKind),
        ))
        .getSingleOrNull();

Future<void> _writeProposalPayload(
  FushiDatabase db,
  int rowId,
  Map<String, Object?> payload,
) => (db.update(db.libraryOrganizeChanges)..where((t) => t.id.equals(rowId)))
    .write(
      LibraryOrganizeChangesCompanion(
        payloadJson: Value<String>(jsonEncode(payload)),
      ),
    );

/// 把合集 [collectionId] 里此刻在的 [keys] 成员钉住（`pinned_by_user`，随合集清单
/// 同步、各端取或）。不在的跳过（不会把它加回来）。
Future<void> _pinPresentMembers(
  FushiDatabase db,
  int collectionId,
  Set<String> keys,
) async {
  for (final MediaCollectionItemRow i in await db.getCollectionItems(
    collectionId,
  )) {
    if (i.pinnedByUser) continue;
    if (!keys.contains(_memberSigPart(i.mediaType, i.entryKey))) continue;
    await db.addToCollectionRaw(
      collectionId,
      i.mediaType,
      i.entryKey,
      userIntent: false,
      pinnedByUser: true,
    );
  }
}

/// 用户处理一条待确认建议（返回处理后的状态；建议不存在或不在等确认返回 null）：
/// - [OrganizeProposalDecision.accept]：以**用户身份**执行（`userIntent: true`）。合并
///   / 改名 / 移出前的状态记进建议（`applied`），[undoLibraryOrganizeProposal] 能撤；
///   没法照原样执行时返回 [OrganizeProposalState.stale]；
/// - [OrganizeProposalDecision.defer]：「这次不」，设备本地暂缓
///   [kOrganizeProposalDeferDuration]；
/// - [OrganizeProposalDecision.rejectForever]：「永远不」，记为拒绝；removeMembers 把
///   这些成员钉住、merge 把败方此刻的成员全钉住（`pinned_by_user`：「用户否决过移出」
///   正是它的语义，随同步各端一致，任何设备的整理器 / 导入器 / 收敛都不再提）。
Future<OrganizeProposalState?> resolveLibraryOrganizeProposal(
  FushiDatabase db,
  int proposalId, {
  required OrganizeProposalDecision decision,
}) async {
  final LibraryOrganizeChangeRow? row = await _proposalRow(db, proposalId);
  if (row == null) return null;
  final LibraryOrganizeProposalView? view = _proposalView(row);
  if (view == null || view.state != OrganizeProposalState.pending) return null;
  final Map<String, Object?> payload = _decode(row.payloadJson)!;
  final int now = DateTime.now().millisecondsSinceEpoch;
  final OrganizeProposalState next;
  switch (decision) {
    case OrganizeProposalDecision.defer:
      next = OrganizeProposalState.deferred;
      payload['deferredUntil'] =
          now + kOrganizeProposalDeferDuration.inMilliseconds;
    case OrganizeProposalDecision.rejectForever:
      next = OrganizeProposalState.rejected;
      await _pinRejected(db, view);
    case OrganizeProposalDecision.accept:
      // 不包事务：合并会回收被解散合集的封面等磁盘资产，回滚不了。
      final ({OrganizeProposalState state, Map<String, Object?>? applied}) r =
          await _acceptProposal(db, view);
      next = r.state;
      if (r.applied != null) payload['applied'] = r.applied;
  }
  payload
    ..['state'] = next.name
    ..['resolvedAt'] = now;
  await _writeProposalPayload(db, row.id, payload);
  return next;
}

Future<void> _pinRejected(
  FushiDatabase db,
  LibraryOrganizeProposalView view,
) async {
  switch (view.kind) {
    case OrganizeProposalKind.removeMembers:
      final MediaCollectionRow? c = await db.getMediaCollectionByNaturalKey(
        view.targetName,
        view.targetType,
      );
      if (c == null) return;
      await _pinPresentMembers(db, c.id, <String>{
        for (final OrganizeProposalMember m in view.members)
          _memberSigPart(m.mediaType, m.entryKey),
      });
    case OrganizeProposalKind.merge:
      for (final String name in view.sourceNames) {
        final MediaCollectionRow? s = await db.getMediaCollectionByNaturalKey(
          name,
          view.targetType,
        );
        if (s == null) continue;
        await _pinPresentMembers(db, s.id, <String>{
          for (final MediaCollectionItemRow i in await db.getCollectionItems(
            s.id,
          ))
            _memberSigPart(i.mediaType, i.entryKey),
        });
      }
    case OrganizeProposalKind.rename:
      break;
  }
}

Future<({OrganizeProposalState state, Map<String, Object?>? applied})>
_acceptProposal(FushiDatabase db, LibraryOrganizeProposalView view) async {
  const ({OrganizeProposalState state, Map<String, Object?>? applied}) stale = (
    state: OrganizeProposalState.stale,
    applied: null,
  );
  final MediaCollectionRow? target = await db.getMediaCollectionByNaturalKey(
    view.targetName,
    view.targetType,
  );
  if (target == null) return stale;
  switch (view.kind) {
    case OrganizeProposalKind.merge:
      final List<int> sources = <int>[
        for (final String name in view.sourceNames)
          if (await db.getMediaCollectionByNaturalKey(name, view.targetType)
              case final MediaCollectionRow s
              when s.id != target.id && s.sourceFolderPath == null)
            s.id,
      ];
      if (sources.isEmpty) return stale;
      final Map<String, Object?> snapshot = await _mergeSnapshot(
        db,
        target.id,
        sources,
      );
      await mergeMediaCollectionsInto(
        db,
        targetId: target.id,
        sourceIds: sources,
      );
      return (state: OrganizeProposalState.accepted, applied: snapshot);
    case OrganizeProposalKind.rename:
      final String? newName = view.newName;
      if (newName == null ||
          await db.getMediaCollectionByNaturalKey(newName, view.targetType) !=
              null) {
        return stale;
      }
      await db.renameMediaCollection(target.id, newName);
      return (
        state: OrganizeProposalState.accepted,
        applied: <String, Object?>{'from': target.name, 'to': newName},
      );
    case OrganizeProposalKind.removeMembers:
      final Set<String> wanted = <String>{
        for (final OrganizeProposalMember m in view.members)
          _memberSigPart(m.mediaType, m.entryKey),
      };
      final List<MediaCollectionItemRow> items = await db.getCollectionItems(
        target.id,
      );
      final List<Map<String, Object?>> removed = <Map<String, Object?>>[];
      for (int i = 0; i < items.length; i++) {
        final MediaCollectionItemRow it = items[i];
        if (it.pinnedByUser) continue;
        if (!wanted.contains(_memberSigPart(it.mediaType, it.entryKey))) {
          continue;
        }
        removed.add(<String, Object?>{
          't': it.mediaType,
          'k': it.entryKey,
          'sortIndex': it.sortIndex,
          'pos': i,
          'pinned': it.pinnedByUser,
        });
      }
      if (removed.isEmpty) return stale;
      // 全部移走 = 合集随最后一个成员自删：先记身份快照，撤销按原 id 还原（BUG-5461）。
      final Map<String, Object?>? identity = removed.length == items.length
          ? await db.captureMediaCollectionSnapshot(target.id)
          : null;
      for (final Map<String, Object?> m in removed) {
        await db.removeFromCollectionRaw(
          target.id,
          m['t']! as String,
          m['k']! as String,
        );
      }
      return (
        state: OrganizeProposalState.accepted,
        applied: <String, Object?>{
          'removed': removed,
          // 移空自删后撤销按原来源 / 分组身份重建。
          'origin': target.origin,
          'key': target.organizeKey,
          'aliases': target.organizeAliases,
          if (identity != null &&
              await db.getMediaCollectionById(target.id) == null)
            'identity': identity,
        },
      );
  }
}

/// 撤销一条已接受的建议（用户在同意后的「撤销」）：
/// - removeMembers：成员放回原合集（移空自删了就按记录的来源 / 分组身份重建）、按移出
///   前的位置插回、pinned 照原样；
/// - merge：按合并快照把败方重建、成员移回（同整理记录的合并撤销）；
/// - rename：新名字还在、原名没被占 → 改回原名。
/// 「这次不」（deferred）的建议也能撤：取消暂缓。
/// 撤成后建议回到 pending（重新出现在待确认列表）。建议不存在 / 不是 accepted 或
/// deferred / 没有可撤的快照 / 目标已不在时返回 false，状态不变。
Future<bool> undoLibraryOrganizeProposal(
  FushiDatabase db,
  int proposalId,
) async {
  final LibraryOrganizeChangeRow? row = await _proposalRow(db, proposalId);
  if (row == null) return false;
  final LibraryOrganizeProposalView? view = _proposalView(row);
  if (view == null) return false;
  final Map<String, Object?> payload = _decode(row.payloadJson)!;
  // 「这次不」的撤销：取消暂缓，回到等确认。
  if (view.state == OrganizeProposalState.deferred) {
    payload
      ..remove('deferredUntil')
      ..remove('resolvedAt')
      ..['state'] = OrganizeProposalState.pending.name;
    await _writeProposalPayload(db, row.id, payload);
    return true;
  }
  if (view.state != OrganizeProposalState.accepted) return false;
  final Object? rawApplied = payload['applied'];
  if (rawApplied is! Map) return false;
  final Map<String, Object?> applied = rawApplied.cast<String, Object?>();
  bool did = false;
  switch (view.kind) {
    case OrganizeProposalKind.removeMembers:
      did = await _undoRemoveMembers(db, view, applied);
    case OrganizeProposalKind.merge:
      final MediaCollectionRow? c = await db.getMediaCollectionByNaturalKey(
        view.targetName,
        view.targetType,
      );
      if (c != null) {
        await _undoMergeSnapshot(db, c, applied);
        did = true;
      }
    case OrganizeProposalKind.rename:
      final Object? from = applied['from'];
      final Object? to = applied['to'];
      if (from is! String || to is! String) break;
      final MediaCollectionRow? c = await db.getMediaCollectionByNaturalKey(
        to,
        view.targetType,
      );
      if (c == null ||
          await db.getMediaCollectionByNaturalKey(from, view.targetType) !=
              null) {
        break;
      }
      await db.renameMediaCollection(c.id, from);
      did = true;
  }
  if (!did) return false;
  payload
    ..remove('applied')
    ..remove('resolvedAt')
    ..['state'] = OrganizeProposalState.pending.name;
  await _writeProposalPayload(db, row.id, payload);
  return true;
}

Future<bool> _undoRemoveMembers(
  FushiDatabase db,
  LibraryOrganizeProposalView view,
  Map<String, Object?> applied,
) async {
  final List<({String t, String k, int pos, bool pinned})> removed =
      <({String t, String k, int pos, bool pinned})>[
        if (applied['removed'] is List)
          for (final Object? m in applied['removed']! as List<Object?>)
            if (m is Map && m['t'] is String && m['k'] is String)
              (
                t: m['t'] as String,
                k: m['k'] as String,
                pos: (m['pos'] as num?)?.toInt() ?? 1 << 30,
                pinned: m['pinned'] == true,
              ),
      ]..sort(
        (
          ({String t, String k, int pos, bool pinned}) a,
          ({String t, String k, int pos, bool pinned}) b,
        ) => a.pos.compareTo(b.pos),
      );
  if (removed.isEmpty) return false;
  final MediaCollectionRow? existing = await db.getMediaCollectionByNaturalKey(
    view.targetName,
    view.targetType,
  );
  final CollectionOrigin origin = _originOr(
    applied['origin'],
    CollectionOrigin.user,
  );
  final int id = await _reviveCollection(
    db,
    identity: applied['identity'],
    existing: existing,
    recreate: () async {
      final int id = await db.createMediaCollection(
        view.targetName,
        collectionType: view.targetType,
        origin: origin,
        organizeKey: applied['key'] as String?,
      );
      await db.setMediaCollectionOrganizeState(
        id,
        origin: origin,
        organizeKey: applied['key'] as String?,
        organizeAliases: decodeOrganizeAliases(applied['aliases'] as String?),
      );
      return id;
    },
  );
  final Set<String> restored = <String>{};
  for (final ({String t, String k, int pos, bool pinned}) m in removed) {
    await db.addToCollectionRaw(
      id,
      m.t,
      m.k,
      userIntent: false,
      pinnedByUser: m.pinned,
    );
    restored.add(_memberSigPart(m.t, m.k));
  }
  // 按移出前的位置插回：其余成员保持现有相对顺序，放回的按原下标升序插入。
  final List<CollectionMemberKey> order = <CollectionMemberKey>[
    for (final MediaCollectionItemRow i in await db.getCollectionItems(id))
      if (!restored.contains(_memberSigPart(i.mediaType, i.entryKey)))
        (mediaType: i.mediaType, entryKey: i.entryKey),
  ];
  for (final ({String t, String k, int pos, bool pinned}) m in removed) {
    order.insert(m.pos < order.length ? m.pos : order.length, (
      mediaType: m.t,
      entryKey: m.k,
    ));
  }
  final MediaCollectionRow? now = await db.getMediaCollectionById(id);
  // 用户合集按用户重排（跨端传播恢复后的顺序）；别的来源不借此转成用户的。
  if (now != null &&
      CollectionOrigin.parse(now.origin) == CollectionOrigin.user) {
    await db.reorderCollectionItems(id, order);
  } else {
    await db.reorderCollectionItemsAutomatically(id, order);
  }
  return true;
}

Map<String, Object?>? _decode(String raw) {
  try {
    final Object? v = jsonDecode(raw);
    return v is Map ? v.cast<String, Object?>() : null;
  } on FormatException {
    return null;
  }
}

/// 整理记录页的数据：最近 [limit] 次运行（新的在前）与各自的改动。
Future<
  List<({LibraryOrganizeRunRow run, List<LibraryOrganizeChangeRow> changes})>
>
loadLibraryOrganizeHistory(FushiDatabase db, {int limit = 50}) async {
  final List<LibraryOrganizeRunRow> runs =
      await (db.select(db.libraryOrganizeRuns)
            ..orderBy(<OrderClauseGenerator<$LibraryOrganizeRunsTable>>[
              (t) => OrderingTerm.desc(t.startedAt),
              (t) => OrderingTerm.desc(t.id),
            ])
            ..limit(limit))
          .get();
  if (runs.isEmpty) {
    return const <
      ({LibraryOrganizeRunRow run, List<LibraryOrganizeChangeRow> changes})
    >[];
  }
  final Map<int, List<LibraryOrganizeChangeRow>> byRun =
      <int, List<LibraryOrganizeChangeRow>>{};
  // 待确认建议不是改动，走 [loadLibraryOrganizeProposals]。
  for (final LibraryOrganizeChangeRow c
      in await (db.select(db.libraryOrganizeChanges)..where(
            (t) =>
                t.runId.isIn(<int>[for (final r in runs) r.id]) &
                t.kind.equals(kLibraryOrganizeProposalKind).not(),
          ))
          .get()) {
    (byRun[c.runId] ??= <LibraryOrganizeChangeRow>[]).add(c);
  }
  return <
    ({LibraryOrganizeRunRow run, List<LibraryOrganizeChangeRow> changes})
  >[
    for (final LibraryOrganizeRunRow r in runs)
      (run: r, changes: byRun[r.id] ?? const <LibraryOrganizeChangeRow>[]),
  ];
}

List<({String t, String k})> _members(Object? raw) => <({String t, String k})>[
  if (raw is List)
    for (final Object? m in raw)
      if (m is Map && m['t'] is String && m['k'] is String)
        (t: m['t'] as String, k: m['k'] as String),
];

/// [_members] 连同成员行当时的 `pinned_by_user`（合并快照记的 `pinned`；旧记录缺
/// 字段按 false）。
List<({String t, String k, bool pinned})> _membersWithPin(
  Object? raw,
) => <({String t, String k, bool pinned})>[
  if (raw is List)
    for (final Object? m in raw)
      if (m is Map && m['t'] is String && m['k'] is String)
        (t: m['t'] as String, k: m['k'] as String, pinned: m['pinned'] == true),
];

/// 一处改动的置信度字面量 → 枚举（整理记录页展示用）。
AiOrganizeConfidence organizeChangeConfidence(LibraryOrganizeChangeRow row) =>
    AiOrganizeConfidence.parse(row.confidence) ?? AiOrganizeConfidence.high;
