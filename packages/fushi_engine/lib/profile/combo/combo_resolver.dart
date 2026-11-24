/// 「组合」的继承解析与编辑运算（纯函数，无 I/O）。
///
/// * 默认组合：所有叶子都有值（`Map<SettingKey, String>` 全量）。
/// * 其他组合（[ComboDocument]）：只记录**单独设置的叶子**，每个被拆的叶子带它那组键的完整
///   值；不在其中的键 = 该叶子在这一层「未设置」，按代码默认值（与今天 `applyProfile` 对
///   「快照里没有的键」删掉活偏好的语义一致）。例外是 [SettingsNode.absentKeysInherit] 的
///   叶子（一行一个独立对象，如词典）：缺的键逐键继承下一层。
/// * 解析（[resolveCombos]）：每个叶子按 作品 → 媒体类型 → 语言 → 默认 各自往下找，取第一个
///   单独设置了它、且该叶子允许在那层拆分的层。
///
/// 设计见 `docs/specs/2026-11-23-combo-settings-tree-design.md`。
library;

import 'package:fushi_engine/profile/combo/settings_tree.dart';

/// 一个非默认组合：被单独设置的叶子 → 该叶子的完整键值。
class ComboDocument {
  ComboDocument([Map<String, Map<SettingKey, String>>? splits])
    : splits = Map<String, Map<SettingKey, String>>.unmodifiable(
        <String, Map<SettingKey, String>>{
          for (final MapEntry<String, Map<SettingKey, String>> e
              in (splits ?? const <String, Map<SettingKey, String>>{}).entries)
            e.key: Map<SettingKey, String>.unmodifiable(e.value),
        },
      );

  /// 什么都没拆的组合（全部继承）。
  static final ComboDocument empty = ComboDocument();

  final Map<String, Map<SettingKey, String>> splits;

  bool isSplit(String leafId) => splits.containsKey(leafId);

  Set<String> get splitLeafIds => splits.keys.toSet();
}

/// 挂在某个绑定层上的组合。
class ComboLayer {
  const ComboLayer({
    required this.scope,
    required this.comboRef,
    required this.document,
  });

  /// 挂载层；不能是 [ComboScope.defaults]。
  final ComboScope scope;

  /// 组合的身份（`profiles.uid`，作品上直接拆出的匿名组合也有 uid），用于「生效值表」写明
  /// 值来自哪个组合。
  final String comboRef;

  final ComboDocument document;
}

/// 一个叶子的生效值来自哪里。
class ComboSource {
  const ComboSource(this.scope, this.comboRef);

  /// 默认组合。
  const ComboSource.defaults() : scope = ComboScope.defaults, comboRef = null;

  final ComboScope scope;

  /// 来源组合；默认组合为 null。
  final String? comboRef;

  @override
  bool operator ==(Object other) =>
      other is ComboSource &&
      other.scope == scope &&
      other.comboRef == comboRef;

  @override
  int get hashCode => Object.hash(scope, comboRef);

  @override
  String toString() =>
      comboRef == null ? scope.name : '${scope.name}($comboRef)';
}

/// 某层组合拆了一个不允许在该层拆分的叶子：解析时被忽略。
class IgnoredSplit {
  const IgnoredSplit({
    required this.leafId,
    required this.scope,
    required this.comboRef,
  });

  final String leafId;
  final ComboScope scope;
  final String comboRef;

  @override
  bool operator ==(Object other) =>
      other is IgnoredSplit &&
      other.leafId == leafId &&
      other.scope == scope &&
      other.comboRef == comboRef;

  @override
  int get hashCode => Object.hash(leafId, scope, comboRef);

  @override
  String toString() => 'IgnoredSplit($leafId @ ${scope.name}($comboRef))';
}

/// 解析结果：最终生效值 + 每个叶子的来源（「最终生效值」表的数据）。
class ResolvedSettings {
  ResolvedSettings._({
    required Map<SettingKey, String> values,
    required Map<String, ComboSource> sources,
    required List<IgnoredSplit> ignoredSplits,
  }) : values = Map<SettingKey, String>.unmodifiable(values),
       sources = Map<String, ComboSource>.unmodifiable(sources),
       ignoredSplits = List<IgnoredSplit>.unmodifiable(ignoredSplits);

