import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Linux GTK runner 单实例转交在 `app.fushi/external_video` 上的 Dart → runner
/// 两个通知（runner 实现见 `linux/runner/my_application.cc` 的
/// `external_video_method_cb`；方法名两侧逐字一致，源码守卫
/// `test/native/linux_single_instance_guard_static_test.dart` 钉住）。
///
/// - [readyMethod]：Dart 的 `openExternalVideo` 处理器已注册。runner 在此之前收到的
///   二次启动参数先排队，收到后按序冲出——否则处理器注册前的消息只由 framework
///   的 ChannelBuffers 暂存、每通道仅 1 条，连续两次转交前一个会被挤掉（BUG-3089）。
/// - [exitingMethod]：退出链已开始（紧接着 `windowManager.hide()`，进程还要活几秒做
///   flush，D-Bus 名一直占着）。runner 此后对二次启动回「正在退出」，不接管参数、
///   不重新显示窗口；二次启动方等旧进程让出名字后自己按首实例启动（BUG-3087）。
///
/// Windows runner 不认这两个方法，只在 Linux 调用。
abstract final class LinuxExternalOpenChannel {
  /// Dart 处理器就绪通知的方法名。
  static const String readyMethod = 'externalOpenReady';

  /// 退出链开始通知的方法名。
  static const String exitingMethod = 'appExiting';

  /// 单次通知的上界：runner 在 platform 线程上同步回复，正常是亚毫秒级；到点不再等，
  /// 免得退出链被一个不归的平台调用拖住。
  static const Duration notifyTimeout = Duration(milliseconds: 300);

  /// 告诉 runner：`openExternalVideo` 处理器已经挂在 [channel] 上。
  static Future<void> notifyHandlerReady(MethodChannel channel) =>
      _notify(channel, readyMethod);

  /// 告诉 runner：本进程已进入退出链，不要再把二次启动交给它。
  static Future<void> notifyExiting(MethodChannel channel) =>
      _notify(channel, exitingMethod);

  /// 通知失败（旧 runner 没实现 / 平台报错 / 超时）只记日志：这是对外部原生边界
  /// 的单向通知，失败时 runner 退回旧行为，不能让它中断启动或退出链。
  static Future<void> _notify(MethodChannel channel, String method) async {
    try {
      await channel.invokeMethod<void>(method).timeout(notifyTimeout);
    } on MissingPluginException catch (e) {
      debugPrint('[Fushi] external_video $method unsupported by runner: $e');
    } on PlatformException catch (e) {
      debugPrint('[Fushi] external_video $method failed: $e');
    } on TimeoutException {
      debugPrint('[Fushi] external_video $method timed out');
    }
  }
}
