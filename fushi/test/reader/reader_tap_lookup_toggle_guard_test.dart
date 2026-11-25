import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_settings_ia.dart';

/// GitHub #3088（反馈 6UvuZxRQkW，BUG-4368）：阅读器「单击查词」开关。
///
/// 开关早就存在（持久化 key `highlight_on_tap`，门控 JS 点词镜像
/// `__fushiTapGate.lookup` 与 Dart `onTap`），但标题是「点击时高亮文本」，用户
/// 找不到；这里钉住设置项的文案与位置。关掉后的手势语义由
/// `reader_paged_touch_swipe_behavior_test.js`（Node 真执行）与
/// `reader_tap_zones_test.dart` / `reader_dismiss_barrier_tap_test.dart` 覆盖。
void main() {
  final String schema = File(
    'lib/src/settings/settings_schema_reading.dart',
  ).readAsStringSync();

  String itemBody(String id) {
    final int start = schema.indexOf("id: '$id',");
    expect(start, greaterThanOrEqualTo(0), reason: '找不到设置项 $id');
    final int end = schema.indexOf('SettingsSwitchItem(', start);
    return schema.substring(start, end < 0 ? schema.length : end);
  }

  test('设置项标题是「单击查词」并带关闭后的行为说明', () {
    final String body = itemBody('reading_controls.highlight_on_tap');
    expect(body, contains('title: t.reader_tap_lookup_enabled,'));
    expect(body, contains('subtitle: t.reader_tap_lookup_description,'));
    expect(
      body,
      isNot(contains('t.highlight_on_tap')),
      reason: '旧标题「点击时高亮文本」名不副实（GitHub #3088）',
    );
  });

  test('i18n 文案：英文与简中说清楚是查词开关', () {
    final String en = File('lib/i18n/strings.i18n.json').readAsStringSync();
    final String zh = File(
      'lib/i18n/strings_zh-CN.i18n.json',
    ).readAsStringSync();
    expect(en, contains('"reader_tap_lookup_enabled": "Look up words on tap"'));
    expect(zh, contains('"reader_tap_lookup_enabled": "单击查词"'));
    expect(en, isNot(contains('"highlight_on_tap"')));
  });

  test('开关在阅读器设置面板「翻页与手势」里', () {
    final bool listed = kReaderSettingsSections.any(
      (ReaderSettingsSectionSpec s) =>
          s.tab == ReaderSettingsTab.gestures &&
          s.itemIds.contains('reading_controls.highlight_on_tap'),
    );
    expect(listed, isTrue);
  });
}
