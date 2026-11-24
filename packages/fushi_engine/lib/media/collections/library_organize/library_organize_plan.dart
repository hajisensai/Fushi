import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';

/// AI 整理库：事实模型 + 「AI 回复 → 要执行的改动」裁决（spec §7.7 / §7.8）。
///
/// 裁决：新建合集、并入、合并整理器合集、给视频打系列标签，以及合集归属整理（AI 库管家
/// 设计稿 §7）——把放错的条目从任何非目录合集（含用户合集）移出：单独放或挪进别的合集。
/// 移出守「用户永远赢」：用户亲手放进来的成员（pinned）不移，同一对（合集, 成员）AI
/// 只移出一次，移出用户合集必须带理由。用户合集的合并 / 改名也直接执行（AI 管库 v3
/// §2.2，取代库管家 §8 的确认卡；自动路径只收 high），可撤销。用户拒绝过的分组不复活；
/// 用户移出过的成员不放回；跨域、越界、重复一律丢弃（只丢那一条，不整批作废）。

/// 整理怎么触发的（决定置信度门槛）。
enum OrganizeTrigger { manual, auto }

/// 一个条目：本地身份 + 给 AI 看的事实。
class OrganizeEntry {
  const OrganizeEntry({
    required this.mediaType,
    required this.entryKey,
    required this.tombstoneKey,
    required this.item,
    this.externalWorkKey,
    this.managedCollectionId,
    this.collectionIds = const <int>[],
    this.companions = const <OrganizeMemberRow>[],
    this.groupTitle,
  });

  /// 成员行的种类与键（本地键域：epub = uid）。
  final String mediaType;
  final String entryKey;

  /// 与 `collectionMemberTombstoneKeysFor` 可直比的墓碑键（`mediaType NUL wireKey`）。
  final String tombstoneKey;

  final AiOrganizeItem item;

  /// 已刮到的作品级外部 id 键（`anilist:<id>` / `tmdb:<tv|movie>:<id>` / `anidb:<id>`，
  /// 与刮削作品同粒度）；只用于本地成组与否决，不发给 AI。
  final String? externalWorkKey;

  /// 它所在的整理器合集（`ai` / `rule`）；null = 散条目。
  final int? managedCollectionId;

  /// 它所在的全部合集（整理器 / 用户；含目录合集的条目不进事实），升序。
  final List<int> collectionIds;

  /// 它所在的合集：[collectionIds]，旧调用方只给了 [managedCollectionId] 时取它。
  List<int> get memberOf => collectionIds.isNotEmpty
      ? collectionIds
      : <int>[if (managedCollectionId != null) managedCollectionId!];

  /// 规则成组时用的组名（视频 = 刮削作品标题）；null = 没有。
  final String? groupTitle;

  /// 跟它算一卷的其它成员行（EPUB 配对的 SRT 有声书）：加入 / 移出时一起动，与
  /// `BookSeriesGrouper` 的「一卷 = 书架上一张卡」同口径。
  final List<OrganizeMemberRow> companions;

  /// 这一卷的全部成员行（主行在前）。
  List<OrganizeMemberRow> get rows => <OrganizeMemberRow>[
    OrganizeMemberRow(
      mediaType: mediaType,
      entryKey: entryKey,
      tombstoneKey: tombstoneKey,
    ),
    ...companions,
  ];

  String get memberKey => '$mediaType\u0000$entryKey';
}

/// 一条成员行。
class OrganizeMemberRow {
  const OrganizeMemberRow({
    required this.mediaType,
    required this.entryKey,
    required this.tombstoneKey,
  });

  final String mediaType;
  final String entryKey;
  final String tombstoneKey;
}

/// 一个已有合集。
class OrganizeCollectionFact {
  const OrganizeCollectionFact({
    required this.id,
    required this.name,
    required this.collectionType,
    required this.origin,
    required this.organizeKey,
    required this.organizeAliases,
    required this.memberKeys,
    required this.sampleTitles,
    this.pinnedMemberKeys = const <String>{},
    this.aiEvictedMemberKeys = const <String>{},
  });

  final int id;
  final String name;
  final String collectionType;

