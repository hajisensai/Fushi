/// 「组合」在 `profile_settings` 里的行格式（编解码，纯函数，无 I/O）。
///
/// 持久化名（新增、冻结）全在 [kComboSyntheticCategory] 这个 category 下：
///
/// * `role`：[ComboRole.wire]。**有这一行 = 这份 Profile 已是组合格式**；没有 = 存量整份
///   快照（迁移前的格式，阶段 3 一次性改写）。
/// * `split:<叶子 id>` = `1`：这个组合单独设置了该叶子（区分「拆了但叶子里的键都未设置」
///   与「继承」）。默认组合不写（所有叶子都有值）。
/// * `srs_shared_uid`（只在默认组合上）：共享复习库的集合 uid。
/// * 其余 key 是合成设置项的值（如 `srs_library`），归各自的叶子。
///
/// 非默认组合只保留被拆叶子的行 + 上述 `combo` 行。设计见
/// `docs/specs/2026-11-23-combo-settings-tree-design.md` §3.1。
library;

import 'package:fushi_engine/profile/combo/combo_resolver.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';

/// 组合格式标记行的 key（category [kComboSyntheticCategory]）。
const String kComboRoleKey = 'role';

/// 「单独设置了某叶子」标记行的 key 前缀；完整 key = 前缀 + 叶子 id。
const String kComboSplitKeyPrefix = 'split:';

/// 默认组合上记共享复习库集合 uid 的 key。
const String kComboSrsSharedUidKey = 'srs_shared_uid';

/// [key]（category [kComboSyntheticCategory] 下）是不是格式元数据而非设置值。
bool isComboMetadataKey(String key) =>
    key == kComboRoleKey ||
    key == kComboSrsSharedUidKey ||
    key.startsWith(kComboSplitKeyPrefix);

/// 组合的角色（`combo/role` 的值，持久化名冻结）。
enum ComboRole {
  /// 唯一的默认组合：所有叶子都有值，行是全量。
  defaults('default'),

  /// 用户建的普通组合（配置列表里列出）。
  named('named'),

  /// 作品上直接拆出的匿名组合（配置列表不列出）。
  workLocal('work_local');

  const ComboRole(this.wire);

  final String wire;

  /// 未知值（更新版本写的新角色）返回 null，调用方按「不认识的格式」处理。
  static ComboRole? fromWire(String? wire) {
    for (final ComboRole r in values) {
      if (r.wire == wire) return r;
    }
    return null;
  }
}

/// 一份 Profile 的 `profile_settings` 行解出来的结果。
class DecodedComboRows {
  const DecodedComboRows({
    required this.role,
    required this.document,
    required this.values,
    this.srsSharedUid,
  });

  /// null = 存量整份快照（没有 `combo/role` 行），或角色值不认识。
  final ComboRole? role;

  /// 组合格式下被拆叶子的值；默认组合与存量快照为 [ComboDocument.empty]。
  final ComboDocument document;

  /// 全部设置值（去掉格式元数据行）。默认组合 / 存量快照的「全量值」就是它。
  final Map<SettingKey, String> values;

  final String? srsSharedUid;

  bool get isComboFormat => role != null;
}

/// 解码一份 Profile 的全部行 [rows]。
///
/// 组合格式：每个 `split:<叶子>` 标记（树上认识的叶子）拿走归属该叶子的行；没有标记的叶子
/// 的行是残留（不该有），忽略。树上不认识的叶子标记（更新版本加的叶子）也忽略。
DecodedComboRows decodeComboRows(
  SettingsTree tree,
  Map<SettingKey, String> rows,
) {
  ComboRole? role;
  String? sharedUid;
  final Set<String> splitLeaves = <String>{};
  final Map<SettingKey, String> values = <SettingKey, String>{};
  for (final MapEntry<SettingKey, String> e in rows.entries) {
    final SettingKey k = e.key;
    if (k.category == kComboSyntheticCategory && isComboMetadataKey(k.key)) {
      if (k.key == kComboRoleKey) {
        role = ComboRole.fromWire(e.value);
      } else if (k.key == kComboSrsSharedUidKey) {
        sharedUid = e.value;
      } else {
        final String leafId = k.key.substring(kComboSplitKeyPrefix.length);
        if (tree.contains(leafId) && tree.node(leafId).isLeaf) {
          splitLeaves.add(leafId);
        }
      }
      continue;
    }
    values[k] = e.value;
  }
  if (role == null || role == ComboRole.defaults) {
    return DecodedComboRows(
      role: role,
      document: ComboDocument.empty,
      values: values,
      srsSharedUid: sharedUid,
    );
  }
  final Map<String, Map<SettingKey, String>> grouped = groupByLeaf(
    tree,
    values,
  );
  return DecodedComboRows(
    role: role,
    document: ComboDocument(<String, Map<SettingKey, String>>{
      for (final String leafId in splitLeaves)
        leafId: grouped[leafId] ?? const <SettingKey, String>{},
    }),
    values: values,
    srsSharedUid: sharedUid,
  );
}

/// 把非默认组合 [document] 编成 `profile_settings` 行（全量替换用）：被拆叶子的值 +
/// `split:*` 标记 + `role`。叶子里混进的别家键（坏数据）不写出去。
Map<SettingKey, String> encodeComboRows(
  SettingsTree tree,
  ComboDocument document, {
  required ComboRole role,
}) {
  if (role == ComboRole.defaults) {
    throw ArgumentError.value(
      role,
      'role',
      'the default combo stores full values, not a split document',
    );
  }
  final Map<SettingKey, String> out = <SettingKey, String>{
    const SettingKey(kComboSyntheticCategory, kComboRoleKey): role.wire,
  };
  for (final MapEntry<String, Map<SettingKey, String>> split
      in document.splits.entries) {
    out[SettingKey(
          kComboSyntheticCategory,
          '$kComboSplitKeyPrefix${split.key}',
        )] =
        '1';
    for (final MapEntry<SettingKey, String> e in split.value.entries) {
      if (tree.leafOf(e.key) == split.key) out[e.key] = e.value;
    }
  }
  return out;
}
