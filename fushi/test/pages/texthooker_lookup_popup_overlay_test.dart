import 'dart:io';

import 'package:test/test.dart';

/// BUG-877 守卫：捕获工作台的查词 WebView 必须在净缩放 1 的根 Overlay 中。
///
/// WebView 是 Windows 平台视图，widget test 无法创建真实控制器；缩放中和器本身已有
/// `app_ui_scale_neutralizer_test.dart` 行为测试，这里守住捕获页的关键接线。
void main() {
  test('texthooker lookup popup is root-overlayed and scale-neutralized', () {
    final String source = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync();

    // 浮层 entry 与中和器归共用宿主（design-shared-lookup-webview），本页只出子项。
    final String host = File(
      'lib/src/pages/implementations/shared_lookup_popup_host.dart',
    ).readAsStringSync();
    expect(host, contains('Overlay.maybeOf(context, rootOverlay: true)'));
    final int overlayBuilder = host.indexOf(
      'Widget _buildOverlay(BuildContext overlayContext)',
    );
    expect(overlayBuilder, greaterThanOrEqualTo(0));
    final int neutralizer = host.indexOf(
      'FushiAppUiScaleNeutralizer(',
      overlayBuilder,
    );
    final int popupStack = host.indexOf(
      'buildSharedLookupPopupLayers(',
      overlayBuilder,
    );
    expect(neutralizer, greaterThan(overlayBuilder));
    expect(popupStack, greaterThan(neutralizer));
    expect(source, contains('_popupHost.sync(context)'));
    expect(source, contains(') => _buildPopups(context, screen);'));

    final int monitorBody = source.indexOf('Widget _buildMonitorBody(');
    final int selectedLine = source.indexOf(
      'TexthookerLineEntry? _selectedLine(',
      monitorBody,
    );
    final String monitorBodySource = source.substring(
      monitorBody,
      selectedLine,
    );
    expect(
      monitorBodySource,
      isNot(contains('..._buildPopups(context)')),
      reason: '浮层不得继续挂在吃全局 UI 缩放的页面内 Stack',
    );
  });
}
