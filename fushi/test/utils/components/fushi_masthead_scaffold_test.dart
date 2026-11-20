import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart'
    show FushiPageChromeCapsule, FushiPageChromeCircle, FushiPageChromeTitle;
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiPageHeader, FushiPageScaffold, FushiToolScaffold;
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadPanel, FushiMastheadTitleSize;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiAppBar;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
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
          FushiIconButtonControl(
            tooltip: 'Refresh',
            onPressed: () {},
            icon: const FushiIcon(FushiIcons.refresh),
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

  // 2026-11-20 用户截图「设置的字看着怪」：设置页名用二级字阶（52 / w700），
  // 库页仍是 84 / w900 大字。
  testWidgets('titleSize: section 的页名是 52 / w700，默认 page 仍是 84 / w900', (
    WidgetTester tester,
  ) async {
    Future<TextStyle?> titleStyleFor(FushiMastheadTitleSize size) async {
      await pumpHost(
        tester,
        Scaffold(
          body: FushiMastheadHeader(
            key: ValueKey<FushiMastheadTitleSize>(size),
            title: 'General',
            titleSize: size,
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

    final TextStyle? page = await titleStyleFor(FushiMastheadTitleSize.page);
    expect(page?.fontSize, 84);
    expect(page?.fontWeight, FontWeight.w900);
    final TextStyle? section = await titleStyleFor(
      FushiMastheadTitleSize.section,
    );
    expect(section?.fontSize, 52);
    expect(section?.fontWeight, FontWeight.w700);
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
            FushiIconButtonControl(
              tooltip: 'Save',
              onPressed: () {},
              icon: const FushiIcon(FushiIcons.refresh),
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
              FushiIconButtonControl(
                tooltip: 'Refresh',
                onPressed: () {},
                icon: const FushiIcon(FushiIcons.refresh),
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
