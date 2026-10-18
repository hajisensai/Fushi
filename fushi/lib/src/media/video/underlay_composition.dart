// Windows 底层合成（ci/patches/flutter-engine 的 FlutterDesktopViewSetUnderlayComposition）：
// Flutter 视图改由 DirectComposition topmost visual（预乘 alpha）呈现，视图 HWND 的子窗口
// （窗口宿主档的 WebView2，硬件 PlayReady）垫在 Flutter 下面、从透明像素处透出来，
// Flutter 的控件 / 字幕 / 查词弹窗画在它上面。
//
// 透出来的前提是视频区下面没有任何不透明的 Flutter 底色：页面自己让开，外层标题栏
// 框架（盖着整个 Navigator 的 surface 底色）听 [underlayCompositionActive]。
import 'package:flutter/foundation.dart';
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
