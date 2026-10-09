import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/platform/desktop/ctl/ctl_data_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_dictionary_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_library_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_online_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_settings_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_video_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';

/// 全部按域注册的控制通道路由。每个域只改自己的 `ctl_<域>_routes.dart`。
List<CtlRoute> buildDesktopCtlRoutes(DesktopCtlContext context) => <CtlRoute>[
  ...buildLibraryCtlRoutes(context),
  ...buildDictionaryCtlRoutes(context),
  ...buildSettingsCtlRoutes(context),
  ...buildDataCtlRoutes(context),
  ...buildOnlineCtlRoutes(context),
  ...buildVideoCtlRoutes(context),
];
