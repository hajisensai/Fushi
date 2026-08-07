import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_chrome_colors.dart';
import 'package:fushi/src/models/theme_notifier.dart';

/// UI 巡检 PR-4 P1：播放器 chrome 前景固定亮色体系。chrome 压在 media_kit fork
/// 的固定深色 scrim 上，前景在**任何主题**下都必须是亮色——此前跟随 cs.primary /
/// cs.onSurface，浅色 / eink 主题下黑压黑不可读。
void main() {
  group('videoChromeAccentColor 固定亮色', () {
    test('深色主题取值与旧实现一致（cs.primary，视觉不变）', () {
      final ColorScheme dark = ColorScheme.fromSeed(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.dark,
      );
      expect(videoChromeAccentColor(dark), dark.primary);
    });

    test('浅色主题下强调色是亮色（不再黑压黑）', () {
      final ColorScheme light = ColorScheme.fromSeed(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
      );
      // 旧实现的 cs.primary 在浅色主题是深色（tone 40）——这正是 bug。
      expect(light.primary.computeLuminance(), lessThan(0.25),
          reason: '前提：浅色主题 primary 本身是深色（旧实现在深色 scrim 上不可读）');
      final Color accent = videoChromeAccentColor(light);
      expect(accent.computeLuminance(), greaterThan(0.25),
          reason: '修复后：浅色主题下 chrome 强调色必须是亮 tone');
    });

    test('多个种子色的浅色主题强调色均为亮色', () {
      for (final Color seed in <Color>[
        Colors.red,
        Colors.green,
        Colors.blue,
        Colors.purple,
        Colors.orange,
      ]) {
        final ColorScheme light = ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
        );
        expect(
          videoChromeAccentColor(light).computeLuminance(),
          greaterThan(0.25),
          reason: 'seed=$seed 的浅色主题 chrome 强调色必须是亮 tone',
        );
      }
    });

    test('eink 两个亮度方案的强调色均为亮色（纯白）', () {
      final ColorScheme einkLight = buildEinkColorScheme(Brightness.light);
      final ColorScheme einkDark = buildEinkColorScheme(Brightness.dark);
      expect(videoChromeAccentColor(einkLight), Colors.white);
      expect(videoChromeAccentColor(einkDark), Colors.white);
    });

    test('中性前景固定近白', () {
      expect(videoChromeNeutralForeground.computeLuminance(), greaterThan(0.9));
    });
  });

  group('source guard: 播放器 chrome 不再直接用 cs.primary / cs.onSurface', () {
    test('controls_theme.part.dart 的控制条前景走 _videoChromeAccent', () {
      final String src = File(
        'lib/src/pages/implementations/video_hibiki/controls_theme.part.dart',
      ).readAsStringSync();
      expect(src, isNot(contains('seekBarPositionColor: cs.primary')),
          reason: '进度条前景必须走 chrome 固定亮色 helper');
      expect(src, isNot(contains('buttonBarButtonColor: cs.primary')),
          reason: '按钮条前景必须走 chrome 固定亮色 helper');
      expect(src, contains('buttonBarButtonColor: _videoChromeAccent(cs)'));
    });

    test('浮层 alpha 收敛两档（无游离字面 alpha）', () {
      const Map<String, String> files = <String, String>{
        'controls_popover':
            'lib/src/pages/implementations/video_hibiki/controls_popover.part.dart',
        'side_panel': 'lib/src/media/video/video_side_panel.dart',
        'episode_panel': 'lib/src/media/video/video_episode_panel.dart',
        'layout': 'lib/src/pages/implementations/video_hibiki/layout.part.dart',
      };
      for (final MapEntry<String, String> entry in files.entries) {
        final String src = File(entry.value).readAsStringSync();
        for (final String stray in <String>[
          'alpha: 0.55',
          'alpha: 0.78',
          'alpha: 0.92',
          'alpha: 0.94',
        ]) {
          expect(src, isNot(contains(stray)),
              reason: '${entry.key} 的浮层表面 alpha 必须走 kVideoOverlay* 两档常量，'
                  '不再写字面 $stray');
        }
      }
    });
  });
}
