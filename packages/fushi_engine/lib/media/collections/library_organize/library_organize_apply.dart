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
        final Set<String> before = <String>{
          for (final MediaCollectionItemRow i in await db.getCollectionItems(
            target.id,
          ))
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
            // pinned：用户亲手放进来 / 否决过移出的成员，撤销重建时照原样钉住
            // （缺字段的旧记录按 false）。
            'members': <Map<String, Object?>>[
              for (final MediaCollectionItemRow i
                  in await db.getCollectionItems(id))
                <String, Object?>{
                  't': i.mediaType,
                  'k': i.entryKey,
                  if (i.pinnedByUser) 'pinned': true,
                },
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
        // 移出最后一个成员时合集会被移空自删（不写合集墓碑）：按记录重建它。
        final int id =
            c?.id ??
            await db.createMediaCollection(
              r.collectionName,
              collectionType: r.collectionType,
              origin: _originOr(payload['origin'], CollectionOrigin.ai),
              organizeKey: r.organizeKey,
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
        final int fromId =
            from?.id ??
            await db.createMediaCollection(
              fromName,
              collectionType: fromType,
              origin: _originOr(rawFrom['origin'], CollectionOrigin.ai),
              organizeKey: rawFrom['key'] as String?,
            );
        await _restorePinned(db, fromId, _members(payload['members']));
        did = true;
      case 'merge':
        if (c == null) break;
        final Set<String> before = <String>{
          for (final Object? k
              in (payload['targetBefore'] as List<Object?>? ??
                  const <Object?>[]))
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
          final int id = await db.createMediaCollection(
            name,
            collectionType: type,
            origin: CollectionOrigin.user,
            organizeKey: s['key'] as String?,
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
              await db.removeFromCollectionRaw(
                c.id,
                m.t,
                m.k,
                userIntent: false,
              );
            }
          }
        }
        final MediaCollectionRow? target = await db.getMediaCollectionById(
          c.id,
        );
        if (target != null) {
          await db.setMediaCollectionOrganizeState(
            target.id,
            origin: CollectionOrigin.user,
            organizeKey: target.organizeKey,
            organizeAliases: decodeOrganizeAliases(target.organizeAliases)
              ..removeAll(returnedKeys),
          );
        }
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

/// 整理记录里「待确认建议」行的 kind。与改动同表（设备本地、不同步），但不计入改动
/// 数、不出现在整理记录的改动列表、不参与撤销。
const String kLibraryOrganizeProposalKind = 'proposal';

/// 一条建议当前的状态。
enum OrganizeProposalState {
  pending,
  accepted,
  rejected,

  /// 涉及的合集已不在 / 新名字被占：没法照原样执行。
  stale;

  static OrganizeProposalState parse(Object? raw) {
    for (final OrganizeProposalState s in OrganizeProposalState.values) {
      if (s.name == raw) return s;
    }
    return OrganizeProposalState.pending;
  }
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
  });

  final int id;
  final int runId;
  final OrganizeProposalKind kind;
  final OrganizeProposalState state;

  /// merge：并进哪个合集；rename：改哪个合集的名字。
  final String targetName;
  final String targetType;

  /// merge 的败方合集名（同类型）。
  final List<String> sourceNames;

  /// rename 的新名字。
  final String? newName;
  final AiOrganizeConfidence confidence;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'runId': runId,
    'kind': kind.name,
    'state': state.name,
    'collection': targetName,
    'collectionType': targetType,
    if (kind == OrganizeProposalKind.merge) 'sources': sourceNames,
    if (newName != null) 'newName': newName,
    'confidence': confidence.name,
    if (reason != null) 'reason': reason,
  };
}

String _proposalSignature(
  OrganizeProposalKind kind,
  String targetName,
  String type,
  List<String> sources,
  String? newName,
) => <String>[
  kind.name,
  type,
  targetName,
  ...(List<String>.of(sources)..sort()),
  newName ?? '',
].join('\u0000');

