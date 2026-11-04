import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi/src/utils/components/page_backdrop_layer.dart';

/// 反馈 DYI1IOZxSM：自定义背景按模块单独设置，没单独设置的模块用全局背景。
void main() {
  tearDown(() {
    pageBackdropSettings.value = const PageBackdropSettings();
    pageBackdropModuleOverrides.value =
        const <HomeTab, PageBackdropModuleOverride>{};
    homeShellTabNotifier.value = HomeTab.home;
  });

  group('模块覆盖的解析', () {
    const PageBackdropSettings global = PageBackdropSettings(
      preset: PageBackdropPreset.wave,
      strength: PageBackdropStrength.strong,
      motion: true,
      landscapeImagePath: 'global.png',
      blur: PageBackdropBlur.heavy,
      scrim: 0.3,
    );

    test('没单独设置 → 原样用全局', () {
      expect(resolvePageBackdropSettings(global, null), global);
    });

    test('单独设了预设 → 只换预设与图片，强度 / 模糊 / 遮罩 / 动效沿用全局', () {
      final PageBackdropSettings resolved = resolvePageBackdropSettings(
        global,
        const PageBackdropModuleOverride(preset: PageBackdropPreset.mesh),
      );
      expect(resolved.preset, PageBackdropPreset.mesh);
      expect(resolved.landscapeImagePath, isNull);
      expect(resolved.strength, PageBackdropStrength.strong);
      expect(resolved.motion, isTrue);
      expect(resolved.blur, PageBackdropBlur.heavy);
      expect(resolved.scrim, 0.3);
    });

    test('模块自定义图片：用模块自己的横 / 竖屏图', () {
      final PageBackdropSettings resolved = resolvePageBackdropSettings(
        global,
        const PageBackdropModuleOverride(
          preset: PageBackdropPreset.custom,
          landscapeImagePath: 'books-l.png',
          portraitImagePath: 'books-p.png',
        ),
      );
      expect(resolved.hasCustomImage, isTrue);
      expect(resolved.imagePathFor(portrait: false), 'books-l.png');
      expect(resolved.imagePathFor(portrait: true), 'books-p.png');
    });

    test('模块选了自定义图片但图不在（换了设备 / 被删）→ 退回全局', () {
      expect(
        resolvePageBackdropSettings(
          global,
          const PageBackdropModuleOverride(preset: PageBackdropPreset.custom),
        ),
        global,
      );
    });

    test('pageBackdropSettingsFor：null 模块与没设置的模块都是全局', () {
      pageBackdropSettings.value = global;
      pageBackdropModuleOverrides.value =
          const <HomeTab, PageBackdropModuleOverride>{
            HomeTab.books: PageBackdropModuleOverride(
              preset: PageBackdropPreset.plain,
            ),
          };
      expect(pageBackdropSettingsFor(null), global);
      expect(pageBackdropSettingsFor(HomeTab.video), global);
      expect(
        pageBackdropSettingsFor(HomeTab.books).preset,
        PageBackdropPreset.plain,
      );
    });
  });

  group('偏好编解码', () {
    test('模块 wire 往返且两两不同', () {
      final Set<String> wires = <String>{};
      for (final HomeTab tab in HomeTab.values) {
        final String wire = pageBackdropModuleWire(tab);
        expect(pageBackdropModuleFromWire(wire), tab);
        expect(wires.add(wire), isTrue, reason: '$wire 重复');
      }
      expect(pageBackdropModuleFromWire('nope'), isNull);
    });

    test('预设表往返；坏 JSON / 未知模块 / 未知预设跳过', () {
      final Map<HomeTab, PageBackdropPreset> map =
          <HomeTab, PageBackdropPreset>{
            HomeTab.books: PageBackdropPreset.custom,
            HomeTab.settings: PageBackdropPreset.plain,
          };
      expect(
        decodePageBackdropModulePresets(encodePageBackdropModulePresets(map)),
        map,
      );
      expect(decodePageBackdropModulePresets('{oops'), isEmpty);
      expect(decodePageBackdropModulePresets(null), isEmpty);
      expect(decodePageBackdropModulePresets('[1]'), isEmpty);
      expect(
        decodePageBackdropModulePresets(
          '{"books":"wave","alien":"wave","video":"dots","manga":3}',
        ),
        <HomeTab, PageBackdropPreset>{HomeTab.books: PageBackdropPreset.wave},
      );
    });

    test('图片表往返；空路径视为没有，两张都没有的模块不留', () {
      final Map<HomeTab, PageBackdropModuleImages> map =
          <HomeTab, PageBackdropModuleImages>{
            HomeTab.books: (landscape: 'l.png', portrait: null),
            HomeTab.video: (landscape: 'v.png', portrait: 'vp.png'),
          };
      expect(
        decodePageBackdropModuleImages(encodePageBackdropModuleImages(map)),
        map,
      );
      expect(
        decodePageBackdropModuleImages(
          '{"books":{"landscape":"","portrait":""},"music":{"landscape":"m"}}',
        ),
        <HomeTab, PageBackdropModuleImages>{
          HomeTab.music: (landscape: 'm', portrait: null),
        },
      );
    });

    test('模块图片表登记为设备本地键，预设表随 Profile', () {
      expect(
        kPageBackdropDeviceLocalPrefKeys,
        contains(kPageBackdropModuleImagesPrefKey),
      );
      expect(
        kPageBackdropDeviceLocalPrefKeys,
        isNot(contains(kPageBackdropModulePresetsPrefKey)),
      );
    });
  });

  group('路由层按模块画背景', () {
    ThemeData theme() => ThemeData(
      extensions: const <ThemeExtension<dynamic>>[
        FushiGlassTheme(FushiGlassMaterial.off, glassDesign: false),
        FushiEinkTheme(false),
      ],
    );

    Finder layer() => find.byType(PageBackdropLayer);

    // 全局纯色（不画），书架单独设了波浪：画不画直接反映这页按哪个模块取的设置。
    void configure() {
      pageBackdropSettings.value = const PageBackdropSettings(
        preset: PageBackdropPreset.plain,
      );
      pageBackdropModuleOverrides.value =
          const <HomeTab, PageBackdropModuleOverride>{
            HomeTab.books: PageBackdropModuleOverride(
              preset: PageBackdropPreset.wave,
            ),
          };
    }

    testWidgets('普通页属于打开它时所在的模块，之后切 tab 不变', (WidgetTester tester) async {
      configure();
      homeShellTabNotifier.value = HomeTab.books;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(),
          home: const FushiPageBackdrop(child: SizedBox.expand()),
        ),
      );
      expect(layer(), findsOneWidget);

      homeShellTabNotifier.value = HomeTab.video;
      await tester.pump();
      expect(layer(), findsOneWidget, reason: '从书架打开的页仍用书架的背景');
    });

    testWidgets('从没单独设置的模块打开的页用全局背景', (WidgetTester tester) async {
      configure();
      homeShellTabNotifier.value = HomeTab.video;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(),
          home: const FushiPageBackdrop(child: SizedBox.expand()),
        ),
      );
      expect(layer(), findsNothing);
    });

    testWidgets('主导航外壳页跟着当前 tab 换背景', (WidgetTester tester) async {
      configure();
      homeShellTabNotifier.value = HomeTab.video;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(),
          home: const FushiPageBackdrop(child: _ShellProbe()),
        ),
      );
      // 外壳登记推到帧后；登记完成后按当前 tab（视频，没单独设置 → 全局纯色）。
      await tester.pump();
      expect(layer(), findsNothing);

      homeShellTabNotifier.value = HomeTab.books;
      await tester.pump();
      expect(layer(), findsOneWidget);

      homeShellTabNotifier.value = HomeTab.settings;
      await tester.pump();
      expect(layer(), findsNothing);
    });

    testWidgets('外壳在构建期改写 tab（同 HomePage.initState）不在构建期标脏，帧后生效', (
      WidgetTester tester,
    ) async {
      configure();
      homeShellTabNotifier.value = HomeTab.home;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(),
          home: const FushiPageBackdrop(
            child: _ShellProbe(startTab: HomeTab.books),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(layer(), findsOneWidget);
    });

    testWidgets('模块覆盖改了，路由层立刻跟着重画', (WidgetTester tester) async {
      configure();
      homeShellTabNotifier.value = HomeTab.video;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(),
          home: const FushiPageBackdrop(child: SizedBox.expand()),
        ),
      );
      expect(layer(), findsNothing);

      pageBackdropModuleOverrides.value =
          const <HomeTab, PageBackdropModuleOverride>{
            HomeTab.video: PageBackdropModuleOverride(
              preset: PageBackdropPreset.mesh,
            ),
          };
      await tester.pump();
      expect(layer(), findsOneWidget);
    });
  });
}

/// 模拟 HomePage：把所在路由登记成主导航外壳；[startTab] 非空时像 HomePage.initState
/// 那样在构建期改写 [homeShellTabNotifier]。
class _ShellProbe extends StatefulWidget {
  const _ShellProbe({this.startTab});

  final HomeTab? startTab;

  @override
  State<_ShellProbe> createState() => _ShellProbeState();
}

class _ShellProbeState extends State<_ShellProbe> {
  Route<Object?>? _route;

  @override
  void initState() {
    super.initState();
    if (widget.startTab case final HomeTab tab) {
      homeShellTabNotifier.value = tab;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (_route case final Route<Object?> route) {
      setFushiPageRouteModuleShell(route, true);
    }
  }

  @override
  void dispose() {
    if (_route case final Route<Object?> route) {
      setFushiPageRouteModuleShell(route, false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