  /// 目录合集（`sourceFolderPath` 非空）一律是 [CollectionOrigin.folder]。
  final CollectionOrigin origin;
  final String? organizeKey;
  final Set<String> organizeAliases;

  /// 成员行键（`mediaType NUL entryKey`，本地键域）。
  final Set<String> memberKeys;
  final List<String> sampleTitles;

  /// 用户亲手放进来的成员（`pinned_by_user`，跨端同步取或）：AI 不移出。
  final Set<String> pinnedMemberKeys;

  /// AI 已经从这个合集移出过一次的成员（本机整理记录里的移出 / 挪走，含已撤销的）：
  /// 不再移出，也不再放回。
  final Set<String> aiEvictedMemberKeys;

  bool get isFolder => origin == CollectionOrigin.folder;

  /// AI 能不能把 [memberKey] 从这个合集里移出（AI 库管家设计稿 §7）。
  bool canRelease(String memberKey) =>
      !isFolder &&
      !pinnedMemberKeys.contains(memberKey) &&
      !aiEvictedMemberKeys.contains(memberKey);

  Set<String> get identityKeys => <String>{
    if (organizeKey != null) organizeKey!,
    ...organizeAliases,
  };
}

/// 一个域的整理输入。
class LibraryOrganizeFacts {
  const LibraryOrganizeFacts({
    required this.domain,
    required this.entries,
    required this.collections,
    required this.rejectedKeys,
    required this.rejectedNames,
    required this.takenNames,
  });

  final CollectionShelfDomain domain;

  /// 散条目 + 非目录合集（整理器 / 用户）的成员。
  final List<OrganizeEntry> entries;

  /// 本域全部合集。
  final List<OrganizeCollectionFact> collections;

  /// 用户拒绝过的分组键 → 当时的合集名。
  final Set<String> rejectedKeys;
  final Map<String, String> rejectedNames;

  /// `(name NUL type)` → 占着这个自然键的分组键集合（活合集的主键与别名、删除墓碑上
  /// 记的键；空集 = 被不带键的合集占着）。新合集撞名且不是同一个分组时换名用。
  final Map<String, Set<String>> takenNames;

  /// [natural] 被别的分组（不是 [key]）占着。
  bool nameTakenByOther(String natural, String key) {
    final Set<String>? holders = takenNames[natural];
    return holders != null && !holders.contains(key);
  }

  /// 已知分组键（活合集的键与别名）。
  Set<String> get knownKeys => <String>{
    for (final OrganizeCollectionFact c in collections) ...c.identityKeys,
  };
}

/// `move`：从 [OrganizeAction.fromCollectionId] 移出并放进 [OrganizeAction.
/// targetCollectionId]，一处记录、整体撤销。`evict` 不带去处 = 移出后单独放。
/// `rename`：把 [OrganizeAction.targetCollectionId] 改名为 [OrganizeAction.name]
/// （AI 身份，不转所有权；目录合集与撞自然键的不改）。
enum OrganizeActionKind { create, add, merge, evict, move, tag, rename }

/// 一处要执行的改动。
class OrganizeAction {
  const OrganizeAction({
    required this.kind,
    required this.source,
    required this.confidence,
    this.name,
    this.collectionType = 'playlist',
    this.organizeKey,
    this.entries = const <OrganizeEntry>[],
    this.targetCollectionId,
    this.sourceCollectionIds = const <int>[],
    this.fromCollectionId,
    this.reason,
  });

  final OrganizeActionKind kind;

  /// `rule` | `ai`。
  final String source;
  final AiOrganizeConfidence confidence;

  /// create：新合集名；tag：标签名；rename：新名字。
  final String? name;
  final String collectionType;
  final String? organizeKey;
  final List<OrganizeEntry> entries;

  /// add / merge / evict / rename 的目标合集；move 的去处。
  final int? targetCollectionId;

  /// merge 的败方合集。
  final List<int> sourceCollectionIds;

  /// move 的来处。
  final int? fromCollectionId;

  /// AI 给的理由（移出 / 挪走时存进整理记录，记录页可见）。
  final String? reason;
}

