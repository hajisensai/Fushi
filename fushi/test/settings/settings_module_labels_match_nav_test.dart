import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show IconData;
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/settings/settings_schema_card_creation.dart';
import 'package:fushi/src/settings/settings_schema_listening.dart';
import 'package:fushi/src/settings/settings_schema_navigation.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';

/// BUG-1921：设置里的「功能模块」开关名字与底栏/侧栏对不上（设置叫「小说」/
/// 「Galgame」，底栏叫「书架」/「游戏」；英文侧 Novels/Browser extension 对
/// Books/Extension）。根因是设置页抄了第二份标签（module_*_label），与底栏的
/// [homeNavItemFor] 各改各的必然漂移。
///
/// 这几条守卫钉死修复后的形状：开关标题/图标只能来自**别处已有的真值**，且整区
/// 住在「导航与首页」。它们咬的是**值相等**而不是源码字面量，所以谁再往设置里塞一份手写
/// 标签就会红。
///
/// 模块扩充之后多了一类：听书 / 制卡 / 在线服务 / AI / 同步备份**没有底栏
/// tab**（它们是横切能力，只有设置一级分类与散落在各页的入口）。这几个的真值来源
/// 换成「它自己那个设置一级分类的标题与图标」——同一个不变式，只是取值的那口井
/// 不同；下面按 [homeTabOfModule] 是否为 null 自动分流，不写第二份名单。
void main() {
  /// 模块 → 开关行 item id。id 带历史 `system.` 前缀（设置搜索的定位锚点，冻结
  /// 不改）。这张表同时钉死**顺序**：必须与 [ModuleId.values] 一致。
  const Map<ModuleId, String> moduleItemIds = <ModuleId, String>{
    ModuleId.home: 'system.module_home',
    ModuleId.books: 'system.module_books',
    ModuleId.manga: 'system.module_manga',
    ModuleId.video: 'system.module_video',
    ModuleId.music: 'system.module_music',
    ModuleId.games: 'system.module_games',
    ModuleId.browse: 'system.module_downloads',
    ModuleId.lookup: 'system.module_lookup',
    ModuleId.srs: 'system.module_srs',
    ModuleId.web: 'system.module_browser_extension',
    ModuleId.listening: 'system.module_listening',
    ModuleId.cardCreation: 'system.module_card_creation',
    ModuleId.services: 'system.module_services',
    ModuleId.ai: 'system.module_ai',
    ModuleId.sync: 'system.module_sync',
  };

  /// 没有底栏 tab 的模块 → 它自己的那条一级分类。取的是**真的那条
  /// destination**（不是重抄一遍标题字面量），分类改名 / 换图标时这里自动跟着改。
  final Map<ModuleId, SettingsDestination> destinationOfTablessModule =
      <ModuleId, SettingsDestination>{
        ModuleId.listening: buildListeningDestination(),
        ModuleId.cardCreation: buildCardCreationDestination(),
        ModuleId.services: buildServicesDestination(),
        ModuleId.ai: buildAiDestination(),
        ModuleId.sync: buildSyncBackupDestination(),
      };

  SettingsSection modulesSection() {
    final SettingsDestination navigation = buildNavigationDestination();
    return navigation.sections.firstWhere(
      (SettingsSection section) => section.title == t.settings_section_modules,
      orElse: () => throw StateError('「导航与首页」里找不到「功能模块」分区'),
    );
  }

  test('每个 ModuleId 都有且只有一个入口：导航模块进拖拽排序列表，其余逐个开关', () {
    expect(
      moduleItemIds.keys.toList(),
      ModuleId.values,
      reason: '本守卫自己的名单漏了模块；加 ModuleId 必须同时在这里点名',
    );
    expect(
      modulesSection().items.map((SettingsItem item) => item.id).toList(),
      <String>[
        // 有底栏 tab 的模块收进一个可拖拽排序的列表（顺序 = 底栏顺序）。
        'appearance.nav_module_order',
        for (final ModuleId module in ModuleId.values)
          if (homeTabOfModule(module) == null) moduleItemIds[module]!,
      ],
      reason:
          '模块分区的构成或顺序变了：先是导航模块的排序列表，再是没有 tab 的'
          '模块开关（枚举顺序），不是手写清单。',
    );
  });

  test('有底栏 tab 的模块：标题与图标取自底栏真值 homeNavItemFor', () {
    for (final ModuleId module in ModuleId.values) {
      final HomeTab? tab = homeTabOfModule(module);
      if (tab == null) continue;
      final ({String label, IconData icon}) identity = moduleNavIdentity(
        module,
      );
      final AdaptiveNavItem navItem = homeNavItemFor(tab);
      expect(
        identity.label,
        navItem.label,
        reason:
            '$module 的标题与底栏「${navItem.label}」对不上——'
            '别在设置里手写第二份标签，取 homeNavItemFor(tab).label',
      );
      expect(
        identity.icon,
        navItem.icon,
        reason: '$module 的图标与底栏不一致，取 homeNavItemFor(tab).icon',
      );
    }
  });

  test('没有底栏 tab 的模块：标题与图标取自它自己的设置一级分类', () {
    final Map<String, SettingsItem> byId = <String, SettingsItem>{
      for (final SettingsItem item in modulesSection().items) item.id: item,
    };

    for (final ModuleId module in ModuleId.values) {
      if (homeTabOfModule(module) != null) continue;
      final SettingsDestination? destination =
          destinationOfTablessModule[module];
      expect(
        destination,
        isNotNull,
        reason:
            '$module 没有 HomeTab，标签必须来自它的设置一级分类；'
            '本守卫的名单漏了它',
      );
      expect(
        moduleOfSettingsDestination(destination!.id),
        module,
        reason:
            '${destination.id} 在 module_registry 里不归 $module——'
            '开关拿着别人分类的标签，等于又抄了一份错标签',
      );
      final SettingsItem item = byId[moduleItemIds[module]!]!;
      expect(
        item.title,
        destination.title,
        reason:
            '${item.id} 的标题与设置分类「${destination.title}」对不上——'
            '别手写第二份标签，取那条 destination 的 title',
      );
      expect(
        item.icon,
        destination.icon,
        reason: '${item.id} 的图标与设置分类不一致，取那条 destination 的 icon',
      );
    }
  });

  test('五个横切模块确实没有底栏 tab（否则上面两条守卫会互相放水）', () {
    // 这条是上面「按 homeTabOfModule 分流」的前提。真给听书加了 tab 的话，
    // 分流会静默把它挪到另一条守卫下，两边都不会红——先在这里挡住。
    expect(
      ModuleId.values.where((ModuleId m) => homeTabOfModule(m) == null).toSet(),
      <ModuleId>{
        ModuleId.listening,
        ModuleId.cardCreation,
        ModuleId.services,
        ModuleId.ai,
        ModuleId.sync,
      },
    );
  });

  test('功能模块只住「导航与首页」，系统与外观里都没有残留', () {
    // 它决定底栏有哪些页、按什么顺序，与底栏样式 / 启动页同域。
    for (final SettingsDestination other in <SettingsDestination>[
      buildSystemDestination(),
      buildAppearanceDestination(),
    ]) {
      expect(
        other.sections
            .where(
              (SettingsSection section) =>
                  section.title == t.settings_section_modules,
            )
            .isEmpty,
        isTrue,
        reason: '「功能模块」应只住「导航与首页」，不该留在 ${other.id}',
      );
      expect(
        other.sections
            .expand((SettingsSection section) => section.items)
            .where(
              (SettingsItem item) => moduleItemIds.values.contains(item.id),
            )
            .isEmpty,
        isTrue,
        reason: '${other.id} 里仍残留模块开关',
      );
    }
  });
}
