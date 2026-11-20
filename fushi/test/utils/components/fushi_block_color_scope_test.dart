// 带色卡片的局部配色（BUG：色块卡里的按钮 / 开关 / 热力图 / 弹出的对话框退回
// 全局 primary / tertiary）。MD3 与 Apple 两套设计系统各验一遍：
// - 色块（FushiPosterBlock / 导入页色块）子树里的主题强调色 = 块的强调色，不是
//   全局 primary；MD3 的开关组件主题（工厂烤进去的颜色）也换成块色；Apple 的
//   玻璃按钮 / 开关读的 FushiAppleColors.accent 也是块色；
// - 色块里的按钮用自己的 context 弹对话框：对话框继承块配色；
// - 色块里的点按目标（FushiCard）经页面 context 转弹对话框：同样继承块配色；
// - 块外的组件、块外点按弹出的对话框保持全局主题；
// - 从色块弹出的二选一对话框里的选项块：同色相、两档深浅。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_block_color_scope.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_poster_block.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

ThemeData _appTheme({required bool apple, required Brightness brightness}) =>
    buildFushiThemeData(
      scheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: brightness,
      ),
      textTheme: const TextTheme(),
      glassDesign: apple,
    );

/// 读子树里 [key] 处的 context。
BuildContext _ctx(WidgetTester tester, Key key) =>
    tester.element(find.byKey(key));

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme,
  Widget Function(BuildContext pageContext) body,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Builder(
          builder: (BuildContext pageContext) =>
              Center(child: SizedBox(width: 400, child: body(pageContext))),
        ),
      ),
    ),
  );
}

