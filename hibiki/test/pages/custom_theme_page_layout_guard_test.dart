import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guards for the custom-theme page reorganization (TODO-072) and
/// the seed-preview hint (TODO-071). A full widget test would need the whole
/// AppModel/InAppWebView stack; the structure that matters here is purely which
/// section titles + note + hint the page references, which a source scan pins
/// reliably (reverting the work turns these red).
void main() {
  final File pageFile = File(
    'lib/src/pages/implementations/custom_theme_page.dart',
  );
  final String source = pageFile.readAsStringSync();

  group('CustomThemePage TODO-072 three-section layout', () {
    test('uses the system-theme section title', () {
      expect(source.contains('t.section_system_theme'), isTrue,
          reason: '系统主题色板块标题缺失');
    });

    test('uses the audiobook & lyrics section title', () {
      expect(source.contains('t.section_audiobook_lyrics'), isTrue,
          reason: '有声书与歌词板块标题缺失');
    });

    test('keeps the reader-text section title', () {
      expect(source.contains('t.section_reader_colors'), isTrue,
          reason: '阅读器文字板块标题缺失');
    });

    test('shows the video-subtitle note line', () {
      expect(source.contains('t.video_subtitle_color_note'), isTrue,
          reason: '视频字幕颜色说明行缺失');
      expect(source.contains('_buildNoteRow('), isTrue,
          reason: '说明行未通过 _buildNoteRow 渲染');
    });

    test(
        'sasayaki + selection sit in the audiobook section, '
        'font/bg/link in reader section', () {
      // The audiobook-lyrics section header must appear before the
      // reader-colors header, and sasayaki/selection must be ordered after the
      // audiobook header but before the reader header.
      final int audiobookIdx = source.indexOf('t.section_audiobook_lyrics');
      final int readerIdx = source.indexOf('t.section_reader_colors');
      final int sasayakiIdx = source.indexOf('t.color_sasayaki');
      final int selectionIdx = source.indexOf('t.selection_color');
      final int fontIdx = source.indexOf('t.font_color');

      expect(audiobookIdx, greaterThanOrEqualTo(0));
      expect(readerIdx, greaterThan(audiobookIdx));
      expect(sasayakiIdx, greaterThan(audiobookIdx));
      expect(sasayakiIdx, lessThan(readerIdx),
          reason: '笹語高亮应位于有声书板块（在阅读器板块之前）');
      expect(selectionIdx, greaterThan(audiobookIdx));
      expect(selectionIdx, lessThan(readerIdx), reason: '选区高亮应位于有声书板块');
      expect(fontIdx, greaterThan(readerIdx), reason: '字色应位于阅读器文字板块');
    });
  });

  group('CustomThemePage TODO-928 自定义主题跟随全局明暗 + 折叠种子色', () {
    test('不再引用自定义专属的「深色模式」开关（已删第二明暗真值的 UI）', () {
      // 删段后页面不应再出现深色三段开关的 onChanged 接线或 t.dark_mode 引用。
      expect(source.contains('t.dark_mode'), isFalse,
          reason: '自定义页仍引用 dark_mode 文案 → 深色开关未删干净');
      expect(source.contains('_setBrightnessMode'), isFalse,
          reason: '_setBrightnessMode 应随深色开关一并删除');
    });

    test('applyCustomTheme 调用不再传 brightnessMode（停写第二真值）', () {
      expect(source.contains('brightnessMode: _brightnessMode'), isFalse,
          reason: '应用按钮不应再把 _brightnessMode 写进 applyCustomTheme');
    });

    test('种子色走折叠式 _buildSeedColorPicker（默认收起，防误触）', () {
      expect(source.contains('_buildSeedColorPicker('), isTrue,
          reason: '种子色应改为折叠选色区，不再裸挂在滚动主路径');
      expect(source.contains('bool _seedExpanded = false'), isTrue,
          reason: '折叠状态应默认收起');
    });
  });

  group('CustomThemePage TODO-071 seed preview hint', () {
    test('renders the seed-preview hint through _buildHintRow', () {
      expect(source.contains('t.theme_seed_preview_hint'), isTrue,
          reason: '种子色预览提示文案缺失');
      expect(source.contains('_buildHintRow('), isTrue,
          reason: '提示未通过 _buildHintRow 渲染');
    });

    test('the hint lives in the system-theme section, above the primary toggle',
        () {
      final int systemIdx = source.indexOf('t.section_system_theme');
      final int hintIdx = source.indexOf('t.theme_seed_preview_hint');
      final int primaryIdx = source.indexOf('t.color_primary');
      expect(hintIdx, greaterThan(systemIdx), reason: '提示应在系统主题色板块内');
      expect(hintIdx, lessThan(primaryIdx), reason: '提示应在主色开关之前展示');
    });
  });
}
