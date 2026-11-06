/// 人物身份图（作品图谱 L5，spec `docs/specs/2026-10-24-cross-media-links.md` §5）：
/// 把视频（`video_metadata_people`）、游戏（VNDB 配音表）、音乐（`music_artists`）
/// 各自的人物行，按**可靠外部 id** 合并成「同一个人」。
///
/// 合并规则（所有者 2026-10-24 拍板）：
/// - 只认外部 id：AniDB creator id、MAL people id、TMDB person id、VNDB staff id、
///   MusicBrainz artist id、Wikidata 条目（经 Wikidata 桥或 VNDB 声优的外部链接得到
///   的等价关系），以及用户在人物页手动确认的「是同一人」。
/// - **名字相同绝不自动合并**，只出「可能是同一人」建议（[PersonGraph.suggestionsFor]）；
///   用户否决过的一对（墓碑）不再建议。
///
/// 节点是带前缀的字符串：外部 id `id:<scheme>:<value>`（[personIdNode]）、本地人物
/// 引用 `ref:<domain>:<key>`（[personRefNode]）。不同 scheme 的 id 分在不同命名空间，
/// 不会因为数字相同而误并（`id:anidb:167` ≠ `id:mal:167`）。
///
/// 这是 IO / 编排层的小图（几千到几万个节点，并查集线性时间），不是 CPU 热点，
/// 留在 Dart（CLAUDE.md「Rust 胖核心」只管计算型子系统）。
library;

/// 外部 id 的 scheme（落库在节点串里，冻结）。
abstract final class PersonIdScheme {
  static const String anidb = 'anidb';
  static const String mal = 'mal';
  static const String tmdb = 'tmdb';
  static const String vndb = 'vndb';
  static const String musicbrainz = 'musicbrainz';
  static const String wikidata = 'wikidata';

  static const List<String> all = <String>[
    anidb,
    mal,
    tmdb,
    vndb,
    musicbrainz,
    wikidata,
  ];
}

/// 本地人物引用的域。
enum PersonRefDomain {
  /// 视频刮削人物（键 = `video_metadata_people.person_key`）。
  video('video'),

  /// 游戏 VNDB 声优（键 = VNDB staff id `s566`）。
  game('game'),

  /// 音乐艺人（键 = `music_artists.artist_uid`）。
  music('music');

  const PersonRefDomain(this.wire);

  final String wire;

  static PersonRefDomain? tryParse(String raw) {
    for (final PersonRefDomain d in values) {
      if (d.wire == raw) return d;
    }
    return null;
  }
}

final RegExp _digits = RegExp(r'^[0-9]{1,12}$');
final RegExp _vndbStaff = RegExp(r'^s[1-9][0-9]{0,8}$');
final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final RegExp _wikidataQ = RegExp(r'^Q[1-9][0-9]{0,11}$');

/// 规范化并校验一个外部 id；不合法 / 未知 scheme 返回 null（拼进 SPARQL 前也靠它
/// 防注入）。
String? normalizePersonExternalId(String scheme, String raw) {
  final String v = raw.trim();
  switch (scheme) {
    case PersonIdScheme.anidb:
    case PersonIdScheme.mal:
    case PersonIdScheme.tmdb:
      return _digits.hasMatch(v) && v != '0' ? v : null;
    case PersonIdScheme.vndb:
      final String s = v.toLowerCase();
      final String id = _digits.hasMatch(s) ? 's$s' : s;
      return _vndbStaff.hasMatch(id) ? id : null;
    case PersonIdScheme.musicbrainz:
      final String s = v.toLowerCase();
      return _uuid.hasMatch(s) ? s : null;
    case PersonIdScheme.wikidata:
      final String s = v.toUpperCase();
      final String id = _digits.hasMatch(s) ? 'Q$s' : s;
      return _wikidataQ.hasMatch(id) ? id : null;
  }
  return null;
}

/// 外部 id 节点；不合法返回 null。
String? personIdNode(String scheme, String raw) {
  final String? v = normalizePersonExternalId(scheme, raw);
  return v == null ? null : 'id:$scheme:$v';
}

/// 视频刮削 provider 名 → 人物外部 id scheme（只收这三家，其余 provider 不参与合并）。
String? personSchemeOfVideoProvider(String provider) =>
    switch (provider.trim().toLowerCase()) {
      'anidb' => PersonIdScheme.anidb,
      'mal' => PersonIdScheme.mal,
      'tmdb' => PersonIdScheme.tmdb,
      _ => null,
    };

/// 本地人物引用节点。
String personRefNode(PersonRefDomain domain, String key) =>
    'ref:${domain.wire}:$key';

/// 拆一个节点：`(kind: 'id' | 'ref', scheme 或 domain, value)`；格式不对返回 null。
({String kind, String head, String value})? parsePersonNode(String node) {
  final int a = node.indexOf(':');
  if (a <= 0) return null;
  final int b = node.indexOf(':', a + 1);
  if (b <= a + 1 || b == node.length - 1) return null;
  final String kind = node.substring(0, a);
  if (kind != 'id' && kind != 'ref') return null;
  return (
    kind: kind,
    head: node.substring(a + 1, b),
    value: node.substring(b + 1),
  );
}

