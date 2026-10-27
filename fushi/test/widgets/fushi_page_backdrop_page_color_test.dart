import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// 形状背景之上，整页底色必须透明：页面自己再铺一层 `surfaces.page` 实色，
/// 形状就被整片盖成白底（2026-10-25 设置页满屏白）。对话框 / 面板不在页面子树
/// 里，照旧拿实色页底。
void main() {
  testWidgets('page background is transparent only under an active backdrop', (
    WidgetTester tester,
  ) async {
    late Color inside;
    late Color outside;
    late Color expectedPage;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            outside = fushiPageBackgroundColor(context);
            expectedPage = FushiDesignTokens.of(context).surfaces.page;
            return FushiPageBackdrop(
              child: Builder(
                builder: (BuildContext context) {
                  inside = fushiPageBackgroundColor(context);
                  return const SizedBox.expand();
                },
              ),
            );
          },
        ),
      ),
    );

    expect(inside, Colors.transparent);
    expect(outside, expectedPage);
    expect(outside.a, 1);
  });

  testWidgets('FushiPageScaffold does not paint over the backdrop', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: FushiPageBackdrop(
          child: FushiPageScaffold(title: 'Settings', body: SizedBox.expand()),
        ),
      ),
    );

    final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, Colors.transparent);
  });
}
