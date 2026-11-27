// G7-5：复习库代际状态页（srs_generation_view.dart）。
// - 打开错误 × 是否主进程 → 哪一种内容（srsGenerationKindOf，全部分支）；
// - MD3 与 Apple 两套下，每种不能迁移的状态都给出说明（不当成「加载失败」）、该有重试的有重试；
// - 主进程要迁移：开始 → 步骤与进度 → 提交点之前可取消 / 之后没有取消 → 各结论就地说明、可重新升级；
// - SrsLoadErrorView 把代际状态转给这一页，把「profile 未绑定」「功能未接线」写成明确的「暂不可用」。
// 迁移执行端是假的（与控制器测试同一个），不碰原生库。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_compose_prefill.dart';
import 'package:fushi/src/pages/implementations/srs/srs_generation_view.dart';
import 'package:fushi/src/pages/implementations/srs/srs_gen4_report_actions.dart';
import 'package:fushi/src/pages/implementations/srs/srs_load_error.dart';
import 'package:fushi/src/srs/srs_gen4_migration_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi_engine/srs/srs_db_store.dart'
    show SrsProfileIdentityPending;
import 'package:fushi_engine/srs/srs_storage.dart'
    show SrsLegacyMainDatabasePending;
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'srs_gen4_migration_controller_test.dart' show FakeGen4Backend;

const SrsStoreNotMigrated needs = SrsStoreNotMigrated(
  'x',
  SrsGenState.needsMigration,
);

Future<void> pumpView(
  WidgetTester tester, {
  required Widget child,
  required bool apple,
  bool main = true,
  SrsGen4MigrationController? controller,
  SrsGen4ReportActions? reportActions,
}) async {
  LocaleSettings.setLocale(AppLocale.en);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        srsGen4IsMainProcessProvider.overrideWithValue(main),
        if (controller != null)
          srsGen4MigrationProvider.overrideWithValue(controller),
        if (reportActions != null)
          srsGen4ReportActionsProvider.overrideWithValue(reportActions),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: apple
                ? FushiDesignSystem.cupertino
                : FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: Scaffold(body: child),
        ),
      ),
    ),
  );
  // 不用 pumpAndSettle：不定进度条一直在动。
  await tester.pump(const Duration(seconds: 1));
}

/// 报告的两个出口记下调用，不碰反馈服务与平台通道。
class FakeReportActions extends SrsGen4ReportActions {
  FakeReportActions({required this.desktop}) : super(openFeedback: _noFeedback);

  static Future<void> _noFeedback(
    BuildContext context,
    FeedbackComposePrefill prefill,
  ) async {}

  final bool desktop;
  final List<String> sent = <String>[];
  final List<String> exported = <String>[];

  @override
  bool get savesToFile => desktop;

  @override
  Future<void> send(BuildContext context, String reportPath) async =>
      sent.add(reportPath);

  @override
  Future<void> export(BuildContext context, String reportPath) async =>
      exported.add(reportPath);
}

const String reportPath =
    '/data/user/0/app.fushi.reader/files/srs4-migration-report.json';

/// 打开错误里内核判定的上次原因（store/ffi.rs `open_error` → [SrsStoreNotMigrated.failure]）。
SrsStoreNotMigrated failedWith(SrsGen4MigrationFailureReason reason) =>
    SrsStoreNotMigrated(
      'x',
      SrsGenState.migrationFailed,
      failure: SrsGen4MigrationFailure(
        reason: reason,
        reportPath: reason == SrsGen4MigrationFailureReason.interrupted
            ? null
            : reportPath,
      ),
    );

/// 每种原因的说明（页面只按内核的原因选一句，四句互不相同）。
String reasonText(SrsGen4MigrationFailureReason r) => switch (r) {
  SrsGen4MigrationFailureReason.fail => t.srs_gen4_aborted_fail,
  SrsGen4MigrationFailureReason.incomplete => t.srs_gen4_aborted_incomplete,
  SrsGen4MigrationFailureReason.error => t.srs_gen4_aborted_error,
  SrsGen4MigrationFailureReason.interrupted => t.srs_gen4_interrupted,
};

