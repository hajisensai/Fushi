import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeNavItemFor;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_search.dart';

import '../helpers/test_platform_services.dart';

/// 「功能模块」关掉一个模块之后，**设置页里属于它的一级分类必须整条消失**——
/// 列表里没有、搜索索引里也没有（用户拍板的隐藏强度：「看不见也到不了」）。
///
/// 这条是横切模块（听书 / 制卡 / 在线服务 / AI / 同步备份）唯一的落地面证据：它们
/// **没有底栏 tab**，`homeActiveTabs` 那套用例根本咬不到；开关翻转之后能观测到的
/// 全部效果就在这里。`settings_schema_coverage_test.dart` 的 `kCoveredElsewhere`
/// 指向本文件，删了这条会让那边直接红。
///
/// 归属真值是 [moduleOfSettingsDestination]（`module_registry.dart`），本测试
/// **不重抄一份名单**：期望值当场从映射表派生，映射改了这里自动跟着改。
void main() {
  /// 覆写可见性即可——`moduleVisibility` 是全 app 门控的唯一合成点，各 destination
  /// 的 `visible` 谓词读的就是它（`isSettingsDestinationVisible(id, ...)`）。
  late _ModuleGatingAppModel appModel;
  late SettingsContext sctx;

  Future<void> pumpContext(WidgetTester tester) async {
    appModel = _ModuleGatingAppModel();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sctx = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  Set<SettingsDestinationId> visibleIds() => buildSettingsSchema(sctx)
      .where((SettingsDestination d) => d.isVisible(sctx))
      .map((SettingsDestination d) => d.id)
      .toSet();

  testWidgets('全部模块开着时，每条一级分类都在（门控没有误伤恒在项）', (WidgetTester tester) async {
    await pumpContext(tester);
    appModel.enabled = ModuleId.values.toSet();
    final List<SettingsDestination> all = buildSettingsSchema(sctx);
    final Set<SettingsDestinationId> visible = visibleIds();
    for (final SettingsDestination destination in all) {
      if (moduleOfSettingsDestination(destination.id) == null) continue;
      expect(
        visible,
        contains(destination.id),
        reason: '${destination.id} 的模块开着却不可见——门控写反了',
      );
    }
  });

  testWidgets('游戏设置分类只属于本机游戏库形态：串流接收端模块开着也不出现', (WidgetTester tester) async {
    // 非 Windows 的 games 模块是串流接收端（PR #1616）；游戏分类里的 hook / 捕获
    // 工作台 / 兼容性诊断全是本机 galgame 库的东西，一条都用不上。
    await pumpContext(tester);
    appModel.enabled = ModuleId.values.toSet();
    expect(visibleIds(), contains(SettingsDestinationId.game));
    appModel.gamesForm = GamesModuleForm.streamClient;
    expect(visibleIds(), isNot(contains(SettingsDestinationId.game)));
  });

  testWidgets('逐个关模块：只有它名下的分类消失，别的一条都不少', (WidgetTester tester) async {
    await pumpContext(tester);
    appModel.enabled = ModuleId.values.toSet();
    final Set<SettingsDestinationId> baseline = visibleIds();

    for (final ModuleId module in ModuleId.values) {
      // 期望值从归属表派生，不重抄名单。
      final Set<SettingsDestinationId> owned = baseline
          .where(
            (SettingsDestinationId id) =>
                moduleOfSettingsDestination(id) == module,
          )
          .toSet();

      appModel.enabled = ModuleId.values.toSet()..remove(module);
      final Set<SettingsDestinationId> after = visibleIds();

      expect(
        after.intersection(owned),
        isEmpty,
        reason: '关掉 $module 之后 ${after.intersection(owned)} 还列在设置主页上',
      );
      expect(
        after,
        baseline.difference(owned),
        reason:
            '关掉 $module 波及了不属于它的分类。成对分类（在线服务+媒体追踪、'
            '同步备份+互联）必须同进同出，恒在分类一条都不能少。',
      );
    }
  });

  testWidgets('关掉的模块在设置搜索索引里一条都不剩（看不见也到不了）', (WidgetTester tester) async {
    await pumpContext(tester);
    appModel.enabled = ModuleId.values.toSet();
    final List<SettingsDestination> all = buildSettingsSchema(sctx);

    for (final ModuleId module in ModuleId.values) {
      final List<SettingsDestination> owned = all
          .where(
            (SettingsDestination d) =>
                moduleOfSettingsDestination(d.id) == module,
          )
          .toList();
      if (owned.isEmpty) continue;

      appModel.enabled = ModuleId.values.toSet()..remove(module);
      expect(
        flattenVisibleSettings(owned, sctx),
        isEmpty,
        reason:
            '关掉 $module 之后它的设置行还能被搜出来。搜索命中会把用户送进一个'
            '本该不存在的分类详情页——「隐藏」就只剩视觉效果了。',
      );
    }
  });

  testWidgets('导航模块合进拖拽排序列表后，按模块名仍能搜到（直达那块列表）', (WidgetTester tester) async {
    await pumpContext(tester);
    appModel.enabled = ModuleId.values.toSet();
    // 只展平「功能模块」这一个分区（住「导航与首页」）：桩 AppModel 没有
    // prefsRepo，同页别的行（读偏好的标题闭包）在这里会抛 null check，与本条要咬的
    // 东西无关。
    final SettingsDestination navigation = buildSettingsSchema(sctx).firstWhere(
      (SettingsDestination d) => d.id == SettingsDestinationId.navigation,
    );
    final List<SettingsSearchEntry> entries = flattenVisibleSettings(
      <SettingsDestination>[
        SettingsDestination(
          id: navigation.id,
          title: navigation.title,
          icon: navigation.icon,
          sections: <SettingsSection>[
            navigation.sections.firstWhere(
              (SettingsSection s) => s.id == 'appearance.section.modules',
            ),
          ],
        ),
      ],
      sctx,
    );
    for (final ModuleId module in <ModuleId>[
      ModuleId.home,
      ModuleId.books,
      ModuleId.manga,
      ModuleId.video,
      ModuleId.lookup,
    ]) {
      final String label = homeNavItemFor(homeTabOfModule(module)!).label;
      final List<SettingsSearchEntry> hits = filterSettingsEntries(
        entries,
        label,
      );
      expect(
        hits.map((SettingsSearchEntry e) => e.item.id),
        contains('appearance.nav_module_order'),
        reason: '搜「$label」找不到功能模块里的那一行开关了',
      );
      final SettingsSearchEntry hit = hits.firstWhere(
        (SettingsSearchEntry e) => e.item.id == 'appearance.nav_module_order',
      );
      expect(
        hit.matchedDetail(label),
        label,
        reason: '结果行要露出命中的模块名，用户才知道这块列表里有「$label」',
      );
    }
  });

  testWidgets('横切模块各自真的名下有分类（否则上面三条在空集上恒绿）', (WidgetTester tester) async {
    // 听书 / 制卡 / 在线服务 / AI / 同步没有底栏 tab，设置分类是它们唯一的可断言
    // 落地面。归属表一旦被改成 null，上面的循环会在空集上静默通过——先在这里挡住。
    await pumpContext(tester);
    appModel.enabled = ModuleId.values.toSet();
    final Set<SettingsDestinationId> visible = visibleIds();
    for (final ModuleId module in <ModuleId>[
      ModuleId.listening,
      ModuleId.cardCreation,
      ModuleId.services,
      ModuleId.ai,
      ModuleId.sync,
    ]) {
      expect(
        visible.where(
          (SettingsDestinationId id) =>
              moduleOfSettingsDestination(id) == module,
        ),
        isNotEmpty,
        reason: '$module 名下没有任何可见设置分类，它的开关就没有落地面了',
      );
    }
  });

  testWidgets('AI 模块的落地面是独立的「AI」分类，「本机模型」不再挂 LLM 入口', (
    WidgetTester tester,
  ) async {
    // AI 重新是一级分类（buildAiDestination），按 destination 归属被上面的循环
    // 覆盖；这里点名钉住，并确认「本机模型」里不再残留 models.llm 这条旁路入口
    // ——它若复活，模型分类不跟 AI 模块走，关掉 AI 仍能从那里进 AI 设置。
    await pumpContext(tester);

    appModel.enabled = ModuleId.values.toSet();
    expect(visibleIds(), contains(SettingsDestinationId.ai));
    final SettingsDestination models = buildSettingsSchema(sctx).singleWhere(
      (SettingsDestination d) => d.id == SettingsDestinationId.models,
    );
    expect(
      models.sections
          .expand((SettingsSection s) => s.items)
          .map((SettingsItem i) => i.id),
      isNot(contains('models.llm')),
    );

    appModel.enabled = ModuleId.values.toSet()..remove(ModuleId.ai);
    expect(
      visibleIds(),
      isNot(contains(SettingsDestinationId.ai)),
      reason: '关掉 AI 模块后「AI」分类仍列在设置主页上',
    );
    expect(
      visibleIds(),
      contains(SettingsDestinationId.models),
      reason: '本机模型是设备级资源，不能跟着 AI 模块一起消失',
    );
  });

  testWidgets('听书模块的落地面是独立的「听书」分类，阅读页不再混入听书分区', (WidgetTester tester) async {
    // 听书重新是一级分类：模块门挂在 destination 上（上面三条循环覆盖），分区上
    // 的 listeningModuleOn 门是同一判据的冗余。这里钉住两件事：开关翻转时分类
    // 进出；阅读页里没有任何 listening.* 分区（否则关掉听书后它们仍会从阅读页漏出来）。
    await pumpContext(tester);

    appModel.enabled = ModuleId.values.toSet();
    expect(visibleIds(), contains(SettingsDestinationId.listening));
    final SettingsDestination reading = buildSettingsSchema(sctx).singleWhere(
      (SettingsDestination d) => d.id == SettingsDestinationId.reading,
    );
    expect(
      reading.sections
          .map((SettingsSection s) => s.id)
          .whereType<String>()
          .where((String id) => id.startsWith('listening.')),
      isEmpty,
    );

    appModel.enabled = ModuleId.values.toSet()..remove(ModuleId.listening);
    expect(
      visibleIds(),
      isNot(contains(SettingsDestinationId.listening)),
      reason: '关掉听书模块后「听书」分类仍列在设置主页上',
    );
    expect(visibleIds(), contains(SettingsDestinationId.reading));
  });
}

class _ModuleGatingAppModel extends AppModel {
  _ModuleGatingAppModel() : super(testPlatformServices());

  /// 直接摆布合成结果，绕开 prefs 仓库与平台判据——本测试要钉的是「门控消费端
  /// 按可见性收缩」，pref 读取与平台剔除各有自己的用例（`module_registry_test`）。
  Set<ModuleId> enabled = ModuleId.values.toSet();

  /// 与上面「绕开平台判据」同一前提：games 模块按本机游戏库形态参与门控。不覆写就
  /// 取宿主平台（CI 的 Linux 上是 null），游戏设置分类在「全部模块开着」时也不可见。
  GamesModuleForm gamesForm = GamesModuleForm.localLibrary;

  @override
  ModuleVisibility get moduleVisibility => ModuleVisibility(enabled);

  @override
  GamesModuleForm get gamesModuleForm => gamesForm;
}
