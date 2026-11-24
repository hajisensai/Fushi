/// 组合在出境载荷里的形态（拍板台 design-combo-node-split 阶段 6，设计 §4.4；纯函数，无 I/O）：
///
/// * **分享 JSON v2**（`profile_document.dart`，也是互联 `/api/interconnect/profile` 的载荷）：带
///   「生效值全量 + 单独设置了哪些叶子」。生效值全量让别的设备 / 旧数据照样能当整份快照用；叶子
///   列表让导入方知道哪些叶子是对方**有意**单独设置的——与本机默认碰巧相同也保持拆分（与
///   [rebaseComboDocument] 对「单独设置是用户的选择」同一口径）。导入为新组合时按本机默认组合
///   重新 diff。
/// * **备份合并**（`backup_merge_engine.dart` 的 Profile 部分）：同名 Profile 的行怎么合、对端的
///   默认组合怎么降级。
///
/// 复习库归属（`srs.library`，合成叶子）是本机复习数据的安排，不出本机、也不从对端带进来；
/// 备份合并里只有「对端默认组合自己承载着它的共享库」这一种情形会落成独立库（那份复习数据由
/// 备份的复习部分按 uid 落到这份配置上，见 `srs_backup_merge.dart`）。
library;

import 'package:fushi_engine/profile/combo/combo_migration.dart'
    show
        kComboSrsLibraryLeafId,
        kComboSrsLibraryOwnValue,
        kComboSrsLibrarySettingKey;
import 'package:fushi_engine/profile/combo/combo_resolver.dart';
import 'package:fushi_engine/profile/combo/combo_rows.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';

/// 分享载荷里要列出的「单独设置的叶子」：[document] 里拆了的、可比较的叶子（合成叶子如复习库
/// 归属是本机安排，不出本机），按树的声明顺序。
List<String> sharedSplitNodesOf(SettingsTree tree, ComboDocument document) =>
    <String>[
      for (final SettingsNode leaf in tree.leaves)
        if (leaf.diffable && document.isSplit(leaf.id)) leaf.id,
    ];

/// 把分享载荷落成本机的组合差异：[values] 是对方的生效值全量，[splitNodes] 是对方单独设置的
/// 叶子（v1 文件为空）。结果 = 与本机默认组合 [localDefaults] 不同的叶子 ∪ 对方单独设置的叶子，
/// 被拆叶子取 [values] 里那组键。树上不认识的叶子（更新版本加的）与合成叶子忽略。
ComboDocument comboDocumentFromShared({
  required SettingsTree tree,
  required Map<SettingKey, String> localDefaults,
  required Map<SettingKey, String> values,
  Iterable<String> splitNodes = const <String>[],
}) {
  final Map<String, Map<SettingKey, String>> grouped = groupByLeaf(
    tree,
    values,
  );
  final ComboDocument declared = ComboDocument(
    <String, Map<SettingKey, String>>{
      for (final String id in splitNodes)
        if (tree.contains(id) && tree.node(id).isLeaf && tree.node(id).diffable)
          id: grouped[id] ?? const <SettingKey, String>{},
    },
  );
  return rebaseComboDocument(
    tree: tree,
    existing: declared,
    base: localDefaults,
    effective: values,
  );
}

const SettingKey _roleKey = SettingKey(kComboSyntheticCategory, kComboRoleKey);
const SettingKey _sharedUidKey = SettingKey(
  kComboSyntheticCategory,
  kComboSrsSharedUidKey,
);
const SettingKey _srsLibraryKey = SettingKey(
  kComboSyntheticCategory,
  kComboSrsLibrarySettingKey,
);

