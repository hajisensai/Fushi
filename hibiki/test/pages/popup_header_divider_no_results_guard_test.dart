import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

import '../widgets/widget_test_helpers.dart';

/// TODO-1187：in-app 查词弹窗「未找到搜索结果」态曾有一条悬空的多余横线。
///
/// 根因：弹窗顶栏 header（reader 音频/收藏行、video 收藏星标行）的容器**无条件**画一条
/// 底边框（`Border(bottom: BorderSide(dividerColor, 0.5))`）。header 恒挂在栈顶层
/// （index 0）与结果数无关，弹窗结构是 `Column[topRegion(header), Expanded(body)]`。有词条
/// 时这条线自然分隔 header 与词条内容；无结果 / 搜索中时 body 只是「未找到搜索结果」占位或
/// 加载盖板，这条线就悬在收藏行与占位卡之间 = 多余横线。
///
/// 修复：把分隔线从 header widget 内移出，改由 [DictionaryPopupLayer.build] 在
/// `headerWidget != null && _hasRenderableResults` 时才画（无结果 / 搜索中 / 无 header 的
/// app 外覆盖窗都不画）。本测试守两件事：
///   1. 无结果态（result=null、非搜索、有 header）真渲染下 **不出现** [Divider]（bug 回归门）。
///   2. 源码守卫：分隔线在 popup 层按上述条件门控，且两处 header 不再带无条件底边框
///      （有词条时分隔线仍由 popup 层画出，故有结果态不回归）。
void main() {
  testWidgets(
    'no-results popup with a header draws no divider between header and body',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(
          SizedBox(
            width: 240,
            height: 200,
            child: DictionaryPopupLayer(
              // result=null + 非搜索 → body 落到「未找到搜索结果」占位分支（不挂 WebView）。
              result: null,
              isSearching: false,
              headerWidget: const SizedBox(
                key: Key('test-popup-header'),
                height: 40,
              ),
              webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
              onDismiss: () {},
              onTextSelected: (text, rect) {},
              onLinkClick: (query, rect) {},
              onMineEntry: (fields) async => const MinePopupResult(),
              onDuplicateCheck: (expression, reading) async => false,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      // header 仍在（顶栏渲染），但 header 与占位 body 之间不得出现分隔线。
      expect(find.byKey(const Key('test-popup-header')), findsOneWidget);
      expect(
        find.byType(Divider),
        findsNothing,
        reason: '无结果态 header 与占位之间不得画分隔线（TODO-1187 悬空横线）',
      );
    },
  );

  test(
    'popup layer gates the header divider on header + renderable results only',
    () {
      const String path =
          'lib/src/pages/implementations/dictionary_popup_layer.dart';
      final String src = File(path).readAsStringSync();

      // 分隔线的门控表达式：既要有 header（app 外覆盖窗 headerWidget=null 不受影响），
      // 又要有可渲染词条（无结果 / 搜索中不画）。
      expect(
        src.contains('headerWidget != null && _hasRenderableResults'),
        isTrue,
        reason: 'header 分隔线必须门控在「有 header 且有可渲染词条」',
      );
      // 门控为真时确实画出一条 Divider（有结果态分隔线保留，不回归）。
      final int gateIdx = src.indexOf('final bool showHeaderDivider =');
      expect(gateIdx, greaterThanOrEqualTo(0),
          reason: 'showHeaderDivider 门控变量缺失');
      final String afterGate = src.substring(gateIdx);
      expect(
        afterGate.contains('if (showHeaderDivider)') &&
            afterGate.contains('Divider('),
        isTrue,
        reason: '门控为真时必须画 Divider（有结果态分隔线保留）',
      );
    },
  );

  test('reader/video popup headers no longer carry an unconditional border',
      () {
    for (final String path in <String>[
      'lib/src/pages/implementations/reader_fushi_page.dart',
      'lib/src/pages/implementations/video_fushi_page.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      final int headerIdx = path.contains('reader_fushi_page')
          ? src.indexOf('Widget? buildPopupAudioControls()')
          : src.indexOf('Widget? buildPopupHeaderFor(');
      expect(headerIdx, greaterThanOrEqualTo(0),
          reason: '$path: popup header 方法未找到');
      // 截取到方法体的一段（足够覆盖 Container 装饰），断言不再有底边框。用精确的
      // `border: Border(` 标记，避免误配按钮的 StadiumBorder/CircleBorder。
      final String header = src.substring(headerIdx, headerIdx + 1600);
      expect(
        header.contains('border: Border('),
        isFalse,
        reason: '$path: header 不得再画无条件底边框（分隔线已移交 popup 层按结果条件画）',
      );
    }
  });
}
