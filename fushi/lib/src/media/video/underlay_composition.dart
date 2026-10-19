// Windows 底层合成（ci/patches/flutter-engine 的 FlutterDesktopViewSetUnderlayComposition）：
// Flutter 视图改由 DirectComposition topmost visual（预乘 alpha）呈现，视图 HWND 的子窗口
// （窗口宿主档的 WebView2，硬件 PlayReady）垫在 Flutter 下面、从透明像素处透出来，
// Flutter 的控件 / 字幕 / 查词弹窗画在它上面。
//
// 透出来的前提是视频区下面没有任何不透明的 Flutter 底色：页面自己让开，外层标题栏
// 框架（盖着整个 Navigator 的 surface 底色）听 [underlayCompositionActive]。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// 与 HDR 输出同一条 runner 通道（`underlayCompositionSupported` / `setUnderlayComposition`）。
const MethodChannel kUnderlayCompositionChannel = MethodChannel(
  'app.fushi/hdr_output',
);

/// 底层合成是否开着（标题栏框架据此让开底色）。
final ValueNotifier<bool> underlayCompositionActive = ValueNotifier<bool>(
  false,
);

int _holders = 0;

/// 引擎能否做底层合成（打了补丁的 flutter_windows.dll 导出了开关）。不改任何状态。
Future<bool> underlayCompositionSupported() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return false;
  try {
    return await kUnderlayCompositionChannel.invokeMethod<bool>(
          'underlayCompositionSupported',
        ) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// 请求开启：返回引擎是否支持（原版引擎 / 非 Windows → false，什么也不变）。
/// 与 [releaseUnderlayComposition] 成对调用；按持有数计，换页交接（新页先 acquire、
/// 旧页后 release）不会中途关掉。
Future<bool> acquireUnderlayComposition() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return false;
  bool ok = false;
  try {
    ok =
        await kUnderlayCompositionChannel.invokeMethod<bool>(
          'setUnderlayComposition',
          true,
        ) ??
        false;
  } on MissingPluginException {
    ok = false;
  } on PlatformException {
    ok = false;
  }
  if (!ok) return false;
  _holders++;
  underlayCompositionActive.value = true;
  return true;
}

/// 归还 [acquireUnderlayComposition] 成功拿到的一份；最后一份归还时关闭。
Future<void> releaseUnderlayComposition() async {
  if (_holders == 0) return;
  _holders--;
  if (_holders > 0) return;
  await _afterBuildPhase();
  // 等待期间又有页 acquire（换页交接）：这份已经不是最后一份。
  if (_holders > 0) return;
  underlayCompositionActive.value = false;
  try {
    await kUnderlayCompositionChannel.invokeMethod<bool>(
      'setUnderlayComposition',
      false,
    );
  } on MissingPluginException {
    // 引擎 / runner 已不在（退出中）。
  } on PlatformException {
    // 同上。
  }
}

/// 页面 dispose 里归还时树是锁着的（`finalizeTree` 卸载 inactive element）：此刻改
/// [underlayCompositionActive] 会让标题栏的 ValueListenableBuilder 标脏失败（断言，release
/// 下是标题栏停在透明底）。在帧的 build 阶段里就等这一帧画完再通知。
Future<void> _afterBuildPhase() {
  final SchedulerBinding binding = SchedulerBinding.instance;
  if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
    return Future<void>.value();
  }
  final Completer<void> done = Completer<void>();
  binding.addPostFrameCallback((Duration _) => done.complete());
  return done.future;
}