  /// 全部生效键值（只含组合管理的键；缺失 = 该键未设置，用代码默认值）。
  final Map<SettingKey, String> values;

  /// 叶子 id → 来源；覆盖树上每个叶子。
  final Map<String, ComboSource> sources;

  /// 被忽略的越层拆分（编辑界面据此提示「这一层不能单独设置这一项」）。
  final List<IgnoredSplit> ignoredSplits;

  String? valueOf(SettingKey key) => values[key];

  ComboSource sourceOf(String leafId) {
    final ComboSource? s = sources[leafId];
    if (s == null) {
      throw ArgumentError.value(leafId, 'leafId', 'not a leaf of this tree');
    }
    return s;
  }

  /// 叶子 [leafId] 那组键的生效值。
  Map<SettingKey, String> leafValues(SettingsTree tree, String leafId) =>
      <SettingKey, String>{
        for (final MapEntry<SettingKey, String> e in values.entries)
          if (tree.leafOf(e.key) == leafId) e.key: e.value,
      };
}

/// 把全量设置 [values] 按叶子分组；设备本地键丢弃。
Map<String, Map<SettingKey, String>> groupByLeaf(
  SettingsTree tree,
  Map<SettingKey, String> values,
) {
  final Map<String, Map<SettingKey, String>> out =
      <String, Map<SettingKey, String>>{};
  for (final MapEntry<SettingKey, String> e in values.entries) {
    final String? leaf = tree.leafOf(e.key);
    if (leaf == null) continue;
    (out[leaf] ??= <SettingKey, String>{})[e.key] = e.value;
  }
  return out;
}

/// 默认组合按叶子分组，并补齐合成节点的默认值（「默认组合所有节点都有值」）。
Map<String, Map<SettingKey, String>> _defaultsByLeaf(
  SettingsTree tree,
  Map<SettingKey, String> defaults,
) {
  final Map<String, Map<SettingKey, String>> grouped = groupByLeaf(
    tree,
    defaults,
  );
  for (final SettingsNode leaf in tree.leaves) {
    for (final MapEntry<SettingKey, String> s
        in leaf.syntheticSettings.entries) {
      final Map<SettingKey, String> bucket = grouped[leaf.id] ??=
          <SettingKey, String>{};
      bucket.putIfAbsent(s.key, () => s.value);
    }
  }
  return grouped;
}

/// 按 作品 → 媒体类型 → 语言 → 默认 解析 [layers]。
///
/// [layers] 顺序无关（按 [ComboScope] 排），每个绑定层至多一个；传入
/// [ComboScope.defaults] 层或同层两个都抛 [ArgumentError]——同层冲突必须在调用方（绑定表
/// 主键）就排除，解析器不替调用方挑。
ResolvedSettings resolveCombos({
  required SettingsTree tree,
  required Map<SettingKey, String> defaults,
  List<ComboLayer> layers = const <ComboLayer>[],
}) {
  final Map<ComboScope, ComboLayer> byScope = <ComboScope, ComboLayer>{};
  for (final ComboLayer l in layers) {
    if (l.scope == ComboScope.defaults) {
      throw ArgumentError('defaults is not a binding layer');
    }
    if (byScope.containsKey(l.scope)) {
      throw ArgumentError('two combos on layer ${l.scope.name}');
    }
    byScope[l.scope] = l;
  }
  for (final ComboLayer l in layers) {
    for (final String leafId in l.document.splits.keys) {
      if (!tree.contains(leafId) || !tree.node(leafId).isLeaf) {
        throw ArgumentError('combo ${l.comboRef} splits unknown leaf $leafId');
      }
    }
  }

  final Map<String, Map<SettingKey, String>> defaultLeaves = _defaultsByLeaf(
    tree,
    defaults,
  );
  final Map<SettingKey, String> values = <SettingKey, String>{};
  final Map<String, ComboSource> sources = <String, ComboSource>{};
  final List<IgnoredSplit> ignored = <IgnoredSplit>[];

  for (final SettingsNode leaf in tree.leaves) {
    // 生效的拆分，按优先级从高到低。
    final List<(ComboLayer, Map<SettingKey, String>)> applied =
        <(ComboLayer, Map<SettingKey, String>)>[];
    for (final ComboScope scope in ComboScope.bindingLayers) {
      final ComboLayer? layer = byScope[scope];
      if (layer == null) continue;
      final Map<SettingKey, String>? split = layer.document.splits[leaf.id];
      if (split == null) continue;
      if (!leaf.splittableAt.contains(scope)) {
        ignored.add(
          IgnoredSplit(leafId: leaf.id, scope: scope, comboRef: layer.comboRef),
        );
        continue;
      }
      applied.add((layer, split));
    }
    final Map<SettingKey, String> leafValues;
    if (applied.isEmpty) {
      sources[leaf.id] = const ComboSource.defaults();
      leafValues = defaultLeaves[leaf.id] ?? const <SettingKey, String>{};
    } else {
      final ComboLayer top = applied.first.$1;
      sources[leaf.id] = ComboSource(top.scope, top.comboRef);
      if (leaf.absentKeysInherit) {
        // 逐键继承：从默认往上叠，高层的行盖低层的行。
        leafValues = <SettingKey, String>{
          ...?defaultLeaves[leaf.id],
          for (final (ComboLayer, Map<SettingKey, String>) a
              in applied.reversed)
            ...a.$2,
        };
      } else {
        leafValues = applied.first.$2;
      }
    }
    for (final MapEntry<SettingKey, String> e in leafValues.entries) {
      // 组合里只该有归这个叶子的键；混进来的别家键（坏数据）不让它越界覆盖别的叶子。
      if (tree.leafOf(e.key) == leaf.id) values[e.key] = e.value;
    }
  }

  return ResolvedSettings._(
    values: values,
    sources: sources,
    ignoredSplits: ignored,
  );
}

