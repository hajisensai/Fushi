import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/lookup_ime_language.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart';

/// 查词设置页「查词输入法语言」项。守卫：
/// 1) 查词 destination 确有此项，且是「弹选择器」形态（不是开关/滑块）；
/// 2) 当前值只进 `titleBuilder`（渲染期求值）——塞进静态 `title` 会被设置页缓存成
///    陈旧文案，`settings_schema_cache_test.dart` 那条纯度守卫也会红；
/// 3) 该项选出来的值必须是本仓解析器认得的 BCP-47（选项表与解析器不能各走各的）。
void main() {
  SettingsItem? findLookupItem(String id) {
    final SettingsDestination dest = buildLookupDestination();
    for (final SettingsSection section in dest.sections) {
      for (final SettingsItem item in section.items) {
        if (item.id == id) return item;
      }
    }
    return null;
  }

  test('查词设置页有「查词输入法语言」项，且是导航/弹选择器形态', () {
    final SettingsItem? item = findLookupItem('lookup.ime_language');
    expect(item, isNotNull, reason: '查词设置页必须能选输入法语言');
    expect(item, isA<SettingsNavigationItem>());
    expect(
      (item! as SettingsNavigationItem).onTap,
      isNotNull,
      reason: '点它要弹语言选择器',
    );
  });

  test('当前值走 titleBuilder 而非静态 title', () {
    final SettingsItem item = findLookupItem('lookup.ime_language')!;
    expect(
      item.titleBuilder,
      isNotNull,
      reason: '当前选中的语言必须渲染期求值，否则设置页缓存会发陈旧文案',
    );
    // 静态 title 里不能出现「· <语言>」那种带当前值的形态。
    expect(item.title.contains('·'), isFalse);
  });

  test('语言选项表里的每个标签都能被输入法语言解析器认出来', () {
    // 选项来自内容语言那份共享清单；解析器认不出就等于用户选了也不生效。
    for (final String tag in <String>['ja', 'zh-Hans', 'zh-Hant', 'ko', 'en']) {
      expect(lookupImeLocaleOf(tag), isNotNull, reason: '$tag 是选择器里的选项，解析器必须认');
    }
  });

  test('未设置（空串）= 不发任何输入法提示', () {
    expect(lookupImeHintLocalesOf(''), isNull);
  });
}
