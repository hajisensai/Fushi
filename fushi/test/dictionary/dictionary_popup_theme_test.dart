import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_theme.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

/// BUG-2430：书内查词弹窗的覆盖主题此前手工 `new ThemeData(...)` 却不带
/// `extensions`，[FushiEinkTheme] 当场丢失 —— 而 `popup_settings_injection` 判定
/// 墨水屏读的正是这个扩展，恒 false 让 popup.css 的整个 `html.eink` 覆盖块在书内
/// 查词这条路径上完全不生效。第二条不变式是墨水屏下不得再叠纸色派生的中性梯度
/// （正文已是纯黑白，弹窗叠灰阶就割裂）。
///
/// 两条不变式都在 [resolveDictionaryPopupTheme] 里，故直接断言它的返回值，而不是
/// 扫源码——扫源码只能证明「写了这行字」，证明不了颜色真的没被覆盖。
void main() {
  // 阅读器 sepia 预设那类「手调纸色」：墨水屏下绝不允许出现在弹窗上。
  const Color paperBg = Color(0xFFF5EFE0);
  const Color paperFg = Color(0xFF3B3229);

  ColorScheme plainScheme(Brightness brightness) =>
      ColorScheme.fromSeed(seedColor: const Color(0xFF1F4959),
          brightness: brightness);

  group('墨水屏：覆盖主题必须带 FushiEinkTheme 且不叠纸色', () {
    test('浅色墨水屏 = 纯白底，扩展为 true，纸色一点都渗不进来', () {
      final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
        eink: true,
        einkDark: false,
        readerBackground: paperBg,
        readerForeground: paperFg,
        readerDark: false,
        buildColorScheme: buildEinkColorScheme,
      );

      // ① 扩展必须在——丢了它 popup.css 的 html.eink 块整块失效。
      expect(resolved.theme.extension<FushiEinkTheme>()?.einkMode, isTrue);

      // ② 纸色不得覆盖纯黑白。
      expect(resolved.fillColor, Colors.white);
      expect(resolved.theme.colorScheme.surface, Colors.white);
      expect(resolved.theme.colorScheme.onSurface, Colors.black);
      expect(resolved.theme.colorScheme.surfaceContainerHigh, Colors.white);
      expect(resolved.fillColor, isNot(paperBg));
      expect(resolved.theme.colorScheme.onSurface, isNot(paperFg));
    });

    test('深色墨水屏 = 纯黑底白字', () {
      final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
        eink: true,
        einkDark: true,
        readerBackground: paperBg,
        readerForeground: paperFg,
        // 阅读器自己的明暗刻意与 einkDark 相反：墨水屏取的是 app 明暗模式，
        // 不读阅读器 theme key（与正文 CSS 的 einkDark 同一真值）。
        readerDark: false,
        buildColorScheme: buildEinkColorScheme,
      );

      expect(resolved.theme.extension<FushiEinkTheme>()?.einkMode, isTrue);
      expect(resolved.fillColor, Colors.black);
      expect(resolved.theme.colorScheme.surface, Colors.black);
      expect(resolved.theme.colorScheme.onSurface, Colors.white);
    });
  });

  group('非墨水屏：既有的纸色派生行为原样保留', () {
    test('填充色仍是阅读器纸色，中性梯度仍由 deriveSurfaceRolesFrom 派生', () {
      final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
        eink: false,
        einkDark: false,
        readerBackground: paperBg,
        readerForeground: paperFg,
        readerDark: false,
        buildColorScheme: plainScheme,
      );

      final SurfaceRoles paper = deriveSurfaceRolesFrom(paperBg);
      expect(resolved.fillColor, paperBg);
      expect(resolved.theme.colorScheme.surface, paper.surface);
      expect(resolved.theme.colorScheme.onSurface, paperFg);
      expect(resolved.theme.colorScheme.outline, paper.outline);
      expect(resolved.theme.colorScheme.surfaceTint, Colors.transparent);
      // 主题色仍来自 app 的真实 ColorScheme（不被纸色重造）。
      expect(
        resolved.theme.colorScheme.primary,
        plainScheme(Brightness.light).primary,
      );
    });

    test('扩展仍挂着，只是值为 false（弹窗才能在关掉墨水屏后摘除 html.eink）', () {
      final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
        eink: false,
        einkDark: false,
        readerBackground: paperBg,
        readerForeground: paperFg,
        readerDark: false,
        buildColorScheme: plainScheme,
      );

      expect(resolved.theme.extension<FushiEinkTheme>(), isNotNull);
      expect(resolved.theme.extension<FushiEinkTheme>()?.einkMode, isFalse);
    });

    test('阅读器深色主题走深色 ColorScheme', () {
      final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
        eink: false,
        einkDark: false,
        readerBackground: const Color(0xFF1A1A1A),
        readerForeground: const Color(0xFFE0E0E0),
        readerDark: true,
        buildColorScheme: plainScheme,
      );

      expect(resolved.theme.colorScheme.brightness, Brightness.dark);
    });
  });
}
