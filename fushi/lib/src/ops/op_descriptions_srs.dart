import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/srs/srs_ctl_ops.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 复习（SRS）操作描述的 app 侧装配。描述与撤销本体（牌组 / 笔记查询、统计、sync v2 冲突、重复
/// 笔记合并、批量改笔记）在 engine `packages/fushi_engine/lib/srs/srs_ctl_ops.dart`，与无头服务端
/// 共用同一份；这里只接 app 的依赖（[srsCtlDeps]，与路由同一份）和模块门。
List<OpDescription> describeSrsOps(OpDescribeKit kit) {
  final SrsCtlDeps deps = srsCtlDeps(kit.context);
  return srsCtlOpDescriptions(
    deps.host,
    // 与路由同一个模块门（[SrsCtlDeps.moduleEnabled] = AppModel.moduleEnabled(ModuleId.srs)）。
    availability: () => deps.moduleEnabled()
        ? const OpAvailability.available()
        : OpAvailability.unavailable('module_disabled', ModuleId.srs.name),
  );
}