/// 把 [nodeId]（叶子或子组）在 [document] 上拆出来：其下每个还没拆的叶子复制 [effective]
/// 里的当前生效值。已经拆了的叶子保持不动。
///
/// 只拆 [scope] 允许拆分的叶子；子组下有不允许的叶子时跳过它们（组的拆分 = 能拆的全拆）。
/// [nodeId] 本身是不允许在 [scope] 拆分的叶子时抛 [ArgumentError]。
ComboDocument splitNode({
  required SettingsTree tree,
  required ComboDocument document,
  required String nodeId,
  required ComboScope scope,
  required ResolvedSettings effective,
}) {
  final SettingsNode node = tree.node(nodeId);
  if (node.isLeaf && !node.splittableAt.contains(scope)) {
    throw ArgumentError('leaf $nodeId cannot be split at ${scope.name}');
  }
  final Map<String, Map<SettingKey, String>> next =
      Map<String, Map<SettingKey, String>>.of(document.splits);
  for (final SettingsNode leaf in tree.leavesUnder(nodeId)) {
    if (!leaf.splittableAt.contains(scope)) continue;
    next.putIfAbsent(leaf.id, () => effective.leafValues(tree, leaf.id));
  }
  return ComboDocument(next);
}

/// 「恢复继承」：撤掉 [nodeId]（叶子或子组）下全部叶子的拆分。
ComboDocument restoreInheritance({
  required SettingsTree tree,
  required ComboDocument document,
  required String nodeId,
}) {
  final Set<String> drop = <String>{
    for (final SettingsNode l in tree.leavesUnder(nodeId)) l.id,
  };
  return ComboDocument(<String, Map<SettingKey, String>>{
    for (final MapEntry<String, Map<SettingKey, String>> e
        in document.splits.entries)
      if (!drop.contains(e.key)) e.key: e.value,
  });
}

/// 在 [document] 这一层写一个设置：所属叶子还在继承时先自动拆出来（复制 [effective] 的
/// 当前值），再写 [key]。[value] 为 null = 在这一层把它设为「未设置」（代码默认值）。
///
/// [key] 是设备本地键（不归组合管理）时抛 [ArgumentError]：那类键直接写活偏好，绝不进组合。
ComboDocument writeSetting({
  required SettingsTree tree,
  required ComboDocument document,
  required ComboScope scope,
  required SettingKey key,
  required String? value,
  required ResolvedSettings effective,
}) {
  final String? leafId = tree.leafOf(key);
  if (leafId == null) {
    throw ArgumentError.value(
      key,
      'key',
      'device-local key is not combo-managed',
    );
  }
  final ComboDocument split = splitNode(
    tree: tree,
    document: document,
    nodeId: leafId,
    scope: scope,
    effective: effective,
  );
  final Map<SettingKey, String> leaf = Map<SettingKey, String>.of(
    split.splits[leafId]!,
  );
  if (value == null) {
    leaf.remove(key);
  } else {
    leaf[key] = value;
  }
  return ComboDocument(<String, Map<SettingKey, String>>{
    ...split.splits,
    leafId: leaf,
  });
}

