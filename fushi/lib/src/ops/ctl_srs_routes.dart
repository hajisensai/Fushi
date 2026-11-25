/// 复习（SRS）控制通道路由的 app 侧装配。路由本体（牌组 / 笔记查询、统计、sync v2 冲突、重复笔记
/// 合并、批量改笔记）在 engine `packages/fushi_engine/lib/srs/srs_ctl_routes.dart`，与无头服务端共用
/// 同一份；这里只接 app 独有的三样：页面在用的那个 store（`srsStoreProvider`，当前 profile）、模块门
/// （[ModuleId.srs]）、写后让打开着的复习页面重读（`bumpSrsRevision`）。CLI 侧命令见
/// `packages/fushi_cli/lib/src/commands/srs_commands.dart`（组 `srs`）。
///
/// 云同步（书 / 进度）中途的冲突不在这里：见 `ctl_data_routes.dart` 的
/// `/api/admin/sync/run`（`conflicts` 策略参数）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/srs/srs_ctl_routes.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart'
    show SrsLegacyMainDatabasePending;
import 'package:fushi_srs/fushi_srs.dart'
    show
        SrsGenState,
        SrsStoreLegacyUnmigrated,
        SrsStoreMigrating,
        SrsStoreNotMigrated,
        SrsStoreOpenBlocked;

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_retained_copy.dart' show srsLibraryDirOf;

export 'package:fushi_engine/srs/srs_ctl_routes.dart' show kSrsCtlRoot;

/// 路由与撤销共用的依赖：store、模块门、写后通知界面刷新。测试注入假实现。
class SrsCtlDeps {
  const SrsCtlDeps({
    required this.store,
    required this.moduleEnabled,
    required this.changed,
    this.libraryDir,
  });

  /// 与页面同一个 store（`srsStoreProvider`）。null = 复习库没就绪。
  final Future<SrsDbStore?> Function() store;

  /// 复习模块开着（[ModuleId.srs]）。
  final bool Function() moduleEnabled;

  /// 写完后让打开着的复习页面重读（页面按钮写完也调同一个 `bumpSrsRevision`）。
  final void Function() changed;

  /// 复习库所在目录（旧版本保留副本的路由按它）；主库没开好 = null。
  final String? Function()? libraryDir;

  factory SrsCtlDeps.of(OpContext context) => SrsCtlDeps(
    store: () => readSrsStore(context.ref),
    moduleEnabled: () => context.appModel.moduleEnabled(ModuleId.srs),
    changed: () => bumpSrsRevision(context.ref),
    libraryDir: () => srsLibraryDirOf(context.appModel),
  );

  /// engine 路由 / 撤销要的宿主：app 只有当前 profile 这一份库，点名的 profile 参数不看。保留副本的路由不经 [open]
  /// 取库、只要库目录：同一道模块门也加在这里（模块关着时查看 / 删除保留副本一样回 422）。
  SrsCtlHost get host => SrsCtlHost(
    open: (String? profile) async =>
        SrsCtlTarget(await requireSrsCtlStore(this)),
    changed: (SrsCtlTarget target) => changed(),
    libraryDir: libraryDir == null ? null : () => requireSrsCtlLibraryDir(this),
  );
}

final Expando<SrsCtlDeps> _depsByContext = Expando<SrsCtlDeps>('srsCtlDeps');

/// [context] 上的复习依赖（路由与 `op_descriptions_srs.dart` 的撤销共用同一份）。
SrsCtlDeps srsCtlDeps(OpContext context) =>
    _depsByContext[context] ??= SrsCtlDeps.of(context);

/// 测试：给 [context] 换上假依赖（之后 [buildSrsCtlRoutes] 与撤销都用它）。
@visibleForTesting
void debugOverrideSrsCtlDeps(OpContext context, SrsCtlDeps deps) =>
    _depsByContext[context] = deps;

List<CtlRoute> buildSrsCtlRoutes(OpContext context) =>
    buildSrsCtlRoutesFor(srsCtlDeps(context));

