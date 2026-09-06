import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2187：自定义主题的正文/背景/选区/链接色在阅读器里永远不生效。
///
/// 根因两层：
/// 1. 编辑页保存后 `app_theme_key` 是 `custom-theme:<id>`，而阅读器 chrome 与
///    `resolveReaderThemeColors` 用 `== 'custom-theme'` 严格比较，自定义分支永远
///    进不去；
/// 2. 即使进去了，chrome 读的是 TODO-930 之后再无人写入的旧扁平偏好
///    `custom_theme_font_color` 等，而不是条目字段。
///
/// 三层锁定：纯函数（解析器接受 `custom-theme:<id>` + 部分覆盖）、ThemeNotifier
/// 的 entry 感知 getter、chrome 源码守卫（不许再回到严格等值 / 扁平 getter）。
void main() {
  const Map<String, ReaderThemeColors> presetMap =
      <String, ReaderThemeColors>{};
  ColorScheme darkScheme() => ColorScheme.fromSeed(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.dark,
      );

  group('resolveReaderThemeColors · custom-theme:<id> 分支', () {
    test('带 id 的 key 也进自定义分支，显式覆盖生效', () {
      final ReaderThemeColors c = resolveReaderThemeColors(
        themeKey: 'custom-theme:ct-1',
        presetMap: presetMap,
        scheme: darkScheme(),
        customOverrides: (
          bg: const Color(0xFFFFF8E1),
          fg: null,
          selection: const Color(0x5500AA00),
          link: null,
        ),
      );
      expect(c.bg, const Color(0xFFFFF8E1));
      expect(c.selection, const Color(0x5500AA00));
      // 链接没覆盖：跟随 scheme.primary。
      expect(c.link, darkScheme().primary);
    });

    test('只覆盖背景时字色按背景亮度取黑/白、dark 跟随最终纸色', () {
      final ReaderThemeColors c = resolveReaderThemeColors(
        themeKey: 'custom-theme:ct-1',
        presetMap: presetMap,
        scheme: darkScheme(),
        customOverrides: (
          bg: const Color(0xFFFFFFFF),
          fg: null,
          selection: null,
          link: null,
        ),
      );
      // 深色 scheme 的 onSurface 是浅色，直接沿用会白字白纸。
      expect(c.fg, const Color(0xDE000000));
      expect(c.dark, isFalse);
    });

    test('全 null 覆盖 == 完全跟随主题（与 system-theme 派生一致）', () {
      final ReaderThemeColors custom = resolveReaderThemeColors(
        themeKey: 'custom-theme:ct-1',
        presetMap: presetMap,
        scheme: darkScheme(),
        customOverrides: (bg: null, fg: null, selection: null, link: null),
      );
      final ReaderThemeColors system = resolveReaderThemeColors(
        themeKey: 'system-theme',
        presetMap: presetMap,
        scheme: darkScheme(),
      );
      expect(custom, system);
    });

    test('非自定义 key 忽略 customOverrides', () {
      final ReaderThemeColors c = resolveReaderThemeColors(
        themeKey: 'light-theme',
        presetMap: presetMap,
        scheme: darkScheme(),
        customOverrides: (
          bg: const Color(0xFF123456),
          fg: null,
          selection: null,
          link: null,
        ),
      );
      expect(c.bg, darkScheme().surface);
    });
  });

  group('ThemeNotifier.activeCustomTheme* · 条目优先、非自定义 key 恒 null', () {
    late FushiDatabase db;
    late ThemeNotifier notifier;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      notifier = ThemeNotifier(db, () => const TextTheme());
      await Future<void>.delayed(Duration.zero);
      await notifier.refreshFromDb();
    });

    tearDown(() async {
      notifier.dispose();
      await db.close();
    });

    test('custom-theme:<id> 读条目字段；未设的角色为 null', () async {
      await notifier.upsertCustomTheme(
        const CustomThemeEntry(
          id: 'ct-x',
          name: 'X',
          seed: 0xFF336699,
          fontColor: 0xFF101010,
          linkColor: 0xFF0000FF,
        ),
      );
      await notifier.setAppThemeKey('custom-theme:ct-x');
      expect(notifier.activeCustomThemeFontColor, const Color(0xFF101010));
      expect(notifier.activeCustomThemeLinkColor, const Color(0xFF0000FF));
      expect(notifier.activeCustomThemeBackgroundColor, isNull);
      expect(notifier.activeCustomThemeSelectionColor, isNull);
    });

    test('条目存在时旧扁平偏好不再被读到', () async {
      await db.setPref('custom_theme_bg_color', PrefCodec.encode(0xFFABCDEF));
      await notifier.refreshFromDb();
      await notifier.upsertCustomTheme(
        const CustomThemeEntry(id: 'ct-y', name: 'Y', seed: 0xFF336699),
      );
      await notifier.setAppThemeKey('custom-theme:ct-y');
      expect(notifier.activeCustomThemeBackgroundColor, isNull);
    });

    test('非自定义 key 一律 null（即使条目里有值）', () async {
      await notifier.upsertCustomTheme(
        const CustomThemeEntry(
          id: 'ct-z',
          name: 'Z',
          seed: 0xFF336699,
          fontColor: 0xFF101010,
        ),
      );
      await notifier.setAppThemeKey('light-theme');
      expect(notifier.activeCustomThemeFontColor, isNull);
    });
  });

  group('源码守卫 · 阅读器 chrome 不再严格等值 / 不再读扁平偏好', () {
    final String chrome = File(
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
    ).readAsStringSync();
    final String page = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();

    test("chrome / page 里没有 == 'custom-theme' 严格比较", () {
      expect(chrome.contains("== 'custom-theme'"), isFalse);
      expect(chrome.contains("!= 'custom-theme'"), isFalse);
      expect(page.contains("== 'custom-theme'"), isFalse);
    });

    test('chrome 只经 activeCustomTheme* getter 取自定义角色色', () {
      for (final String legacy in <String>[
        'appModel.customThemeFontColor',
        'appModel.customThemeBackgroundColor',
        'appModel.customThemeSelectionColor',
        'appModel.customThemeLinkColor',
        'appModel.customThemePrimaryColor',
      ]) {
        expect(
          chrome.contains(legacy),
          isFalse,
          reason: '$legacy 仍被 chrome 读取',
        );
      }
      expect(chrome.contains('appModel.activeCustomThemeFontColor'), isTrue);
      expect(
        chrome.contains('appModel.activeCustomThemeBackgroundColor'),
        isTrue,
      );
      expect(
        chrome.contains('customOverrides: _customReaderThemeOverrides'),
        isTrue,
      );
    });

    test('主色不再隐式覆盖收藏句高亮（5 色收藏高亮保持独立）', () {
      expect(chrome.contains('_customHighlightCss'), isFalse);
      final String bridge = File(
        'lib/src/media/audiobook/highlight_bridge.dart',
      ).readAsStringSync();
      expect(bridge.contains('__fushiCustomHighlightColor'), isFalse);
    });
  });
}
