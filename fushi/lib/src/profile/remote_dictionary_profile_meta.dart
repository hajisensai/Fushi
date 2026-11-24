import 'dart:convert' show jsonDecode;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/profile/combo/combo_rows.dart'
    show ComboRole, kComboRoleKey, kComboSplitKeyPrefix;
import 'package:fushi_engine/profile/combo/settings_tree.dart'
    show kComboSyntheticCategory;
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart'
    show FushiComboNode;
import 'package:fushi_engine/profile/profile_document.dart'
    show kProfileSettingCategoryRemoteDictionaryMeta;

/// 配置快照里服务器托管词典那一类（`remote_dictionary_meta`）的 key / value 编解码。
///
/// 唯一解析点：配置应用（`ProfileRepository.applyProfile` / 只读视图）与目录对账
/// （`RemoteDictionaryCatalogService.reconcileHost` 插新行时，BUG-4693）都从这里解。

/// 一行 `remote_dictionary_meta` 快照解出的配置列。
typedef RemoteDictionaryProfileColumns = ({
  String hostId,
  String name,
  int order,
  bool hidden,
});

/// 快照行的 key：`<hostId>/<真名>`。
/// 真名是目录名、不含 `/`，解码按最后一个 `/` 切（hostId 可能是带 `/` 的 origin）。
String remoteDictionaryProfileKey(String hostId, String name) =>
    '$hostId/$name';

/// [remoteDictionaryProfileKey] 的反向：切出 hostId；切不出（无 `/`、host 或真名为空）
/// 返回 null。
String? remoteDictionaryHostIdOfProfileKey(String key) {
  final int slash = key.lastIndexOf('/');
  if (slash <= 0 || slash == key.length - 1) return null;
  return key.substring(0, slash);
}

/// 解码一行快照；key 切不出 host / 真名、value 不是 `{order:int, hidden:bool}` 时
/// 返回 null（调用方跳过这一行，不中断整次应用 / 对账）。
RemoteDictionaryProfileColumns? decodeRemoteDictionaryProfileColumns(
  String key,
  String value,
) {
  final String? hostId = remoteDictionaryHostIdOfProfileKey(key);
  if (hostId == null) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final Object? order = decoded['order'];
  final Object? hidden = decoded['hidden'];
  if (order is! int || hidden is! bool) return null;
  return (
    hostId: hostId,
    name: key.substring(hostId.length + 1),
    order: order,
    hidden: hidden,
  );
}

/// 当前激活配置（[FushiDatabase.resolveActiveProfileId]）的生效值里 [hostId] 那台 host 的
/// 服务器词典配置列，按真名索引；没有激活配置（纯 DB 场景）或没有这台 host 的行时返回空表。
/// 坏行跳过。
///
/// 激活配置是组合格式（只存被拆叶子，拍板台 design-combo-node-split）时，词典叶子逐行继承
/// （`absentKeysInherit`）：先取默认组合那份行，它单独设置了词典时再用它自己的行逐个覆盖——
/// 它那份里没有的词典照样沿用默认组合的选择。
Future<Map<String, RemoteDictionaryProfileColumns>>
activeProfileRemoteDictionaryColumns(FushiDatabase db, String hostId) async {
  final int activeId = await db.resolveActiveProfileId();
  if (activeId <= 0) return const <String, RemoteDictionaryProfileColumns>{};
  final List<int> layers = <int>[activeId];
  final Map<int, String> roles = await db.profileSettingValuesOf(
    kComboSyntheticCategory,
    kComboRoleKey,
  );
  final String? role = roles[activeId];
  if (role != null && role != ComboRole.defaults.wire) {
    int? defaultId;
    for (final MapEntry<int, String> e in roles.entries) {
      if (e.value != ComboRole.defaults.wire) continue;
      if (defaultId == null || e.key < defaultId) defaultId = e.key;
    }
    final bool splitsDictionary = (await db.profileSettingValuesOf(
      kComboSyntheticCategory,
      '$kComboSplitKeyPrefix${FushiComboNode.dictionary}',
    )).containsKey(activeId);
    if (defaultId != null) {
      layers
        ..clear()
        ..add(defaultId);
      if (splitsDictionary) layers.add(activeId);
    }
  }
  final Map<String, RemoteDictionaryProfileColumns> out =
      <String, RemoteDictionaryProfileColumns>{};
  for (final int profileId in layers) {
    for (final ProfileSettingRow row in await db.getProfileSettings(
      profileId,
    )) {
      if (row.category != kProfileSettingCategoryRemoteDictionaryMeta) {
        continue;
      }
      final RemoteDictionaryProfileColumns? columns =
          decodeRemoteDictionaryProfileColumns(row.key, row.value);
      if (columns != null && columns.hostId == hostId) {
        out[columns.name] = columns;
      }
    }
  }
  return out;
}