/// 合集级改动的待确认建议（AI 库管家设计稿 §8）。AI 管库 v3（§2.2）起 AI 裁决不再
/// 产出建议（合并 / 改名直接执行）；建议只剩动**用户合集**（`origin == user`）的路径：
/// 收敛想把同键的用户合集并掉（[merge]）、导入器想从用户合集移出成员
/// （[removeMembers]，见 [MemberRemovalProposal]）。用户 2026-11-24 拍板：「用户的合集
/// 整理器永远不能往外移成员 取消这个设定吧，我觉得让用户显式同意就行了吧，用户可以
/// 永远拒绝」——这些改动一律等用户逐条同意 / 这次不 / 永远不。
enum OrganizeProposalKind { merge, rename, removeMembers }

/// 从用户合集移出成员的待确认建议（导入器 / 整理器给出，[recordMemberRemovalProposals]
/// 记账）。成员按 `(mediaType, entryKey)` 指认。
class MemberRemovalProposal {
  const MemberRemovalProposal({
    required this.collectionId,
    required this.members,
    required this.reasonCode,
    this.reason,
  });

  final int collectionId;
  final List<CollectionMemberKey> members;

  /// 机器可读的原因码（如 [kMemberRemovalReasonDiscExtra]），界面按码出本地化说明。
  final String reasonCode;

  /// 可选的原文补充（不本地化，原样显示）。
  final String? reason;
}

/// [MemberRemovalProposal.reasonCode]：原盘特典不是正片的一集。
const String kMemberRemovalReasonDiscExtra = 'disc_extra';

class OrganizeProposal {
  const OrganizeProposal({
    required this.kind,
    required this.targetCollectionId,
    required this.confidence,
    this.sourceCollectionIds = const <int>[],
    this.newName,
    this.reason,
    this.source = 'ai',
  });

  final OrganizeProposalKind kind;

  /// 谁提的：`ai`（AI 整理）/ `rule`（收敛等确定性规则）。整理记录的 source 列。
  final String source;

  /// merge：胜方；rename：要改名的合集。
  final int targetCollectionId;

  /// merge 的败方合集。
  final List<int> sourceCollectionIds;

  /// rename 的新名字。
  final String? newName;
  final AiOrganizeConfidence confidence;
  final String? reason;
}

/// 一份 AI 回复的裁决结果：要直接执行的改动。
class OrganizePlan {
  const OrganizePlan({required this.actions});

  final List<OrganizeAction> actions;
}

/// 一次请求发给 AI 的那一块：下标 ↔ 本地对象。
class OrganizeChunk {
  const OrganizeChunk({required this.entries, required this.collections});

  /// 下标 i ↔ entries[i]。
  final List<OrganizeEntry> entries;

  /// `C<n>` ↔ collections[n]。
  final List<OrganizeCollectionFact> collections;

  String collectionIdOf(int index) => 'C$index';

  OrganizeCollectionFact? collectionById(String id) {
    final int? n = int.tryParse(id.substring(1));
    if (n == null || n < 0 || n >= collections.length) return null;
    return collections[n];
  }
}

/// 某置信度在该触发方式下能不能落盘（spec §7.7）。合并两个已有合集更重，自动时只收 high。
bool organizeConfidenceAccepted(
  AiOrganizeConfidence c,
  OrganizeTrigger trigger, {
  bool isMerge = false,
}) {
  switch (c) {
    case AiOrganizeConfidence.high:
      return true;
    case AiOrganizeConfidence.medium:
      return trigger == OrganizeTrigger.manual && !isMerge;
    case AiOrganizeConfidence.low:
      return false;
  }
}

/// 新合集名的上限（字符）。
const int kOrganizeMaxNameLength = 80;

/// 裁决一份 AI 回复，只要直接执行的改动（[planOrganizeReply] 的 `actions`）。
List<OrganizeAction> planFromAiReply({
  required LibraryOrganizeFacts facts,
  required OrganizeChunk chunk,
  required AiOrganizeReply reply,
  required OrganizeTrigger trigger,
  required String tagPrefix,
}) => planOrganizeReply(
  facts: facts,
  chunk: chunk,
  reply: reply,
  trigger: trigger,
  tagPrefix: tagPrefix,
).actions;

