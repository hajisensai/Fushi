/// 合集清单同步的因果基线（毫秒）读写，按 [SyncChannelScope] 分账。
///
/// 从 app 的 `SyncRepository.getCollectionsSyncBaselineMs` / `set…` 抽出：互联 host
/// 合并对端清单时要读写 host 那本账（BUG-1579），而 SyncRepository 拖着全部云盘
/// 后端。app 的两个方法委派到这里，键与回退规则逐字节一致。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';

const String kCollectionsSyncBaselineMsKey = 'sync_collections_baseline_ms';

Future<String?> _readPref(FushiDatabase db, String key) async {
  final PreferenceRow? row = await (db.select(db.preferences)
        ..where(($PreferencesTable t) => t.key.equals(key)))
      .getSingleOrNull();
  return row?.value;
}

/// 未分账的旧键作为回退（分账之前写下的基线）。0 = 从未同步过。
Future<int> readCollectionsSyncBaselineMs(
  FushiDatabase db,
  SyncChannelScope scope,
) async {
  final String? s = await _readPref(db, scope.key(kCollectionsSyncBaselineMsKey)) ??
      await _readPref(db, kCollectionsSyncBaselineMsKey);
  return s == null ? 0 : int.tryParse(s) ?? 0;
}

Future<void> writeCollectionsSyncBaselineMs(
  FushiDatabase db,
  SyncChannelScope scope,
  int ms,
) =>
    db.into(db.preferences).insertOnConflictUpdate(
      PreferencesCompanion.insert(
        key: scope.key(kCollectionsSyncBaselineMsKey),
        value: ms.toString(),
      ),
    );
