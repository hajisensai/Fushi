import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/models/app_model.dart';

/// 按域注册的控制通道路由拿到的 app 上下文。
///
/// 路由在 UI isolate 上执行，可以直接读 [AppModel] 与全局导航；需要界面的动作
/// （打开阅读器、弹窗）走 [navigator]。
class DesktopCtlContext {
  DesktopCtlContext({required this.ref, required this.focusMainWindow});

  final WidgetRef ref;

  /// 把主窗口带到前台（需要用户看到结果的动作先调它）。
  final Future<void> Function() focusMainWindow;

  AppModel get appModel => ref.read(appProvider);

  NavigatorState? get navigator => appModel.navigatorKey.currentState;
}
