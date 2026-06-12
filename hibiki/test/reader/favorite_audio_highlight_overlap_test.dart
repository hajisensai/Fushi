import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<ReaderSettings> _defaultSettings() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  return settings;
}

void main() {
  group('TODO-191 收藏高亮与音频高亮重叠', () {
    test('reader CSS 给收藏高亮保留背景外的可见标记', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);

      for (final String color in <String>[
        'yellow',
        'green',
        'blue',
        'pink',
        'purple',
      ]) {
        final int start = css.indexOf('::highlight(hoshi-hl-$color)');
        expect(start, greaterThanOrEqualTo(0), reason: color);
        final int end = css.indexOf('}', start);
        final String block = css.substring(start, end);

        expect(block, contains('background-color'), reason: color);
        expect(block, contains('text-decoration-line: underline'),
            reason: '收藏高亮和 hoshi-sasayaki 音频背景重叠时，必须还有独立可见语义');
        expect(block, contains('text-decoration-color'), reason: color);
        expect(block, contains('text-decoration-thickness'), reason: color);
      }
    });

    test('HighlightBridge 同时更新 CSS highlight 变量和旧 span fallback 标记', () {
      final String bridge =
          File('lib/src/media/audiobook/highlight_bridge.dart')
              .readAsStringSync();

      expect(bridge, contains('--hoshi-hl-yellow-mark'),
          reason: 'CSS Highlights 路径要给收藏 underline 提供独立颜色变量');
      expect(bridge, contains('_hlMarkColor'),
          reason: '标记色应与背景色分开计算，避免只是另一层半透明背景');
      expect(bridge, contains('span.style.textDecorationLine = \'underline\''),
          reason: '旧 WebView span fallback 也要保留收藏语义');
      expect(bridge, contains('span.style.textDecorationColor = markColor'),
          reason: 'fallback underline 要使用独立标记色');
    });

    test('收藏高亮 ruby 和 fallback span 都保留 hoshi-hl 语义', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      final String bridge =
          File('lib/src/media/audiobook/highlight_bridge.dart')
              .readAsStringSync();

      for (final String color in <String>[
        'yellow',
        'green',
        'blue',
        'pink',
        'purple',
      ]) {
        expect(css, contains('.hoshi-hl-$color'),
            reason: '旧 WebView span fallback 应使用和 CSS Highlight 同名的颜色 class');
        expect(css, contains('ruby.hoshi-hl-$color-ruby-active'),
            reason: '收藏句高亮遇到 ruby 时应改用元素 class，避免 ::highlight 双绘遮字');
      }

      expect(bridge, contains('_rubyForNode'),
          reason: 'HighlightBridge 需要像 sasayaki/selection 一样识别 ruby 节点');
      expect(bridge, contains('rubyElements'),
          reason: 'ruby 元素应从 CSS Highlight range / fallback span 包裹中分流出来');
      expect(
        bridge,
        contains("className = 'hoshi-hl hoshi-hl-' + color"),
        reason: 'fallback span 必须暴露 hoshi-hl-* 语义，和 ::highlight(hoshi-hl-*) 对齐',
      );
      expect(
        bridge,
        contains("classList.add('hoshi-hl-' + color + '-ruby-active')"),
        reason: 'ruby 收藏高亮应使用颜色化 class，而不是包裹 ruby 内部文本',
      );
    });
  });
}
