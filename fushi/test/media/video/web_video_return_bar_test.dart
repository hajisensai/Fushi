import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/web_video_return_bar.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';

/// 反馈 -TwLAKqRZx：网页视频页顶部返回条画在窗口 y=0，右端「在浏览器中打开」被
/// 自绘标题行的窗口按钮盖住。返回条必须让出页面顶部 padding（标题行高度）。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('Windows 自绘标题栏：返回条按钮不与窗口关闭键重叠，站点页面让在返回条下面', (
    WidgetTester tester,
  ) async {
    const MethodChannel windowManager = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowManager,
      (MethodCall call) async => call.method.startsWith('is') ? false : null,
    );
    final TargetPlatform Function() savedHost =
        FushiDesktopTitleBar.debugHostPlatform;
    FushiDesktopTitleBar.debugIsEnabled = true;
    FushiDesktopTitleBar.debugHostPlatform = () => TargetPlatform.windows;
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowManager,
        null,
      );
      FushiDesktopTitleBar.debugIsEnabled = false;
      FushiDesktopTitleBar.debugHostPlatform = savedHost;
    });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final ValueNotifier<String?> title = ValueNotifier<String?>('Netflix');
    addTearDown(title.dispose);
    double extent = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          builder: (BuildContext context, Widget? child) =>
              FushiDesktopTitleBar(
                title: const SizedBox.shrink(),
                child: child!,
              ),
          home: Builder(
            builder: (BuildContext context) {
              extent = webVideoReturnBarExtent(context);
              return Stack(
                children: <Widget>[
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: extent,
                    child: WebVideoReturnBar(
                      title: title,
                      onBack: () {},
                      onOpenInBrowser: () {},
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect close = tester.getRect(
      find.byKey(FushiDesktopTitleBar.closeButtonKey),
    );
    final Rect open = tester.getRect(
      find.byKey(const ValueKey<String>('video-web-open-in-browser')),
    );
    final Rect back = tester.getRect(
      find.byKey(const ValueKey<String>('video-web-return-back')),
    );
    expect(open.overlaps(close), isFalse, reason: '「在浏览器中打开」被关闭键盖住');
    expect(open.top, greaterThanOrEqualTo(FushiDesktopTitleBar.height));
    expect(back.top, greaterThanOrEqualTo(FushiDesktopTitleBar.height));
    expect(
      extent,
      greaterThanOrEqualTo(
        FushiDesktopTitleBar.height + kWebVideoReturnBarRowHeight,
      ),
    );
  });
}
