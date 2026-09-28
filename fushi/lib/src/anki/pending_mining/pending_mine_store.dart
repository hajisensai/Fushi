import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/anki_sync/pending_mine_store.dart';

import 'package:fushi/src/storage/app_paths.dart';

// 存储本体在 fushi_engine（无头服务端当落地设备也用同一份）；这里只补 app 的定位。
export 'package:fushi_engine/anki_sync/pending_mine_store.dart';

/// 本机的待发队列：载荷在 `<support>/pending_mine_queue`。制卡链路（仓库 provider）
/// 与跨设备中转（同步触发器）共用这一处定位。
PendingMineStore pendingMineStoreAtSupportRoot(FushiDatabase Function() db) =>
    PendingMineStore.inSupportDir(db, AppPaths.supportRootDirectory);