/// 裁决一份 AI 回复。[tagPrefix] 是视频系列标签名的前缀（UI 语言，如 `系列:`）。
/// 合集级改动（合并、改名用户合集）与合并同一道门槛：自动只收 high。
OrganizePlan planOrganizeReply({
  required LibraryOrganizeFacts facts,
  required OrganizeChunk chunk,
  required AiOrganizeReply reply,
  required OrganizeTrigger trigger,
  required String tagPrefix,
}) {
  final String domainName = facts.domain.name;
  final List<OrganizeAction> out = <OrganizeAction>[];
  final _OrganizeNameAllocator names = _OrganizeNameAllocator(facts);
  final Map<int, OrganizeCollectionFact> byId = <int, OrganizeCollectionFact>{
    for (final OrganizeCollectionFact c in facts.collections) c.id: c,
  };

  // 同一条目出现在多条建议里：都不信。
  final Map<int, int> uses = <int, int>{};
  for (final AiOrganizeGroupProposal g in reply.groups) {
    for (final int i in g.members) {
      uses[i] = (uses[i] ?? 0) + 1;
    }
  }
  for (final AiOrganizeEvictionProposal e in reply.evictions) {
    for (final int i in e.members) {
      uses[i] = (uses[i] ?? 0) + 1;
    }
  }
  bool single(int i) => uses[i] == 1;

  // ── 合并已有合集 ────────────────────────────────────────────────────────
  // 败方 → 胜方：同一份回复里「并入败方」的分组 / 挪走改并进胜方（执行时合并先于
  // 加入，败方已不在了）。
  final Map<int, int> mergedInto = <int, int>{};
  for (final AiOrganizeMergeProposal m in reply.merges) {
    if (!organizeConfidenceAccepted(m.confidence, trigger, isMerge: true)) {
      continue;
    }
    final List<OrganizeCollectionFact> cs = <OrganizeCollectionFact>[
      for (final String id in m.collections)
        if (chunk.collectionById(id) case final OrganizeCollectionFact c) c,
    ];
    // 目录合集不参与。胜方按收敛同口径（用户合集优先）：几个用户合集合并也直接
    // 执行（AI 管库 v3 §2.2），撤销按快照把败方重建回来。
    if (cs.any((OrganizeCollectionFact c) => c.isFolder) || cs.length < 2) {
      continue;
    }
    final OrganizeCollectionFact target = (List<OrganizeCollectionFact>.of(
      cs,
    )..sort(_mergeWinnerOrder)).first;
    final List<int> sources = <int>[
      for (final OrganizeCollectionFact c in cs)
        if (c.id != target.id && !mergedInto.containsKey(c.id)) c.id,
    ];
    if (sources.isEmpty || mergedInto.containsKey(target.id)) continue;
    for (final int id in sources) {
      mergedInto[id] = target.id;
    }
    out.add(
      OrganizeAction(
        kind: OrganizeActionKind.merge,
        source: 'ai',
        confidence: m.confidence,
        targetCollectionId: target.id,
        sourceCollectionIds: sources,
      ),
    );
  }

  OrganizeCollectionFact? resolveTarget(String chunkId) {
    final OrganizeCollectionFact? c = chunk.collectionById(chunkId);
    if (c == null) return null;
    final int? winner = mergedInto[c.id];
    return winner == null ? c : byId[winner];
  }

  // ── 移出：单独放 / 挪进别的合集（设计稿 §7）──────────────────────────────
  for (final AiOrganizeEvictionProposal e in reply.evictions) {
    if (!organizeConfidenceAccepted(e.confidence, trigger)) continue;
    final OrganizeCollectionFact? from = chunk.collectionById(e.collection);
    if (from == null || from.isFolder) continue;
    final String? reason = _reasonOf(e.reason);
    // 从用户合集移出必须说清理由（存进整理记录给用户看）。
    if (from.origin == CollectionOrigin.user && reason == null) continue;
    OrganizeCollectionFact? to;
    if (e.into != null) {
      to = resolveTarget(e.into!);
      if (to == null || to.id == from.id) continue;
    }
    final List<OrganizeEntry> members = <OrganizeEntry>[
      for (final int i in e.members)
        if (single(i) &&
            from.memberKeys.contains(chunk.entries[i].memberKey) &&
            from.canRelease(chunk.entries[i].memberKey) &&
            !(to?.aiEvictedMemberKeys.contains(chunk.entries[i].memberKey) ??
                false))
          chunk.entries[i],
    ];
    if (members.isEmpty) continue;
    // 去处里已经有它：只剩「移出」一步。
    final List<OrganizeEntry> evictOnly = <OrganizeEntry>[
      for (final OrganizeEntry m in members)
        if (to == null || to.memberKeys.contains(m.memberKey)) m,
    ];
    final List<OrganizeEntry> moves = <OrganizeEntry>[
      for (final OrganizeEntry m in members)
        if (to != null && !to.memberKeys.contains(m.memberKey)) m,
    ];
    if (evictOnly.isNotEmpty) {
      out.add(
        OrganizeAction(
          kind: OrganizeActionKind.evict,
          source: 'ai',
          confidence: e.confidence,
          targetCollectionId: from.id,
          entries: evictOnly,
          reason: reason,
        ),
      );
    }
    if (moves.isNotEmpty) {
      out.add(
        OrganizeAction(
          kind: OrganizeActionKind.move,
          source: 'ai',
          confidence: e.confidence,
          fromCollectionId: from.id,
          targetCollectionId: to!.id,
          organizeKey: to.organizeKey,
          entries: moves,
          reason: reason,
        ),
      );
    }
  }

  // ── 改名：用户合集名字明显不对时直接改（AI 管库 v3 §2.2；门槛同合并）────────
  final Set<String> renamedTo = <String>{};
  for (final AiOrganizeRenameProposal r in reply.renames) {
    if (!organizeConfidenceAccepted(r.confidence, trigger, isMerge: true)) {
      continue;
    }
    final OrganizeCollectionFact? c = chunk.collectionById(r.collection);
    // 被合并掉的败方不改名（它马上就不在了）。
    if (c == null ||
        c.origin != CollectionOrigin.user ||
        mergedInto.containsKey(c.id)) {
      continue;
    }
    final String name = clampOrganizeName(r.name);
    if (name.isEmpty || name == c.name) continue;
    final String natural = '$name\u0000${c.collectionType}';
    // 新名字已被别的合集（或删除墓碑）占着、或本次已改给别的合集：改过去会撞自然键，
    // 不改。
    if (facts.takenNames.containsKey(natural) || !renamedTo.add(natural)) {
      continue;
    }
    out.add(
      OrganizeAction(
        kind: OrganizeActionKind.rename,
        source: 'ai',
        confidence: r.confidence,
        targetCollectionId: c.id,
        name: name,
        collectionType: c.collectionType,
        organizeKey: c.organizeKey,
        reason: _reasonOf(r.reason),
      ),
    );
  }

  // 分组只动「散的或只在整理器合集里、且都能移出来」的条目：在用户合集里的条目换
  // 合集只走「移出 + into」（带理由），pinned / 已被 AI 移出过的不动。
  bool groupable(OrganizeEntry e, OrganizeCollectionFact? target) {
    if (target != null && target.aiEvictedMemberKeys.contains(e.memberKey)) {
      return false;
    }
    for (final int cid in e.memberOf) {
      if (cid == target?.id) continue;
      final OrganizeCollectionFact? c = byId[cid];
      if (c == null || !c.origin.isOrganizerManaged) return false;
      if (!c.canRelease(e.memberKey)) return false;
    }
    return true;
  }

  // ── 分组：并入 / 新建 / 系列标签 ────────────────────────────────────────
  for (final AiOrganizeGroupProposal g in reply.groups) {
    if (!organizeConfidenceAccepted(g.confidence, trigger)) continue;
    final List<OrganizeEntry> members = <OrganizeEntry>[
      for (final int i in g.members)
        if (single(i)) chunk.entries[i],
    ];
    if (members.isEmpty) continue;

    if (g.into != null) {
      final OrganizeCollectionFact? target = resolveTarget(g.into!);
      if (target == null) continue;
      final List<OrganizeEntry> adds = <OrganizeEntry>[
        for (final OrganizeEntry e in members)
          if (!target.memberKeys.contains(e.memberKey) && groupable(e, target))
            e,
      ];
      if (adds.isEmpty) continue;
      out.addAll(_moveInto(adds, target, g.confidence));
      continue;
    }

    if (members.length < 2) continue;
    AiOrganizeLevel level = g.level;
    final Set<String> externals = <String>{
      for (final OrganizeEntry e in members)
        if (e.externalWorkKey != null) e.externalWorkKey!,
    };
    // 视频「同一部作品」里成员刮到了不同作品：那是系列，不是作品（spec §9）。
    if (facts.domain == CollectionShelfDomain.video &&
        level == AiOrganizeLevel.work &&
        externals.length > 1) {
      level = AiOrganizeLevel.franchise;
    }
    final String key = _keyFor(
      facts: facts,
      domainName: domainName,
      proposal: g,
      externals: level == AiOrganizeLevel.work ? externals : const <String>{},
    );
    if (facts.rejectedKeys.contains(key)) continue;

    if (facts.domain == CollectionShelfDomain.video &&
        level == AiOrganizeLevel.franchise) {
      final String label = clampOrganizeName(g.name);
      if (label.isEmpty) continue;
      out.add(
        OrganizeAction(
          kind: OrganizeActionKind.tag,
          source: 'ai',
          confidence: g.confidence,
          name: '$tagPrefix$label',
          organizeKey: key,
          entries: members,
        ),
      );
      continue;
    }

    // 分组键已有人持有：并进它，不新建。
    final OrganizeCollectionFact? holder = _holderOf(facts, key);
    if (holder != null) {
      final List<OrganizeEntry> adds = <OrganizeEntry>[
        for (final OrganizeEntry e in members)
          if (!holder.memberKeys.contains(e.memberKey) && groupable(e, holder))
            e,
      ];
      if (adds.isEmpty) continue;
      out.addAll(_moveInto(adds, holder, g.confidence));
      continue;
    }

    final List<OrganizeEntry> fresh = <OrganizeEntry>[
      for (final OrganizeEntry e in members)
        if (groupable(e, null)) e,
    ];
    if (fresh.length < 2) continue;
    String rawName = clampOrganizeName(g.name);
    if (rawName.isEmpty) rawName = clampOrganizeName(g.originalTitle ?? '');
    if (rawName.isEmpty) continue;
    const String type = 'playlist';
    final String? name = names.allocate(rawName, type, key);
    if (name == null) continue;
    out.addAll(_moveOut(fresh, g.confidence));
    out.add(
      OrganizeAction(
        kind: OrganizeActionKind.create,
        source: 'ai',
        confidence: g.confidence,
        name: name,
        collectionType: type,
        organizeKey: key,
        entries: fresh,
      ),
    );
  }
  return OrganizePlan(actions: out);
}

