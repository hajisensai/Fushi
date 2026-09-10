import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_search.dart';

import '../helpers/test_platform_services.dart';

/// 「功能模块」关掉一个模块之后，**设置页里属于它的一级分类必须整条消失**——
/// 列表里没有、搜索索引里也没有（用户拍板的隐藏强度：「看不见也到不了」）。
///
/// 这条是四个新模块（听书 / 制卡 / 在线服务 / 同步备份）唯一的落地面证据：它们
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

  testWidgets('三个横切模块各自真的名下有分类（否则上面三条在空集上恒绿）', (WidgetTester tester) async {
    // 制卡/在线服务/同步没有底栏 tab，设置分类是它们唯一的可断言落地面。
    // 归属表一旦被改成 null，上面的循环会在空集上静默通过——先在这里挡住。
    //
    // 听书不在这份名单里：2026-08-24 它并入了「阅读」分类（见
    // buildListeningSections），落地面从「一条一级分类」降到「阅读里的两个分区」。
    // 上面那三条循环只认 destination 级归属，对听书因此是空集恒绿——真正的门控
    // 断言挪到下面那条专用用例，别把这里的名单当成全部覆盖。
    await pumpContext(tester);
    appModel.enabled = ModuleId.values.toSet();
    final Set<SettingsDestinationId> visible = visibleIds();
    for (final ModuleId module in <ModuleId>[
      ModuleId.cardCreation,
      ModuleId.services,
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

  testWidgets('听书模块的落地面是「阅读」里的两个分区（分区级门控，非分类级）', (
    WidgetTester tester,
  ) async {
    // 并类之后听书没有自己的 destination，上面按 destination 归属做的三条循环
    // 对它恒为空集。不变式本身没变——「关掉模块 ⇒ 它的设置行看不见也搜不到」——
    // 只是粒度降到了分区，所以这里直接按 item id 前缀断言那条不变式。
    await pumpContext(tester);

    // 断言落在**分区可见性**上，而不是展平后的行：桩 AppModel 没有 prefsRepo，
    // 求值 item 的 visible/titleBuilder 会当场抛（上面第三条用例同样靠只展平
    // 模块名下那几条来绕开）。分区不可见时其下的行本就进不了搜索索引
    // （SettingsSection.visibleCopy 先过滤分区，flattenVisibleSettings 再展平），
    // 所以这一层就是「看不见也到不了」的收口点。
    List<String> visibleListeningSectionIds() {
      final List<SettingsDestination> reading = buildSettingsSchema(sctx)
          .where(
            (SettingsDestination d) => d.id == SettingsDestinationId.reading,
          )
          .toList();
      expect(reading, hasLength(1), reason: '阅读分类不见了，下面的断言会在空集上恒绿');
      return reading.single.sections
          .where((SettingsSection s) => s.isVisible(sctx))
          .map((SettingsSection s) => s.id)
          .whereType<String>()
          .where((String id) => id.startsWith('listening.'))
          .toList();
    }

    appModel.enabled = ModuleId.values.toSet();
    expect(
      visibleListeningSectionIds(),
      hasLength(2),
      reason: '听书模块开着却看不到那两个分区——并入阅读时把分区门写反了，'
          '或者分区根本没被展开进 buildReadingDestination',
    );

    appModel.enabled = ModuleId.values.toSet()..remove(ModuleId.listening);
    expect(
      visibleListeningSectionIds(),
      isEmpty,
      reason: '关掉听书模块后 listening.* 分区还在阅读里。并类时模块门原本挂在'
          'destination 上，下放到分区时漏了哪一个，这条就会红。',
    );
  });
}

class _ModuleGatingAppModel extends AppModel {
  _ModuleGatingAppModel() : super(testPlatformServices());

  /// 直接摆布合成结果，绕开 prefs 仓库与平台判据——本测试要钉的是「门控消费端
  /// 按可见性收缩」，pref 读取与平台剔除各有自己的用例（`module_registry_test`）。
  Set<ModuleId> enabled = ModuleId.values.toSet();

  @override
  ModuleVisibility get moduleVisibility => ModuleVisibility(enabled);
}
