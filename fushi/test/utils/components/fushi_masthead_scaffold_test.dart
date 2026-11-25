import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart'
    show
        FushiPageChromeCapsule,
        FushiPageChromeCircle,
        FushiPageChromeTitle,
        FushiPinnedPageChromeScope;
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiPageHeader, FushiPageScaffold, FushiToolScaffold;
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadPanel;
import 'package:fushi/src/utils/components/fushi_page_title_metrics.dart'
    show FushiPageTitleTier;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiAppBar;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 二级页共享的页头大字外壳：正文让位与页头同一次布局定下（首帧不跳）、滚动中
/// 页名收缩不改让位、`titleInBody` 页头的页名按给定偏移淡入。
void main() {
  Future<void> pumpHost(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData(useMaterial3: true), home: home),
    );
  }

  testWidgets('首帧正文的顶部让位就等于页头下沿，之后不再变', (WidgetTester tester) async {
    final List<double> insets = <double>[];
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpHost(
      tester,
      FushiMastheadScaffold(
        title: 'Statistics',
        actions: <Widget>[
          FushiIconButton(
            tooltip: 'Refresh',
            onTap: () {},
            icon: FushiIcons.refresh,
          ),
        ],
        body: Builder(
          builder: (BuildContext context) {
            insets.add(MediaQuery.paddingOf(context).top);
            return ListView.builder(
              controller: controller,
              itemExtent: 80,
              itemCount: 60,
              itemBuilder: (BuildContext context, int i) => Text('row $i'),
            );
          },
        ),
      ),
    );
    // 只过了一帧：正文已经按页头实高让位，不是先只让状态栏、下一帧再下移。
    final double headerBottom = tester
        .getRect(find.byType(FushiMastheadHeader))
        .bottom;
    expect(insets, isNotEmpty);
    expect(insets.first, moreOrLessEquals(headerBottom));
    expect(headerBottom, greaterThan(0));

    await tester.pump(const Duration(milliseconds: 600));
    controller.jumpTo(200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // 页名收缩（页头变矮）但正文让位不跟着变：内容不跳。
    expect(
      tester.getRect(find.byType(FushiMastheadHeader)).bottom,
      lessThan(headerBottom),
    );
    expect(insets.toSet(), <double>{insets.first});
    // 滚到页头下面后垫底板。
    final FushiMastheadPanel panel = tester.widget(
      find.byType(FushiMastheadPanel),
    );
    expect(panel.progress, greaterThan(0));
  });

  // 反馈 ONNjqh7wxs / BUG-5409：牌组设置页宽窗两栏各自滚动，页头只认最后一条
  // 滚动通知，一栏在顶、另一栏已滚动时大字 / 小字来回跳。页头取两栏里滚得最远的。
  testWidgets('并排两栏各自滚动：页头按滚得最远的一栏收起，不在两栏之间来回跳', (WidgetTester tester) async {
    final ScrollController left = ScrollController();
    final ScrollController right = ScrollController();
    addTearDown(left.dispose);
    addTearDown(right.dispose);
    Widget pane(ScrollController controller, String tag) => ListView.builder(
      controller: controller,
      itemExtent: 80,
      itemCount: 60,
      itemBuilder: (BuildContext context, int i) => Text('$tag $i'),
    );
    await pumpHost(
      tester,
      FushiMastheadScaffold(
        title: 'Deck options',
        // SrsAdaptiveSections 宽窗两栏就是这样声明「并排各自滚动」的。
        body: FushiPinnedPageChromeScope(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: pane(left, 'left')),
              Expanded(child: pane(right, 'right')),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    double progress() => tester
        .widget<FushiMastheadHeader>(find.byType(FushiMastheadHeader))
        .progress;
    expect(progress(), 0);

    left.jumpTo(400);
    await tester.pump();
    final double collapsed = progress();
    expect(collapsed, greaterThan(0));

    // 另一栏轻轻一动（仍在顶部附近）：页头不因它弹回大字。
    right.jumpTo(4);
    await tester.pump();
    expect(progress(), collapsed);
    right.jumpTo(0);
    await tester.pump();
    expect(progress(), collapsed);

    // 左栏继续滚 / 右栏也滚下去：都保持收起。
    right.jumpTo(600);
    await tester.pump();
    expect(progress(), collapsed);

    // 左栏回到顶，右栏还压在页头下：仍收起。
    left.jumpTo(0);
    await tester.pump();
    expect(progress(), collapsed);

    // 两栏都回到顶才展开。
    right.jumpTo(0);
    await tester.pump();
    expect(progress(), 0);
  });

  // BUG-5409 审查：取最大值只对声明了「并排各自滚动」的两栏（
  // FushiPinnedPageChromeScope）成立。分页 / 换页（TabBarView、IndexedStack、
  // AnimatedSwitcher）里同一深度的几个列表是「换着显示」的，前一页滚下去的位置
  // 不能把刚换上、停在顶部的那一页的页头压成收起态。
  testWidgets('分页切到停在顶部的另一页：页头展开，不被前一页的滚动位置压住', (WidgetTester tester) async {
    final ScrollController first = ScrollController();
    final ScrollController second = ScrollController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final TabController tabs = TabController(
      length: 2,
      vsync: const TestVSync(),
    );
    addTearDown(tabs.dispose);
    Widget page(ScrollController controller, String tag) => ListView.builder(
      controller: controller,
      itemExtent: 80,
      itemCount: 60,
      itemBuilder: (BuildContext context, int i) => Text('$tag $i'),
    );
    await pumpHost(
      tester,
      FushiMastheadScaffold(
        title: 'Statistics',
        body: TabBarView(
          controller: tabs,
          children: <Widget>[page(first, 'first'), page(second, 'second')],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    double progress() => tester
        .widget<FushiMastheadHeader>(find.byType(FushiMastheadHeader))
        .progress;

    first.jumpTo(400);
    await tester.pump();
    expect(progress(), greaterThan(0));

    tabs.animateTo(1);
    await tester.pumpAndSettle();
    expect(second.offset, 0);
    expect(progress(), 0);
  });

  testWidgets('两栏收成一栏（窄窗）：页头跟这一栏走，不留两栏时的位置', (WidgetTester tester) async {
    final ScrollController left = ScrollController();
    final ScrollController right = ScrollController();
    final ScrollController single = ScrollController();
    addTearDown(left.dispose);
    addTearDown(right.dispose);
    addTearDown(single.dispose);
    final ValueNotifier<bool> wide = ValueNotifier<bool>(true);
    addTearDown(wide.dispose);
    Widget pane(ScrollController controller, String tag) => ListView.builder(
      controller: controller,
      itemExtent: 80,
      itemCount: 60,
      itemBuilder: (BuildContext context, int i) => Text('$tag $i'),
    );
    await pumpHost(
      tester,
      FushiMastheadScaffold(
        title: 'Deck options',
        body: ValueListenableBuilder<bool>(
          valueListenable: wide,
          builder: (BuildContext context, bool isWide, Widget? _) => isWide
              ? FushiPinnedPageChromeScope(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(child: pane(left, 'left')),
                      Expanded(child: pane(right, 'right')),
                    ],
                  ),
                )
              : pane(single, 'single'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    double progress() => tester
        .widget<FushiMastheadHeader>(find.byType(FushiMastheadHeader))
        .progress;

    left.jumpTo(400);
    await tester.pump();
    expect(progress(), greaterThan(0));

    wide.value = false;
    await tester.pumpAndSettle();
    expect(single.offset, 0);
    expect(progress(), 0);
  });

  // BUG-5409 复审：主深度要等第一次竖向滚动才定。栏里更深的竖向滚动区（多行
  // 输入框的内部滚动等）先动时会被当成一栏记下，主深度定到栏这一层后它的记录
  // 必须作废，否则它的内部偏移一直压着页头，两栏都回顶也展不开。
  testWidgets('并排两栏：栏里嵌套的竖向滚动区先动过，两栏回顶后页头照样展开', (WidgetTester tester) async {
    final ScrollController left = ScrollController();
    final ScrollController right = ScrollController();
    final ScrollController inner = ScrollController();
    addTearDown(left.dispose);
    addTearDown(right.dispose);
    addTearDown(inner.dispose);
    Widget rows(String tag) => Column(
      children: <Widget>[
        for (int i = 0; i < 60; i++)
          SizedBox(height: 80, child: Text('$tag $i')),
      ],
    );
    await pumpHost(
      tester,
      FushiMastheadScaffold(
        title: 'Deck options',
        body: FushiPinnedPageChromeScope(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: ListView(
                  controller: left,
                  children: <Widget>[
                    SizedBox(
                      height: 120,
                      child: ListView(
                        controller: inner,
                        children: <Widget>[rows('inner')],
                      ),
                    ),
                    rows('left'),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: right,
                  children: <Widget>[rows('right')],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    double progress() => tester
        .widget<FushiMastheadHeader>(find.byType(FushiMastheadHeader))
        .progress;
    expect(progress(), 0);

    // 页面上第一次竖向滚动发生在栏里的小框：主深度暂时落在它那一层。
    inner.jumpTo(300);
    await tester.pump();

    // 栏本身滚一下再回顶（小框仍挂着、内部仍停在 300）：页头回到大字。
    left.jumpTo(100);
    await tester.pump();
    expect(progress(), greaterThan(0));
    left.jumpTo(0);
    await tester.pump();
    expect(inner.offset, 300);
    expect(progress(), 0);

    // 之后再动小框也不驱动页头。
    inner.jumpTo(600);
    await tester.pump();
    expect(progress(), 0);
  });

  // 2026-11-20 用户截图「设置的字看着怪」：设置页名用二级字阶（52 / w700），
  // 库页仍是 84 / w900 大字。
  testWidgets('titleTier: section 的页名是 52 / w700，默认 page 仍是 84 / w900', (
    WidgetTester tester,
  ) async {
    Future<TextStyle?> titleStyleFor(FushiPageTitleTier size) async {
      await pumpHost(
        tester,
        Scaffold(
          body: FushiMastheadHeader(
            key: ValueKey<FushiPageTitleTier>(size),
            title: 'General',
            titleTier: size,
            progress: 0,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final RenderParagraph paragraph = tester.renderObject(
        find.text('General'),
      );
      return paragraph.text.style;
    }

    final TextStyle? page = await titleStyleFor(FushiPageTitleTier.page);
    expect(page?.fontSize, 84);
    expect(page?.fontWeight, FontWeight.w900);
    final TextStyle? section = await titleStyleFor(FushiPageTitleTier.section);
    expect(section?.fontSize, 52);
    expect(section?.fontWeight, FontWeight.w700);
  });

  /// 手机窄窗（380 宽）里挂一个带一颗动作的二级页头，返回页名的 RenderParagraph。
  Future<RenderParagraph> pumpPhoneHeader(
    WidgetTester tester,
    String title,
  ) async {
    tester.view.physicalSize = const Size(380, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: FushiMastheadScaffold(
          title: title,
          actions: <Widget>[
            FushiIconButton(
              tooltip: 'Search',
              onTap: () {},
              icon: FushiIcons.search,
            ),
          ],
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.renderObject(find.text(title));
  }

  testWidgets('手机窄窗：长页名先缩小到放得下，不省略成「Read…」', (WidgetTester tester) async {
    const String title = 'Reading';
    final RenderParagraph paragraph = await pumpPhoneHeader(tester, title);
    // 整个页名一行排得下（没被省略号截断）……
    expect(paragraph.maxLines, 1);
    expect(paragraph.didExceedMaxLines, isFalse);
    // ……是靠缩小字号，不是画出页头：缩放后的页名在屏幕内、比满字号窄。
    final Rect rect = tester.getRect(find.text(title));
    expect(rect.right, lessThanOrEqualTo(380));
    expect(rect.width, lessThan(paragraph.size.width));
  });

  testWidgets('手机窄窗：缩到收起态字号仍放不下的页名折成两行，不省略', (WidgetTester tester) async {
    const String title = 'Reading controls';
    final RenderParagraph paragraph = await pumpPhoneHeader(tester, title);
    final double fontSize = paragraph.text.style!.fontSize!;
    // 两行、完整排下（词不拆开、没有省略号）。
    expect(paragraph.maxLines, 2);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(paragraph.size.height, greaterThan(1.5 * fontSize * 0.98));
    // 缩放后仍在屏幕内。
    expect(tester.getRect(find.text(title)).right, lessThanOrEqualTo(380));
  });

  // 裸图标行行高固定 48，装不下两行：长专辑名 / 曲名必须仍是收起态字号一行、
  // 末尾省略，不能折成两行画到行外、压住正文顶部的大标题。
  testWidgets('titleInBody 裸图标行：长页名一行省略，不折两行、不超出行高', (
    WidgetTester tester,
  ) async {
    const String title =
        'Symphony No. 9 in D minor Op. 125 Choral Complete Recording';
    tester.view.physicalSize = const Size(380, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: FushiMastheadHeader(
              title: title,
              progress: 1,
              titleInBody: true,
              onBack: () {},
              actions: <Widget>[
                FushiIconButton(
                  tooltip: 'More',
                  onTap: () {},
                  icon: FushiIcons.search,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final RenderParagraph paragraph = tester.renderObject(find.text(title));
    expect(paragraph.maxLines, 1);
    expect(paragraph.didExceedMaxLines, isTrue);
    final Rect header = tester.getRect(find.byType(FushiMastheadHeader));
    final Rect text = tester.getRect(find.text(title));
    expect(header.height, kFushiMastheadBareRowExtent);
    expect(text.height, lessThanOrEqualTo(kFushiMastheadBareRowExtent));
    expect(text.top, greaterThanOrEqualTo(header.top));
    expect(text.bottom, lessThanOrEqualTo(header.bottom));
  });

  testWidgets('titleInBody：页名在主滚动越过 titleRevealOffset 后才淡入', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    final ValueNotifier<double> reveal = ValueNotifier<double>(300);
    addTearDown(controller.dispose);
    addTearDown(reveal.dispose);
    await pumpHost(
      tester,
      Scaffold(
        body: FushiMastheadFrame(
          title: 'Work title',
          titleInBody: true,
          titleRevealOffset: reveal,
          body: ListView.builder(
            controller: controller,
            itemExtent: 80,
            itemCount: 60,
            itemBuilder: (BuildContext context, int i) => Text('row $i'),
          ),
        ),
      ),
    );
    double titleOpacity() => tester
        .widget<Opacity>(
          find
              .ancestor(
                of: find.text('Work title'),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    // 裸图标页头一行高。
    expect(
      tester.getSize(find.byType(FushiMastheadHeader)).height,
      kFushiMastheadBareRowExtent,
    );
    expect(titleOpacity(), 0);
    controller.jumpTo(200);
    await tester.pump();
    expect(titleOpacity(), 0);
    controller.jumpTo(400);
    await tester.pump();
    expect(titleOpacity(), 1);
  });

  // 2026-11-15 所有者「二级页还是胶囊」：旧胶囊（返回圆钮 + 标题胶囊）是共用
  // 脚手架画的。二级页统一成现行页头——FushiPageScaffold 默认（不带自定义
  // header）、FushiToolScaffold、FushiAppBar 的 M3E 分支都不再画胶囊。
  group('二级页共用脚手架统一现行页头', () {
    Widget pushedFrom(Widget page) => Builder(
      builder: (BuildContext context) => Center(
        child: TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => page)),
          child: const Text('open'),
        ),
      ),
    );

    Future<void> openPushed(WidgetTester tester, Widget page) async {
      await pumpHost(tester, pushedFrom(page));
      await tester.pump();
      // 焦点驱动：自动聚焦的入口按钮，Enter 推入二级页。
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    void expectNoCapsules() {
      expect(find.byType(FushiPageChromeTitle), findsNothing);
      expect(find.byType(FushiPageChromeCircle), findsNothing);
      expect(find.byType(FushiPageChromeCapsule), findsNothing);
    }

    testWidgets('FushiPageScaffold 默认（无 header）走页头大字，副标题照画', (
      WidgetTester tester,
    ) async {
      await openPushed(
        tester,
        FushiPageScaffold(
          title: 'Feedback',
          subtitle: 'Profile: default',
          body: ListView(
            children: const <Widget>[SizedBox(height: 40, child: Text('row'))],
          ),
        ),
      );
      expect(find.byType(FushiMastheadHeader), findsOneWidget);
      expect(find.byType(FushiPageHeader), findsNothing);
      expectNoCapsules();
      expect(
        find.descendant(
          of: find.byType(FushiMastheadHeader),
          matching: find.text('Feedback'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(FushiMastheadHeader),
          matching: find.text('Profile: default'),
        ),
        findsOneWidget,
      );
      // 推入的二级页有返回键（页头大字口径的裸图标按钮）。
      expect(
        find.descendant(
          of: find.byType(FushiMastheadHeader),
          matching: find.byTooltip('Back'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('revealTitleAfterScroll 映射为 titleInBody + 偏移淡入', (
      WidgetTester tester,
    ) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await pumpHost(
        tester,
        FushiPageScaffold(
          title: 'Work title',
          revealTitleAfterScroll: 300,
          body: ListView.builder(
            controller: controller,
            itemExtent: 80,
            itemCount: 60,
            itemBuilder: (BuildContext context, int i) => Text('row $i'),
          ),
        ),
      );
      double titleOpacity() => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.text('Work title'),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      expect(
        tester.getSize(find.byType(FushiMastheadHeader)).height,
        kFushiMastheadBareRowExtent,
      );
      expect(titleOpacity(), 0);
      controller.jumpTo(400);
      await tester.pump();
      expect(titleOpacity(), 1);
    });

    testWidgets('自定义 header / 显式 masthead: false 照旧走原页头', (
      WidgetTester tester,
    ) async {
      await pumpHost(
        tester,
        const FushiPageScaffold(
          title: 'Custom',
          header: Text('custom header'),
          body: SizedBox.expand(),
        ),
      );
      expect(find.byType(FushiMastheadHeader), findsNothing);
      expect(find.text('custom header'), findsOneWidget);

      await pumpHost(
        tester,
        const FushiPageScaffold(
          title: 'Opt out',
          masthead: false,
          body: SizedBox.expand(),
        ),
      );
      expect(find.byType(FushiMastheadHeader), findsNothing);
      expect(find.byType(FushiPageHeader), findsOneWidget);
    });

    testWidgets('FushiToolScaffold 走页头大字，正文排在页头下沿以下', (
      WidgetTester tester,
    ) async {
      final GlobalKey bodyKey = GlobalKey();
      await openPushed(
        tester,
        FushiToolScaffold(
          title: 'CSS editor',
          actions: <Widget>[
            FushiIconButton(
              tooltip: 'Save',
              onTap: () {},
              icon: FushiIcons.refresh,
            ),
          ],
          body: SizedBox.expand(key: bodyKey),
        ),
      );
      expect(find.byType(FushiMastheadHeader), findsOneWidget);
      expectNoCapsules();
      expect(find.byTooltip('Save'), findsOneWidget);
      expect(
        tester.getRect(find.byKey(bodyKey)).top,
        greaterThanOrEqualTo(
          tester.getRect(find.byType(FushiMastheadHeader)).bottom - 0.5,
        ),
      );
    });

    testWidgets('FushiAppBar（M3E）是页头大字一行：无胶囊、页名与动作在栏内', (
      WidgetTester tester,
    ) async {
      await openPushed(
        tester,
        Scaffold(
          appBar: FushiAppBar(
            title: const Text('Search resources'),
            actions: <Widget>[
              FushiIconButton(
                tooltip: 'Refresh',
                onTap: () {},
                icon: FushiIcons.refresh,
              ),
            ],
          ),
          body: const SizedBox.expand(),
        ),
      );
      expect(tester.takeException(), isNull);
      expectNoCapsules();
      final Rect bar = tester.getRect(find.byType(AppBar));
      final Rect title = tester.getRect(find.text('Search resources'));
      expect(title.top, greaterThanOrEqualTo(bar.top));
      expect(title.bottom, lessThanOrEqualTo(bar.bottom));
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byTooltip('Refresh'), findsOneWidget);
      // 页名取页头大字（粗体收起字号），不再是 titleLarge 胶囊标题。
      final RenderParagraph paragraph = tester.renderObject(
        find.text('Search resources'),
      );
      expect(paragraph.text.style?.fontWeight, FontWeight.w900);
    });
  });
}
