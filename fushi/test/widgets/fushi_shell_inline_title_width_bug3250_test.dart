import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-3250：宽窗库页工具栏行里的外壳标题胶囊（[FushiShellInlineTitle]）在 Row
/// 里不限宽，长页面名按自然宽把页签胶囊挤没、整行溢出。
void main() {
  testWidgets('长页面名：标题胶囊限宽省略，页签保有宽度，不溢出', (WidgetTester tester) async {
    final FushiShellActionsSlot slot = FushiShellActionsSlot();
    addTearDown(slot.dispose);
    const double rowWidth = 720;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: rowWidth,
              child: FushiShellTitleScope(
                title: '一个非常非常长的页面名称' * 6,
                child: FushiShellInlineTitle(
                  enabled: true,
                  child: FushiFloatingChromeBar(
                    padding: EdgeInsets.zero,
                    tabs: const SizedBox(
                      key: ValueKey<String>('tabs'),
                      height: 40,
                    ),
                    slot: slot,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull, reason: '长标题不得撑爆整行');
    final double titleWidth = tester
        .getSize(
          find.byKey(const ValueKey<String>('floating-chrome-shell-title')),
        )
        .width;
    expect(titleWidth, lessThanOrEqualTo(rowWidth / 3 + 0.01));
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('tabs'))).width,
      greaterThan(rowWidth / 3),
      reason: '页签胶囊要保有剩余宽度',
    );
  });
}
