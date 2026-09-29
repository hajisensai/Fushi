// 首页各模块 × 墨水屏模式（eink）的行为守卫。
//
// 主题层早就把 ColorScheme 塌成纯黑白（`buildEinkColorScheme`）：所有 surface
// container 等于页面底色、所有强调色等于前景色。但首页的组件层此前零处读 eink——
// 靠「container 色差」表达的东西（分区卡、底栏 / 侧栏、迷你条、选中药丸、进度条
// 轨道）全部消失，靠 alpha 叠层表达的东西（热力图深浅、标签 chip、拖放罩、封面
// 进度条轨道）全部变成抖动灰，不定态进度条与淡入动画则是持续局部刷新的残影。
//
// 这里每条都把 `FushiEinkTheme(true)` 塞进 ThemeData 走产品代码真正的 eink 分支，
// 断言的是渲染出来的颜色 / 边 / 时长，而不是「代码里出现了 isEinkTheme」；只有
// 页面级（需要 AppModel）的几处退化成源码守卫。
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/sync/remote_download_progress_badge.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/library_section_tabs.dart';
import 'package:fushi_core/fushi_core.dart';

/// 最小 eink 主题：白底黑字的纯黑白 scheme + 扩展标志，与产品 `_buildThemeData`
/// 的 eink 分支同源（这里只需要颜色角色塌缩这一层）。
ThemeData _einkTheme() => ThemeData(
  colorScheme: buildEinkColorScheme(Brightness.light),
  extensions: const <ThemeExtension<dynamic>>[FushiEinkTheme(true)],
);

Widget _wrap(Widget child, {bool eink = true}) => MaterialApp(
  theme: eink ? _einkTheme() : ThemeData(),
  home: FushiFocusRoot(child: Scaffold(body: child)),
);

