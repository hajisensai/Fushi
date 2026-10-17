import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 反馈 #PwEC1evz1E：旧开关「启动时打开查词」泛化为「启动页」下拉，只能从此刻
/// 可见、有底栏 tab 的模块里选。item id 沿用旧开关的（设置搜索锚点）。
void main() {
  test('startup page setting is wired through schema and i18n', () {
    final String schema = File(
      'lib/src/settings/settings_schema_system.dart',
    ).readAsStringSync();
    expect(schema, contains("id: 'appearance.startup_default_dictionary_tab'"));
    final int at = schema.indexOf(
      "id: 'appearance.startup_default_dictionary_tab'",
    );
    final String item = schema.substring(at, at + 1200);
    expect(item, contains('t.startup_module'));
    expect(item, contains('t.startup_module_hint'));
    expect(item, contains('setStartupModule('));
    // 选项按当前可见模块求值，而不是静态全集。
    expect(item, contains('optionsBuilder:'));
    expect(item, contains('moduleVisibility'));

    final String english = File(
      'lib/i18n/strings.i18n.json',
    ).readAsStringSync();
    final String chinese = File(
      'lib/i18n/strings_zh-CN.i18n.json',
    ).readAsStringSync();
    for (final String key in <String>[
      '"startup_module"',
      '"startup_module_hint"',
      '"startup_module_default"',
    ]) {
      expect(english, contains(key));
      expect(chinese, contains(key));
    }
    // 旧文案已删（开关语义不复存在）。
    expect(english, isNot(contains('"startup_default_dictionary_tab"')));
  });
}
