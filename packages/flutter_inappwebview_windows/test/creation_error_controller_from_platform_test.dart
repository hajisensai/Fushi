import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/in_app_webview.dart';

/// 模拟 app-facing `flutter_inappwebview` 的 `InAppWebViewController`：它不是
/// [PlatformInAppWebViewController] 的子类，只包了一层平台控制器。
class _AppFacingController {
  _AppFacingController(this.platform);

  final PlatformInAppWebViewController platform;
}

/// BUG-4073 回归守卫：WebView2 实例创建失败时，`_onCreationError` 必须像
/// `onWebViewCreated` 一样先经 `controllerFromPlatform` 把平台控制器转成
/// app-facing 控制器，再交给 `onReceivedError`。
///
/// app-facing 包装层（flutter_inappwebview-6.1.5 in_app_webview.dart:329-331）
/// 的回调是 `(controller, request, error) => onReceivedError.call(controller, ...)`，
/// `controller` 静态是 dynamic、调用时隐式向下转型成 `InAppWebViewController`。
/// 修复前直接传 `WindowsInAppWebViewController` → TypeError，sentinel 恢复链
/// 永远到不了 reader。这里用同形的 dynamic → [_AppFacingController] 转型复现。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_manager',
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'createInAppWebView') {
            throw PlatformException(
              code: '0',
              message: 'Cannot create the InAppWebView instance!',
            );
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    '创建失败时 onReceivedError 收到经 controllerFromPlatform 转换的控制器与 sentinel',
    (WidgetTester tester) async {
      final List<_AppFacingController> received = <_AppFacingController>[];
      final List<WebResourceError> errors = <WebResourceError>[];

      void appOnReceivedError(
        _AppFacingController controller,
        WebResourceRequest request,
        WebResourceError error,
      ) {
        received.add(controller);
        errors.add(error);
      }

      final WindowsInAppWebViewWidget webView = WindowsInAppWebViewWidget(
        PlatformInAppWebViewWidgetCreationParams(
          controllerFromPlatform: (PlatformInAppWebViewController controller) =>
              _AppFacingController(controller),
          onReceivedError:
              (
                dynamic controller,
                WebResourceRequest request,
                WebResourceError error,
              ) => appOnReceivedError(controller, request, error),
        ),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: Builder(builder: webView.build),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(received, hasLength(1));
      expect(received.single.platform, isA<PlatformInAppWebViewController>());
      expect(
        errors.single.description,
        startsWith(kInAppWebViewCreationFailedSentinel),
      );
    },
  );
}