/// 把裁决出的待确认建议记进整理记录（按此刻的合集自然键快照）。同一条建议已在等确认
/// 或用户拒绝过的不再记（不反复打扰）。返回新记的条数。
Future<int> recordOrganizeProposals(
  FushiDatabase db, {
  required int runId,
  required List<OrganizeProposal> proposals,
}) async {
  if (proposals.isEmpty) return 0;
  final Set<String> known = <String>{
    for (final LibraryOrganizeChangeRow r in await (db.select(
      db.libraryOrganizeChanges,
    )..where((t) => t.kind.equals(kLibraryOrganizeProposalKind))).get())
      if (_decode(r.payloadJson) case final Map<String, Object?> p)
        if (OrganizeProposalState.parse(p['state']) !=
            OrganizeProposalState.accepted)
          if (p['sig'] case final String sig) sig,
  };
  int recorded = 0;
  for (final OrganizeProposal p in proposals) {
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
    final String sig = _proposalSignature(
      p.kind,
      target.name,
      target.collectionType,
      sources,
      p.newName,
    );
    if (!known.add(sig)) continue;
    await db
        .into(db.libraryOrganizeChanges)
        .insert(
          LibraryOrganizeChangesCompanion.insert(
            runId: runId,
            kind: kLibraryOrganizeProposalKind,
            collectionName: target.name,
            collectionType: target.collectionType,
            organizeKey: Value<String?>(target.organizeKey),
            source: 'ai',
            confidence: p.confidence.name,
            payloadJson: jsonEncode(<String, Object?>{
              'proposal': p.kind.name,
              'state': OrganizeProposalState.pending.name,
              'sig': sig,
              if (p.kind == OrganizeProposalKind.merge) 'sources': sources,
              if (p.newName != null) 'newName': p.newName,
              if (p.reason != null) 'reason': p.reason,
            }),
          ),
        );
    recorded++;
  }
  return recorded;
}

/// 列出待确认建议（新的在前）。[pendingOnly] 为 false 时连已处理的一起列。
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
  final OrganizeProposalKind? kind = switch (p['proposal']) {
    'merge' => OrganizeProposalKind.merge,
    'rename' => OrganizeProposalKind.rename,
    _ => null,
  };
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
  );
}

/// 用户处理一条待确认建议：[accept] 为 true 时以**用户身份**执行（`userIntent:
/// true`，一次用户写入，不进整理撤销），false 时记为拒绝（以后同样的建议不再提）。
/// 返回处理后的状态；建议不存在或已处理过返回 null。
Future<OrganizeProposalState?> resolveLibraryOrganizeProposal(
  FushiDatabase db,
  int proposalId, {
  required bool accept,
}) async {
  final LibraryOrganizeChangeRow? row =
      await (db.select(db.libraryOrganizeChanges)..where(
            (t) =>
                t.id.equals(proposalId) &
                t.kind.equals(kLibraryOrganizeProposalKind),
          ))
          .getSingleOrNull();
  if (row == null) return null;
  final LibraryOrganizeProposalView? view = _proposalView(row);
  if (view == null || view.state != OrganizeProposalState.pending) return null;
  OrganizeProposalState next = OrganizeProposalState.rejected;
  if (accept) {
    // 不包事务：合并会回收被解散合集的封面等磁盘资产，回滚不了。
    next = await (() async {
      final MediaCollectionRow? target = await db
          .getMediaCollectionByNaturalKey(view.targetName, view.targetType);
      if (target == null) return OrganizeProposalState.stale;
      switch (view.kind) {
        case OrganizeProposalKind.merge:
          final List<int> sources = <int>[
            for (final String name in view.sourceNames)
              if (await db.getMediaCollectionByNaturalKey(name, view.targetType)
                  case final MediaCollectionRow s
                  when s.id != target.id && s.sourceFolderPath == null)
                s.id,
          ];
          if (sources.isEmpty) return OrganizeProposalState.stale;
          await mergeMediaCollectionsInto(
            db,
            targetId: target.id,
            sourceIds: sources,
          );
          return OrganizeProposalState.accepted;
        case OrganizeProposalKind.rename:
          final String? newName = view.newName;
          if (newName == null ||
              await db.getMediaCollectionByNaturalKey(
                    newName,
                    view.targetType,
                  ) !=
                  null) {
            return OrganizeProposalState.stale;
          }
          await db.renameMediaCollection(target.id, newName);
          return OrganizeProposalState.accepted;
      }
    })();
  }
  final Map<String, Object?> payload = _decode(row.payloadJson)!
    ..['state'] = next.name
    ..['resolvedAt'] = DateTime.now().millisecondsSinceEpoch;
  await (db.update(
    db.libraryOrganizeChanges,
  )..where((t) => t.id.equals(row.id))).write(
    LibraryOrganizeChangesCompanion(
      payloadJson: Value<String>(jsonEncode(payload)),
    ),
  );
  return next;
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
