import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/library_section_tabs.dart';

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
}
