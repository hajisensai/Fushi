import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart'
    show AiAgentActionsCompanion, FushiDatabase;

import 'package:fushi/src/ai/agent/ai_agent_toolbox.dart'
    show redactAiAgentArgs;

import 'package:fushi/src/ops/ctl_ai_agent_routes.dart';
import 'package:fushi/src/ops/ctl_web_routes.dart';
import 'package:fushi/src/ops/ctl_url_import_routes.dart';
import 'package:fushi/src/ops/ctl_disc_routes.dart';
import 'package:fushi/src/ops/ctl_media_links_routes.dart';
import 'package:fushi/src/ops/ctl_book_metadata_routes.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi/src/ops/ctl_music_routes.dart';
import 'package:fushi/src/ops/ctl_data_routes.dart';
import 'package:fushi/src/ops/ctl_dictionary_routes.dart';
import 'package:fushi/src/ops/ctl_game_routes.dart';
import 'package:fushi/src/ops/ctl_library_routes.dart';
import 'package:fushi/src/ops/ctl_online_routes.dart';
import 'package:fushi/src/ops/ctl_settings_routes.dart';
import 'package:fushi/src/ops/ctl_video_routes.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 全部按域注册的路由，外加操作目录的通用面（`/api/admin/ops*`，`fushi_cli op`）。
/// 目录在第一次被访问时才组装（构造路由表本身不碰 AppModel）。
List<CtlRoute> buildOpRoutes(OpContext context) {
  final List<CtlRoute> domain = buildDomainOpRoutes(context);
  OpInvoker? invoker;
  return <CtlRoute>[
    ...domain,
    ...buildOpCatalogRoutes(
      () => invoker ??= OpInvoker(buildAppOpCatalog(context, domain)),
      recordUndo: (FushiOp op, Map<String, Object?> args, OpUndoRecord undo) =>
          recordCliOpUndo(context.appModel.database, op, args, undo),
    ),
  ];
}

/// 用户经 `/api/admin/ops/call`（`fushi_cli`）执行的可撤销操作记进的「会话」id：与 AI 助手的
/// 操作记录同一张表（`ai_agent_actions`），操作记录页 / `fushi_cli ai undo <id>` 照样能撤销。
const String kCliOpSessionId = 'cli';

/// 把一次 CLI 发起的可撤销操作记进操作记录，返回记录 id。
Future<int> recordCliOpUndo(
  FushiDatabase db,
  FushiOp op,
  Map<String, Object?> args,
  OpUndoRecord undo, {
  DateTime Function() clock = DateTime.now,
}) => db.insertAiAgentAction(
  AiAgentActionsCompanion.insert(
    sessionId: kCliOpSessionId,
    opId: op.id,
    argsJson: jsonEncode(redactAiAgentArgs(args)),
    risk: op.risk.name,
    confirmation: 'user',
    resultCode: 'ok',
    undoPayloadJson: Value<String?>(jsonEncode(undo.payload)),
    beforeText: Value<String?>(undo.before),
    afterText: Value<String?>(undo.after),
    createdAt: clock().millisecondsSinceEpoch,
  ),
);

/// 进程内调用器（五个平台的 AI 助手用）：同一批路由 + 只在进程内有的操作 [extra]。
OpInvoker buildInProcessOpInvoker(
  OpContext context, {
  Iterable<FushiOp> extra = const <FushiOp>[],
}) => OpInvoker(
  buildAppOpCatalog(context, buildDomainOpRoutes(context), extra: extra),
  ready: () => context.appModel.isInitialised,
);

/// 全部按域注册的控制通道路由。每个域只改自己的 `ctl_<域>_routes.dart`。
List<CtlRoute> buildDomainOpRoutes(OpContext context) => <CtlRoute>[
  ...buildLibraryCtlRoutes(context),
  ...buildDictionaryCtlRoutes(context),
  ...buildSettingsCtlRoutes(context),
  ...buildDataCtlRoutes(context),
  ...buildOnlineCtlRoutes(context),
  ...buildVideoCtlRoutes(context),
  ...buildGameCtlRoutes(context),
  ...buildMusicCtlRoutes(context),
  ...buildSrsCtlRoutes(context),
  ...buildBookMetadataCtlRoutes(context),
  ...buildMediaLinksCtlRoutes(context),
  ...buildDiscCtlRoutes(context),
  ...buildUrlImportCtlRoutes(context),
  ...buildWebCtlRoutes(context),
  ...buildAiAgentCtlRoutes(context),
];
