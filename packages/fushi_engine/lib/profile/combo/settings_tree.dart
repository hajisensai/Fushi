/// 「组合」模型的设置树：模块 → 子组 → 单项（叶子），每个设置键唯一归属一个叶子。
///
/// 拍板台 design-combo-node-split：Profile 不再是整包，改成「默认组合 + 只记录单独设置节点的
/// 组合」。继承 / 拆分的最小单位是**叶子节点**而不是单个键——同一叶子里的键必须一起取自
/// 同一层（例如笔记类型与字段映射：字段映射只对它那个笔记类型有意义，两者分别取自不同层
/// 会拼出无效的制卡目标）。设计见 `docs/specs/2026-11-23-combo-settings-tree-design.md`。
///
/// 这里只放与具体设置无关的通用结构（纯 Dart，app 与无头服务端共用）；Fushi 的具体节点登记
/// 在 app 的 `fushi/lib/src/profile/combo/fushi_settings_tree.dart`。
library;

/// 组合挂载的层，按**优先级从高到低**声明：作品 → 媒体类型 → 语言 → 默认。
///
/// 每个叶子各自从高往低找，取第一个单独设置了它的层；都没有就取默认组合。
enum ComboScope {
  /// 作品（`book_profiles` 绑定的组合，或作品上直接拆出的匿名组合）。
  work,

  /// 媒体类型（`media_type_profiles`）。
  mediaType,

  /// 内容语言（`language_profiles`，键经 `normalizeLanguageBinding` 归一）。
  language,

  /// 唯一的默认组合：所有叶子都有值。
  defaults;

  /// 绑定层（不含 [defaults]），按优先级从高到低。
  static const List<ComboScope> bindingLayers = <ComboScope>[
    work,
    mediaType,
    language,
  ];
}

/// 合成设置项（只存在于组合模型、存量 `profile_settings` 里没有的项，如复习库归属）的
/// category。新持久化名，进 `profile_settings` 时与存量 category 并列。
const String kComboSyntheticCategory = 'combo';

/// 一个设置项的身份：`profile_settings` 的 (category, key)。
///
/// category 沿用存量持久化名（`pref` / `anki` / `dictionary_meta` /
/// `remote_dictionary_meta` …），键名冻结不改。
class SettingKey implements Comparable<SettingKey> {
  const SettingKey(this.category, this.key);

  final String category;
  final String key;

  @override
  bool operator ==(Object other) =>
      other is SettingKey && other.category == category && other.key == key;

  @override
  int get hashCode => Object.hash(category, key);

  @override
  int compareTo(SettingKey other) {
    final int byCategory = category.compareTo(other.category);
    return byCategory != 0 ? byCategory : key.compareTo(other.key);
  }

  @override
  String toString() => '$category/$key';
}

/// 叶子认领设置键的规则。一个叶子可以有多条（不同 category 各一条）。
///
/// 判定顺序：category 不符 → 不认领；命中 [except] → 不认领；[wholeCategory] / [keys] /
/// [prefixes] / [test] 任一命中 → 认领。
class SettingKeyMatcher {
  const SettingKeyMatcher({
    required this.category,
    this.keys = const <String>{},
    this.prefixes = const <String>[],
    this.except = const <String>{},
    this.wholeCategory = false,
    this.test,
  });

  /// 整个 category 都归这个叶子（如词典启用 / 顺序的 `dictionary_meta`，一行一本词典）。
  const SettingKeyMatcher.category(this.category)
    : keys = const <String>{},
      prefixes = const <String>[],
      except = const <String>{},
      wholeCategory = true,
      test = null;

  final String category;
  final Set<String> keys;
  final List<String> prefixes;
  final Set<String> except;
  final bool wholeCategory;

  /// 键集合由别处的单一真相源判定时用（例如主题键的 `isProfileThemePrefKey`），避免抄一份
  /// 会漂移的清单。
  final bool Function(String key)? test;

  bool matches(SettingKey k) {
    if (k.category != category) return false;
    if (except.contains(k.key)) return false;
    if (wholeCategory) return true;
    if (keys.contains(k.key)) return true;
    for (final String p in prefixes) {
      if (k.key.startsWith(p)) return true;
    }
    final bool Function(String key)? t = test;
    return t != null && t(k.key);
  }
}

