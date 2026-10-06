// BUG-2977：M3E 浮动页头的标题胶囊下半截被裁（底边一条直线、下圆角消失），
// 返回圆底部的投影被切平。
//
// 根因：FushiPageChromeCapsule 外层 minHeight 56 + 标题胶囊竖向 padding 6×2 +
// 内层又一层 minHeight 56 → 标题胶囊实高 68；而 FushiAppBar 的工具栏只有 56，
// AppBar 默认用 Clip.hardEdge 把工具栏裁在 56 里——多出的 12 被一刀切掉。
// 守住：胶囊恒为 kFushiPageChromeExtent、完整落在 AppBar 内、栏不裁投影。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';

void main() {
  Future<void> pumpBar(WidgetTester tester, Widget title) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          appBar: FushiAppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {},
            ),
            title: title,
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('BUG-2977 标题胶囊高 = kFushiPageChromeExtent 且完整落在顶栏内', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester, const Text('搜索字幕'));
    final Finder capsule = find.byType(FushiPageChromeTitle);
    expect(capsule, findsOneWidget);
    final Rect capsuleRect = tester.getRect(capsule);
    final Rect barRect = tester.getRect(find.byType(AppBar));
    expect(capsuleRect.height, kFushiPageChromeExtent);
    expect(capsuleRect.top, greaterThanOrEqualTo(barRect.top));
    expect(capsuleRect.bottom, lessThanOrEqualTo(barRect.bottom));

    final Finder circle = find.byType(FushiPageChromeCircle);
    expect(circle, findsOneWidget);
    expect(tester.getSize(circle), const Size.square(kFushiPageChromeExtent));
    expect(tester.getRect(circle).bottom, lessThanOrEqualTo(barRect.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('BUG-2977 调用方大行高 / 副标题都撑不高标题胶囊', (WidgetTester tester) async {
    await pumpBar(
      tester,
      const Text('作品资料', style: TextStyle(fontSize: 22, height: 2.4)),
    );
    expect(
      tester.getSize(find.byType(FushiPageChromeTitle)).height,
      kFushiPageChromeExtent,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: FushiPageChromeTitle(
              title: Text('统计中心'),
              subtitle: Text('副标题'),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(FushiPageChromeTitle)).height,
      kFushiPageChromeExtent,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('BUG-2977 悬浮顶栏不再把工具栏裁在 toolbarHeight 里（投影不被切平）', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester, const Text('自定义主题'));
    // 深度优先的第一个 ClipRect 就是 AppBar 包工具栏的那层。
    final ClipRect toolbarClip = tester
        .widgetList<ClipRect>(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byType(ClipRect),
          ),
        )
        .first;
    expect(toolbarClip.clipBehavior, Clip.none);
  });
}
