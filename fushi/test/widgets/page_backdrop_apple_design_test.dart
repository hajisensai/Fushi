import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/page_backdrop_layer.dart';

/// Apple（玻璃）设计系统下，用户自选的背景图片必须垫到每一页底下。
///
/// 回归原样：Apple 主题的页面转场没套 [FushiBackdropPageTransitionsBuilder]，
/// 整个 app 一页都不挂 [FushiPageBackdrop]：设置里选了「自定义图片」、缩略图也
/// 画出了图，首页 / 设置页却始终是白底。形状类预设在 Apple 下照旧不画，页面
/// 底色不被改成透明。
void main() {
  ThemeData appleTheme() => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glassDesign: true,
    eink: false,
  );

  tearDown(() {
    pageBackdropSettings.value = const PageBackdropSettings();
  });

  Future<BuildContext> pumpPage(WidgetTester tester) async {
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: appleTheme(),
        home: Builder(
          builder: (BuildContext context) {
            pageContext = context;
            return const Scaffold(body: Text('page'));
          },
        ),
      ),
    );
    await tester.pump();
    return pageContext;
  }

  testWidgets('custom image is drawn under every route in the Apple design', (
    WidgetTester tester,
  ) async {
    pageBackdropSettings.value = const PageBackdropSettings(
      preset: PageBackdropPreset.custom,
      landscapeImagePath: 'backdrop.png',
    );
    final BuildContext page = await pumpPage(tester);

    expect(find.byType(FushiPageBackdrop), findsOneWidget);
    expect(find.byType(PageBackdropLayer), findsOneWidget);
    // 页面自己的 Scaffold 要透出图片。
    expect(FushiPageBackdrop.activeOf(page), isTrue);
    expect(Theme.of(page).scaffoldBackgroundColor, Colors.transparent);
    expect(fushiPageBackgroundColor(page), Colors.transparent);
  });

  testWidgets('pages pushed with adaptivePageRoute get the custom image too', (
    WidgetTester tester,
  ) async {
    pageBackdropSettings.value = const PageBackdropSettings(
      preset: PageBackdropPreset.custom,
      landscapeImagePath: 'backdrop.png',
    );
    final BuildContext home = await pumpPage(tester);
    late BuildContext pushed;
    Navigator.of(home).push<void>(
      adaptivePageRoute<void>(
        context: home,
        builder: (BuildContext context) {
          pushed = context;
          return const Scaffold(body: Text('pushed'));
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('pushed'), findsOneWidget);
    expect(FushiPageBackdrop.activeOf(pushed), isTrue);
    expect(Theme.of(pushed).scaffoldBackgroundColor, Colors.transparent);
  });

  // Apple 的设置页壳原先直接画分组底（groupedBackground），把背景图片整片盖住。
  testWidgets('Apple settings page shell lets the custom image through', (
    WidgetTester tester,
  ) async {
    pageBackdropSettings.value = const PageBackdropSettings(
      preset: PageBackdropPreset.custom,
      landscapeImagePath: 'backdrop.png',
    );
    final BuildContext home = await pumpPage(tester);
    Navigator.of(home).push<void>(
      adaptivePageRoute<void>(
        context: home,
        builder: (BuildContext context) => SettingsKitScaffold(
          title: 'Probe',
          bodyBuilder:
              (
                BuildContext context,
                ScrollController controller,
                SettingsSectionSpy _,
              ) => ListView(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder shell = find.byType(SettingsKitScaffold);
    expect(shell, findsOneWidget);
    expect(
      SettingsKitStyle.of(tester.element(shell)),
      SettingsKitStyle.apple,
      reason: '要测的是 Apple 分支',
    );
    final Scaffold scaffold = tester.widget<Scaffold>(
      find.descendant(of: shell, matching: find.byType(Scaffold)).first,
    );
    expect(scaffold.backgroundColor, Colors.transparent);
    // 整页 Material 也不能画分组底。
    final Color grouped = appleColorsOf(
      tester.element(shell),
    ).groupedBackground;
    expect(
      tester
          .widgetList<Material>(
            find.descendant(of: shell, matching: find.byType(Material)),
          )
          .where((Material m) => m.color == grouped),
      isEmpty,
    );
  });

  testWidgets('shape presets stay off in the Apple design and leave the page '
      'background alone', (WidgetTester tester) async {
    pageBackdropSettings.value = const PageBackdropSettings(
      preset: PageBackdropPreset.mesh,
    );
    final BuildContext page = await pumpPage(tester);

    expect(find.byType(PageBackdropLayer), findsNothing);
    expect(FushiPageBackdrop.activeOf(page), isFalse);
    expect(
      Theme.of(page).scaffoldBackgroundColor,
      appleTheme().scaffoldBackgroundColor,
    );
  });
}
