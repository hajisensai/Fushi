import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 共享测试夹具：互联 live 客户端 backend 的搭建。多个 `hibiki_client_live_*` 测试
/// 逐字复制同一套「建内存库 → 写 url/token → withProbe(true) → restoreAuth +
/// authenticate」流程，此处上移为唯一真相源。
///
/// 刻意不调 `addTearDown`：orchestrator live 测试跑真实 socket、**不**初始化
/// TestWidgetsFlutterBinding，此 helper 需在无 binding 场景下也可用。内存
/// [HibikiDatabase] 泄漏对测试进程无害（进程退出即回收）。

/// 内存 [HibikiDatabase]，供互联 live 测试建 SyncRepository。
HibikiDatabase memLiveDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 把 [base] url + [token] 写库，`withProbe`（恒 true，server 已在运行）后
/// restoreAuth + authenticate，返回配好的 [HibikiClientSyncBackend]。
Future<HibikiClientSyncBackend> buildHibikiClientBackend({
  required String base,
  required String token,
}) async {
  final HibikiDatabase db = memLiveDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(<HibikiClientUrl>[
    HibikiClientUrl(url: base, enabled: true),
  ]);
  await repo.setHibikiClientToken(token);
  final HibikiClientSyncBackend backend =
      HibikiClientSyncBackend.withProbe((String url, String tok) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}
