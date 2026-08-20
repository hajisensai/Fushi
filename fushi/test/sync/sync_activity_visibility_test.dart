import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_progress_banner.dart';

/// 「同步进度条只有一条线、没有任何文字」的回归守卫。
///
/// 用户报告：书架页顶部那条细线在转，但一个字都没有，无从判断到底是在同步还是在
/// 空转。根因是状态模型缺了一层——`syncInProgress` 是裸 bool，`syncProgress` 只在
/// 编排器真进入某个阶段后才有值，于是三种完全不同的现实在界面上同形：
///   1. 跑的是合集 / 单本这两条天生没有阶段结构的轻量路径；
///   2. 全量 sweep 还停在第一个阶段 tick 之前的准备段（等锁 / 读开关 / 网络鉴权）；
///   3. 所有通道都没通过认证被跳过 —— 什么也没同步的纯空转。
///
/// 断言用语言无关信号（非空、两两不同、含书名），不绑定具体措辞，避免 17 语言脆弱。
void main() {
  group('syncActivityLine：没有阶段 tick 时也必须说清这轮同步是谁', () {
    test('三种同步身份各有各的文案，且都不为空', () {
      final Map<SyncActivityKind, String> lines = <SyncActivityKind, String>{
        for (final SyncActivityKind kind in SyncActivityKind.values)
          kind: syncActivityLine(SyncActivity(kind)),
      };
      for (final MapEntry<SyncActivityKind, String> e in lines.entries) {
        expect(e.value, isNotEmpty, reason: '${e.key} 没有可显示的文案');
      }
      // 两两不同：否则用户仍分不清在跑哪一种同步。
      expect(
        lines.values.toSet().length,
        SyncActivityKind.values.length,
        reason: '不同种类的同步必须显示不同文案',
      );
    });

    test('单本同步拿到书名后把书名显示出来', () {
      const String title = 'Do Androids Dream of Electric Sheep?';
      final String withTitle = syncActivityLine(
        const SyncActivity(SyncActivityKind.singleBook, title: title),
      );
      expect(withTitle, contains(title));
      // 没书名时退化成不带名字的文案，不能漏出空引号 / null。
      final String withoutTitle =
          syncActivityLine(const SyncActivity(SyncActivityKind.singleBook));
      expect(withoutTitle, isNotEmpty);
      expect(withoutTitle, isNot(contains('null')));
      expect(withoutTitle, isNot(equals(withTitle)));
    });

    test('空字符串书名按「没有书名」处理（不显示空标题）', () {
      final String line = syncActivityLine(
        const SyncActivity(SyncActivityKind.singleBook, title: ''),
      );
      expect(
        line,
        equals(
            syncActivityLine(const SyncActivity(SyncActivityKind.singleBook))),
      );
    });
  });

  group('syncOutcomeLine：一轮同步结束后必须留下可读的结局', () {
    test('每种结局各有各的文案，且都不为空', () {
      final Map<SyncOutcomeReason, String> lines = <SyncOutcomeReason, String>{
        for (final SyncOutcomeReason reason in SyncOutcomeReason.values)
          reason: syncOutcomeLine(SyncRunOutcome(
            kind: SyncActivityKind.fullSweep,
            reason: reason,
            channelsRun: reason == SyncOutcomeReason.completed ? 1 : 0,
            finishedAt: 0,
          )),
      };
      for (final MapEntry<SyncOutcomeReason, String> e in lines.entries) {
        expect(e.value, isNotEmpty, reason: '${e.key} 没有可显示的文案');
      }
      expect(
        lines.values.toSet().length,
        SyncOutcomeReason.values.length,
        reason: '不同结局必须显示不同文案',
      );
    });

    test('「跑完了」与「一条通道都没跑起来」文案必须不同（本 bug 的核心）', () {
      String lineFor(SyncOutcomeReason reason, int channels) => syncOutcomeLine(
            SyncRunOutcome(
              kind: SyncActivityKind.fullSweep,
              reason: reason,
              channelsRun: channels,
              finishedAt: 0,
            ),
          );
      expect(
        lineFor(SyncOutcomeReason.completed, 2),
        isNot(equals(lineFor(SyncOutcomeReason.noChannels, 0))),
        reason: '零通道空转以前与正常跑完在界面上完全同形，用户无从判断同没同步',
      );
    });

    test('completed 把实跑通道数带进文案', () {
      final String one = syncOutcomeLine(const SyncRunOutcome(
        kind: SyncActivityKind.fullSweep,
        reason: SyncOutcomeReason.completed,
        channelsRun: 1,
        finishedAt: 0,
      ));
      final String two = syncOutcomeLine(const SyncRunOutcome(
        kind: SyncActivityKind.fullSweep,
        reason: SyncOutcomeReason.completed,
        channelsRun: 2,
        finishedAt: 0,
      ));
      expect(one, contains('1'));
      expect(two, contains('2'));
      expect(one, isNot(equals(two)));
    });
  });

  group('SyncProgressBanner', () {
    tearDown(() {
      syncInProgress.value = false;
      syncProgress.value = null;
      syncActivity.value = null;
    });

    Future<void> pumpBanner(WidgetTester tester) => tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: SyncProgressBanner()),
          ),
        );

    testWidgets('没有同步在跑时收成零高度，不占布局', (WidgetTester tester) async {
      syncInProgress.value = false;
      await pumpBanner(tester);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('同步中但没有阶段 tick（轻量路径）→ 仍然有文字，不是光秃秃一条线',
        (WidgetTester tester) async {
      syncInProgress.value = true;
      syncProgress.value = null;
      syncActivity.value = const SyncActivity(SyncActivityKind.collections);
      await pumpBanner(tester);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      final Finder text = find.byType(Text);
      expect(text, findsOneWidget, reason: '这正是用户报的现象：条子在转但一个字都没有');
      expect(
        (tester.widget<Text>(text).data ?? ''),
        equals(
            syncActivityLine(const SyncActivity(SyncActivityKind.collections))),
      );
    });

    testWidgets('全量 sweep 的准备段（尚无 tick）也有文字', (WidgetTester tester) async {
      syncInProgress.value = true;
      syncProgress.value = null;
      syncActivity.value = const SyncActivity(SyncActivityKind.fullSweep);
      await pumpBanner(tester);
      expect(find.byType(Text), findsOneWidget);
      // 准备段没有可测总数 → 不确定进度条。
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
    });

    testWidgets('有阶段 tick 时阶段行优先于身份行，并给出确定性进度', (WidgetTester tester) async {
      syncInProgress.value = true;
      syncActivity.value = const SyncActivity(SyncActivityKind.fullSweep);
      const SyncProgress p = SyncProgress(
        phase: SyncPhase.readingData,
        itemIndex: 2,
        itemTotal: 8,
      );
      syncProgress.value = p;
      await pumpBanner(tester);
      expect(
        tester.widget<Text>(find.byType(Text)).data,
        equals(syncProgressLine(p)),
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        closeTo(2 / 8, 1e-9),
      );
    });
  });

  group('同步状态维护的单点守卫（源码扫描）', () {
    // 运行时表面在 headless 测试里挂不稳（真跑一轮同步要 DB + 网络后端），故用源码
    // 扫描锁住不变式本身：全局同步状态只能由 _beginSyncActivity / _endSyncActivity
    // 这一对维护。
    final String src =
        File('lib/src/sync/sync_auto_trigger.dart').readAsStringSync();

    int occurrences(String needle) => needle.allMatches(src).length;

    test('五条同步路径都经由 _beginSyncActivity 登记身份', () {
      // 1 处定义 + 5 处调用（开机自动 sweep / 手动全量 / 合集轻量 / 单本 /
      // 设置页显式资产上传下载）。
      expect(
        occurrences('_beginSyncActivity('),
        6,
        reason: '新增同步路径必须一并登记身份，否则进度条又会退回「只有线没有字」',
      );
    });

    test('每条路径都在 finally 里经由 _endSyncActivity 公布结局', () {
      expect(
        occurrences('_endSyncActivity('),
        6,
        reason: '漏掉结局 = 那轮同步静默收尾，用户无从判断到底同没同步',
      );
    });

    test('在飞标志与计数只在这一对 helper 里被写', () {
      expect(
        occurrences('syncInProgress.value = true'),
        1,
        reason: '各路径手写这行正是「合集/单本 finally 漏清 syncProgress」的来源',
      );
      expect(occurrences('_activeSyncs++'), 1);
      expect(occurrences('_activeSyncs--'), 1);
    });

    test('设置页「立即同步」只拿全量同步的结局填副标题', () {
      // 那一行讲的是「立即同步」这件事；拿后台单本 / 合集轻量同步的结局来填会
      // 答非所问（用户点的是全量，看到的却是某本书的结果）。设置页运行时表面要
      // AppModel + SettingsContext，headless 挂不稳，故在此锁不变式。
      final String rowSrc =
          File('lib/src/sync/sync_settings_schema/actions.part.dart')
              .readAsStringSync();
      expect(
        rowSrc,
        contains('outcome.kind == SyncActivityKind.fullSweep'),
        reason: '空闲副标题必须过滤同步种类，否则会显示别的同步的结局',
      );
      // 进行中的两段不做这个过滤：它们回答「现在有没有东西在跑」，任何同步都算数。
      expect(rowSrc, contains('syncActivityLine(activity)'));
    });

    test('最后一个在飞同步退出时同时清掉阶段与身份', () {
      // 两者必须一起清：只清其一会把上一轮的残留文字带进下一轮开头。
      expect(src, contains('syncProgress.value = null'));
      expect(src, contains('syncActivity.value = null'));
      expect(
        occurrences('if (_activeSyncs == 0)'),
        1,
        reason: '清理只能有一处（在 _endSyncActivity 内），不得散回各路径',
      );
    });
  });
}