/// 设置树上的一个节点：子组（[children] 非空）或叶子（[matchers] / [syntheticDefaults]
/// 认领设置键）。
///
/// 节点 id 是点分路径（`mining.note_type`），子节点 id 必须以父节点 id + `.` 开头。id 是
/// 持久化名（组合里「哪些节点单独设置了」按 id 记），定下后冻结。
class SettingsNode {
  const SettingsNode.group({required this.id, required this.children})
    : matchers = const <SettingKeyMatcher>[],
      splittableAt = const <ComboScope>{},
      syntheticDefaults = const <String, String>{},
      diffable = false,
      absentKeysInherit = false;

  const SettingsNode.leaf({
    required this.id,
    this.matchers = const <SettingKeyMatcher>[],
    this.splittableAt = const <ComboScope>{
      ComboScope.work,
      ComboScope.mediaType,
      ComboScope.language,
    },
    this.syntheticDefaults = const <String, String>{},
    this.diffable = true,
    this.absentKeysInherit = false,
  }) : children = const <SettingsNode>[];

  final String id;
  final List<SettingsNode> children;
  final List<SettingKeyMatcher> matchers;

  /// 这个叶子允许在哪些绑定层单独设置（[ComboScope.defaults] 恒有值，不必列）。某层的组合
  /// 拆了一个不允许在该层拆的叶子时，解析器忽略那份拆分并在结果里报告。
  final Set<ComboScope> splittableAt;

  /// 不存在于存量 `profile_settings` 的合成设置项（category 恒为
  /// [kComboSyntheticCategory]，这里只写 key）及其默认值，例如复习库归属。默认组合缺这些键
  /// 时按这里补齐，保证「默认组合所有节点都有值」。
  final Map<String, String> syntheticDefaults;

  /// [syntheticDefaults] 的完整 [SettingKey] 形。
  Map<SettingKey, String> get syntheticSettings => <SettingKey, String>{
    for (final MapEntry<String, String> e in syntheticDefaults.entries)
      SettingKey(kComboSyntheticCategory, e.key): e.value,
  };

  /// 从存量快照迁移成差异时是否参与比较。合成节点的拆分由各自的迁移规则决定（复习库按
  /// 「哪些 Profile 有复习数据」），不由快照比较决定。
  final bool diffable;

  /// 被拆的叶子里**缺的键**怎么算：
  ///
  /// * `false`（默认）：叶子是原子的，缺 = 在这一层「未设置」（代码默认值）。对应今天
  ///   `applyProfile` 对 pref 的 prune 语义，也是笔记类型 + 字段映射这类耦合键必须的语义。
  /// * `true`：缺的键逐键继承下一层（最终落到默认组合）。用于「一行一个独立对象」的叶子，
  ///   例如词典启用 / 顺序（一行一本词典）：Profile 只拥有「怎么排、开不开」，不拥有「装了
  ///   哪些」（BUG-1994），快照里没有某本词典的行 = 那本沿用当前值，而不是「没有词典」。
  ///   迁移比较时也只看快照里有的、默认组合也有的行（默认组合没有的行 = 已不存在的对象，
  ///   不构成差异），否则每个在新词典导入前建的 Profile 都会被误判成「单独设置了词典」。
  final bool absentKeysInherit;

  bool get isLeaf => children.isEmpty;
}

/// 设置树注册表：校验结构，并把任意设置键归到唯一叶子。
class SettingsTree {
  SettingsTree({
    required List<SettingsNode> roots,
    required this.fallbackLeafId,
    bool Function(SettingKey key)? isExcluded,
  }) : roots = List<SettingsNode>.unmodifiable(roots),
       _isExcluded = isExcluded ?? _neverExcluded {
    for (final SettingsNode r in roots) {
      if (r.id.contains('.')) {
        throw ArgumentError.value(
          r.id,
          'roots',
          'root id must not contain "."',
        );
      }
      _register(r, null);
    }
    final SettingsNode? fallback = _nodes[fallbackLeafId];
    if (fallback == null || !fallback.isLeaf) {
      throw ArgumentError.value(
        fallbackLeafId,
        'fallbackLeafId',
        'must name a registered leaf',
      );
    }
    for (final SettingsNode leaf in _leaves) {
      for (final SettingKey k in leaf.syntheticSettings.keys) {
        final String? prior = _syntheticOwner[k];
        if (prior != null) {
          throw ArgumentError(
            'synthetic key $k claimed by $prior and ${leaf.id}',
          );
        }
        _syntheticOwner[k] = leaf.id;
      }
    }
  }

