import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'startup default dictionary tab setting is wired through schema and i18n',
      () {
    // 阶段 G 归位：该项从「外观」分区移到「系统 · 通用」分区（item id 不变）。
    final String schema =
        File('lib/src/settings/settings_schema_system.dart').readAsStringSync();
    expect(schema, contains("id: 'appearance.startup_default_dictionary_tab'"));
    expect(schema, contains('t.startup_default_dictionary_tab'));
    expect(schema, contains('t.startup_default_dictionary_tab_hint'));

    final String english =
        File('lib/i18n/strings.i18n.json').readAsStringSync();
    final String chinese =
        File('lib/i18n/strings_zh-CN.i18n.json').readAsStringSync();
    expect(english, contains('"startup_default_dictionary_tab"'));
    expect(english, contains('"startup_default_dictionary_tab_hint"'));
    expect(chinese, contains('"startup_default_dictionary_tab"'));
    expect(chinese, contains('"startup_default_dictionary_tab_hint"'));
  });
}
