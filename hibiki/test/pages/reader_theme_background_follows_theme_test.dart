import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

/// BUG-208 / TODO-143 —— 「书籍背景没吃主题」。
///
/// 阅读器背景由 [resolveReaderThemeColors] 解析当前主题 key 得到。旧逻辑只查
/// reader 私有的 5 个 preset（ecru/water/gray/dark/black），命中失败就硬编码
/// 白底/黑字。但真实主题系统（`ThemeNotifier.themePresets`）里还有 `light-theme`，
/// 而**默认主题**是 `system-theme`，两者都不在那 5 个 preset 里——于是阅读器背景
/// 永远白色，无论系统强调色或明暗如何。
///
/// 这些用例锁住根因修复：未在 presetMap 命中的 key（light-theme / system-theme）
/// 必须回落到真实 ColorScheme 的 surface/onSurface/brightness，而不是写死成白。
/// 撤掉修复（回到 `presetMap[key]?.bg ?? 白色`）这些断言会红。
void main() {
  // 复刻 reader `_themeMap` 的「只有 5 个 preset、不含 light/system」结构，
  // 以脱离整个 reader page 状态单测纯函数的回落分支。
  const Map<String, ReaderThemeColors> presetMap = <String, ReaderThemeColors>{
    'ecru-theme': (
      bg: Color(0xFFF7F6EB),
      fg: Color(0xDE000000),
      sasayaki: Color(0x66A8C68C),
      selection: Color(0x59C2B280),
      link: Color(0xFF7A6232),
      dark: false,
    ),
    'black-theme': (
      bg: Color(0xFF000000),
      fg: Color(0xDEFFFFFF),
      sasayaki: Color(0x663C78AA),
      selection: Color(0x66AA8750),
      link: Color(0xFF5B9BD5),
      dark: true,
    ),
  };

  ColorScheme darkScheme() => ColorScheme.fromSeed(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.dark,
      );
  ColorScheme lightScheme() => ColorScheme.fromSeed(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
      );

  group('TODO-143 · 阅读器背景跟随主题（resolveReaderThemeColors）', () {
    test('preset 命中：用手调底色（向后兼容，零变化）', () {
      final ReaderThemeColors colors = resolveReaderThemeColors(
        themeKey: 'ecru-theme',
        presetMap: presetMap,
        scheme: lightScheme(),
      );
      expect(colors.bg, const Color(0xFFF7F6EB));
      expect(colors.fg, const Color(0xDE000000));
      expect(colors.dark, isFalse);
    });

    test('system-theme（默认主题）：背景跟随 scheme.surface，不再恒白', () {
      final ColorScheme scheme = darkScheme();
      final ReaderThemeColors colors = resolveReaderThemeColors(
        themeKey: 'system-theme',
        presetMap: presetMap,
        scheme: scheme,
      );
      // 暗色系统主题下背景必须是 scheme 的深色 surface，而非硬编码白。
      expect(colors.bg, scheme.surface);
      expect(colors.bg, isNot(const Color(0xFFFFFFFF)),
          reason: '暗色 system-theme 背景恒白 = 没吃主题（BUG-208）');
      expect(colors.fg, scheme.onSurface);
      expect(colors.dark, isTrue);
    });

    test('light-theme（不在 reader preset 里）：跟随 scheme，不落硬编码白', () {
      final ColorScheme scheme = lightScheme();
      final ReaderThemeColors colors = resolveReaderThemeColors(
        themeKey: 'light-theme',
        presetMap: presetMap,
        scheme: scheme,
      );
      expect(colors.bg, scheme.surface);
      expect(colors.fg, scheme.onSurface);
      expect(colors.dark, isFalse);
    });

    test('任意未来未覆盖 key：跟随 scheme 而不崩/不恒白', () {
      final ColorScheme scheme = darkScheme();
      final ReaderThemeColors colors = resolveReaderThemeColors(
        themeKey: 'some-future-theme',
        presetMap: presetMap,
        scheme: scheme,
      );
      expect(colors.bg, scheme.surface);
      expect(colors.dark, isTrue);
    });

    test('custom-theme：用传入的 customColors（与旧 custom 分支一致）', () {
      const ReaderThemeColors custom = (
        bg: Color(0xFF102030),
        fg: Color(0xFFEEEEEE),
        sasayaki: Color(0x66335577),
        selection: Color(0x66445566),
        link: Color(0xFF778899),
        dark: true,
      );
      final ReaderThemeColors colors = resolveReaderThemeColors(
        themeKey: 'custom-theme',
        presetMap: presetMap,
        scheme: lightScheme(),
        customColors: custom,
      );
      expect(colors, custom);
    });
  });

  /// BUG-396 —— 默认（system）主题下 sasayaki/选区/链接色「不吃主题」。
  ///
  /// 旧逻辑：未命中 preset 的 key 只回落 bg/fg 到 scheme，selection/sasayaki/link
  /// 三个角色色仍落 `_ThemeColors` 硬编码默认（天蓝高亮 / 灰选区 / 蓝链接），无论桌面
  /// 强调色如何都不变。修复：这三个角色色也跟随真实 ColorScheme（强调色派生），
  /// sasayaki=primary、selection=tertiary（与跟读区分）、link=primary。
  group('BUG-396 · 高亮/选区/链接色跟随主题（resolveReaderThemeColors）', () {
    test('system-theme：三色派生自 scheme（强调色），非硬编码默认', () {
      final ColorScheme scheme = lightScheme();
      final ReaderThemeColors c = resolveReaderThemeColors(
        themeKey: 'system-theme',
        presetMap: presetMap,
        scheme: scheme,
      );
      expect(c.sasayaki, scheme.primary.withValues(alpha: 0.40));
      expect(c.selection, scheme.tertiary.withValues(alpha: 0.40));
      expect(c.link, scheme.primary);
      // 关键回归断言：不再是旧硬编码默认色。
      expect(c.sasayaki, isNot(const Color(0x6687CEEB)),
          reason: '旧默认 sasayaki 天蓝 = 没吃强调色（BUG-396）');
      expect(c.selection, isNot(const Color(0x66A0A0A0)),
          reason: '旧默认 selection 灰 = 没吃强调色');
      expect(c.link, isNot(const Color(0xFF426CF5)),
          reason: '旧默认 link 蓝 = 没吃强调色');
    });

    test('暗色 system-theme：高亮/选区 alpha 用 dark 档', () {
      final ColorScheme scheme = darkScheme();
      final ReaderThemeColors c = resolveReaderThemeColors(
        themeKey: 'system-theme',
        presetMap: presetMap,
        scheme: scheme,
      );
      expect(c.sasayaki, scheme.primary.withValues(alpha: 0.34));
      expect(c.selection, scheme.tertiary.withValues(alpha: 0.35));
      expect(c.link, scheme.primary);
    });

    test('preset 命中：selection/link 透传 presetMap（零变化）', () {
      final ReaderThemeColors c = resolveReaderThemeColors(
        themeKey: 'ecru-theme',
        presetMap: presetMap,
        scheme: lightScheme(),
      );
      expect(c.selection, const Color(0x59C2B280));
      expect(c.link, const Color(0xFF7A6232));
    });
  });
}