bool isPersonIdNode(String node) => node.startsWith('id:');

/// 一个本地人物行（图的原料）。
class PersonRecord {
  PersonRecord({
    required this.domain,
    required this.key,
    required this.name,
    this.originalName,
    Iterable<String> idNodes = const <String>[],
  }) : idNodes = Set<String>.unmodifiable(idNodes);

  final PersonRefDomain domain;
  final String key;

  /// 显示名（多为罗马音 / 源显示名）。
  final String name;

  /// 原文名（日文汉字等）；没有为 null。
  final String? originalName;

  /// 这个人物行自带的外部 id 节点。
  final Set<String> idNodes;

  String get node => personRefNode(domain, key);
}

/// 「同一个人」的一组本地人物行。
class PersonCluster {
  PersonCluster({
    required this.root,
    required List<PersonRecord> records,
    required Set<String> idNodes,
  }) : records = List<PersonRecord>.unmodifiable(records),
       idNodes = Set<String>.unmodifiable(idNodes);

  /// 并查集代表元（同一张图内稳定，跨图重建不保证）。
  final String root;
  final List<PersonRecord> records;

  /// 合并后已知的全部外部 id 节点（含经桥得到的）。
  final Set<String> idNodes;

  Iterable<PersonRecord> inDomain(PersonRefDomain d) =>
      records.where((PersonRecord r) => r.domain == d);

  /// 显示名：优先原文名（游戏 / 音乐常给日文写法），再退到显示名；各域按
  /// 游戏 → 视频 → 音乐取第一个非空。
  String get displayName {
    for (final PersonRefDomain d in const <PersonRefDomain>[
      PersonRefDomain.game,
      PersonRefDomain.video,
      PersonRefDomain.music,
    ]) {
      for (final PersonRecord r in inDomain(d)) {
        final String? o = r.originalName?.trim();
        if (o != null && o.isNotEmpty) return o;
      }
    }
    for (final PersonRecord r in records) {
      if (r.name.trim().isNotEmpty) return r.name.trim();
    }
    return '';
  }

  /// 除 [displayName] 外的其它写法（去重）。
  List<String> get otherNames {
    final String main = displayName;
    final Set<String> seen = <String>{main};
    final List<String> out = <String>[];
    for (final PersonRecord r in records) {
      for (final String? n in <String?>[r.name, r.originalName]) {
        final String? v = n?.trim();
        if (v == null || v.isEmpty || !seen.add(v)) continue;
        out.add(v);
      }
    }
    return out;
  }

  /// 某 scheme 的外部 id 值（去前缀）。
  List<String> idsOf(String scheme) => <String>[
    for (final String n in idNodes)
      if (parsePersonNode(n) case (
        kind: 'id',
        head: final String h,
        value: final String v,
      ) when h == scheme)
        v,
  ]..sort();
}

/// 「可能是同一人」建议：[other] 与当前人物名字相同但没有共享外部 id。
class PersonSuggestion {
  const PersonSuggestion({required this.other, required this.matchedName});

  final PersonCluster other;

  /// 撞上的那个写法（展示用）。
  final String matchedName;
}

/// 名字归一的比较键：去空白 / 中点 / 连字符，全角拉丁转半角，小写；纯拉丁且多段
/// 时再加一把「段排序」键（`Kasahara Hiroko` 与 `Hiroko Kasahara` 撞上）。
/// 不足两个字符的名字不产生键（单字名撞车太多，建议没有意义）。
Set<String> personNameKeys(String raw) {
  final StringBuffer half = StringBuffer();
  for (final int rune in raw.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      half.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      half.write(' ');
    } else {
      half.writeCharCode(rune);
    }
  }
  final String lower = half.toString().toLowerCase().trim();
  final List<String> tokens = lower
      .split(RegExp(r'[\s・･·.\-_,]+'))
      .where((String s) => s.isNotEmpty)
      .toList();
  final String compact = tokens.join();
  if (compact.runes.length < 2) return const <String>{};
  final Set<String> keys = <String>{compact};
  if (tokens.length > 1 && RegExp(r'^[a-z]+$').hasMatch(compact)) {
    keys.add((List<String>.of(tokens)..sort()).join());
  }
  return keys;
}

/// 人物身份图：并查集 + 名字索引。一次构建、多次查询（人物页每次打开重建一次）。
class PersonGraph {
  PersonGraph._(this._parent, this._records, this._nameIndex, this._rejected);

