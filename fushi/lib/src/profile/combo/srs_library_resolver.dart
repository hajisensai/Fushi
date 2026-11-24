/// 复习库解析的 app 侧读口（拍板台 design-srs-shared-library 方案 a，组合阶段 4）。
///
/// 「制卡 / .apkg 导入 / 复习页落进哪份复习库」的**唯一**入口：从 `profile_settings` 读出
/// `combo` category 下几张小表，交给引擎 [ComboSrsLibraries] 解析（规则见
/// `combo_srs_library.dart` 与设计 §4.1）。消费方不再拿 `profileUidOf(激活配置)` 当集合身份。
library;

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/profile/combo/combo_repository.dart';

/// 读本库全部 Profile 的复习库归属快照（几条小查询，不读设置值本身）。
Future<ComboSrsLibraries> loadComboSrsLibraries(FushiDatabase db) async {
  final Map<int, String> uidById = <int, String>{
    for (final ProfileRow p in await db.getAllProfiles())
      p.id: await db.profileUidOf(p.id),
  };
  return ComboSrsLibraries.fromRows(
    uidById: uidById,
    roles: await db.profileSettingValuesOf(
      kComboSyntheticCategory,
      kComboRoleKey,
    ),
    sharedUids: await db.profileSettingValuesOf(
      kComboSyntheticCategory,
      kComboSrsSharedUidKey,
    ),
    librarySplits: await db.profileSettingValuesOf(
      kComboSyntheticCategory,
      kComboSrsLibrarySplitKey,
    ),
    libraryValues: await db.profileSettingValuesOf(
      kComboSyntheticCategory,
      kComboSrsLibrarySettingKey,
    ),
  );
}

/// [baseProfileId]（缺省 = 激活配置）之上叠 [layers] 时落进的复习库的集合 uid；库里一个
/// Profile 都没有 / [baseProfileId] 不存在时空串（与 `resolveActiveProfileUid` 同口径）。
Future<String> resolveSrsLibraryUid(
  FushiDatabase db, {
  int? baseProfileId,
  Map<ComboScope, int> layers = const <ComboScope, int>{},
}) async {
  final int base = baseProfileId ?? await db.resolveActiveProfileId();
  if (base <= 0) return '';
  final ComboSrsLibrary? library = (await loadComboSrsLibraries(
    db,
  )).resolve(baseProfileId: base, layers: layers);
  return library?.uid ?? '';
}

/// 复习库 [libraryUid] 挂在哪份配置上（`profiles.uid` 等于它的那份：共享库可能挂在激活配置以外的
/// 配置上，见设计 §4.2）；不在库里时 null。
Future<int?> profileIdOfSrsLibrary(FushiDatabase db, String libraryUid) async {
  if (libraryUid.isEmpty) return null;
  for (final ProfileRow p in await db.getAllProfiles()) {
    if (await db.profileUidOf(p.id) == libraryUid) return p.id;
  }
  return null;
}