void main() {
  group('主题层', () {
    late FushiDatabase db;
    late ThemeNotifier notifier;

    setUp(() {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      notifier = ThemeNotifier(db, () => const TextTheme());
      notifier.loadFromPrefsSnapshot(<String, String>{
        'eink_mode': PrefCodec.encode(true),
      });
    });

    tearDown(() async {
      notifier.dispose();
      await db.close();
    });

    test('hover / highlight 叠层归零：NoSplash 之外的两层 alpha 灰也不画', () {
      final ThemeData theme = notifier.theme;
      expect(theme.hoverColor, Colors.transparent);
      expect(theme.highlightColor, Colors.transparent);
    });

    test('tonal 按钮与 FAB 有描边：填充色塌成底色后靠边把按钮体画回来', () {
      final ThemeData theme = notifier.theme;
      final BorderSide? buttonSide = theme.filledButtonTheme.style?.side
          ?.resolve(<WidgetState>{});
      expect(buttonSide, isNotNull);
      expect(buttonSide!.style, BorderStyle.solid);
      expect(buttonSide.color, theme.colorScheme.outline);

      final ShapeBorder? fabShape = theme.floatingActionButtonTheme.shape;
      expect(fabShape, isA<RoundedRectangleBorder>());
      expect(
        (fabShape! as RoundedRectangleBorder).side.style,
        BorderStyle.solid,
      );
    });
  });

  testWidgets('einkSafeProgressValue：eink 下不定态钉成 0，确定值原样', (
    WidgetTester tester,
  ) async {
    late BuildContext einkContext;
    late BuildContext plainContext;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (BuildContext context) {
            einkContext = context;
            return Theme(
              data: ThemeData(),
              child: Builder(
                builder: (BuildContext inner) {
                  plainContext = inner;
                  return const SizedBox.shrink();
                },
              ),
            );
          },
        ),
      ),
    );
    expect(einkSafeProgressValue(einkContext, null), 0);
    expect(einkSafeProgressValue(einkContext, 0.4), 0.4);
    expect(einkSafeProgressValue(plainContext, null), isNull);
    expect(einkSafeProgressValue(plainContext, 0.4), 0.4);
  });

  group('自绘导航', () {
    const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
      AdaptiveNavItem(
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: '首页',
      ),
      AdaptiveNavItem(icon: Icons.search, label: '词典'),
    ];

    Container selectedPill(WidgetTester tester) {
      // 选中项的药丸：那个 64×32、带 BoxDecoration 的 Container。
      return tester.widget<Container>(
        find
            .ancestor(
              of: find.byIcon(Icons.home),
              matching: find.byWidgetPredicate(
                (Widget w) => w is Container && w.decoration is BoxDecoration,
              ),
            )
            .first,
      );
    }

    testWidgets('底栏选中药丸反色：底色前景、图标底色', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (BuildContext context) => adaptiveBottomBar(
              context: context,
              currentIndex: 0,
              onTap: (_) {},
              items: items,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final ColorScheme colors = buildEinkColorScheme(Brightness.light);
      final BoxDecoration pill =
          selectedPill(tester).decoration! as BoxDecoration;
      expect(pill.color, colors.onSurface, reason: '药丸必须是实心前景色');
      expect(
        tester.widget<Icon>(find.byIcon(Icons.home)).color,
        colors.surface,
        reason: '反色药丸里的图标用底色',
      );

      // 底栏本体与内容面之间要有一条前景色边线。
      final Material bar = tester.widget<Material>(
        find.byKey(fushiMaterialNavKey),
      );
      expect(bar.shape, isA<Border>());
      expect((bar.shape! as Border).top.color, colors.outline);
    });

    testWidgets('侧栏尾侧描边', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          Row(
            children: <Widget>[
              Builder(
                builder: (BuildContext context) => adaptiveNavRail(
                  context: context,
                  currentIndex: 0,
                  onTap: (_) {},
                  items: items,
                ),
              ),
              const Expanded(child: SizedBox.expand()),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Material rail = tester.widget<Material>(
        find.byKey(fushiMaterialNavKey),
      );
      expect(rail.shape, isA<BorderDirectional>());
      expect(
        (rail.shape! as BorderDirectional).end.color,
        buildEinkColorScheme(Brightness.light).outline,
      );
    });

    testWidgets('非 eink 主题原样：secondaryContainer 药丸、无边线', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (BuildContext context) => adaptiveBottomBar(
              context: context,
              currentIndex: 0,
              onTap: (_) {},
              items: items,
            ),
          ),
          eink: false,
        ),
      );
      await tester.pumpAndSettle();
      final BoxDecoration pill =
          selectedPill(tester).decoration! as BoxDecoration;
      expect(pill.color, ThemeData().colorScheme.secondaryContainer);
      expect(
        tester.widget<Material>(find.byKey(fushiMaterialNavKey)).shape,
        isNull,
      );
    });
  });

  group('FushiTagChip surface 色调', () {
    BoxDecoration chipDecoration(WidgetTester tester) {
      return tester
              .widget<AnimatedContainer>(find.byType(AnimatedContainer))
              .decoration!
          as BoxDecoration;
    }

    testWidgets('未选中：实心底色 + 描边，不再是 overlay 塌成的隐形药丸', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const FushiTagChip(label: '下载中', tone: FushiTagChipTone.surface)),
      );
      final BoxDecoration d = chipDecoration(tester);
      final ColorScheme colors = buildEinkColorScheme(Brightness.light);
      expect(d.color, colors.surface);
      expect(d.color!.a, 1.0, reason: '零 alpha 叠层');
      expect(d.border, isNotNull);
      expect((d.border! as Border).top.color, colors.outline);
    });

    testWidgets('选中：反色填充，文字用底色', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          const FushiTagChip(
            label: '失败',
            tone: FushiTagChipTone.surface,
            selected: true,
          ),
        ),
      );
      final BoxDecoration d = chipDecoration(tester);
      final ColorScheme colors = buildEinkColorScheme(Brightness.light);
      expect(d.color, colors.onSurface);
      expect(tester.widget<Text>(find.text('失败')).style?.color, colors.surface);
      expect(
        tester
            .widget<AnimatedContainer>(find.byType(AnimatedContainer))
            .duration,
        Duration.zero,
        reason: '状态切换不补间',
      );
    });

    testWidgets('dimmed 不走 40% alpha 文字', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          const FushiTagChip(
            label: '已完成',
            tone: FushiTagChipTone.surface,
            dimmed: true,
          ),
        ),
      );
      expect(tester.widget<Text>(find.text('已完成')).style?.color?.a, 1.0);
    });
  });

  group('不定态进度', () {
    testWidgets('adaptiveIndicator：eink 沙漏在 tight 小容器里随容器缩、不被裁', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (BuildContext context) => Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: adaptiveIndicator(context: context),
              ),
            ),
          ),
        ),
      );
      final Finder icon = find.byIcon(Icons.hourglass_top);
      expect(icon, findsOneWidget);
      // 字形本身仍是默认 24（布局尺寸），靠 FittedBox 的缩放变换落进容器：
      // 全局矩形 ≤ 16×16 且整个在容器内，不再被裁。
      expect(tester.getSize(icon), const Size(24, 24));
      final Rect box = tester.getRect(find.byType(FittedBox));
      expect(box.size, const Size(16, 16));
      final Rect glyph = tester.getRect(icon);
      expect(glyph.width, lessThanOrEqualTo(16.0));
      expect(box.contains(glyph.topLeft), isTrue);
      expect(
        box.contains(glyph.bottomRight - const Offset(0.01, 0.01)),
        isTrue,
      );
    });

    testWidgets('adaptiveIndicator：eink 下不定态是静止沙漏，确定值照画环', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (BuildContext context) => Row(
              children: <Widget>[
                adaptiveIndicator(context: context),
                adaptiveIndicator(context: context, value: 0.5),
              ],
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        0.5,
      );
    });

    testWidgets('远端下载角标：首个进度回报前不转圈、圆盘有边', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          const Row(
            children: <Widget>[
              RemoteDownloadProgressBadge(progress: null, tooltip: '下载中'),
              RemoteDownloadFailedBadge(tooltip: '失败'),
            ],
          ),
        ),
      );
      final CircularProgressIndicator ring = tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          );
      expect(ring.value, 0, reason: 'null = 无限转圈，eink 下钉成 0');
      final List<Container> discs = tester
          .widgetList<Container>(find.byType(Container))
          .toList();
      final Iterable<Container> bordered = discs.where(
        (Container c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).border != null,
      );
      expect(bordered.length, 2, reason: '进度盘与失败盘各描一圈边');
    });
  });

  group('分区 tab 条', () {
    const List<LibrarySectionTab<int>> tabs = <LibrarySectionTab<int>>[
      LibrarySectionTab<int>(value: 0, label: '首页'),
      LibrarySectionTab<int>(value: 1, label: '系列'),
      LibrarySectionTab<int>(value: 2, label: '全部视频'),
      LibrarySectionTab<int>(value: 3, label: '发现'),
      LibrarySectionTab<int>(value: 4, label: '来源'),
      LibrarySectionTab<int>(value: 5, label: '设置'),
    ];

    testWidgets('自持 controller 的指示条滑动时长归零，尾端渐隐不画渐变', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(260, 180));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _wrap(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: FushiSectionTabBar<int>(
                tabs: tabs,
                selected: 0,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final TabBar bar = tester.widget<TabBar>(find.byType(TabBar));
      expect(bar.controller?.animationDuration, Duration.zero);

      final Finder gradientBox = find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient != null,
      );
      expect(gradientBox, findsNothing, reason: '渐变淡出在墨水屏上是抖动带');
    });

    testWidgets('非 eink 主题保留 300ms 滑动与渐隐', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(260, 180));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _wrap(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: FushiSectionTabBar<int>(
                tabs: tabs,
                selected: 0,
                onChanged: (_) {},
              ),
            ),
          ),
          eink: false,
        ),
      );
      await tester.pumpAndSettle();
      final TabBar bar = tester.widget<TabBar>(find.byType(TabBar));
      expect(bar.controller?.animationDuration, kTabScrollDuration);
    });
  });

  group('页面级源码守卫（需要 AppModel 的页面装不进 widget 测试）', () {
    String read(String path) => File(path).readAsStringSync();

    test('首页 dashboard：分区卡描边、封面进度条实心轨道、书封面不淡入', () {
      final String src = read(
        'lib/src/pages/implementations/home_dashboard_page.dart',
      );
      expect(src, contains('Widget _sectionCard('));
      expect(
        RegExp(
          r'Widget _sectionCard\([\s\S]*?isEinkTheme\(context\)',
        ).hasMatch(src),
        isTrue,
        reason: '四张分区卡的 group 面层塌成底色后必须描边',
      );
      expect(src, contains('Widget _bookCoverImage('));
      expect(
        'FadeInImage('.allMatches(src).length,
        1,
        reason: '书封面只能经 _bookCoverImage 淡入（eink 下它换成直出的 Image）',
      );
      expect(src, contains('backgroundColor: eink\n'));
    });

    test('学习热力图：eink 用尺寸而非 alpha 编码等级', () {
      final String src = read(
        'lib/src/utils/components/stat_contribution_heatmap.dart',
      );
      expect(src, contains('_einkInset'));
      expect(src, contains('if (eink && level > 0) return baseColor;'));
      expect(src, contains('old.eink != eink'));
    });

    test('视频页：筛选 chip 激活态反色、封面进度条实心轨道、衬底描边', () {
      final String src = read(
        'lib/src/pages/implementations/home_video_page.dart',
      );
      expect(src, contains('color: active && eink ? colors.onSurface : null'));
      expect(
        RegExp(
          r'backgroundColor: isEinkTheme\(context\)\s*\?\s*Theme\.of\(context\)\.colorScheme\.surface',
        ).allMatches(src).length,
        2,
        reason: '横排卡与墙卡两条进度条都要换实心轨道',
      );
      expect(
        RegExp(
          r'Widget _coverBacking\([\s\S]*?isEinkTheme\(context\)',
        ).hasMatch(src),
        isTrue,
      );
    });

    test('底部迷你条：顶线切分 + 不定态归零', () {
      final String pack = read(
        'lib/src/onboarding/recommended_pack_download_mini_bar.dart',
      );
      expect(
        pack,
        contains('Border(top: BorderSide(color: tokens.surfaces.outline))'),
      );
      expect(pack, contains('einkSafeProgressValue('));
      final String listen = read(
        'lib/src/media/audiobook/now_listening_mini_bar.dart',
      );
      expect(
        listen,
        contains('Border(top: BorderSide(color: scheme.outline))'),
      );
      final String sync = read('lib/src/sync/sync_progress_banner.dart');
      expect(sync, contains('einkSafeProgressValue(context, p?.fraction)'));
    });
  });
}