String? _reasonOf(String? raw) {
  final String t = (raw ?? '').trim();
  if (t.isEmpty) return null;
  return clampOrganizeCodePoints(t, 200);
}

/// 本地硬归组（spec §7.4，不花钱）：散条目里刮到**同一个**外部作品 id 的成组；
/// 已有合集持有这个键的并进去。
List<OrganizeAction> planFromRules({
  required LibraryOrganizeFacts facts,
  required String Function(List<OrganizeEntry> members) nameOf,
}) {
  final Map<String, List<OrganizeEntry>> byWork =
      <String, List<OrganizeEntry>>{};
  for (final OrganizeEntry e in facts.entries) {
    // 规则只给散条目成组（已在任何合集里的不动）。
    if (e.memberOf.isNotEmpty || e.externalWorkKey == null) continue;
    (byWork[e.externalWorkKey!] ??= <OrganizeEntry>[]).add(e);
  }
  final List<OrganizeAction> out = <OrganizeAction>[];
  final _OrganizeNameAllocator names = _OrganizeNameAllocator(facts);
  final List<String> keys = byWork.keys.toList()..sort();
  for (final String key in keys) {
    if (facts.rejectedKeys.contains(key)) continue;
    final List<OrganizeEntry> members = byWork[key]!;
    final OrganizeCollectionFact? holder = _holderOf(facts, key);
    if (holder != null) {
      out.add(
        OrganizeAction(
          kind: OrganizeActionKind.add,
          source: 'rule',
          confidence: AiOrganizeConfidence.high,
          targetCollectionId: holder.id,
          organizeKey: holder.organizeKey,
          entries: members,
        ),
      );
      continue;
    }
    if (members.length < 2) continue;
    final String rawName = clampOrganizeName(nameOf(members));
    if (rawName.isEmpty) continue;
    final String? name = names.allocate(rawName, 'playlist', key);
    if (name == null) continue;
    out.add(
      OrganizeAction(
        kind: OrganizeActionKind.create,
        source: 'rule',
        confidence: AiOrganizeConfidence.high,
        name: name,
        organizeKey: key,
        entries: members,
      ),
    );
  }
  return out;
}

