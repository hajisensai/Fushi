import 'package:flutter/widgets.dart';
// ignore: depend_on_referenced_packages  — 测试桩需直接实现该平台接口（flutter_inappwebview 的传递依赖）
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';

/// Registers a no-op [InAppWebViewPlatform] so widget trees that contain an
/// `InAppWebView` (e.g. the persistent warm dictionary popup slot, BUG-092) can
/// build under the unit-test harness, where the real platform view has no
/// implementation. The fake WebView renders an empty box and never fires
/// lifecycle callbacks (so app code's `_controller` stays null — no JS eval).
void installFakeInAppWebViewPlatform() {
  InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
}

class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
      PlatformInAppWebViewWidgetCreationParams params) {
    return _FakeInAppWebViewWidget(params);
  }
}

class _FakeInAppWebViewWidget extends PlatformInAppWebViewWidget {
  _FakeInAppWebViewWidget(PlatformInAppWebViewWidgetCreationParams params)
      : super.implementation(params);

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) {
    throw UnimplementedError(
        'controllerFromPlatform is not used by the fake WebView');
  }

  @override
  void dispose() {}
}
