import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/srs/srs_mined_history_import.dart';

/// 复习：牌组列表 ⋯「从制卡历史导入」背后的 [importMinedSentencesIntoSrs]（拍板台
/// PGpPujl99g：CLI 要能做 app 里能点的操作）。确认框换成 `confirm`。制卡历史在主库
/// （`mined_sentences`），只有 app 有，所以不进与无头服务端共用的 engine 路由表。
///
/// CLI 侧是 `fushi_cli srs import-mined --yes`。
List<CtlRoute> buildSrsMinedImportCtlRoutes(OpContext context) =>
    buildSrsMinedImportCtlRoutesFor(
      srs: srsCtlDeps(context),
      database: () => context.appModel.database,
    );

/// 路由路径。
const String kSrsMinedImportCtlPath = '$kSrsCtlRoot/import-mined';

/// 路由表本体：复习库门控沿用 [requireSrsCtlStore]（模块关 / 库没就绪 / 代际状态）。
List<CtlRoute> buildSrsMinedImportCtlRoutesFor({
  required SrsCtlDeps srs,
  required FushiDatabase Function() database,
}) => <CtlRoute>[
  CtlRoute.post(kSrsMinedImportCtlPath, (CtlCall call) async {
    final SrsDbStore store = await requireSrsCtlStore(srs);
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest(
        '把制卡历史导入当前 profile 的默认牌组需要 confirm: true（CLI 用 --yes）',
      );
    }
    final SrsMinedHistoryImportResult result =
        await importMinedSentencesIntoSrs(db: database(), store: store);
    srs.changed();
    return <String, Object?>{
      'imported': result.imported,
      'skipped': result.skipped,
    };
  }),
];
