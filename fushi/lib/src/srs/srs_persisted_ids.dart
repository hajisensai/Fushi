/// App 里持久化的 SRS 实体 ID 归一的统一入口（G9-6，交接说明 §11）。
///
/// 位置清单与判据见交接说明 §11.1；归一本身（分批、改写、缺失保留）在 fushi_engine 的 srs_canonical_ids.dart。
/// 这里只把偏好仓库接成 [SrsPersistedIdSite]，由 [srsNormalizeStoreIds] 在两个时刻跑：
/// - 打开 / 重新激活激活 profile 的复习副本后（`srsStoreProvider`）；
/// - `bindingChanged` 之后（`SrsDbStore` 的绑定变化通知，G7-5b 接）。
library;

import 'package:fushi_engine/srs/srs_canonical_ids.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';

import 'package:fushi/src/models/preferences_repository.dart';

/// [prefs] 里存着 SRS 实体 ID 的偏好位置（键名冻结）。读写都绕过作品级覆盖层：这里改的是 profile 本身的那一份
/// （作品级覆盖层里的值在制卡解析落点时读时归一，`resolveSrsMiningDestination`）。
List<SrsPersistedIdSite> srsPreferenceIdSites(PreferencesRepository prefs) {
  SrsMiningDestination read() => prefs.withoutWorkScope(
    () => SrsMiningDestination(
      deckId: prefs.srsMiningDeckId,
      noteTypeId: prefs.srsMiningNoteTypeId,
      fieldMappingsByType: prefs.srsMiningFieldMappings,
    ),
  );
  return srsMiningDestinationIdSites(
    read: read,
    writeDeckId: (String id) =>
        prefs.withoutWorkScope(() => prefs.setSrsMiningDeckId(id)),
    writeNoteTypeId: (String id) =>
        prefs.withoutWorkScope(() => prefs.setSrsMiningNoteTypeId(id)),
    writeFieldMappings: (Map<String, Map<String, String>> m) =>
        prefs.withoutWorkScope(() => prefs.setSrsMiningFieldMappings(m)),
  );
}

/// 把 [prefs] 里存的 SRS 实体 ID 换成规范 ID（[lookup] = 那个 profile 的 `canonical_ids`）并落盘；返回写了的偏好键。
/// 只读视图（别的配置的快照）不写。[shouldStop] 见 [srsNormalizePersistedIds]。
Future<List<String>> srsNormalizePersistedPreferenceIds({
  required SrsCanonicalIdsLookup lookup,
  required PreferencesRepository prefs,
  bool Function()? shouldStop,
}) async {
  if (prefs.isReadOnlySnapshot) return const <String>[];
  return srsNormalizePersistedIds(
    srsPreferenceIdSites(prefs),
    lookup,
    shouldStop: shouldStop,
  );
}

/// 统一入口：内置实体（默认牌组等）的规范 ID 向内核要一遍（[SrsDbStore.resolveBuiltinIds]；只读打开的副本不跑
/// `ensureBuiltins`，靠这里拿到），偏好里的 ID 归一并落盘。开库后与 `bindingChanged`（补盐 / 并入，别名类变了）
/// 之后各调一次。
Future<List<String>> srsNormalizeStoreIds({
  required SrsDbStore store,
  required PreferencesRepository prefs,
  bool Function()? shouldStop,
}) async {
  await store.resolveBuiltinIds();
  return srsNormalizePersistedPreferenceIds(
    lookup: srsStoreCanonicalIds(store),
    prefs: prefs,
    shouldStop: shouldStop,
  );
}