  static bool _neverExcluded(SettingKey key) => false;

  final List<SettingsNode> roots;

  /// 没有任何叶子认领、又不是设备本地的键归这里（「其他设置」）。新加的设置不登记也有归属，
  /// 但登记守卫测试会要求把它放到正确的叶子。
  final String fallbackLeafId;

  final bool Function(SettingKey key) _isExcluded;
  final Map<String, SettingsNode> _nodes = <String, SettingsNode>{};
  final Map<String, String?> _parents = <String, String?>{};
  final List<SettingsNode> _leaves = <SettingsNode>[];
  final Map<SettingKey, String> _syntheticOwner = <SettingKey, String>{};

  void _register(SettingsNode node, SettingsNode? parent) {
    if (node.id.isEmpty) {
      throw ArgumentError('empty node id');
    }
    if (_nodes.containsKey(node.id)) {
      throw ArgumentError('duplicate node id ${node.id}');
    }
    if (parent != null && !node.id.startsWith('${parent.id}.')) {
      throw ArgumentError('node ${node.id} must be prefixed by ${parent.id}.');
    }
    if (node.isLeaf &&
        node.matchers.isEmpty &&
        node.syntheticDefaults.isEmpty &&
        node.id != fallbackLeafId) {
      throw ArgumentError('leaf ${node.id} claims no setting keys');
    }
    if (node.isLeaf && node.splittableAt.contains(ComboScope.defaults)) {
      throw ArgumentError(
        'leaf ${node.id}: defaults is implicit, do not list it in splittableAt',
      );
    }
    _nodes[node.id] = node;
    _parents[node.id] = parent?.id;
    if (node.isLeaf) {
      _leaves.add(node);
    } else {
      for (final SettingsNode c in node.children) {
        _register(c, node);
      }
    }
  }

  /// 全部叶子（深度优先、声明顺序）。
  List<SettingsNode> get leaves => List<SettingsNode>.unmodifiable(_leaves);

  /// 按 id 取节点；不存在抛 [ArgumentError]。
  SettingsNode node(String id) {
    final SettingsNode? n = _nodes[id];
    if (n == null) throw ArgumentError.value(id, 'id', 'unknown settings node');
    return n;
  }

  bool contains(String id) => _nodes.containsKey(id);

  /// 父节点 id；根节点返回 null。
  String? parentOf(String id) {
    node(id);
    return _parents[id];
  }

  /// [id] 自身（若是叶子）或其下全部叶子。
  List<SettingsNode> leavesUnder(String id) {
    final SettingsNode n = node(id);
    if (n.isLeaf) return <SettingsNode>[n];
    return <SettingsNode>[
      for (final SettingsNode c in n.children) ...leavesUnder(c.id),
    ];
  }

  /// [key] 是否不归组合管理（设备本地 / 凭据 / 本安装状态）。
  bool isExcluded(SettingKey key) =>
      !_syntheticOwner.containsKey(key) && _isExcluded(key);

  /// 认领 [key] 的全部叶子（不含兜底）。正常树里至多一个；登记守卫测试用它查重叠。
  List<String> claimingLeaves(SettingKey key) {
    final String? synthetic = _syntheticOwner[key];
    if (synthetic != null) return <String>[synthetic];
    return <String>[
      for (final SettingsNode leaf in _leaves)
        if (leaf.matchers.any((SettingKeyMatcher m) => m.matches(key))) leaf.id,
    ];
  }

  /// [key] 归属的叶子 id；设备本地键返回 null（从不进任何组合）。没被认领的归
  /// [fallbackLeafId]。多个叶子认领时取声明顺序第一个（守卫测试会把这种情况判红）。
  String? leafOf(SettingKey key) {
    if (isExcluded(key)) return null;
    final List<String> claimed = claimingLeaves(key);
    return claimed.isEmpty ? fallbackLeafId : claimed.first;
  }
}
