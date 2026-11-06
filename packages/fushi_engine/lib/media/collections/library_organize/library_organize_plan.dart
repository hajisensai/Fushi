import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';

/// AI 整理库：事实模型 + 「AI 回复 → 要执行的改动」裁决（spec §7.7 / §7.8）。
///
/// 裁决只做加法与纠正整理器自己的错：新建合集、并入、合并、移出整理器合集里放错的、
/// 给视频打系列标签。用户的合集只能往里加；用户拒绝过的分组不复活；用户移出过的成员
/// 不放回；跨域、越界、重复一律丢弃（只丢那一条，不整批作废）。

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
  });

  final int id;
  final String name;
  final String collectionType;
  final CollectionOrigin origin;
  final String? organizeKey;
  final Set<String> organizeAliases;

  /// 成员行键（`mediaType NUL entryKey`，本地键域）。
  final Set<String> memberKeys;
  final List<String> sampleTitles;

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

  /// 散条目 + 整理器合集的成员。
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

enum OrganizeActionKind { create, add, merge, evict, tag }

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
  });

  final OrganizeActionKind kind;

  /// `rule` | `ai`。
  final String source;
  final AiOrganizeConfidence confidence;

  /// create：新合集名；tag：标签名。
  final String? name;
  final String collectionType;
  final String? organizeKey;
  final List<OrganizeEntry> entries;

  /// add / merge / evict 的目标合集。
  final int? targetCollectionId;

  /// merge 的败方合集。
  final List<int> sourceCollectionIds;
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

/// 裁决一份 AI 回复。[tagPrefix] 是视频系列标签名的前缀（UI 语言，如 `系列:`）。
List<OrganizeAction> planFromAiReply({
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

  // ── 移出 ────────────────────────────────────────────────────────────────
  for (final AiOrganizeEvictionProposal e in reply.evictions) {
    if (!organizeConfidenceAccepted(e.confidence, trigger)) continue;
    final OrganizeCollectionFact? c = chunk.collectionById(e.collection);
    if (c == null || !c.origin.isOrganizerManaged) continue;
    final List<OrganizeEntry> members = <OrganizeEntry>[
      for (final int i in e.members)
        if (single(i) && c.memberKeys.contains(chunk.entries[i].memberKey))
          chunk.entries[i],
    ];
    if (members.isEmpty) continue;
    out.add(
      OrganizeAction(
        kind: OrganizeActionKind.evict,
        source: 'ai',
        confidence: e.confidence,
        targetCollectionId: c.id,
        entries: members,
      ),
    );
  }

  // ── 合并已有合集 ────────────────────────────────────────────────────────
  // 败方 → 胜方：同一份回复里「并入败方」的分组改并进胜方（执行时合并先于加入，
  // 败方已不在了）。
  final Map<int, int> mergedInto = <int, int>{};
  for (final AiOrganizeMergeProposal m in reply.merges) {
    if (!organizeConfidenceAccepted(m.confidence, trigger, isMerge: true)) {
      continue;
    }
    final List<OrganizeCollectionFact> cs = <OrganizeCollectionFact>[
      for (final String id in m.collections)
        if (chunk.collectionById(id) case final OrganizeCollectionFact c) c,
    ];
    // 目录合集不参与；用户合集至多一个且当胜方；其余必须是整理器合集。
    if (cs.any(
      (OrganizeCollectionFact c) => c.origin == CollectionOrigin.folder,
    )) {
      continue;
    }
    final List<OrganizeCollectionFact> users = <OrganizeCollectionFact>[
      for (final OrganizeCollectionFact c in cs)
        if (c.origin == CollectionOrigin.user) c,
    ];
    if (users.length > 1 || cs.length < 2) continue;
    final OrganizeCollectionFact target = users.isNotEmpty
        ? users.single
        : (List<OrganizeCollectionFact>.of(cs)..sort(_mergeWinnerOrder)).first;
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

  // ── 分组：并入 / 新建 / 系列标签 ────────────────────────────────────────
  for (final AiOrganizeGroupProposal g in reply.groups) {
    if (!organizeConfidenceAccepted(g.confidence, trigger)) continue;
    final List<OrganizeEntry> members = <OrganizeEntry>[
      for (final int i in g.members)
        if (single(i)) chunk.entries[i],
    ];
    if (members.isEmpty) continue;

    if (g.into != null) {
      OrganizeCollectionFact? target = chunk.collectionById(g.into!);
      if (target == null) continue;
      final int? winner = mergedInto[target.id];
      if (winner != null) target = byId[winner];
      if (target == null) continue;
      final List<OrganizeEntry> adds = <OrganizeEntry>[
        for (final OrganizeEntry e in members)
          if (!target.memberKeys.contains(e.memberKey)) e,
      ];
      if (adds.isEmpty) continue;
      out.addAll(_moveOut(adds, target.id, byId, g.confidence));
      out.add(
        OrganizeAction(
          kind: OrganizeActionKind.add,
          source: 'ai',
          confidence: g.confidence,
          targetCollectionId: target.id,
          organizeKey: target.organizeKey,
          entries: adds,
        ),
      );
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
      final String label = _clampName(g.name);
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
          if (!holder.memberKeys.contains(e.memberKey)) e,
      ];
      if (adds.isEmpty) continue;
      out.addAll(_moveOut(adds, holder.id, byId, g.confidence));
      out.add(
        OrganizeAction(
          kind: OrganizeActionKind.add,
          source: 'ai',
          confidence: g.confidence,
          targetCollectionId: holder.id,
          organizeKey: holder.organizeKey,
          entries: adds,
        ),
      );
      continue;
    }

    String rawName = _clampName(g.name);
    if (rawName.isEmpty) rawName = _clampName(g.originalTitle ?? '');
    if (rawName.isEmpty) continue;
    const String type = 'playlist';
    final String? name = names.allocate(rawName, type, key);
    if (name == null) continue;
    out.addAll(_moveOut(members, null, byId, g.confidence));
    out.add(
      OrganizeAction(
        kind: OrganizeActionKind.create,
        source: 'ai',
        confidence: g.confidence,
        name: name,
        collectionType: type,
        organizeKey: key,
        entries: members,
      ),
    );
  }
  return out;
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
    if (e.managedCollectionId != null || e.externalWorkKey == null) continue;
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
    final String rawName = _clampName(nameOf(members));
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

/// 组里已经在别的整理器合集里的成员：先从那里移出（整理器自己的合集才动）。
List<OrganizeAction> _moveOut(
  List<OrganizeEntry> members,
  int? targetId,
  Map<int, OrganizeCollectionFact> byId,
  AiOrganizeConfidence confidence,
) {
  final Map<int, List<OrganizeEntry>> byCollection =
      <int, List<OrganizeEntry>>{};
  for (final OrganizeEntry e in members) {
    final int? from = e.managedCollectionId;
    if (from == null || from == targetId) continue;
    if (byId[from]?.origin.isOrganizerManaged != true) continue;
    (byCollection[from] ??= <OrganizeEntry>[]).add(e);
  }
  return <OrganizeAction>[
    for (final MapEntry<int, List<OrganizeEntry>> m in byCollection.entries)
      OrganizeAction(
        kind: OrganizeActionKind.evict,
        source: 'ai',
        confidence: confidence,
        targetCollectionId: m.key,
        entries: m.value,
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

String _clampName(String raw) {
  final String t = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.runes.length <= kOrganizeMaxNameLength) return t;
  return String.fromCharCodes(t.runes.take(kOrganizeMaxNameLength)).trim();
}
