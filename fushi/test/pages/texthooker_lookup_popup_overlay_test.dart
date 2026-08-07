import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-877 守卫：捕获工作台的查词 WebView 必须在净缩放 1 的根 Overlay 中。
///
/// WebView 是 Windows 平台视图，widget test 无法创建真实控制器；缩放中和器本身已有
/// `app_ui_scale_neutralizer_test.dart` 行为测试，这里守住捕获页的关键接线。
void main() {
  test('texthooker lookup popup is root-overlayed and scale-neutralized', () {
    final String source = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync();

    final int overlayBuilder = source.indexOf(
      'Widget _buildPopupOverlay(BuildContext overlayContext)',
    );
    expect(overlayBuilder, greaterThanOrEqualTo(0));
    final int neutralizer = source.indexOf(
      'FushiAppUiScaleNeutralizer(',
      overlayBuilder,
    );
    final int popupStack = source.indexOf(
      'children: _buildPopups(context)',
      overlayBuilder,
    );
    expect(neutralizer, greaterThan(overlayBuilder));
    expect(popupStack, greaterThan(neutralizer));

    final int monitorBody = source.indexOf('Widget _buildMonitorBody(');
    final int selectedOrLatest = source.indexOf(
      'TexthookerLineEntry? _selectedOrLatestLine(',
      monitorBody,
    );
    final String monitorBodySource = source.substring(
      monitorBody,
      selectedOrLatest,
    );
    expect(
      monitorBodySource,
      isNot(contains('..._buildPopups(context)')),
      reason: '浮层不得继续挂在吃全局 UI 缩放的页面内 Stack',
    );
  });
}
