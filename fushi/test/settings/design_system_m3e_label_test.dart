import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 用户 2026-10-05：「直接外观那也改名 M3E 吧」。Material 设计系统唯一就是
/// M3 Expressive，外观页设计系统选项显示「M3E」（tooltip 全称 Material 3
/// Expressive）；持久化值仍是 `material`（冻结），只改显示文案。
///
/// 也守住用户可见文案里不再出现把这套设计系统叫「MD3 / Material Design 3」的
/// 说法（`Material You` 指 Android 壁纸取色，是另一个概念，不在此列）。
void main() {
  test('外观页设计系统选项显示 M3E，持久化值仍是 material', () {
    final String src = File(
      'lib/src/settings/settings_actions.dart',
    ).readAsStringSync();
    final int start = src.indexOf('Widget buildDesignSystemSelector(');
    expect(start, isNonNegative);
    final int end = src.indexOf('\nWidget ', start + 1);
    final String body = src.substring(start, end < 0 ? src.length : end);

    expect(body, contains("value: 'material'"));
    expect(body, contains("label: Text('M3E')"));
    expect(body, contains("tooltip: 'Material 3 Expressive'"));
    expect(body, isNot(contains("'MD3'")));
    expect(body, isNot(contains('Material Design 3')));
  });

  test('i18n 文案不再把设计系统称作 MD3 / Material Design 3', () {
    final Directory dir = Directory('lib/i18n');
    final RegExp banned = RegExp(r'\bMD3\b|Material Design 3');
    final List<String> hits = <String>[];
    for (final FileSystemEntity f in dir.listSync()) {
      if (f is! File || !f.path.endsWith('.i18n.json')) continue;
      final Map<String, dynamic> json =
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      json.forEach((String key, dynamic value) {
        if (value is String && banned.hasMatch(value)) {
          hits.add('${f.uri.pathSegments.last}: $key');
        }
      });
    }
    expect(hits, isEmpty);
  });
}
