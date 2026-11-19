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

/// 门控后的 store：模块关 → 422；复习库没就绪 → 422。
Future<SrsDbStore> requireSrsCtlStore(SrsCtlDeps deps) async {
  _requireSrsModule(deps);
  final SrsDbStore? store = await deps.store();
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

/// 路由表：依赖按 [deps] 注入，测试不必起 [OpContext]。
List<CtlRoute> buildSrsCtlRoutesFor(SrsCtlDeps deps) => srsCtlRoutes(deps.host);
