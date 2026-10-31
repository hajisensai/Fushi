import 'package:material_ui/material_ui.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/sync/fushi_api_server.dart' show kFushiApiDefaultPort;

/// Fushi API 服务器（内部名 Yomitan API server）端口被占用时给用户看的说明。
/// 默认端口的占用者几乎总是浏览器拉起的 yomitan-api Python 进程，给专项修复路径；
/// 自定义端口只能泛泛说「被占用」。设置页开关与启动提醒共用这一处。
String fushiApiPortInUseMessage(int port) {
  return port == kFushiApiDefaultPort
      ? t.browser_extension_yomitan_port_conflict(port: port)
      : t.sync_server_port_in_use(port: port);
}

/// 启动时自启 Fushi API 服务器撞端口的提醒。
///
/// 自启发生在 `AppModel.initialise()` 里、`runApp` 之前，而且是 fire-and-forget，
/// 失败那一刻多半还没有 Navigator；所以冲突端口作为状态挂在 [conflictPort] 上，
/// 这里既在首帧后检查一次，也监听之后才落下的失败，Navigator 就绪才弹窗。
/// 每个冲突值只弹一次：弹过即把 [conflictPort] 清回 null。
void installFushiApiPortConflictNotice({
  required GlobalKey<NavigatorState> navigatorKey,
  required ValueNotifier<int?> conflictPort,
}) {
  bool showing = false;

  Future<void> showIfPending() async {
    final int? port = conflictPort.value;
    if (port == null || showing) return;
    final BuildContext? context = navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      // Navigator 还没起来：等下一帧再试，状态保留不丢。
      WidgetsBinding.instance.addPostFrameCallback((_) => showIfPending());
      return;
    }
    showing = true;
    conflictPort.value = null;
    try {
      await _showConflictDialog(context, port);
    } finally {
      showing = false;
    }
  }

  conflictPort.addListener(showIfPending);
  WidgetsBinding.instance.addPostFrameCallback((_) => showIfPending());
}

Future<void> _showConflictDialog(BuildContext context, int port) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog.adaptive(
      title: Text(t.fushi_api_server),
      content: Text(fushiApiPortInUseMessage(port)),
      actions: <Widget>[
        adaptiveDialogAction(
          context: dialogContext,
          isDefaultAction: true,
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(t.dialog_ok),
        ),
      ],
    ),
  );
}
