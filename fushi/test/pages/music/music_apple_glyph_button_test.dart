import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_apple_glyph_button.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// 用户 2026-11-24：Cupertino 下音乐播放页按钮「不要着色和背景，和 Apple Music
// 一致」。Apple 分支的播放 / 暂停、喜欢、循环等全走 [FushiAppleGlyphButton]：
// 静止无底、无着色，字形 label / secondaryLabel 色，开关的「开」用实心字形。
void main() {
  ThemeData theme() => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(
      seedColor: Colors.deepPurple,
      brightness: Brightness.dark,
    ),
    textTheme: Typography.material2021().white,
    glass: FushiGlassMaterial.minimal,
    glassDesign: true,
    eink: false,
  );

  Future<BuildContext> pump(WidgetTester tester, Widget child) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(),
        home: FushiGlassScope(
          child: Scaffold(
            body: Center(
              child: Builder(
                builder: (BuildContext context) {
                  ctx = context;
                  return child;
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return ctx;
  }

  Icon iconOf(WidgetTester tester, Finder button) => tester.widget<Icon>(
    find.descendant(of: button, matching: find.byType(Icon)),
  );

  /// 子树里所有带底色的装饰（静止时应为空：没有圆底、没有强调色块）。
  List<Color> visibleFills(WidgetTester tester, Finder root) => <Color>[
    for (final Material m in tester.widgetList<Material>(
      find.descendant(of: root, matching: find.byType(Material)),
    ))
      if (m.type != MaterialType.transparency && (m.color?.a ?? 0) > 0)
        m.color!,
    for (final Widget w in tester.widgetList<Widget>(
      find.descendant(of: root, matching: find.byType(DecoratedBox)),
    ))
      if (_decorationColor((w as DecoratedBox).decoration) case final Color c
          when c.a > 0 && !_insideZeroOpacity(tester, w))
        c,
  ];

  testWidgets('play / pause: no fill, no tint, label-coloured glyph', (
    WidgetTester tester,
  ) async {
    final BuildContext ctx = await pump(
      tester,
      FushiApplePlayPauseButton(
        key: const ValueKey<String>('play'),
        isPlaying: false,
        tooltip: 'Play',
        glyphSize: 60,
        extent: 80,
        onPressed: () {},
      ),
    );
    final Finder button = find.byKey(const ValueKey<String>('play'));
    expect(visibleFills(tester, button), isEmpty);
    final Icon icon = iconOf(tester, button);
    expect(icon.color, appleColorsOf(ctx).label);
    expect(icon.icon, fushiAppleIcon(FushiIcons.filled(FushiIcons.play)));
    expect(icon.size, 60);
  });

  testWidgets('liked uses the filled glyph, not a coloured block', (
    WidgetTester tester,
  ) async {
    final BuildContext ctx = await pump(
      tester,
      FushiAppleGlyphButton(
        key: const ValueKey<String>('fav'),
        icon: FushiIcons.favorite,
        selected: true,
        tooltip: 'Unlike',
        onPressed: () {},
      ),
    );
    final Finder button = find.byKey(const ValueKey<String>('fav'));
    expect(visibleFills(tester, button), isEmpty);
    final Icon icon = iconOf(tester, button);
    expect(icon.icon, fushiAppleIcon(FushiIcons.filled(FushiIcons.favorite)));
    expect(icon.color, appleColorsOf(ctx).label);
    expect(
      tester.getSemantics(button),
      matchesSemantics(
        label: 'Unlike',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        isSelected: true,
        isFocusable: true,
        hasFocusAction: true,
        hasTapAction: true,
      ),
    );
  });

  testWidgets('unliked: outline glyph in secondaryLabel', (
    WidgetTester tester,
  ) async {
    final BuildContext ctx = await pump(
      tester,
      FushiAppleGlyphButton(
        key: const ValueKey<String>('fav'),
        icon: FushiIcons.favorite,
        selected: false,
        tooltip: 'Like',
        onPressed: () {},
      ),
    );
    final Icon icon = iconOf(tester, find.byKey(const ValueKey<String>('fav')));
    expect(icon.icon, fushiAppleIcon(FushiIcons.favorite));
    expect(icon.color, appleColorsOf(ctx).secondaryLabel);
  });

  testWidgets('focus + Enter toggles play / pause', (
    WidgetTester tester,
  ) async {
    bool playing = false;
    final FocusNode node = FocusNode();
    addTearDown(node.dispose);
    await pump(
      tester,
      StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) =>
            FushiApplePlayPauseButton(
              key: const ValueKey<String>('play'),
              isPlaying: playing,
              tooltip: playing ? 'Pause' : 'Play',
              glyphSize: 60,
              extent: 80,
              onPressed: () => setState(() => playing = !playing),
            ),
      ),
    );
    // 焦点要挂在按钮自己的 FocusableActionDetector 上：用键盘 Tab 走过去。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(playing, isTrue);
    final Finder button = find.byKey(const ValueKey<String>('play'));
    expect(
      iconOf(tester, button).icon,
      fushiAppleIcon(FushiIcons.filled(FushiIcons.pause)),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(playing, isFalse);
  });

  test('M3E branch of the lyrics page keeps its original controls', () {
    final String src = File(
      'lib/src/pages/implementations/music/music_lyrics_page.dart',
    ).readAsStringSync();
    // MD3 传输行仍是 Expressive 播放键 + 六格 FushiIconButtonControl，喜欢仍是
    // 红色实心心形；Apple 分支在 isGlassDesign 判据后另起。
    expect(src, contains('FushiExpressivePlayButton('));
    expect(src, contains('color: liked ? const Color(0xFFFF4D6D) : null'));
    expect(src, contains('cell(MusicVolumeButton(iconSize: icon))'));
    expect(src, contains('_buildAppleTransportRow('));
  });
}

Color? _decorationColor(Decoration d) => switch (d) {
  BoxDecoration(:final Color? color) => color,
  ShapeDecoration(:final Color? color) => color,
  _ => null,
};

/// [w] 是否处在不透明度为 0 的祖先下（按下高亮静止时 opacity = 0）。
bool _insideZeroOpacity(WidgetTester tester, Widget w) {
  final Element e = tester.element(find.byWidget(w));
  bool hidden = false;
  e.visitAncestorElements((Element a) {
    final Widget aw = a.widget;
    if (aw is AnimatedOpacity && aw.opacity == 0) hidden = true;
    if (aw is Opacity && aw.opacity == 0) hidden = true;
    return !hidden;
  });
  return hidden;
}
