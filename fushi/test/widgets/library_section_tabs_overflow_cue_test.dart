import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/library_section_tabs.dart';
import '../helpers/glass_unwrap.dart';

const Key _leadingCue = ValueKey<String>(
  'library-section-tabs-leading-overflow-cue',
);
const Key _trailingCue = ValueKey<String>(
  'library-section-tabs-trailing-overflow-cue',
);

void main() {
  testWidgets('BUG-1971 overflow cues follow the visible tab range', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(260, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: FushiSectionTabBar<int>(
                tabs: const <LibrarySectionTab<int>>[
                  LibrarySectionTab<int>(value: 0, label: '首页'),
                  LibrarySectionTab<int>(value: 1, label: '系列'),
                  LibrarySectionTab<int>(value: 2, label: '全部视频'),
                  LibrarySectionTab<int>(value: 3, label: '发现'),
                  LibrarySectionTab<int>(value: 4, label: '来源'),
                  LibrarySectionTab<int>(value: 5, label: '设置'),
                ],
                selected: 0,
                onChanged: (_) {},
                // 2026-10-04 起 fill 默认 true（铺满 → 收紧 → 「更多」三档）；
                // 两侧渐隐只属于 fill: false 的可滚动形态，这里显式钉住它。
                fill: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(_leadingCue),
      findsNothing,
      reason: '起点左侧没有离屏 tab，不应画假提示',
    );
    expect(
      find.byKey(_trailingCue),
      findsOneWidget,
      reason: '窄视口隐藏了后续 tab，右缘必须提示还能横向滚动',
    );

    await tester.drag(find.byType(TabBar), const Offset(-120, 0));
    await tester.pumpAndSettle();

    expect(
      find.byKey(_leadingCue),
      findsOneWidget,
      reason: '向右浏览后，左缘应提示前面还有 tab',
    );
    expect(find.byKey(_trailingCue), findsOneWidget, reason: '未到末尾时两侧都还有内容');

    await tester.drag(find.byType(TabBar), const Offset(-1000, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(_leadingCue), findsOneWidget);
    expect(find.byKey(_trailingCue), findsNothing, reason: '到达末尾后右缘提示必须消失');
  });

  Future<void> pumpFillTabs(
    WidgetTester tester, {
    required double width,
    required List<String> labels,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 180));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: FushiSectionTabBar<int>(
                tabs: <LibrarySectionTab<int>>[
                  for (int i = 0; i < labels.length; i++)
                    LibrarySectionTab<int>(value: i, label: labels[i]),
                ],
                selected: 0,
                onChanged: (_) {},
                secondary: true,
                fill: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('fill 判据按最宽段：长短文案混排总宽够也不许铺满截字', (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const String long = 'Einstellungen für Downloads';
    // 各段自然宽之和摆得进 480，但 fill 每段只分到 480 / 3 = 160，长段会被截断渐隐。
    await pumpFillTabs(tester, width: 480, labels: <String>['小说', '漫画', long]);

    expect(
      tester.widget<TabBar>(glassUnwrap<TabBar>(find.byType(TabBar))).isScrollable,
      isTrue,
      reason: '最宽段放不进等分格时必须退回可滚动形态',
    );
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      find.text(long),
    );
    expect(
      paragraph.size.width,
      greaterThanOrEqualTo(
        paragraph.getMaxIntrinsicWidth(double.infinity) - 0.5,
      ),
      reason: '长段文字必须完整排下，不能被截',
    );
    expect(tester.takeException(), isNull);
  });

  // 2026-10-04 起 fill 形态窄窗不再横滑截断，而是「前 N 段 + 末尾『更多』下拉」：
  // 离屏段的提示由「更多」按钮承担，渐隐不再出现；窄 ↔ 宽来回切换时既不能残留
  // 渐隐盖在最后一段上，也不能丢掉「更多」入口。
  testWidgets('先窄出「更多」溢出入口、再放宽进入 fill 后渐隐与入口都必须消失', (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const List<String> labels = <String>['首页', '系列', '全部视频', '发现', '来源', '设置'];
    final Finder moreButton = find.byIcon(Icons.expand_more);

    await pumpFillTabs(tester, width: 240, labels: labels);
    expect(moreButton, findsOneWidget, reason: '窄窗溢出时末尾应有「更多」入口提示后续段');
    expect(find.byKey(_leadingCue), findsNothing);
    expect(find.byKey(_trailingCue), findsNothing, reason: '溢出档的提示是「更多」入口，不叠渐隐');

    await pumpFillTabs(tester, width: 1200, labels: labels);
    expect(tester.widget<TabBar>(glassUnwrap<TabBar>(find.byType(TabBar))).isScrollable, isFalse);
    expect(find.byKey(_leadingCue), findsNothing);
    expect(
      find.byKey(_trailingCue),
      findsNothing,
      reason: '铺满形态没有离屏内容，残留渐隐会盖在最后一段上',
    );
    expect(moreButton, findsNothing, reason: '铺满形态全部段可见，不需要「更多」');

    // 再窄回去：「更多」入口重新出现。
    await pumpFillTabs(tester, width: 240, labels: labels);
    expect(moreButton, findsOneWidget);
    expect(find.byKey(_trailingCue), findsNothing);
  });
}