  /// [sameAs]：等价边（Wikidata 桥、用户确认的同一人；端点可以是 id 节点也可以是
  /// ref 节点）。[rejected]：用户否决过的一对节点（只影响建议，不拆外部 id 合并）。
  factory PersonGraph.build({
    required Iterable<PersonRecord> records,
    Iterable<(String, String)> sameAs = const <(String, String)>[],
    Iterable<(String, String)> rejected = const <(String, String)>[],
  }) {
    final Map<String, String> parent = <String, String>{};
    final Map<String, PersonRecord> byNode = <String, PersonRecord>{};
    String find(String x) {
      String r = parent.putIfAbsent(x, () => x);
      while (r != parent[r]) {
        r = parent[r]!;
      }
      // 路径压缩。
      String c = x;
      while (parent[c] != r) {
        final String next = parent[c]!;
        parent[c] = r;
        c = next;
      }
      return r;
    }

    void union(String a, String b) {
      final String ra = find(a);
      final String rb = find(b);
      if (ra == rb) return;
      // 让字典序小的当代表元：同一组输入建出的图代表元稳定（测试可断言）。
      if (ra.compareTo(rb) < 0) {
        parent[rb] = ra;
      } else {
        parent[ra] = rb;
      }
    }

    for (final PersonRecord r in records) {
      byNode[r.node] = r;
      find(r.node);
      for (final String id in r.idNodes) {
        union(r.node, id);
      }
    }
    for (final (String a, String b) in sameAs) {
      union(a, b);
    }
    final Map<String, Set<String>> nameIndex = <String, Set<String>>{};
    for (final PersonRecord r in byNode.values) {
      for (final String? n in <String?>[r.name, r.originalName]) {
        if (n == null) continue;
        for (final String k in personNameKeys(n)) {
          nameIndex.putIfAbsent(k, () => <String>{}).add(r.node);
        }
      }
    }
    // 把 find 的结果冻结成扁平映射，查询期不再改结构。
    final Map<String, String> flat = <String, String>{
      for (final String n in parent.keys.toList()) n: find(n),
    };
    return PersonGraph._(
      flat,
      byNode,
      nameIndex,
      List<(String, String)>.unmodifiable(rejected),
    );
  }

  final Map<String, String> _parent;
  final Map<String, PersonRecord> _records;
  final Map<String, Set<String>> _nameIndex;
  final List<(String, String)> _rejected;

  String? _rootOf(String node) => _parent[node];

  /// 某个本地人物（ref 节点）所在的人；图里没有这个节点返回 null。
  PersonCluster? clusterOf(String refNode) {
    final String? root = _rootOf(refNode);
    if (root == null || !_records.containsKey(refNode)) return null;
    return _clusterByRoot(root);
  }

  /// 图里的全部人（每个至少含一条本地人物记录；纯外部 id 的连通块不算），按根节点
  /// 排序。人物列表（控制通道 / AI 助手）用。
  List<PersonCluster> get clusters {
    final Set<String> roots = <String>{
      for (final String node in _records.keys) ?_rootOf(node),
    };
    return <PersonCluster>[
      for (final String root in roots.toList()..sort()) _clusterByRoot(root),
    ];
  }

  PersonCluster _clusterByRoot(String root) {
    final List<PersonRecord> records = <PersonRecord>[];
    final Set<String> ids = <String>{};
    for (final MapEntry<String, String> e in _parent.entries) {
      if (e.value != root) continue;
      final PersonRecord? r = _records[e.key];
      if (r != null) {
        records.add(r);
      } else if (isPersonIdNode(e.key)) {
        ids.add(e.key);
      }
    }
    records.sort((PersonRecord a, PersonRecord b) => a.node.compareTo(b.node));
    return PersonCluster(root: root, records: records, idNodes: ids);
  }

  /// 两个人之间有没有否决墓碑。
  bool _isRejected(String rootA, String rootB) {
    for (final (String x, String y) in _rejected) {
      final String? rx = _rootOf(x);
      final String? ry = _rootOf(y);
      if ((rx == rootA && ry == rootB) || (rx == rootB && ry == rootA)) {
        return true;
      }
    }
    return false;
  }

  /// 名字相同、但没有共享外部 id 的其他人（建议，绝不自动合并）。
  List<PersonSuggestion> suggestionsFor(
    PersonCluster cluster, {
    int limit = 8,
  }) {
    final Map<String, String> matched = <String, String>{};
    for (final PersonRecord r in cluster.records) {
      for (final String? n in <String?>[r.originalName, r.name]) {
        if (n == null) continue;
        for (final String k in personNameKeys(n)) {
          for (final String other in _nameIndex[k] ?? const <String>{}) {
            final String? root = _rootOf(other);
            if (root == null || root == cluster.root) continue;
            matched.putIfAbsent(root, () => n.trim());
          }
        }
      }
    }
    final List<PersonSuggestion> out = <PersonSuggestion>[];
    final List<String> roots = matched.keys.toList()..sort();
    for (final String root in roots) {
      if (_isRejected(cluster.root, root)) continue;
      out.add(
        PersonSuggestion(
          other: _clusterByRoot(root),
          matchedName: matched[root]!,
        ),
      );
      if (out.length >= limit) break;
    }
    return out;
  }
}
