import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/utils.dart';

/// BUG-1921：设置里的「功能模块」开关名字与底栏/侧栏对不上（设置叫「小说」/
/// 「Galgame」，底栏叫「书架」/「游戏」；英文侧 Novels/Browser extension 对
/// Books/Extension）。根因是设置页抄了第二份标签（module_*_label），与底栏的
/// [homeNavItemFor] 各改各的必然漂移。
///
/// 这两条守卫钉死修复后的形状：开关标题/图标只能来自底栏真值，且整区已搬到外观。
/// 它们咬的是**值相等**而不是源码字面量，所以谁再往设置里塞一份手写标签就会红。
void main() {
  /// 每个模块开关 id → 它在底栏/侧栏代表的 tab。顺序与 schema 内一致
  /// （库页 → 下载 → 查词 → 扩展）。
  const Map<String, HomeTab> moduleTabById = <String, HomeTab>{
    'system.module_books': HomeTab.books,
    'system.module_manga': HomeTab.manga,
    'system.module_video': HomeTab.video,
    'system.module_games': HomeTab.games,
    'system.module_downloads': HomeTab.downloads,
    'system.module_lookup': HomeTab.dictionaries,
    'system.module_browser_extension': HomeTab.browserExtension,
  };

  SettingsSection modulesSection() {
    final SettingsDestination appearance = buildAppearanceDestination();
    return appearance.sections.firstWhere(
      (SettingsSection section) => section.title == t.settings_section_modules,
      orElse: () => throw StateError('外观里找不到「功能模块」分区'),
    );
  }

  test('功能模块开关的标题与图标取自底栏真值 homeNavItemFor', () {
    final SettingsSection section = modulesSection();

    expect(
      section.items.map((SettingsItem item) => item.id).toList(),
      moduleTabById.keys.toList(),
      reason: '模块开关的构成或顺序变了；顺序必须与底栏一致',
    );

    for (final SettingsItem item in section.items) {
      final HomeTab tab = moduleTabById[item.id]!;
      final AdaptiveNavItem navItem = homeNavItemFor(tab);
      expect(
        item.title,
        navItem.label,
        reason: '${item.id} 的标题与底栏「${navItem.label}」对不上——'
            '别在设置里手写第二份标签，取 homeNavItemFor(tab).label',
      );
      expect(
        item.icon,
        navItem.icon,
        reason: '${item.id} 的图标与底栏不一致，取 homeNavItemFor(tab).icon',
      );
    }
  });

  test('功能模块已从系统分区搬到外观分区', () {
    final SettingsDestination system = buildSystemDestination();

    expect(
      system.sections
          .where(
            (SettingsSection section) =>
                section.title == t.settings_section_modules,
          )
          .isEmpty,
      isTrue,
      reason: '「功能模块」应住外观（与「反转导航栏」同域），不该留在系统',
    );
    expect(
      system.sections
          .expand((SettingsSection section) => section.items)
          .where((SettingsItem item) => moduleTabById.containsKey(item.id))
          .isEmpty,
      isTrue,
      reason: '系统分区里仍残留模块开关',
    );
  });
}
