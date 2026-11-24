import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_catalog_section.dart'
    show mangaAddSourceHint;
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_shelf.dart';
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_source_block.dart';
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_widgets.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_source_block.dart';
import 'package:fushi/src/platform/host_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

/// 「浏览」页 Cupertino 重设计（2026-11-24 用户拍板：窄屏大标题菜单「发现 ⌄」、
/// 宽屏横滑货架）：
/// - 外壳分派：`isGlassDesign` 才走 Apple 外壳，M3E 原样（源码形态守卫——真
///   BrowsePage 一挂就要 Mihon / LNReader manager 与数据库目录，见
///   browse_handoff_shared_domain_test 的说明）；
/// - 来源块 / glyph：Apple 下中性卡、无按源取色；M3E 原样；
/// - 第三层筛选是 pull-down（菜单选值回调）；
/// - 宽屏货架可横滑；
/// - 来源行焦点 + Enter 触发；
/// - iOS 合规：「添加来源」引导走 [StoreRestrictedCapability]。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    required bool glass,
    TargetPlatform platform = TargetPlatform.iOS,
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glassDesign: glass,
          ).copyWith(platform: platform),
          home: FushiGlassScope(child: Scaffold(body: child)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  group('外壳分派（源码形态）', () {
    final String page = File(
      'lib/src/pages/implementations/browse_page.dart',
    ).readAsStringSync();
    final String apple = File(
      'lib/src/pages/implementations/browse/apple/apple_browse_layout.part.dart',
    ).readAsStringSync();

    test('build 先按 isGlassDesign 分派到 Apple 外壳，M3E 一级页签照旧', () {
      final int dispatch = page.indexOf(
        'if (isGlassDesign(context)) return _buildApple(tabs, controller);',
      );
      expect(dispatch, greaterThan(0));
      expect(
        page,
        contains("part 'browse/apple/apple_browse_layout.part.dart';"),
      );
      // M3E 的一级胶囊页签与 Scaffold 接线仍在主文件、在分派之后。
      expect(
        page.indexOf('LibrarySectionTabs<BrowseTab>.controlled'),
        greaterThan(dispatch),
      );
      expect(page, contains('resizeToAvoidBottomInset: !onDownloads'));
    });

    test('窄屏大标题菜单切一级；宽窗一级进侧栏；macOS 档交叉淡入', () {
      expect(apple, contains('AppleLibraryTitleMenu('));
      expect(apple, contains('_appleSelectTab(controller, i)'));
      expect(apple, contains('appleSidebarHostsLibrarySections('));
      expect(apple, contains('host?.publish('));
      expect(apple, contains('_AppleBrowseFadeStack<BrowseTab>('));
      // iOS 档二级横滑保留越界接力（同 M3E 的 _handOffFrom）。
      expect(apple, contains('_handOffFrom(BrowseTab.discover, delta)'));
      // 二级分段只走设计系统组件，不出裸 SegmentedButton / Material chip。
      expect(apple, contains('adaptiveSegmentedButton<Object>('));
      expect(apple, isNot(contains(RegExp(r'SegmentedButton<'))));
      expect(apple, isNot(contains('FushiSelectableChip')));
    });

    test('Apple 画法文件不出现 Material 混搭与平台硬判', () {
      final List<String> files = <String>[
        'lib/src/pages/implementations/browse/apple/apple_browse_layout.part.dart',
        'lib/src/pages/implementations/discovery/apple/apple_media_discovery.part.dart',
        'lib/src/pages/implementations/discovery/apple/apple_video_discovery.part.dart',
        'lib/src/media/manga/discovery/apple/apple_manga_discovery.part.dart',
        'lib/src/pages/implementations/discovery/apple/apple_discovery_widgets.dart',
        'lib/src/pages/implementations/discovery/apple/apple_discovery_shelf.dart',
        'lib/src/pages/implementations/discovery/apple/apple_discovery_source_block.dart',
        'lib/src/pages/implementations/discovery/apple/apple_discovery_header.dart',
      ];
      for (final String path in files) {
        final String src = File(path).readAsStringSync();
        expect(src, isNot(contains('FushiSelectableChip(')), reason: path);
        expect(
          src,
          isNot(contains(RegExp(r'(?<!Fushi)PopupMenuItem<'))),
          reason: path,
        );
        expect(src, isNot(contains('Platform.isIOS')), reason: path);
        expect(src, isNot(contains('discoverySourceColors')), reason: path);
      }
    });
  });

  group('来源块 / glyph', () {
    Widget block() => DiscoverySourceBlock(
      sourceId: 'src-a',
      name: 'Source A',
      chips: const <String>['EN', 'Preset'],
      onTap: () {},
    );

    testWidgets('Apple 下来源块是中性卡（无按源取色块），能力降为副行', (WidgetTester tester) async {
      await pump(tester, Center(child: block()), glass: true);
      expect(find.byType(AppleDiscoverySourceCard), findsOneWidget);
      expect(find.byType(AppleDiscoverySourceGlyph), findsOneWidget);
      expect(find.text('EN · Preset'), findsOneWidget);
    });

    testWidgets('M3E 下来源块原样', (WidgetTester tester) async {
      await pump(tester, Center(child: block()), glass: false);
      expect(find.byType(AppleDiscoverySourceCard), findsNothing);
      expect(find.byType(AppleDiscoverySourceGlyph), findsNothing);
      expect(find.text('Source A'), findsOneWidget);
    });
  });

  testWidgets('来源行：焦点 + Enter 触发（手柄 / 键盘可达）', (WidgetTester tester) async {
    int taps = 0;
    await pump(
      tester,
      ListView(
        children: <Widget>[
          AppleDiscoverySourceRow(
            name: 'Source A',
            caption: 'EN',
            onTap: () => taps++,
          ),
        ],
      ),
      glass: true,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 500));
    expect(taps, 1);
  });

  testWidgets('第三层筛选是 pull-down：显示当前值，选菜单项回调新值', (WidgetTester tester) async {
    String selected = 'Novel';
    await pump(
      tester,
      Center(
        child: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) =>
              AppleDiscoveryPullDown<String>(
                keyPrefix: 'kind',
                values: const <String>['Novel', 'Audiobook'],
                selected: selected,
                labelOf: (String v) => v,
                onSelected: (String v) => setState(() => selected = v),
              ),
        ),
      ),
      glass: true,
    );
    expect(find.text('Novel'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('kind-pull-down')));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey<String>('kind_1')));
    await tester.pump(const Duration(seconds: 1));
    expect(selected, 'Audiobook');
    expect(find.text('Audiobook'), findsOneWidget);
  });

  testWidgets('宽屏货架（macOS 档）可横滑，悬停箭头包在货架外', (WidgetTester tester) async {
    await pump(
      tester,
      Align(
        alignment: Alignment.topCenter,
        child: AppleDiscoveryLockupStrip(
          horizontalInset: 24,
          children: <Widget>[
            for (int i = 0; i < 12; i++)
              AppleDiscoveryLockup(
                key: ValueKey<String>('lockup-$i'),
                name: 'Source $i',
                caption: 'EN',
                actionLabel: 'Browse',
                onTap: () {},
              ),
          ],
        ),
      ),
      glass: true,
      platform: TargetPlatform.macOS,
      size: const Size(1000, 700),
    );
    expect(find.byType(AppleShelfHoverArrows), findsOneWidget);
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(scrollable.position.axis, Axis.horizontal);
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    await tester.drag(find.byType(Scrollable).first, const Offset(-400, 0));
    await tester.pump(const Duration(seconds: 1));
    expect(scrollable.position.pixels, greaterThan(0));
  });

  group('iOS 合规：添加来源引导走 StoreRestrictedCapability', () {
    tearDown(() => debugHostPlatformOverride = null);

    test('iOS 不引导去装扩展，改为连接自己的服务器', () {
      debugHostPlatformOverride = HostPlatform.ios;
      expect(mangaAddSourceHint(), t.discovery_source_add_hint_server);
    });

    test('其它平台引导去「扩展」装源', () {
      debugHostPlatformOverride = HostPlatform.android;
      expect(mangaAddSourceHint(), t.discovery_source_add_hint_extensions);
    });

    test('书 / 游戏发现的 Apple 引导同口径', () {
      final String src = File(
        'lib/src/pages/implementations/discovery/apple/apple_media_discovery.part.dart',
      ).readAsStringSync();
      expect(
        src,
        contains('StoreRestrictedCapability.externalDiscovery.isAvailable'),
      );
    });
  });
}