/// 复习模块门：模块关 → 422。
void _requireSrsModule(SrsCtlDeps deps) {
  if (!deps.moduleEnabled()) {
    throw const CtlFailure.rejected('复习模块已关闭（设置 › 模块里打开）');
  }
}

/// 门控后的 store：模块关 → 422；复习库没就绪 → 422；库卡在代际 / 身份状态（要升级、正在升级、上次升级失败……）
/// → 409 + 稳定错误码（[srsCtlOpenBlockedFailure]）。其余打开失败是真错误，原样抛（ctl 回 500）。
Future<SrsDbStore> requireSrsCtlStore(SrsCtlDeps deps) async {
  _requireSrsModule(deps);
  final SrsDbStore? store;
  try {
    store = await deps.store();
  } on Object catch (e) {
    final CtlFailure? blocked = srsCtlOpenBlockedFailure(e);
    if (blocked == null) rethrow;
    throw blocked;
  }
  if (store == null) {
    throw const CtlFailure.rejected('复习库还没就绪（稍后再试，或先打开一次复习页）');
  }
  return store;
}

/// 门控后的复习库目录（保留副本路由）：模块关 → 422；目录没就绪 = null（engine 路由回 422）。
String? requireSrsCtlLibraryDir(SrsCtlDeps deps) {
  _requireSrsModule(deps);
  return deps.libraryDir?.call();
}

/// 复习库打开时报的「库处在某个代际 / 身份状态」→ 控制通道的 409 + 稳定错误码（调用方按 `code` 分支，不认文本）；
/// 不是这类状态（真错误）回 null，由调用方原样抛出。码与复习页的代际状态页（`srs_generation_view.dart`）一一对应：
///
/// - `srs_needs_migration`：有旧格式（协议 3）的复习库要升级——在主窗口复习页按「开始升级」；
/// - `srs_migration_failed`：上次升级失败、留着半成品——在复习页重新升级；
/// - `srs_upgrading`：别的进程正在升级（拿着换代锁），等它做完（与无头服务端的同名码同义）；
/// - `srs_sealed_old_only`：只剩封存的旧库、新库不见了——要人工恢复；
/// - `srs_legacy_unmigrated`：新库旁边还有一份没升级过的旧库；
/// - `srs_legacy_main_db`：主库里还有协议 1 的复习表，先用能导入它的版本打开一次；
/// - `srs_profile_identity_pending`：辅助进程里这个 profile 还没有本机身份，先在主窗口打开一次复习；
/// - `srs_open_blocked`：「就绪」却打不开（内核不该这样报；不猜，按「打不开」报）。
CtlFailure? srsCtlOpenBlockedFailure(Object error) => switch (error) {
  final SrsStoreOpenBlocked e => CtlFailure(409, _blockedCode(e), e.message),
  SrsLegacyMainDatabasePending() => CtlFailure(
    409,
    'srs_legacy_main_db',
    '$error',
  ),
  SrsProfileIdentityPending() => CtlFailure(
    409,
    'srs_profile_identity_pending',
    '$error',
  ),
  _ => null,
};

String _blockedCode(SrsStoreOpenBlocked e) => switch (e) {
  SrsStoreNotMigrated(state: SrsGenState.needsMigration) =>
    'srs_needs_migration',
  SrsStoreNotMigrated(state: SrsGenState.migrationFailed) =>
    'srs_migration_failed',
  SrsStoreNotMigrated(state: SrsGenState.migratingElsewhere) ||
  SrsStoreMigrating() => 'srs_upgrading',
  SrsStoreNotMigrated(state: SrsGenState.sealedOldOnly) =>
    'srs_sealed_old_only',
  SrsStoreLegacyUnmigrated() => 'srs_legacy_unmigrated',
  SrsStoreNotMigrated(state: SrsGenState.ready) => 'srs_open_blocked',
};

/// 路由表：依赖按 [deps] 注入，测试不必起 [OpContext]。
List<CtlRoute> buildSrsCtlRoutesFor(SrsCtlDeps deps) => srsCtlRoutes(deps.host);
