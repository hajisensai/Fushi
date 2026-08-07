import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';

/// 墨水屏模式（eink_mode）守卫：
///  1. 阅读器 CSS 生成器的 eink 分支——纯黑白正文、线式高亮、关过渡、
///     `--hoshi-reader-eink-mode: 1`（JS 侧 isEInkMode() 与连续模式跟随滚动
///     瞬时化都读它）；关掉时逐项不出现（零行为变化）。
///  2. buildEinkColorScheme——纯黑白 ColorScheme（手工构造，不走 fromSeed），
///     surfaceTint/shadow 透明（e-ink 不能有 elevation 灰阶）。
///  3. eink_mode 必须在 Profile 快照黑名单里（设备属性，切 Profile 不回滚）。
Future<ReaderSettings> _defaultSettings() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  return settings;
}

void main() {
  group('ReaderContentStyles.css eink branch', () {
    test('einkMode=true (light) forces pure black-on-white body', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        einkMode: true,
      );
      expect(css, contains('--hoshi-reader-eink-mode: 1'));
      expect(css, contains('background: #fff !important'));
      expect(css, contains('color: #000 !important'));
      // 关过渡：书籍自带动画一并压掉。
      expect(css, contains('transition: none !important'));
      expect(css, contains('animation: none !important'));
      // 线式高亮：查词=实线、sasayaki=虚线、搜索=双线。
      expect(css, contains('text-decoration-style: dashed'));
      expect(css, contains('text-decoration-style: double'));
      expect(css, contains('text-decoration-line: underline'));
    });

    test('einkMode=true honours einkDark (white-on-black)', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        einkMode: true,
        einkDark: true,
      );
      expect(css, contains('background: #000 !important'));
      expect(css, contains('color: #fff !important'));
      expect(css, contains('--hoshi-reader-eink-mode: 1'));
    });

    test('einkMode=true overrides themed colors even for preset themes',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'ecru-theme',
        einkMode: true,
      );
      // ecru 的手调底色被 eink 压掉。
      expect(css, isNot(contains('#f7f6eb')));
      expect(css, contains('background: #fff !important'));
    });

    test('einkMode=false (default) leaves normal output untouched', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, isNot(contains('--hoshi-reader-eink-mode')));
      expect(css, isNot(contains('text-decoration-style: dashed')));
      // sasayaki 仍是色块填充（背景变量非 transparent）。
      expect(css, contains('--hoshi-sentence-audio-background-color: rgba'));
    });
  });

  group('buildEinkColorScheme', () {
    test('light = black on white, no tint/shadow', () {
      final ColorScheme cs = buildEinkColorScheme(Brightness.light);
      expect(cs.surface, Colors.white);
      expect(cs.onSurface, Colors.black);
      expect(cs.primary, Colors.black);
      expect(cs.onPrimary, Colors.white);
      expect(cs.outline, Colors.black);
      expect(cs.surfaceContainerLow, Colors.white);
      expect(cs.surfaceContainerHighest, Colors.white);
      expect(cs.surfaceTint, Colors.transparent);
      expect(cs.shadow, Colors.transparent);
    });

    test('dark = white on black', () {
      final ColorScheme cs = buildEinkColorScheme(Brightness.dark);
      expect(cs.surface, Colors.black);
      expect(cs.onSurface, Colors.white);
      expect(cs.primary, Colors.white);
      expect(cs.onPrimary, Colors.black);
      expect(cs.outline, Colors.white);
      expect(cs.surfaceTint, Colors.transparent);
    });
  });

  group('profile snapshot exclusion', () {
    test('eink_mode is app-global (excluded from per-profile snapshot)', () {
      expect(ProfileKeys.isExcludedPref('eink_mode'), isTrue,
          reason: 'eink_mode 描述物理屏幕，切 Profile 不得把整个 app 颜色翻转回去');
    });
  });
}