/// 一次裁决里给「新建」分配合集名：既避开库里已占用的自然键（[LibraryOrganizeFacts.
/// nameTakenByOther]），也避开**本次已分配给别的分组**的名字——同一份回复里两组撞名
/// 时，`createMediaCollection` 会按自然键把第二组落进第一组的行，两个分组被静默并成
/// 一个。同一分组键重复出现照用原名（落盘时按自然键复用同一行，等于并入）。
class _OrganizeNameAllocator {
  _OrganizeNameAllocator(this._facts);

  final LibraryOrganizeFacts _facts;

  /// `(name NUL type)` → 本次把它分给了哪个分组键。
  final Map<String, String> _claimed = <String, String>{};

  bool _takenByOther(String name, String type, String key) {
    final String natural = '$name\u0000$type';
    final String? claimedBy = _claimed[natural];
    return _facts.nameTakenByOther(natural, key) ||
        (claimedBy != null && claimedBy != key);
  }

  /// 给分组 [key] 分配名字；原名被别的分组占着就加键哈希后缀，后缀名仍被占（哈希
  /// 撞车）返回 null——丢掉这一条，不冒险落进别人的合集。
  String? allocate(String name, String type, String key) {
    String out = name;
    if (_takenByOther(out, type, key)) {
      out = disambiguatedOrganizeName(name, key);
      if (_takenByOther(out, type, key)) return null;
    }
    _claimed['$out\u0000$type'] = key;
    return out;
  }
}

