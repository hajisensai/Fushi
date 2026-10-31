/// 折叠分组头在手机宽度下：长摘要不能把标题挤到只剩几个字宽。
///
/// 尾随区（摘要 + 箭头）是头部 Row 里的非 flex 子，量到无界宽，摘要整句铺开，
/// `Expanded` 的标题只拿到余下的几十 dp、折成三行（LLM 设置页「功能提供商」）。
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('长摘要的折叠头：标题仍保持单行，摘要在自己的 Flexible 里省略', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const String title = 'Feature providers';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        // 测试字体（Ahem）的字形远宽于真字体：缩到 0.5 倍，只量布局判据。
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.5)),
          child: child!,
        ),
        home: const Scaffold(
          body: AdaptiveSettingsSection(
            title: title,
            titlePlacement: SettingsSectionTitlePlacement.inside,
            collapsible: true,
            summary: 'All features use the default provider and more words',
            children: <Widget>[SizedBox(height: 40)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      find.text(title),
    );
    final TextPainter natural = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler,
    )..layout();
    expect(
      paragraph.size.width,
      greaterThanOrEqualTo(natural.width - 0.5),
      reason: '标题被摘要挤窄、折成了多行',
    );
  });
}
