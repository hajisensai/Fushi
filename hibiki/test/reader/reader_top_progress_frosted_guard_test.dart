import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// BUG-547 / TODO-1136：悬浮阅读进度文字直接叠在正文上，浅色书/复杂背景下看不清。
/// 修复在文字后加一层毛玻璃背景（ClipRRect > BackdropFilter(ImageFilter.blur) >
/// 半透明 Container），背景色跟随主题背景、文字色跟随主题文字色。此守卫从合并语料切出
/// `_buildTopProgressBar` 方法体，断言毛玻璃三件套俱在且颜色跟随主题、未被硬编码，
/// 防止回退成裸 Text 或不透明纯色块。
void main() {
  test('top reading progress wraps text in a theme-following frosted layer',
      () {
    final String src = readReaderPageSource();
    final String body = _functionSource(
      src,
      '  Widget _buildTopProgressBar()',
    );

    // 毛玻璃三件套：限定范围的裁剪 + backdrop blur + 半透明容器。
    expect(
      body,
      contains('ClipRRect'),
      reason:
          'frosted layer must clip the blur to the pill (no whole-page blur)',
    );
    expect(
      body,
      contains('BackdropFilter'),
      reason: 'progress pill must sit on a BackdropFilter frosted layer',
    );
    expect(
      body,
      contains('ImageFilter.blur'),
      reason: 'the frosted layer must actually blur the content behind it',
    );

    // 背景色跟随主题背景（半透明），文字色跟随主题文字色——都不硬编码。
    expect(
      body,
      contains('_themeBackgroundColor()'),
      reason: 'frosted fill must follow the active reader theme background',
    );
    expect(
      body,
      contains('withValues('),
      reason: 'frosted fill must stay translucent, not an opaque block that '
          'hides the content behind it',
    );
    expect(
      body,
      contains('_themeTextColor()'),
      reason: 'progress text color must follow the active reader theme text',
    );

    // 文字仍在语料内、pill 仍带内边距（可读性）。
    expect(
      body,
      contains("ValueKey<String>('hoshi_progress')"),
      reason: 'the progress Text (hoshi_progress) must remain inside the pill',
    );
    expect(
      body,
      contains('EdgeInsets.symmetric('),
      reason:
          'the frosted pill must pad the text so it does not touch the edge',
    );
  });
}

String _functionSource(String source, String start) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int bodyStart = source.indexOf('{', startIndex + start.length);
  expect(bodyStart, isNonNegative, reason: 'Missing function body: $start');

  int depth = 0;
  for (int index = bodyStart; index < source.length; index++) {
    final String char = source[index];
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(startIndex, index + 1);
      }
    }
  }

  fail('Missing function end: $start');
}
