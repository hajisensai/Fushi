import 'package:fushi_cli/fushi_cli.dart';

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
    ),
  ];
}

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
