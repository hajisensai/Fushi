import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/settings/settings_schema_card_creation.dart';
import 'package:fushi/src/settings/settings_schema_reading.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi/utils.dart';

/// BUG-1921：设置里的「功能模块」开关名字与底栏/侧栏对不上（设置叫「小说」/
/// 「Galgame」，底栏叫「书架」/「游戏」；英文侧 Novels/Browser extension 对
/// Books/Extension）。根因是设置页抄了第二份标签（module_*_label），与底栏的
/// [homeNavItemFor] 各改各的必然漂移。
///
/// 这几条守卫钉死修复后的形状：开关标题/图标只能来自**别处已有的真值**，且整区
/// 已搬到外观。它们咬的是**值相等**而不是源码字面量，所以谁再往设置里塞一份手写
/// 标签就会红。
///
/// 模块从 7 个扩到 11 个之后多了一类：听书 / 制卡 / 在线服务 / 同步备份**没有底栏
/// tab**（它们是横切能力，只有设置一级分类与散落在各页的入口）。这四个的真值来源
/// 换成「它自己那个设置一级分类的标题与图标」——同一个不变式，只是取值的那口井
/// 不同；下面按 [homeTabOfModule] 是否为 null 自动分流，不写第二份名单。
void main() {
  /// 模块 → 开关行 item id。id 带历史 `system.` 前缀（设置搜索的定位锚点，冻结
  /// 不改）。这张表同时钉死**顺序**：必须与 [ModuleId.values] 一致。
  const Map<ModuleId, String> moduleItemIds = <ModuleId, String>{
    ModuleId.books: 'system.module_books',
    ModuleId.manga: 'system.module_manga',
    ModuleId.video: 'system.module_video',
    ModuleId.games: 'system.module_games',
    ModuleId.downloads: 'system.module_downloads',
    ModuleId.lookup: 'system.module_lookup',
    ModuleId.browserExtension: 'system.module_browser_extension',
    ModuleId.listening: 'system.module_listening',
    ModuleId.cardCreation: 'system.module_card_creation',
    ModuleId.services: 'system.module_services',
    ModuleId.sync: 'system.module_sync',
  };

  /// 没有底栏 tab、且仍有自己一级分类的模块 → 那条分类。取的是**真的那条
  /// destination**（不是重抄一遍标题字面量），分类改名 / 换图标时这里自动跟着改。
  ///
  /// 听书 2026-08-24 并入「阅读」，不再有自己的 destination（见
  /// buildListeningSections），因此不在这张表里——它的标签真值改由下面那条
  /// 专用用例钉住。
  final Map<ModuleId, SettingsDestination> destinationOfTablessModule =
      <ModuleId, SettingsDestination>{
        ModuleId.cardCreation: buildCardCreationDestination(),
        ModuleId.services: buildServicesDestination(),
        ModuleId.sync: buildSyncBackupDestination(),
      };

  SettingsSection modulesSection() {
    final SettingsDestination appearance = buildAppearanceDestination();
    return appearance.sections.firstWhere(
      (SettingsSection section) => section.title == t.settings_section_modules,
      orElse: () => throw StateError('外观里找不到「功能模块」分区'),
    );
  }

  test('每个 ModuleId 都有且只有一个开关行，顺序与枚举一致', () {
    expect(
      moduleItemIds.keys.toList(),
      ModuleId.values,
      reason: '本守卫自己的名单漏了模块；加 ModuleId 必须同时在这里点名',
    );
    expect(
      modulesSection().items.map((SettingsItem item) => item.id).toList(),
      moduleItemIds.values.toList(),
      reason:
          '模块开关的构成或顺序变了。顺序是 ModuleId 的枚举顺序'
          '（库页 → 工具页 → 横切能力 → 设备数据），不是手写清单。',
    );
  });

  test('有底栏 tab 的模块：标题与图标取自底栏真值 homeNavItemFor', () {
    final Map<String, SettingsItem> byId = <String, SettingsItem>{
      for (final SettingsItem item in modulesSection().items) item.id: item,
    };

    for (final ModuleId module in ModuleId.values) {
      final HomeTab? tab = homeTabOfModule(module);
      if (tab == null) continue;
      final SettingsItem item = byId[moduleItemIds[module]!]!;
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

  test('没有底栏 tab 的四个模块：标题与图标取自它自己的设置一级分类', () {
    final Map<String, SettingsItem> byId = <String, SettingsItem>{
      for (final SettingsItem item in modulesSection().items) item.id: item,
    };

    for (final ModuleId module in ModuleId.values) {
      if (homeTabOfModule(module) != null) continue;
      if (module == ModuleId.listening) continue; // 见下方专用用例
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

  test('听书：并入阅读后，开关标签仍与「阅读」摘要里那半边同源', () {
    // 听书没有 destination 了，上面那条按 destination 取真值的循环够不着它。
    // 但不变式还在：开关标签不能是手写的第二份。并类后这两处共用同一个 i18n
    // key —— 开关行取 t.settings_destination_listening，「阅读」的 summary 也把它
    // 拼进去（那是并类之后用户能搜到「听书」的唯一命中面，见 settings_search 把
    // destination.summary 纳入 haystack）。任一处改成别的字面量，这条就红。
    final Map<String, SettingsItem> byId = <String, SettingsItem>{
      for (final SettingsItem item in modulesSection().items) item.id: item,
    };
    final SettingsItem item = byId[moduleItemIds[ModuleId.listening]!]!;
    expect(
      item.title,
      t.settings_destination_listening,
      reason: '听书开关的标题改成手写字面量了——它必须与阅读摘要共用同一个 key',
    );
    final String? summary = buildReadingDestination().summary;
    expect(summary, isNotNull, reason: '阅读分类没有摘要，听书在设置里就搜不到了');
    expect(
      summary,
      contains(item.title),
      reason:
          '「阅读」的摘要里不再出现「${item.title}」。并类之后这是听书唯一的可发现面：'
          '摘要参与设置搜索的 haystack，去掉它 = 用户搜「听书」什么也搜不到。',
    );
  });

  test('四个横切模块确实没有底栏 tab（否则上面两条守卫会互相放水）', () {
    // 这条是上面「按 homeTabOfModule 分流」的前提。真给听书加了 tab 的话，
    // 分流会静默把它挪到另一条守卫下，两边都不会红——先在这里挡住。
    expect(
      ModuleId.values.where((ModuleId m) => homeTabOfModule(m) == null).toSet(),
      <ModuleId>{
        ModuleId.listening,
        ModuleId.cardCreation,
        ModuleId.services,
        ModuleId.sync,
      },
    );
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
          .where((SettingsItem item) => moduleItemIds.values.contains(item.id))
          .isEmpty,
      isTrue,
      reason: '系统分区里仍残留模块开关',
    );
  });
}