/// 备份合并时一份对端 Profile 的行落到本机后应是什么（全量替换本机那份的行）。
///
/// * [local]：本机同名 Profile 合并前的行；null = 本机没有同名的（这份是新插入的）。
/// * [incoming]：对端那份的行。[incomingUid] 是它在对端的 uid（判「对端默认组合是否自己承载
///   着共享库」用）。
/// * [localDefaultValues]：本机默认组合的全量设置值；null = 本机还不是组合格式（迁移前）。
///
/// 规则（设计 §4.4）：
///
/// * 本机还不是组合格式：照旧「本机有的键保留、缺的键从对端补」，但对端的 `role = default`
///   与共享库指针不带进来——否则下一次归一会在两份默认里挑中对端那份。
/// * 对端是默认组合 / 存量整份快照：先按本机默认组合 diff 成差异（降级成普通组合）。对端默认
///   组合自己承载着它的共享库时拆成独立复习库（那份复习数据随备份按 uid 落到这份配置上）。
/// * 本机没有同名 Profile：落成上面的差异（对端本来就是组合格式的照原样，角色不变）。
/// * 本机同名的是默认组合：本机的行原样保留（本机默认保持默认，值以本机为准）。
/// * 本机同名的是组合：单独设置的叶子取并集；两边都拆了的叶子整组取本机那份（叶子是原子的，
///   不逐键混拼；行没有时间戳，「以本机为准」就是现有的合并口径）；复习库归属只看本机。
/// * 任一边是不认识的角色（更新版本写的）：本机有就原样保留，本机没有就照对端原样落。
///
/// 返回 null = 本机那份不用改。
Map<SettingKey, String>? mergeComboProfileRows({
  required SettingsTree tree,
  required Map<SettingKey, String>? local,
  required Map<SettingKey, String> incoming,
  required String? incomingUid,
  required Map<SettingKey, String>? localDefaultValues,
}) {
  final DecodedComboRows theirs = decodeComboRows(tree, incoming);
  final bool theirsForeign =
      incoming.containsKey(_roleKey) && theirs.role == null;

  if (localDefaultValues == null) {
    // 本机迁移前：旧口径（键级「本机为准、缺的补」），对端的组合格式身份行不带进来。
    final Map<SettingKey, String> carried = <SettingKey, String>{
      for (final MapEntry<SettingKey, String> e in incoming.entries)
        if (!(e.key == _sharedUidKey ||
            e.key == _roleKey && e.value == ComboRole.defaults.wire))
          e.key: e.value,
    };
    if (local == null) return carried;
    final Map<SettingKey, String> merged = <SettingKey, String>{
      ...carried,
      ...local,
    };
    return merged.length == local.length ? null : merged;
  }

  if (theirsForeign) return local == null ? incoming : null;

  // 对端的差异文档（相对本机默认组合）与角色。
  final ComboDocument theirDoc;
  final ComboRole theirRole;
  final ComboRole? incomingRole = theirs.role;
  if (incomingRole != null && incomingRole != ComboRole.defaults) {
    theirDoc = theirs.document;
    theirRole = incomingRole;
  } else {
    ComboDocument doc = diffAgainstDefaults(
      tree: tree,
      defaults: localDefaultValues,
      snapshot: theirs.values,
    );
    final String? theirShared = theirs.srsSharedUid;
    if (theirs.role == ComboRole.defaults &&
        incomingUid != null &&
        theirShared == incomingUid) {
      doc = ComboDocument(<String, Map<SettingKey, String>>{
        ...doc.splits,
        kComboSrsLibraryLeafId: <SettingKey, String>{
          _srsLibraryKey: kComboSrsLibraryOwnValue,
        },
      });
    }
    theirDoc = doc;
    theirRole = ComboRole.named;
  }

  if (local == null) return encodeComboRows(tree, theirDoc, role: theirRole);

  final DecodedComboRows mine = decodeComboRows(tree, local);
  final bool mineForeign = local.containsKey(_roleKey) && mine.role == null;
  if (mineForeign || mine.role == ComboRole.defaults) return null;
  if (mine.role == null) {
    // 本机这份还是存量整份快照（组合格式的库里不该有，下一次归一会处理）：旧口径补缺的键，
    // 只补对端可比较叶子的值，不带组合格式元数据。
    final Map<SettingKey, String> merged = <SettingKey, String>{
      for (final MapEntry<String, Map<SettingKey, String>> leaf
          in theirDoc.splits.entries)
        if (leaf.key != kComboSrsLibraryLeafId) ...leaf.value,
      ...local,
    };
    return merged.length == local.length ? null : merged;
  }

  final Map<String, Map<SettingKey, String>> splits =
      Map<String, Map<SettingKey, String>>.of(mine.document.splits);
  bool changed = false;
  for (final MapEntry<String, Map<SettingKey, String>> e
      in theirDoc.splits.entries) {
    if (e.key == kComboSrsLibraryLeafId) continue;
    if (splits.containsKey(e.key)) continue;
    splits[e.key] = e.value;
    changed = true;
  }
  if (!changed) return null;
  return encodeComboRows(tree, ComboDocument(splits), role: mine.role!);
}
