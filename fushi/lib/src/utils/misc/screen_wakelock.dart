import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 开关「保持屏幕常亮」，**永不抛错**。
///
/// `WakelockPlus.enable/disable` 的失败全部经返回的 Future 抛出：Linux 实现走
/// D-Bus `org.freedesktop.ScreenSaver.Inhibit`，没有这个服务的会话（部分窗口管理器、
/// Sway、容器、远程桌面）里它以 `DBusMethodResponseException(ServiceUnknown)` 失败。
/// 调用点从前写成同步 `try { WakelockPlus.enable(); } catch` ——catch 只接得住同步
/// 异常，Future 里的错误成了未处理的异步错误，在 Linux 上打开阅读器即触发（集成测试里
/// 直接判红）。所有调用点都经这里：内部 await 并吞掉失败、记一行日志；同步上下文
/// （dispose / 启动）用 `unawaited(setScreenWakelock(...))` 也是安全的。
Future<void> setScreenWakelock({
  required bool enable,
  required String source,
}) async {
  try {
    await WakelockPlus.toggle(enable: enable);
  } catch (e) {
    debugPrint(
      '[Fushi] wakelock ${enable ? 'enable' : 'disable'} '
      'failed ($source): $e',
    );
  }
}