/// 新建分组前：成员已在的（整理器）合集里先移出（调用方已用 `groupable` 筛过，
/// 这里的来源都能移）。
List<OrganizeAction> _moveOut(
  List<OrganizeEntry> members,
  AiOrganizeConfidence confidence,
) {
  final Map<int, List<OrganizeEntry>> byCollection =
      <int, List<OrganizeEntry>>{};
  for (final OrganizeEntry e in members) {
    for (final int from in e.memberOf) {
      (byCollection[from] ??= <OrganizeEntry>[]).add(e);
    }
  }
  final List<int> ids = byCollection.keys.toList()..sort();
  return <OrganizeAction>[
    for (final int id in ids)
      OrganizeAction(
        kind: OrganizeActionKind.evict,
        source: 'ai',
        confidence: confidence,
        targetCollectionId: id,
        entries: byCollection[id]!,
      ),
  ];
}

/// 并进已有合集 [target]：散条目是一处「加入」；已在别的合集里的是「挪走」（从第一个
/// 来处移出并放进 [target]，一处记录、整体撤销），其余来处单纯移出。
List<OrganizeAction> _moveInto(
  List<OrganizeEntry> adds,
  OrganizeCollectionFact target,
  AiOrganizeConfidence confidence,
) {
  final List<OrganizeEntry> plain = <OrganizeEntry>[];
  final Map<int, List<OrganizeEntry>> moves = <int, List<OrganizeEntry>>{};
  final Map<int, List<OrganizeEntry>> evicts = <int, List<OrganizeEntry>>{};
  for (final OrganizeEntry e in adds) {
    final List<int> sources = <int>[
      for (final int cid in e.memberOf)
        if (cid != target.id) cid,
    ]..sort();
    if (sources.isEmpty) {
      plain.add(e);
      continue;
    }
    (moves[sources.first] ??= <OrganizeEntry>[]).add(e);
    for (final int cid in sources.skip(1)) {
      (evicts[cid] ??= <OrganizeEntry>[]).add(e);
    }
  }
  return <OrganizeAction>[
    for (final int id in evicts.keys.toList()..sort())
      OrganizeAction(
        kind: OrganizeActionKind.evict,
        source: 'ai',
        confidence: confidence,
        targetCollectionId: id,
        entries: evicts[id]!,
      ),
    for (final int id in moves.keys.toList()..sort())
      OrganizeAction(
        kind: OrganizeActionKind.move,
        source: 'ai',
        confidence: confidence,
        fromCollectionId: id,
        targetCollectionId: target.id,
        organizeKey: target.organizeKey,
        entries: moves[id]!,
      ),
    if (plain.isNotEmpty)
      OrganizeAction(
        kind: OrganizeActionKind.add,
        source: 'ai',
        confidence: confidence,
        targetCollectionId: target.id,
        organizeKey: target.organizeKey,
        entries: plain,
      ),
  ];
}

