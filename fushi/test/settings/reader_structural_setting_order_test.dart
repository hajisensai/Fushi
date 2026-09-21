import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2616：**结构性**阅读设置（改完要重建 WebView 的那些）的 `onChanged` 必须
/// `await` 异步 setter，再调 `notifyReaderLayoutChanged`。
///
/// 不 await 的后果不是「重载读到旧设置」——`ReaderSettings._set` 第一行就同步写
/// 内存缓存、读侧 `_get` 直接读缓存，重载怎么排都拿得到新值。真正错位的是**两个
/// 钩子的先后**：setter 内部在 `await` 持久化之后才 `onSettingsChangedLive`
/// （CSS 重注入），不 await 就变成「先结构重载 → 重载途中迟到的 CSS 重注入打进
/// 正在重建的 WebView」；iOS 的 WKWebView 重载慢、窗口更宽，表现为切了模式却还是
/// 旧布局。
///
/// 这批项在源码里曾经是两种写法并存（10 处 async + 8 处 fire-and-forget），守卫
/// 把它们钉齐：新增结构性设置照抄同一形状。
void main() {
  final String source = File(
    'lib/src/settings/settings_schema_reading.dart',
  ).readAsStringSync();

  /// 一个设置项的源码片段：从它的 `id:` 起到下一个 `id:` 为止。
  String itemOf(String id) {
    final int start = source.indexOf("id: '$id'");
    expect(start, greaterThanOrEqualTo(0), reason: 'missing settings item $id');
    final int end = source.indexOf("id: '", start + 1);
    return source.substring(start, end < 0 ? source.length : end);
  }

  for (final (String id, String setter) in <(String, String)>[
    ('reading_display.view_mode', 'setReaderViewMode'),
    ('reading_display.writing_mode', 'setReaderWritingMode'),
    ('reading_display.spread_mode', 'setReaderSpreadMode'),
    ('reading_display.spread_direction', 'setReaderSpreadDirection'),
    ('reading_display.page_columns', 'setReaderPageColumns'),
    (
      'reading_display.prioritize_reader_styles',
      'setReaderPrioritizeReaderStyles'
    ),
    ('reading_display.blur_images', 'setReaderBlurImages'),
    ('reading_display.merge_image_pages', 'setReaderMergeImagePages'),
  ]) {
    test('$id awaits $setter before layout reload', () {
      final String item = itemOf(id);
      final int callback = item.indexOf('onChanged:');
      final int awaitSetter = item.indexOf('await c.readerSource.$setter');
      final int notify = item.indexOf('notifyReaderLayoutChanged(c)');
      expect(callback, greaterThanOrEqualTo(0));
      expect(
        item.substring(callback, item.indexOf('{', callback) + 1),
        contains('async'),
        reason: '回调必须是 async，否则 await 写不进去',
      );
      expect(awaitSetter, greaterThan(callback));
      expect(notify, greaterThan(awaitSetter));
    });
  }

  test('结构性设置没有漏网的 fire-and-forget 写法', () {
    // `notifyReaderLayoutChanged(c)` 之前的那一行若是裸 `c.readerSource.setX(`
    // （无 await），就是本 bug 的形状。
    final List<String> offenders = <String>[];
    int at = source.indexOf('notifyReaderLayoutChanged(c)');
    while (at >= 0) {
      final int lineStart = source.lastIndexOf('\n', at - 1);
      final int prevStart = source.lastIndexOf('\n', lineStart - 1);
      final String previous = source.substring(prevStart + 1, lineStart).trim();
      if (previous.startsWith('c.readerSource.set')) {
        offenders.add(previous);
      }
      at = source.indexOf('notifyReaderLayoutChanged(c)', at + 1);
    }
    expect(
      offenders,
      isEmpty,
      reason: '这些 setter 返回 Future，必须 await 后再触发重载：$offenders',
    );
  });
}