void main() {
  test('every open error maps to one kind per process role', () {
    SrsGenerationKind k(Object e, bool main) =>
        srsGenerationKindOf(e, isMainProcess: main);
    SrsStoreNotMigrated st(SrsGenState s) => SrsStoreNotMigrated('x', s);
    expect(k(needs, true), SrsGenerationKind.migrate);
    expect(k(needs, false), SrsGenerationKind.openMainWindow);
    expect(
      k(st(SrsGenState.migrationFailed), true),
      SrsGenerationKind.retryFailed,
    );
    expect(
      k(st(SrsGenState.migrationFailed), false),
      SrsGenerationKind.openMainWindow,
    );
    for (final bool main in <bool>[true, false]) {
      expect(
        k(st(SrsGenState.sealedOldOnly), main),
        SrsGenerationKind.sealedOldOnly,
      );
      expect(
        k(st(SrsGenState.migratingElsewhere), main),
        SrsGenerationKind.migratingElsewhere,
      );
      expect(k(st(SrsGenState.ready), main), SrsGenerationKind.ready);
      expect(
        k(const SrsStoreMigrating('x'), main),
        SrsGenerationKind.migratingElsewhere,
      );
      expect(
        k(const SrsStoreLegacyUnmigrated('x'), main),
        SrsGenerationKind.legacyUnmigrated,
      );
      expect(
        k(const SrsLegacyMainDatabasePending(), main),
        SrsGenerationKind.legacyMainDatabase,
      );
    }
  });

  for (final bool apple in <bool>[false, true]) {
    final String design = apple ? 'Apple' : 'Material';

    testWidgets('static states explain themselves ($design)', (
      WidgetTester tester,
    ) async {
      final List<(Object, bool, String, bool)> cases =
          <(Object, bool, String, bool)>[
            (needs, false, t.srs_gen4_secondary_needs_migration, true),
            (
              const SrsStoreMigrating('x'),
              true,
              t.srs_gen4_migrating_elsewhere,
              true,
            ),
            (
              const SrsStoreNotMigrated('x', SrsGenState.sealedOldOnly),
              true,
              t.srs_gen4_sealed_old_only,
              false,
            ),
            (
              const SrsStoreLegacyUnmigrated('x'),
              true,
              t.srs_gen4_legacy_unmigrated,
              true,
            ),
            (
              const SrsLegacyMainDatabasePending(),
              true,
              t.srs_gen4_legacy_main_db,
              true,
            ),
          ];
      for (final (Object error, bool main, String text, bool retry) in cases) {
        int retried = 0;
        await pumpView(
          tester,
          apple: apple,
          main: main,
          child: SrsLoadErrorView(error: error, onRetry: () => retried++),
        );
        expect(find.text(t.srs_gen4_title), findsOneWidget, reason: '$error');
        expect(find.text(text), findsOneWidget, reason: '$error');
        expect(find.text(t.error_load_failed), findsNothing, reason: '$error');
        expect(
          find.byKey(SrsGenerationView.retryKey),
          retry ? findsOneWidget : findsNothing,
          reason: '$error',
        );
        if (retry) {
          await tester.tap(find.byKey(SrsGenerationView.retryKey));
          expect(retried, 1, reason: '$error');
        }
        expect(find.byKey(SrsGenerationView.startKey), findsNothing);
      }
    });

    testWidgets(
      'migration: start, progress, cancel window, outcomes ($design)',
      (WidgetTester tester) async {
        final FakeGen4Backend b = FakeGen4Backend();
        int committed = 0;
        final SrsGen4MigrationController c = SrsGen4MigrationController(
          directory: 'dir',
          profileUids: () async => <String>['p1'],
          onCommitted: () async => committed++,
          backend: b,
          pollInterval: const Duration(milliseconds: 50),
          nowMs: () => 1,
        );
        addTearDown(c.dispose);
        await pumpView(
          tester,
          apple: apple,
          controller: c,
          child: const SrsLoadErrorView(error: needs, onRetry: null),
        );
        expect(find.text(t.srs_gen4_needs_migration), findsOneWidget);
        expect(find.text(t.srs_gen4_start), findsOneWidget);

        await tester.tap(find.byKey(SrsGenerationView.startKey));
        await tester.pump();
        b.running = (step: SrsGen4MigrationStep.translate, done: 2, total: 4);
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.text(t.srs_gen4_running), findsOneWidget);
        expect(find.text('5/10  ${t.srs_gen4_step_translate}'), findsOneWidget);
        expect(find.text(t.srs_gen4_cancel_hint), findsOneWidget);
        expect(find.byKey(SrsGenerationView.startKey), findsNothing);

        await tester.tap(find.byKey(SrsGenerationView.cancelKey));
        await tester.pump();
        expect(b.cancels, hasLength(1));
        b.finish(<String, Object?>{'verdict': 'cancelled'});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text(t.srs_gen4_cancelled), findsOneWidget);
        expect(find.text(t.srs_gen4_restart), findsOneWidget);

        // 第二次：到了提交点没有取消；空间不够就地说明。
        b.pending = Completer<SrsGen4MigrationOutcome>();
        b.running = (step: SrsGen4MigrationStep.commit, done: 0, total: 1);
        await tester.tap(find.byKey(SrsGenerationView.startKey));
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.text('9/10  ${t.srs_gen4_step_commit}'), findsOneWidget);
        expect(find.byKey(SrsGenerationView.cancelKey), findsNothing);
        b.finish(<String, Object?>{
          'verdict': 'noSpace',
          'needed': 3 * 1024 * 1024,
          'free': 1024 * 1024,
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.text(
            t.srs_gen4_no_space(size: FushiByteFormat.bytes(2 * 1024 * 1024)),
          ),
          findsOneWidget,
        );
        expect(committed, 0);

        // 第三次：提交 → onCommitted（页面随存储重开由外层换掉）。
        b.pending = Completer<SrsGen4MigrationOutcome>();
        b.running = null;
        await tester.tap(find.byKey(SrsGenerationView.startKey));
        await tester.pump();
        b.finish(<String, Object?>{'verdict': 'committed'});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(committed, 1);
        expect(c.phase, SrsGen4MigrationPhase.committed);
      },
    );

    testWidgets('each kernel reason of a previous run gets its own '
        'explanation, once; only aborted runs offer a report ($design)', (
      WidgetTester tester,
    ) async {
      expect(
        <String>{
          for (final SrsGen4MigrationFailureReason r
              in SrsGen4MigrationFailureReason.values)
            reasonText(r),
        }.length,
        SrsGen4MigrationFailureReason.values.length,
      );
      for (final SrsGen4MigrationFailureReason reason
          in SrsGen4MigrationFailureReason.values) {
        final FakeGen4Backend b = FakeGen4Backend();
        final FakeReportActions actions = FakeReportActions(desktop: apple);
        final SrsGen4MigrationController c = SrsGen4MigrationController(
          directory: 'dir',
          profileUids: () async => <String>['p1'],
          onCommitted: () async {},
          backend: b,
          nowMs: () => 1,
        );
        addTearDown(c.dispose);
        // 每种原因一棵新树（ProviderScope 换了覆盖值，不在旧树上更新）。
        await tester.pumpWidget(const SizedBox());
        await pumpView(
          tester,
          apple: apple,
          controller: c,
          reportActions: actions,
          child: SrsLoadErrorView(error: failedWith(reason), onRetry: null),
        );
        for (final SrsGen4MigrationFailureReason other
            in SrsGen4MigrationFailureReason.values) {
          expect(
            find.text(reasonText(other)),
            other == reason ? findsOneWidget : findsNothing,
            reason: '${reason.wire} / ${other.wire}',
          );
        }
        final bool report = reason != SrsGen4MigrationFailureReason.interrupted;
        expect(
          find.byKey(SrsGenerationView.reportSendKey),
          report ? findsOneWidget : findsNothing,
          reason: reason.wire,
        );
        expect(
          find.byKey(SrsGenerationView.reportExportKey),
          report ? findsOneWidget : findsNothing,
          reason: reason.wire,
        );
        expect(find.text(t.srs_gen4_restart), findsOneWidget);
        expect(find.text(t.srs_gen4_failed), findsNothing);
      }
      // 原因读不出来（坏数据）也不空着：说笼统的「出错停止了」，没有报告可给。
      final SrsGen4MigrationController unknown = SrsGen4MigrationController(
        directory: 'dir',
        profileUids: () async => <String>['p1'],
        onCommitted: () async {},
        backend: FakeGen4Backend(),
        nowMs: () => 1,
      );
      addTearDown(unknown.dispose);
      await tester.pumpWidget(const SizedBox());
      await pumpView(
        tester,
        apple: apple,
        controller: unknown,
        reportActions: FakeReportActions(desktop: apple),
        child: const SrsLoadErrorView(
          error: SrsStoreNotMigrated('x', SrsGenState.migrationFailed),
          onRetry: null,
        ),
      );
      expect(find.text(t.srs_gen4_failed), findsOneWidget);
      expect(find.byKey(SrsGenerationView.reportSendKey), findsNothing);
    });

    testWidgets('a previous run that failed verification offers its report, '
        'never both explanations ($design)', (WidgetTester tester) async {
      final FakeGen4Backend b = FakeGen4Backend();
      final FakeReportActions actions = FakeReportActions(desktop: apple);
      final SrsGen4MigrationController c = SrsGen4MigrationController(
        directory: 'dir',
        profileUids: () async => <String>['p1'],
        onCommitted: () async {},
        backend: b,
        nowMs: () => 1,
      );
      addTearDown(c.dispose);
      await pumpView(
        tester,
        apple: apple,
        controller: c,
        reportActions: actions,
        child: SrsLoadErrorView(
          error: failedWith(SrsGen4MigrationFailureReason.fail),
          onRetry: null,
        ),
      );
      expect(find.text(t.srs_gen4_aborted_fail), findsOneWidget);
      expect(find.text(t.srs_gen4_interrupted), findsNothing);
      // 私有目录路径不上屏（手机上用户拿不到）。
      expect(find.textContaining('/data/user/0'), findsNothing);
      expect(find.text(t.srs_gen4_report_send), findsOneWidget);
      expect(
        find.text(apple ? t.srs_gen4_report_save : t.srs_gen4_report_share),
        findsOneWidget,
      );

      await tester.tap(find.byKey(SrsGenerationView.reportSendKey));
      await tester.pump();
      expect(actions.sent, <String>[reportPath]);
      await tester.tap(find.byKey(SrsGenerationView.reportExportKey));
      await tester.pump();
      expect(actions.exported, <String>[reportPath]);

      // 重新升级：跑的时候报告动作收起；又一次对拍不过 → 只说这次的结论（不再叠「上次没做完」），报告换成这次的。
      await tester.tap(find.byKey(SrsGenerationView.startKey));
      await tester.pump();
      expect(find.byKey(SrsGenerationView.reportSendKey), findsNothing);
      expect(find.text(t.srs_gen4_aborted_fail), findsNothing);
      const String again = 'dir/srs4-migration-report.json';
      b.finish(<String, Object?>{
        'verdict': 'aborted',
        'reportPath': again,
        'failure': <String, Object?>{
          'reason': 'incomplete',
          'reportPath': again,
        },
        'report': <String, Object?>{'verdict': 'aborted'},
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // 这次内核说的是「没法核对全」：只说这一句，不再说上次的「对拍有差异」。
      expect(find.text(t.srs_gen4_aborted_incomplete), findsOneWidget);
      expect(find.text(t.srs_gen4_aborted_fail), findsNothing);
      expect(find.text(t.srs_gen4_interrupted), findsNothing);
      expect(find.textContaining(again), findsNothing);
      await tester.tap(find.byKey(SrsGenerationView.reportSendKey));
      await tester.pump();
      expect(actions.sent, <String>[reportPath, again]);

      // 这次被取消：说「已取消」，不给报告动作（这次没有新报告），也不叠「上次」的说明。
      b.pending = Completer<SrsGen4MigrationOutcome>();
      await tester.tap(find.byKey(SrsGenerationView.startKey));
      await tester.pump();
      b.finish(<String, Object?>{'verdict': 'cancelled'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(t.srs_gen4_cancelled), findsOneWidget);
      expect(find.text(t.srs_gen4_aborted_incomplete), findsNothing);
      expect(find.text(t.srs_gen4_aborted_fail), findsNothing);
      expect(find.text(t.srs_gen4_interrupted), findsNothing);
      expect(find.byKey(SrsGenerationView.reportSendKey), findsNothing);
    });

    // 反馈 QW3kL_jEQF：出错（不是对拍不过）时内核也写报告；出错页同样给「发给开发者」与「分享 / 保存」，发的就是这份。
    testWidgets('a kernel error offers the error report it left ($design)', (
      WidgetTester tester,
    ) async {
      final Directory dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gen4-view-err'),
      ))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final String path = p.join(dir.path, SrsGen4Migration.reportFileName);
      File(path).writeAsStringSync(
        jsonEncode(<String, Object?>{'verdict': 'error', 'startedAtMs': 1}),
      );
      final FakeGen4Backend b = FakeGen4Backend();
      final FakeReportActions actions = FakeReportActions(desktop: apple);
      final SrsGen4MigrationController c = SrsGen4MigrationController(
        directory: dir.path,
        profileUids: () async => <String>['p1'],
        onCommitted: () async {},
        backend: b,
        nowMs: () => 1,
      );
      addTearDown(c.dispose);
      await pumpView(
        tester,
        apple: apple,
        controller: c,
        reportActions: actions,
        child: const SrsLoadErrorView(error: needs, onRetry: null),
      );
      expect(find.byKey(SrsGenerationView.reportSendKey), findsNothing);
      await tester.runAsync(() async {
        final Future<void> done = c.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        b.pending.completeError(const SrsCoreException(-1, 'disk full'));
        await done;
      });
      await tester.pump();
      expect(find.text(t.srs_gen4_failed), findsOneWidget);
      await tester.tap(find.byKey(SrsGenerationView.reportSendKey));
      await tester.pump();
      expect(actions.sent, <String>[path]);
      await tester.tap(find.byKey(SrsGenerationView.reportExportKey));
      await tester.pump();
      expect(actions.exported, <String>[path]);
    });

    testWidgets('blocked outcomes say why, by code ($design)', (
      WidgetTester tester,
    ) async {
      // (内核 code, 原因原文, 该出的说明, 原文给不给, 还给不给「重新升级」)
      for (final (
            String code,
            String reason,
            String text,
            bool shown,
            bool restart,
          )
          in <(String, String, String, bool, bool)>[
            (
              'migrating',
              'migrating: another process holds the generation lock',
              t.srs_gen4_migrating_elsewhere,
              false,
              true,
            ),
            (
              'busy',
              'busy: the protocol 3 library is being written',
              t.srs_gen4_blocked,
              false,
              true,
            ),
            // 补完之后仍不过 / 缺缓存配置：原文给出来，可以重新升级（补完每次重做能补的）。
            (
              'precondition',
              'p1: legacy rows are not migrated into the op log yet',
              t.srs_gen4_blocked_unfinished,
              true,
              true,
            ),
            (
              'missingCacheConfig',
              'no cache configuration was given for profile(s) p9',
              t.srs_gen4_blocked_unfinished,
              true,
              true,
            ),
            // 重试不会变的两类：不给「重新升级」。
            (
              'schemaNewer',
              'the protocol 3 library is at schema 31',
              t.srs_gen4_blocked_newer,
              true,
              false,
            ),
            (
              'corrupt',
              'srs.db is damaged: file is not a database',
              t.srs_gen4_blocked_damaged,
              true,
              false,
            ),
          ]) {
        final FakeGen4Backend b = FakeGen4Backend();
        final SrsGen4MigrationController c = SrsGen4MigrationController(
          directory: 'dir',
          profileUids: () async => <String>['p1'],
          onCommitted: () async {},
          backend: b,
          nowMs: () => 1,
        );
        await pumpView(
          tester,
          apple: apple,
          controller: c,
          child: const SrsLoadErrorView(error: needs, onRetry: null),
        );
        await tester.tap(find.byKey(SrsGenerationView.startKey));
        await tester.pump();
        b.finish(<String, Object?>{
          'verdict': 'blocked',
          'code': code,
          'reason': reason,
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text(text), findsOneWidget, reason: code);
        if (text != t.srs_gen4_blocked) {
          expect(
            find.text(t.srs_gen4_blocked),
            findsNothing,
            reason: '不能把 $code 说成「被占用」',
          );
        }
        expect(
          find.text(reason),
          shown ? findsOneWidget : findsNothing,
          reason: code,
        );
        expect(
          find.byKey(SrsGenerationView.startKey),
          restart ? findsOneWidget : findsNothing,
          reason: code,
        );
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
    });
  }

  for (final bool apple in <bool>[false, true]) {
    final String design = apple ? 'Apple' : 'MD3';
    testWidgets('a closing database greys out the start button ($design)', (
      WidgetTester tester,
    ) async {
      final FakeGen4Backend b = FakeGen4Backend();
      final ChangeNotifier closing = ChangeNotifier();
      addTearDown(closing.dispose);
      bool open = true;
      final SrsGen4MigrationController c = SrsGen4MigrationController(
        directory: 'dir',
        profileUids: () async => <String>['p1'],
        onCommitted: () async {},
        backend: b,
        databaseOpen: () => open,
        databaseClosing: closing,
        nowMs: () => 1,
      );
      addTearDown(c.dispose);
      await pumpView(
        tester,
        apple: apple,
        controller: c,
        child: const SrsLoadErrorView(error: needs, onRetry: null),
      );
      expect(find.text(t.srs_gen4_closing), findsNothing);
      // 关库开始（AppModel.closeDatabase 先置 isDatabaseOpen 为假、再通知）：按钮置灰、说明原因，点了也不开始。
      open = false;
      closing.notifyListeners();
      await tester.pump();
      expect(find.text(t.srs_gen4_closing), findsOneWidget);
      await tester.tap(find.byKey(SrsGenerationView.startKey));
      await tester.pump();
      expect(b.runs, isEmpty);
      expect(c.phase, SrsGen4MigrationPhase.idle);
    });

    testWidgets(
      'start-up greys out without the closing text; reopening restores ($design)',
      (WidgetTester tester) async {
        final FakeGen4Backend b = FakeGen4Backend();
        final ChangeNotifier closing = ChangeNotifier();
        final ChangeNotifier changed = ChangeNotifier();
        addTearDown(closing.dispose);
        addTearDown(changed.dispose);
        bool open = false;
        final SrsGen4MigrationController c = SrsGen4MigrationController(
          directory: 'dir',
          profileUids: () async => <String>['p1'],
          onCommitted: () async {},
          backend: b,
          databaseOpen: () => open,
          databaseClosing: closing,
          databaseChanged: changed,
          nowMs: () => 1,
        );
        addTearDown(c.dispose);
        await pumpView(
          tester,
          apple: apple,
          controller: c,
          child: const SrsLoadErrorView(error: needs, onRetry: null),
        );
        // 启动还没初始化完：点不了，但不说「正在关闭」。
        expect(find.text(t.srs_gen4_closing), findsNothing);
        await tester.tap(find.byKey(SrsGenerationView.startKey));
        await tester.pump();
        expect(b.runs, isEmpty);
        // 关库 → 说明；重新开库 → 说明消失、按钮恢复可点。
        open = true;
        changed.notifyListeners();
        open = false;
        closing.notifyListeners();
        await tester.pump();
        expect(find.text(t.srs_gen4_closing), findsOneWidget);
        open = true;
        changed.notifyListeners();
        await tester.pump();
        expect(find.text(t.srs_gen4_closing), findsNothing);
        await tester.tap(find.byKey(SrsGenerationView.startKey));
        await tester.pump();
        expect(b.runs, hasLength(1));
        b.finish(<String, Object?>{'verdict': 'cancelled'});
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('profile without identity reads as waiting for the main window, '
      'unwired features as unavailable', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.en);
    expect(
      srsLoadErrorDetail(
        const SrsProfileUnboundException(-1, 'x', profile: 'p'),
      ),
      t.srs_gen4_profile_pending_primary,
    );
    expect(
      srsLoadErrorDetail(const SrsProfileIdentityPending('p')),
      t.srs_gen4_profile_pending_primary,
    );
    expect(
      srsLoadErrorDetail(
        SrsCoreException.of(-1, 'gen4: not wired yet: `merge` belongs to G9-5'),
      ),
      t.srs_gen4_feature_unwired,
    );
  });
}
