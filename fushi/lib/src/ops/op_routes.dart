import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/ctl_data_routes.dart';
import 'package:fushi/src/ops/ctl_dictionary_routes.dart';
import 'package:fushi/src/ops/ctl_game_routes.dart';
import 'package:fushi/src/ops/ctl_library_routes.dart';
import 'package:fushi/src/ops/ctl_online_routes.dart';
import 'package:fushi/src/ops/ctl_settings_routes.dart';
import 'package:fushi/src/ops/ctl_video_routes.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 全部按域注册的控制通道路由。每个域只改自己的 `ctl_<域>_routes.dart`。
List<CtlRoute> buildOpRoutes(OpContext context) => <CtlRoute>[
  ...buildLibraryCtlRoutes(context),
  ...buildDictionaryCtlRoutes(context),
  ...buildSettingsCtlRoutes(context),
  ...buildDataCtlRoutes(context),
  ...buildOnlineCtlRoutes(context),
  ...buildVideoCtlRoutes(context),
  ...buildGameCtlRoutes(context),
];