void main() {
  for (final bool apple in <bool>[false, true]) {
    for (final Brightness brightness in Brightness.values) {
      final String label = '${apple ? 'Apple' : 'MD3'} ${brightness.name}';

      testWidgets('$label：色块子树的强调色 / 开关 / 弹出对话框都取块配色', (
        WidgetTester tester,
      ) async {
        final ThemeData theme = _appTheme(apple: apple, brightness: brightness);
        final FushiCoverBlockColors colors = FushiCoverBlockColors.fromHue(
          theme,
          140,
        );
        const Key inside = ValueKey<String>('inside');
        const Key outside = ValueKey<String>('outside');
        const Key open = ValueKey<String>('open');
        const Key dialogBody = ValueKey<String>('dialog-body');
        bool switchValue = true;
        await _pump(
          tester,
          theme,
          (BuildContext _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(key: outside),
              FushiPosterBlock(
                watermark: '',
                colors: colors,
                child: Builder(
                  builder: (BuildContext context) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const SizedBox(key: inside),
                      adaptiveSwitch(
                        context: context,
                        value: switchValue,
                        onChanged: (bool v) => switchValue = v,
                      ),
                      FushiFilledButton.tonal(
                        key: open,
                        onPressed: () => showAppDialog<void>(
                          context: context,
                          builder: (BuildContext _) =>
                              const Dialog(child: SizedBox(key: dialogBody)),
                        ),
                        child: const Text('open'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );

        final ThemeData global = Theme.of(_ctx(tester, outside));
        expect(global.colorScheme.primary, isNot(colors.accent));

        final ThemeData local = Theme.of(_ctx(tester, inside));
        expect(local.colorScheme.primary, colors.accent);
        expect(local.colorScheme.secondary, colors.accent);
        expect(local.colorScheme.tertiary, colors.accent);
        expect(local.colorScheme.onSecondaryContainer, colors.onContainer);
        expect(local.colorScheme.surface, colors.container);
        if (apple) {
          expect(appleColorsOf(_ctx(tester, inside)).accent, colors.accent);
          expect(
            appleColorsOf(_ctx(tester, outside)).accent,
            isNot(colors.accent),
          );
        } else {
          // 主题工厂烤进开关组件主题的勾选色跟着换（不是只换 colorScheme）。
          final Icon? thumb = local.switchTheme.thumbIcon?.resolve(
            <WidgetState>{WidgetState.selected},
          );
          expect(thumb?.color, colors.accent);
        }

        await tester.tap(find.byKey(open));
        await tester.pumpAndSettle();
        final BuildContext dialog = _ctx(tester, dialogBody);
        expect(Theme.of(dialog).colorScheme.primary, colors.accent);
        expect(
          FushiBlockColorScope.maybeColorsOf(dialog)?.container,
          colors.container,
        );
        if (apple) expect(appleColorsOf(dialog).accent, colors.accent);
      });

      testWidgets('$label：色块里的卡片经页面 context 转弹的对话框也承接块配色', (
        WidgetTester tester,
      ) async {
        final ThemeData theme = _appTheme(apple: apple, brightness: brightness);
        final FushiCoverBlockColors colors = FushiCoverBlockColors.fromHue(
          theme,
          229,
        );
        const Key card = ValueKey<String>('card');
        const Key plain = ValueKey<String>('plain');
        const Key dialogBody = ValueKey<String>('dialog-body');
        const Key tileA = ValueKey<String>('tile-a');
        const Key tileB = ValueKey<String>('tile-b');
        late FushiCoverBlockColors a;
        late FushiCoverBlockColors b;
        // 页面级弹框（导入页「导入文件夹」：块的点按转到页面 State、用页面的
        // context 弹二选一对话框）。
        late BuildContext page;
        Future<void> openFromPage() async {
          await Future<void>.delayed(Duration.zero); // 跨 await 也算这次点按
          if (!page.mounted) return;
          await showAppDialog<void>(
            context: page,
            builder: (BuildContext _) => Dialog(
              child: Builder(
                builder: (BuildContext context) {
                  a = importToneColors(context, ImportTone.green);
                  b = importToneColors(context, ImportTone.indigo);
                  return const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      SizedBox(key: dialogBody),
                      SizedBox(key: tileA),
                      SizedBox(key: tileB),
                    ],
                  );
                },
              ),
            ),
          );
        }

        await _pump(tester, theme, (BuildContext pageContext) {
          page = pageContext;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiBlockColorScope(
                colors: colors,
                child: FushiCard(
                  key: card,
                  onTap: openFromPage,
                  child: const SizedBox(height: 40, width: 200),
                ),
              ),
              FushiCard(
                key: plain,
                onTap: openFromPage,
                child: const SizedBox(height: 40, width: 200),
              ),
            ],
          );
        });

        await tester.tap(find.byKey(card));
        await tester.pumpAndSettle();
        final BuildContext dialog = _ctx(tester, dialogBody);
        expect(Theme.of(dialog).colorScheme.primary, colors.accent);
        if (apple) expect(appleColorsOf(dialog).accent, colors.accent);
        // 选项块：同一色相（块的色相），两档深浅（深色低明度档经 8 位量化，色相
        // 会漂几度，按 5° 容差比）。
        expect(a.hue, colors.hue);
        expect(b.hue, colors.hue);
        expect(a.container, isNot(b.container));
        expect(
          HSLColor.fromColor(a.container).hue,
          closeTo(HSLColor.fromColor(colors.container).hue, 5),
        );
        expect(
          HSLColor.fromColor(b.container).hue,
          closeTo(HSLColor.fromColor(colors.container).hue, 5),
        );
        Navigator.of(dialog).pop();
        await tester.pumpAndSettle();

        // 块外的卡片弹出的对话框保持全局主题，选项块按各自钉色。
        await tester.tap(find.byKey(plain));
        await tester.pumpAndSettle();
        final BuildContext plainDialog = _ctx(tester, dialogBody);
        expect(Theme.of(plainDialog).colorScheme.primary, isNot(colors.accent));
        expect(FushiBlockColorScope.maybeColorsOf(plainDialog), isNull);
        expect(a.hue, ImportTone.green.hue);
        expect(b.hue, ImportTone.indigo.hue);
      });
    }
  }

  testWidgets('中性块（没封面 / 墨水屏）不另包主题', (WidgetTester tester) async {
    final ThemeData theme = _appTheme(
      apple: false,
      brightness: Brightness.dark,
    );
    final FushiCoverBlockColors neutral = FushiCoverBlockColors.resolve(
      theme,
      null,
    );
    const Key inside = ValueKey<String>('inside');
    await _pump(
      tester,
      theme,
      (BuildContext _) => FushiPosterBlock(
        watermark: '',
        colors: neutral,
        child: const SizedBox(key: inside),
      ),
    );
    expect(FushiBlockColorScope.maybeColorsOf(_ctx(tester, inside)), isNull);
    expect(
      Theme.of(_ctx(tester, inside)).colorScheme.primary,
      theme.colorScheme.primary,
    );
  });
}
