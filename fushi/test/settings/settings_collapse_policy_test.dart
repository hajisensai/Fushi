// 长分类的默认折叠策略守卫（2026-08-24）。
//
// 用户诉求「调整自动展开、非自动展开的配置项」落成一条规则：**一个分类只默认展开
// 最常调的一两组，其余带标题的分区默认折叠**。理由是详情页一屏能容纳的是「分区标题
// 的清单」而不是「几十行配置」——阅读并入听书后 8 组 49 项、视频 11 组 81 项、查词
// 7 组 44 项，全平铺的话用户要滚三四屏才知道这个分类里有什么。
//
// 守卫只钉可维护的上界，不钉「具体哪一组展开」（那是产品判断，会随功能重心变）：
// 分区数 >= 7 的分类，默认展开的带标题分区不超过 3 个。
//
// 阈值取 7 而不是「所有分类」：6 组以内的详情页一屏就能扫完分区标题，全平铺不构成
// 问题（互联那种「配一次就不再碰」的流程页反而更适合平铺）。这条守卫防的是超长分类
// 退回全平铺，不是要求人人折叠。
//
// 注意 collapsedByDefault 只对带 title 的分区生效（无题分区没有可点的头，恒平铺，
// 见 SettingsSection.collapsedByDefault），所以计数只看带标题的。
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 触发本规则的分区数下限。
const int kLongDestinationSectionCount = 7;

/// 长分类允许的默认展开分区上限。
const int kMaxExpandedSections = 3;

void main() {
  Future<SettingsContext> makeContext(WidgetTester tester) async {
    final FushiDatabase db =
        FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tempDir =
        Directory.systemTemp.createTempSync('hibiki_collapse_policy_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tempDir,
      )
      ..wireDatabaseForTesting(db);

    late SettingsContext sctx;
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        home: Consumer(
          builder: (BuildContext ctx, WidgetRef ref, Widget? _) {
            sctx = SettingsContext(
              context: ctx,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ));
    return sctx;
  }

  /// 带标题的分区（无题分区不可折叠，不计入）。
  List<SettingsSection> titledSections(SettingsDestination d) =>
      d.sections
          .where((SettingsSection s) => (s.title ?? '').isNotEmpty)
          .toList(growable: false);

  testWidgets('分区多的分类不得全平铺（默认展开 <= $kMaxExpandedSections 组）',
      (WidgetTester tester) async {
    final SettingsContext sctx = await makeContext(tester);
    final Map<String, int> offenders = <String, int>{};
    int longDestinations = 0;
    for (final SettingsDestination d in buildSettingsSchema(sctx)) {
      final List<SettingsSection> titled = titledSections(d);
      if (titled.length < kLongDestinationSectionCount) continue;
      longDestinations += 1;
      final int expanded = titled
          .where((SettingsSection s) => !s.collapsedByDefault)
          .length;
      if (expanded > kMaxExpandedSections) offenders[d.id.name] = expanded;
    }
    // 规则本身要有作用对象——阈值以上一个分类都没有，说明这条守卫已经空转
    // （分类被拆小了就该重新定阈值，而不是留一条恒真断言）。
    expect(longDestinations, greaterThan(0),
        reason: '没有分区数 >= $kLongDestinationSectionCount 的分类了，本守卫需要重新定阈值');
    expect(
      offenders,
      isEmpty,
      reason: '这些分类默认展开的分区过多，进详情页要滚几屏才知道里面有什么：$offenders',
    );
  });

  testWidgets('阅读：默认展开的正是三组核心（模式 / 排版 / 有声书）',
      (WidgetTester tester) async {
    final SettingsContext sctx = await makeContext(tester);
    final SettingsDestination reading = buildSettingsSchema(sctx).firstWhere(
      (SettingsDestination d) => d.id == SettingsDestinationId.reading,
    );
    final List<String> expanded = titledSections(reading)
        .where((SettingsSection s) => !s.collapsedByDefault)
        .map((SettingsSection s) => s.title!)
        .toList(growable: false);
    expect(expanded, hasLength(3));
    expect(
      expanded,
      containsAll(<String>[t.reading_section_mode, t.section_typography]),
      reason: '模式与排版是进阅读设置最先要调的两组',
    );
    // 「有声书」这组必须还在默认展开里：听书并进来后不能被折叠一起藏掉——那等于
    // 把一个原本的一级分类降级成了两次点击才够得着。
    expect(expanded, contains(t.section_audiobook));
    final List<String> collapsed = titledSections(reading)
        .where((SettingsSection s) => s.collapsedByDefault)
        .map((SettingsSection s) => s.title!)
        .toList(growable: false);
    expect(collapsed, isNotEmpty);
    expect(expanded.length + collapsed.length, titledSections(reading).length);
  });
}
