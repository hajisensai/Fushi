import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/models/app_model.dart';

/// 按域注册的操作（控制通道路由 / AI 助手工具）拿到的 app 上下文。
///
/// 路由在 UI isolate 上执行，可以直接读 [AppModel] 与全局导航；需要界面的动作
/// （打开阅读器、弹窗）走 [navigator]。与平台无关：桌面在它上面挂本机 HTTP 控制
/// 通道（`fushi_cli`），五个平台的 AI 助手都经 `OpInvoker` 进程内调用同一批路由。
class OpContext {
  OpContext({
    required this.ref,
    Future<void> Function()? focusMainWindow,
    this.ingestExternalVideo,
  }) : _focusMainWindow = focusMainWindow;

  final WidgetRef ref;

  final Future<void> Function()? _focusMainWindow;

  /// 外部视频单文件入库（不打开），返回 bookUid；失败返回 null（app 内已提示）。
  /// 与 argv / 单实例转交 / `fushi_cli open` 打开视频走同一个入口
  /// （`main.dart` 的 `_ingestExternalVideo`）。null = 当前宿主不提供。
  final Future<String?> Function(String path)? ingestExternalVideo;

  AppModel get appModel => ref.read(appProvider);

  NavigatorState? get navigator => appModel.navigatorKey.currentState;

  /// 把主窗口带到前台（需要用户看到结果的动作先调它）。宿主没给（手机、AI 页里
  /// 进程内调用——用户本来就在看 app）时什么也不做。
  Future<void> focusMainWindow() async {
    final Future<void> Function()? focus = _focusMainWindow;
    if (focus != null) await focus();
  }
}
