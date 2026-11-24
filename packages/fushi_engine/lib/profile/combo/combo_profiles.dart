/// 「组合」在 `profiles` 表上的读口（拍板台 design-combo-node-split 阶段 6）：配置列表列哪些
/// Profile。app 的配置列表、首页配置胶囊、悬浮球切换、浏览器扩展选配置共用这一个判据。
library;

import 'package:fushi_core/fushi_core.dart' show FushiDatabase, ProfileRow;

import 'package:fushi_engine/profile/combo/combo_rows.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';

/// 配置列表里列出的 Profile：不含作品上直接拆出的匿名组合（`role = work_local`，只挂在那部作品上，
/// 在作品的「作品配置」里管理）。切换配置 / 绑定 / 浏览器扩展选配置的列表都用它（唯一判据）。
Future<List<ProfileRow>> listedComboProfiles(FushiDatabase db) async {
  final Set<int> workLocal = await workLocalComboIds(db);
  return <ProfileRow>[
    for (final ProfileRow p in await db.getAllProfiles())
      if (!workLocal.contains(p.id)) p,
  ];
}

/// 作品上直接拆出的匿名组合的 Profile id。
Future<Set<int>> workLocalComboIds(FushiDatabase db) async => <int>{
  for (final MapEntry<int, String> e in (await db.profileSettingValuesOf(
    kComboSyntheticCategory,
    kComboRoleKey,
  )).entries)
    if (e.value == ComboRole.workLocal.wire) e.key,
};
