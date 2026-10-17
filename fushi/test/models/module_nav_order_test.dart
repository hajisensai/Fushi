import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/settings/nav_module_order_list.dart';

/// 底栏 tab 顺序可由用户拖拽排序（设置 → 外观 → 功能模块）。顺序存在
/// [ModuleId.orderPrefKey]，经 [ModuleVisibility.order] 喂给 [homeActiveTabs]。
void main() {
  const Set<ModuleId> allNav = <ModuleId>{
    ModuleId.home,
    ModuleId.books,
    ModuleId.manga,
    ModuleId.video,
    ModuleId.games,
    ModuleId.browse,
    ModuleId.lookup,
    ModuleId.browserExtension,
  };

  group('顺序偏好编解码', () {
    test('用冻结的 prefKey 编码，往返一致', () {
      const List<ModuleId> order = <ModuleId>[
        ModuleId.lookup,
        ModuleId.browse,
        ModuleId.home,
      ];
      final String encoded = ModuleId.encodeOrder(order);
      expect(
        encoded,
        'module_dictionaries_enabled,module_downloads_enabled,module_home_enabled',
      );
      expect(ModuleId.parseOrder(encoded), order);
    });

    test('空值 / 未知键 / 重复项不抛异常，直接跳过', () {
      expect(ModuleId.parseOrder(null), isEmpty);
      expect(ModuleId.parseOrder(''), isEmpty);
      expect(
        ModuleId.parseOrder(
          'module_video_enabled,module_from_future,module_video_enabled',
        ),
        <ModuleId>[ModuleId.video],
      );
    });

    test('顺序键随模块开关一起是设备本地键（不进备份 / Profile）', () {
      expect(ModuleId.devicePrefKeys, contains(ModuleId.orderPrefKey));
      expect(ModuleId.devicePrefKeys, contains(ModuleId.startupPrefKey));
      expect(ModuleId.devicePrefKeys, containsAll(ModuleId.allPrefKeys));
    });
  });

  group('homeActiveTabs 按用户顺序', () {
    test('没排过 = 排序功能上线前的固定顺序', () {
      expect(homeActiveTabs(const ModuleVisibility(allNav)), <HomeTab>[
        HomeTab.home,
        HomeTab.books,
        HomeTab.manga,
        HomeTab.video,
        HomeTab.games,
        HomeTab.browse,
        HomeTab.dictionaries,
        HomeTab.browserExtension,
        HomeTab.settings,
      ]);
    });

    test('排过的模块打头，没排到的按枚举顺序接后，设置恒在最后', () {
      final List<HomeTab> tabs = homeActiveTabs(
        const ModuleVisibility(
          allNav,
          order: <ModuleId>[ModuleId.lookup, ModuleId.video],
        ),
      );
      expect(tabs, <HomeTab>[
        HomeTab.dictionaries,
        HomeTab.video,
        HomeTab.home,
        HomeTab.books,
        HomeTab.manga,
        HomeTab.games,
        HomeTab.browse,
        HomeTab.browserExtension,
        HomeTab.settings,
      ]);
    });

    test('关掉的模块不出 tab，但不打乱其余模块的相对顺序', () {
      final List<HomeTab> tabs = homeActiveTabs(
        const ModuleVisibility(
          <ModuleId>{ModuleId.books, ModuleId.lookup, ModuleId.video},
          order: <ModuleId>[
            ModuleId.lookup,
            ModuleId.home,
            ModuleId.video,
            ModuleId.books,
          ],
        ),
      );
      expect(tabs, <HomeTab>[
        HomeTab.dictionaries,
        HomeTab.video,
        HomeTab.books,
        HomeTab.settings,
      ]);
    });

    test('顺序不同的快照不相等（底栏据此重建）', () {
      expect(
        const ModuleVisibility(allNav),
        isNot(
          const ModuleVisibility(allNav, order: <ModuleId>[ModuleId.lookup]),
        ),
      );
      // 补全后同一顺序视为相等：显式写出枚举顺序 == 没排过。
      expect(
        const ModuleVisibility(allNav),
        ModuleVisibility(allNav, order: ModuleId.values.toList()),
      );
    });
  });

  group('reorderVisibleModules', () {
    test('只重排本平台可见的位置，其它模块原位不动', () {
      // 浏览器扩展（仅桌面）在手机上不出现在列表里，它在顺序里的位置要保住。
      final List<ModuleId> full = orderModules(const <ModuleId>[]);
      final List<ModuleId> visible = <ModuleId>[
        for (final ModuleId id in full)
          if (allNav.contains(id) && id != ModuleId.browserExtension) id,
      ];
      // 查词（visible 下标 6）拖到最前。
      final List<ModuleId> result = reorderVisibleModules(
        full: full,
        visible: visible,
        from: visible.indexOf(ModuleId.lookup),
        to: 0,
      );
      expect(result.length, ModuleId.values.length);
      expect(result.first, ModuleId.lookup);
      expect(
        result.indexOf(ModuleId.browserExtension),
        full.indexOf(ModuleId.browserExtension),
      );
      expect(result.indexOf(ModuleId.sync), full.indexOf(ModuleId.sync));
      expect(
        homeActiveTabs(ModuleVisibility(allNav, order: result)).take(3),
        <HomeTab>[HomeTab.dictionaries, HomeTab.home, HomeTab.books],
      );
    });
  });
}
