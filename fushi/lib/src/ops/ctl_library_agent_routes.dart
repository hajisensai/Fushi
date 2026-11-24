import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/library_agent/library_changeset.dart';
import 'package:fushi_engine/media/library_agent/library_map.dart';

import 'package:fushi/src/ops/op_context.dart';

/// AI 管库 v3 的两条宿主操作（spec `docs/specs/2026-11-22-ai-library-agent-design.md`
/// §3.2 / §3.3）：整库地图（只读、紧凑列式、分页）与一次提交一整份变更集（AI 身份
/// 落库、一条撤销记录）。助手的整库整理技能 `skill.library.reorganize` 用它们；CLI
/// 也能直接调（`fushi_cli ops call library.map …`）。
const String kLibraryAgentCtlRoot = '/api/admin/library/agent';

List<CtlRoute> buildLibraryAgentCtlRoutes(OpContext context) =>
    buildLibraryAgentCtlRoutesFor(
      database: () => context.appModel.database,
      isReadonly: () => context.appModel.isMigrationReadonly,
    );

/// 路由表本体：依赖按回调注入，测试不必起 [OpContext]。
List<CtlRoute> buildLibraryAgentCtlRoutesFor({
  required FushiDatabase Function() database,
  bool Function()? isReadonly,
}) {
  void requireWritable() {
    if (isReadonly?.call() ?? false) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
    }
  }

  return <CtlRoute>[
    CtlRoute.get('$kLibraryAgentCtlRoot/map', (CtlCall call) async {
      final LibraryMapQuery query;
      try {
        query = LibraryMapQuery.fromJson(<String, Object?>{
          ...call.query,
          ...call.body,
        });
      } on FormatException catch (e) {
        throw CtlFailure.badRequest(e.message);
      }
      return loadLibraryMap(database(), query);
    }),
    CtlRoute.post('$kLibraryAgentCtlRoot/changes', (CtlCall call) async {
      final bool dryRun = call.optBool('dryRun') ?? false;
      if (!dryRun) requireWritable();
      final LibraryChangeset changeset;
      try {
        changeset = parseLibraryChangeset(call.body);
      } on FormatException catch (e) {
        throw CtlFailure.badRequest(e.message);
      }
      final LibraryChangesetOutcome outcome = await applyLibraryChangeset(
        database(),
        changeset,
        dryRun: dryRun,
      );
      return outcome.toJson();
    }),
  ];
}
