import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_theme.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

/// BUG-2434：书内查词弹窗的覆盖主题此前手工 `new ThemeData(...)` 却不带
/// `extensions`，[FushiEinkTheme] 当场丢失 —— 而 `popup_settings_injection` 判定
/// 墨水屏读的正是这个扩展，恒 false 让 popup.css 的整个 `html.eink` 覆盖块在书内
/// 查词这条路径上完全不生效。第二条不变式是墨水屏下不得再叠纸色派生的中性梯度
/// （正文已是纯黑白，弹窗叠灰阶就割裂）。
///
/// 两条不变式都在 [resolveDictionaryPopupTheme] 里，故直接断言它的返回值，而不是
/// 扫源码——扫源码只能证明「写了这行字」，证明不了颜色真的没被覆盖。
void main() {
  ColorScheme plainScheme(Brightness brightness) =>
      ColorScheme.fromSeed(seedColor: const Color(0xFF1F4959),
          brightness: brightness);

  group('墨水屏：覆盖主题必须带 FushiEinkTheme 且不叠纸色', () {
    test('浅色墨水屏 = 纯白底，扩展为 true，纸色一点都渗不进来', () {
      final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
        eink: true,
        einkDark: false,
        readerDark: false,
        buildColorScheme: buildEinkColorScheme,
        textTheme: const TextTheme(),
      );

      // ① 扩展必须在——丢了它 popup.css 的 html.eink 块整块失效。
      expect(resolved.theme.extension<FushiEinkTheme>()?.einkMode, isTrue);

      // ② 纸色不得覆盖纯黑白。
      expect(resolved.fillColor, Colors.white);
      expect(resolved.theme.colorScheme.surface, Colors.white);
      expect(resolved.theme.colorScheme.onSurface, Colors.black);
      expect(resolved.theme.colorScheme.surfaceContainerHigh, Colors.white);
    });

    test('深色墨水屏 = 纯黑底白字', () {
      final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
        eink: true,
        einkDark: true,
        // 阅读器自己的明暗刻意与 einkDark 相反：墨水屏取的是 app 明暗模式，
        // 不读阅读器 theme key（与正文 CSS 的 einkDark 同一真值）。
        readerDark: false,
        buildColorScheme: buildEinkColorScheme,
        textTheme: const TextTheme(),
      );

      expect(resolved.theme.extension<FushiEinkTheme>()?.einkMode, isTrue);
      expect(resolved.fillColor, Colors.black);
      expect(resolved.theme.colorScheme.surface, Colors.black);
      expect(resolved.theme.colorScheme.onSurface, Colors.white);
    });
  });

  group('非墨水屏：配色 = app ColorScheme 本身（与外部查词模块同源）', () {
    // 用户 10-09：外部查词模块（浏览器扩展 / 桌面全局查词窗）直接用
    // buildColorScheme(明暗) 的整套角色，书内弹窗以它为准——不再拿阅读器纸色覆盖
    // 中性梯度（那会把粉色等主题的表面色调抹成纸色灰阶、展开后的词典块发灰）。
    test('全部角色与 buildColorScheme 逐一相同，填充色即 scheme.surface', () {
      final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
        eink: false,
        einkDark: false,
        readerDark: false,
        buildColorScheme: plainScheme,
        textTheme: const TextTheme(),
      );

      final ColorScheme app = plainScheme(Brightness.light);
      final ColorScheme got = resolved.theme.colorScheme;
      expect(got.primary, app.primary);
      expect(got.secondaryContainer, app.secondaryContainer);
      expect(got.surface, app.surface);
      expect(got.surfaceContainer, app.surfaceContainer);
      expect(got.surfaceContainerHigh, app.surfaceContainerHigh);
      expect(got.onSurface, app.onSurface);
      expect(got.outlineVariant, app.outlineVariant);
      expect(resolved.fillColor, app.surface);
    });

    test('扩展仍挂着，只是值为 false（弹窗才能在关掉墨水屏后摘除 html.eink）', () {
      final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
        eink: false,
        einkDark: false,
        readerDark: false,
        buildColorScheme: plainScheme,
        textTheme: const TextTheme(),
      );

      expect(resolved.theme.extension<FushiEinkTheme>(), isNotNull);
      expect(resolved.theme.extension<FushiEinkTheme>()?.einkMode, isFalse);
    });

    test('阅读器深色主题走深色 ColorScheme', () {
      final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
        eink: false,
        einkDark: false,
        readerDark: true,
        buildColorScheme: plainScheme,
        textTheme: const TextTheme(),
      );

      expect(resolved.theme.colorScheme.brightness, Brightness.dark);
    });
  });
}
