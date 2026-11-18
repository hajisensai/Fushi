import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:material_ui/material_ui.dart';

/// 页头大字钉在收起态（`FushiFloatingChromeOverlay(mastheadPinnedCollapsed:
/// true)`，首页手机）：
///
/// - 页名一开始就是收起态字号（与库页顶栏滚动折叠后完全一致），滚动不再变；
/// - 让给正文的顶部空间就是收起态高度——正文第一行紧贴收起后的页头，不空出
///   展开态与收起态之差那一截；
/// - 默认（false）行为不变：未滚动时是展开态大字、让位按展开态。
void main() {
  const Key firstItemKey = ValueKey<String>('first-item');
  const Key titleKey = ValueKey<String>('floating-chrome-shell-title');

  /// 手机竖屏（compact 档）。
  ///
  /// 改 [WidgetTester.view] 而不是 `binding.setSurfaceSize`：页头的 compact 判据
  /// （[fushiMastheadCompact]）读 `MediaQuery` 宽度，`setSurfaceSize` 只改渲染面、
  /// 不改 MediaQuery（仍是默认 800 宽 → 走宽窗 84 → 36 档），基线断言就对不上。
  Future<void> usePhoneSurface(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
  }

  Future<
    ({
      FushiFloatingChromeController chrome,
      ScrollController scroll,
      ValueNotifier<double> inset,
    })
  >
  pumpMasthead(WidgetTester tester, {required bool pinned}) async {
    final FushiFloatingChromeController chrome =
        FushiFloatingChromeController();
    final ScrollController scroll = ScrollController();
    final FushiShellActionsSlot slot = FushiShellActionsSlot();
    final ValueNotifier<double> inset = ValueNotifier<double>(-1);
    addTearDown(chrome.dispose);
    addTearDown(scroll.dispose);
    addTearDown(slot.dispose);
    addTearDown(inset.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FushiFloatingChromeScope(
            controller: chrome,
            child: FushiFloatingChromeOverlay(
              masthead: true,
              mastheadPinnedCollapsed: pinned,
              chrome: FushiShellTitleScope(
                title: '首页',
                actionsSlot: slot,
                child: FushiFloatingChromeBar(
                  tabs: const SizedBox.shrink(),
                  slot: slot,
                ),
              ),
              child: NotificationListener<ScrollNotification>(
                onNotification: chrome.handleScrollNotification,
                child: Builder(
                  builder: (BuildContext context) {
                    final double top = FushiFloatingChromeInset.of(context);
                    inset.value = top;
                    return ListView.builder(
                      controller: scroll,
                      padding: EdgeInsets.only(top: top),
                      itemCount: 40,
                      itemBuilder: (BuildContext context, int i) => SizedBox(
                        key: i == 0 ? firstItemKey : null,
                        height: 120,
                        child: Text('item $i'),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 几何帧末上报、让位帧末同步：泵到落定。
    await tester.pumpAndSettle();
    return (chrome: chrome, scroll: scroll, inset: inset);
  }

  /// 滚过收缩距离（手机 90）后把工具区拉回显示，页头底板才画得出来。
  Future<void> scrollPastCollapse(
    WidgetTester tester,
    FushiFloatingChromeController chrome,
    ScrollController scroll,
  ) async {
    scroll.jumpTo(120);
    await tester.pump();
    chrome.show();
    await tester.pumpAndSettle();
  }

  double panelHeight(WidgetTester tester) {
    final Finder panel = find.byWidgetPredicate(
      (Widget w) => w is FushiMastheadPanel && w.backdropBlur,
    );
    expect(panel, findsOneWidget);
    return tester.widget<FushiMastheadPanel>(panel).height;
  }

  double panelProgress(WidgetTester tester) {
    final Finder panel = find.byWidgetPredicate(
      (Widget w) => w is FushiMastheadPanel && w.backdropBlur,
    );
    expect(panel, findsOneWidget);
    return tester.widget<FushiMastheadPanel>(panel).progress;
  }

  testWidgets('钉在收起态：页名即收起态字号，正文顶部紧贴收起态高度', (WidgetTester tester) async {
    await usePhoneSurface(tester);

    // 基线：默认页头（展开态 → 滚动折叠）。
    final ({
      FushiFloatingChromeController chrome,
      ScrollController scroll,
      ValueNotifier<double> inset,
    })
    free = await pumpMasthead(tester, pinned: false);
    final Rect freeExpandedTitle = tester.getRect(find.byKey(titleKey));
    final double freeInset = free.inset.value;
    expect(
      tester.getTopLeft(find.byKey(firstItemKey)).dy,
      moreOrLessEquals(freeInset, epsilon: 0.01),
    );
    await scrollPastCollapse(tester, free.chrome, free.scroll);
    final Rect freeCollapsedTitle = tester.getRect(find.byKey(titleKey));
    final double freeCollapsedHeight = panelHeight(tester);
    expect(
      freeCollapsedTitle.height,
      moreOrLessEquals(freeExpandedTitle.height * 28 / 46, epsilon: 0.5),
      reason: '基线：手机页名滚动折叠 46 → 28',
    );
    expect(freeCollapsedHeight, lessThan(freeInset));

    // 钉在收起态。
    await tester.pumpWidget(const SizedBox.shrink());
    final ({
      FushiFloatingChromeController chrome,
      ScrollController scroll,
      ValueNotifier<double> inset,
    })
    pinned = await pumpMasthead(tester, pinned: true);
    final Rect pinnedTitle = tester.getRect(find.byKey(titleKey));
    expect(
      pinnedTitle.top,
      moreOrLessEquals(freeCollapsedTitle.top, epsilon: 0.01),
      reason: '未滚动就画在库页顶栏折叠后的位置',
    );
    expect(
      pinnedTitle.height,
      moreOrLessEquals(freeCollapsedTitle.height, epsilon: 0.01),
      reason: '未滚动就是折叠后的字号',
    );

    // 让位 = 收起态高度（= 默认页头折叠后实际画出的高度），正文不空一截。
    final double pinnedInset = pinned.inset.value;
    expect(pinnedInset, moreOrLessEquals(freeCollapsedHeight, epsilon: 0.5));
    expect(pinnedInset, lessThan(freeInset));
    expect(
      tester.getTopLeft(find.byKey(firstItemKey)).dy,
      moreOrLessEquals(pinnedInset, epsilon: 0.01),
      reason: '正文第一行紧贴收起态页头',
    );
    // 工具区可见时根层底板一定挂着（只是 progress 为 0 时不画），直接取唯一
    // 那块断言进度——不能用 `every`，找不到底板时它恒真。
    expect(panelProgress(tester), 0, reason: '未滚动不画页头底板（底板渐入仍只认真实滚动）');

    // 滚动后字号 / 位置不再变，底板高度就是让位高度（不再另收一截）。
    await scrollPastCollapse(tester, pinned.chrome, pinned.scroll);
    expect(tester.getRect(find.byKey(titleKey)), pinnedTitle);
    expect(panelProgress(tester), greaterThan(0), reason: '滚动后底板照常按真实滚动渐入');
    expect(panelHeight(tester), moreOrLessEquals(pinnedInset, epsilon: 0.5));
  });
}