String _keyFor({
  required LibraryOrganizeFacts facts,
  required String domainName,
  required AiOrganizeGroupProposal proposal,
  required Set<String> externals,
}) {
  if (externals.length == 1) return externals.single;
  final String? claimed = proposal.key;
  if (claimed != null &&
      (facts.knownKeys.contains(claimed) ||
          facts.rejectedKeys.contains(claimed))) {
    return claimed;
  }
  return titleOrganizeKey(
        domainName,
        proposal.originalTitle ?? proposal.name,
      ) ??
      titleOrganizeKey(domainName, proposal.name) ??
      't:$domainName:${proposal.name}';
}

OrganizeCollectionFact? _holderOf(LibraryOrganizeFacts facts, String key) {
  // 用户合集只认主键（别名只是吸收记录，见 organize_convergence 的 holdsKey）。
  final List<OrganizeCollectionFact> holders = <OrganizeCollectionFact>[
    for (final OrganizeCollectionFact c in facts.collections)
      if (c.origin == CollectionOrigin.user
          ? c.organizeKey == key
          : c.identityKeys.contains(key))
        c,
  ]..sort(_mergeWinnerOrder);
  return holders.isEmpty ? null : holders.first;
}

/// 与收敛同口径的胜方序（用户优先、外部 id 键优先、名字）。
int _mergeWinnerOrder(OrganizeCollectionFact a, OrganizeCollectionFact b) {
  final bool aUser = a.origin == CollectionOrigin.user;
  final bool bUser = b.origin == CollectionOrigin.user;
  if (aUser != bUser) return aUser ? -1 : 1;
  final String? ak = a.organizeKey;
  final String? bk = b.organizeKey;
  if (ak != null && bk == null) return -1;
  if (ak == null && bk != null) return 1;
  if (ak != null && bk != null) {
    final int c = compareOrganizeKeys(ak, bk);
    if (c != 0) return c;
  }
  final int byName = a.name.compareTo(b.name);
  return byName != 0 ? byName : a.collectionType.compareTo(b.collectionType);
}

/// 合集名规整：去首尾空白、连续空白折成一个空格、按码点截到
/// [kOrganizeMaxNameLength]。AI 整理建议与 AI 管库变更集（`library_changeset.dart`）
/// 共用这一处口径。
String clampOrganizeName(String raw) {
  final String t = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  return clampOrganizeCodePoints(t, kOrganizeMaxNameLength);
}

/// 按码点截到 [max] 个（合集名 / 理由的长度上限，不是学习字数）。
String clampOrganizeCodePoints(String t, int max) {
  if (t.runes.length <= max) return t;
  return String.fromCharCodes(t.runes.take(max)).trim();
}
