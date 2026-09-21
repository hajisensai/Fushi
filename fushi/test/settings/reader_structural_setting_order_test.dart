import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2616：结构性阅读设置的持久化是异步的，必须完成后再触发 WebView 重载。
/// 否则重载读取到旧 viewMode，iOS 会继续显示旧的分页布局；随后到达的普通
/// settings 回调只重注入旧布局的 CSS，模式切换看起来就像没有生效。
void main() {
  final String source = File(
    'lib/src/settings/settings_schema_reading.dart',
  ).readAsStringSync();

  String segmentedItem(String id) {
    final int start = source.indexOf("id: '$id'");
    expect(start, greaterThanOrEqualTo(0), reason: 'missing settings item $id');
    final int end = source.indexOf('SettingsSegmentedItem<String>(', start + 1);
    return source.substring(start, end < 0 ? source.length : end);
  }

  for (final (String id, String setter) in <(String, String)>[
    ('reading_display.view_mode', 'setReaderViewMode'),
    ('reading_display.writing_mode', 'setReaderWritingMode'),
    ('reading_display.spread_mode', 'setReaderSpreadMode'),
    ('reading_display.spread_direction', 'setReaderSpreadDirection'),
  ]) {
    test('$id awaits $setter before layout reload', () {
      final String item = segmentedItem(id);
      final int callback = item.indexOf('onChanged:');
      final int awaitSetter = item.indexOf('await c.readerSource.$setter');
      final int notify = item.indexOf('notifyReaderLayoutChanged(c)');
      expect(callback, greaterThanOrEqualTo(0));
      expect(
        item.substring(callback),
        contains('onChanged: (SettingsContext c, String v) async'),
      );
      expect(awaitSetter, greaterThan(callback));
      expect(notify, greaterThan(awaitSetter));
    });
  }
}