/// 迁移用：把一个存量 Profile 的全量快照 [snapshot] 化成「相对默认组合 [defaults] 的差异」。
///
/// 比较以叶子为单位：叶子那组键（含「快照里没有」= 未设置）与默认组合完全相同就继承，否则
/// 整个叶子拆出来、带快照里的完整值。[SettingsNode.absentKeysInherit] 的叶子只看快照里有的
/// 行：快照缺行 = 沿用（不构成差异）；与默认组合不同、或默认组合此刻没有的行构成差异——后者
/// 是快照对一个此刻不在的对象的选择（服务器词典目录还没拉到、词典以后会重装），丢掉它就丢了
/// 那份选择（BUG-4693：目录拉到时按激活配置那份对账）。合成
/// 节点（`diffable: false`）不参与比较，由各自的迁移规则决定要不要拆。设备本地键两边都丢弃。
ComboDocument diffAgainstDefaults({
  required SettingsTree tree,
  required Map<SettingKey, String> defaults,
  required Map<SettingKey, String> snapshot,
}) {
  final Map<String, Map<SettingKey, String>> base = groupByLeaf(tree, defaults);
  final Map<String, Map<SettingKey, String>> mine = groupByLeaf(tree, snapshot);
  final Map<String, Map<SettingKey, String>> splits =
      <String, Map<SettingKey, String>>{};
  for (final SettingsNode leaf in tree.leaves) {
    if (!leaf.diffable) continue;
    final Map<SettingKey, String> a =
        base[leaf.id] ?? const <SettingKey, String>{};
    final Map<SettingKey, String> b =
        mine[leaf.id] ?? const <SettingKey, String>{};
    final bool differs = leaf.absentKeysInherit
        ? _snapshotRowsDiffer(a, b)
        : !_sameValues(a, b);
    if (differs) splits[leaf.id] = b;
  }
  return ComboDocument(splits);
}

/// 把一个组合重新落到默认组合 [base] 之上，使它的生效值是 [effective]：
///
/// * 原来就拆了的叶子（[existing]）保持拆分——「单独设置」是用户的选择，值与默认碰巧相同也不
///   自动恢复继承（恢复继承要显式操作）；
/// * [effective] 与 [base] 不同的叶子（[diffAgainstDefaults] 的口径）拆出来；
/// * 被拆的可比较叶子取 [effective] 里那组键；合成叶子（`diffable: false`，如复习库归属）
///   沿用 [existing] 的值（[effective] 来自活偏好时没有它们）。
///
/// 用途：组合格式的激活配置切走时把活偏好写回它自己（`snapshotCurrentSettings`），以及默认
/// 组合换人时把其余组合改基到新默认（生效值不变）。
ComboDocument rebaseComboDocument({
  required SettingsTree tree,
  required ComboDocument existing,
  required Map<SettingKey, String> base,
  required Map<SettingKey, String> effective,
}) {
  final ComboDocument diff = diffAgainstDefaults(
    tree: tree,
    defaults: base,
    snapshot: effective,
  );
  final Map<String, Map<SettingKey, String>> grouped = groupByLeaf(
    tree,
    effective,
  );
  final Map<String, Map<SettingKey, String>> splits =
      <String, Map<SettingKey, String>>{};
  for (final SettingsNode leaf in tree.leaves) {
    if (!existing.isSplit(leaf.id) && !diff.isSplit(leaf.id)) continue;
    splits[leaf.id] = leaf.diffable
        ? grouped[leaf.id] ?? const <SettingKey, String>{}
        : existing.splits[leaf.id]!;
  }
  return ComboDocument(splits);
}

bool _snapshotRowsDiffer(Map<SettingKey, String> a, Map<SettingKey, String> b) {
  for (final MapEntry<SettingKey, String> e in b.entries) {
    if (a[e.key] != e.value) return true;
  }
  return false;
}

bool _sameValues(Map<SettingKey, String> a, Map<SettingKey, String> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<SettingKey, String> e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}
