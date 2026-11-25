/// 复习库代际状态页：本机库打不开不是因为「坏了」，而是要换代迁移 / 别的进程在迁移 / 旁边有没迁移的旧库……
/// 时，[SrsLoadErrorView] 换成这一页（交接说明 §8.1 与「G7-5 Dart 接线」）。
///
/// - [SrsGenState.needsMigration]（主进程）：说明 +「开始升级」→ 步骤与进度，提交点之前可取消；结论（取消 /
///   别的窗口在迁移 / 被占用 / 旧库没整理好 / 更新版本写的 / 文件坏了 / 并入没做完 / 空间不够 / 对拍不过）就地说明。
///   旧库里协议 3 没做完的收尾由迁移自己补完（G7-2b，步骤「整理旧库」）；`blocked` 按内核的 `code` 分类
///   （[SrsGen4BlockedReason]），重试会变的（[SrsGen4BlockedReason.retryable]）给「重新升级」，其余三类不给。主库已关 /
///   正在关（覆盖恢复、换数据根、退出）时「开始升级」置灰并说明（[SrsGen4MigrationController.canStart] /
///   [SrsGen4MigrationController.databaseClosing]；启动还没初始化完只置灰、不说「正在关」，重新开库后恢复）。提交后存储
///   重开，页面随之换成正常内容。
/// - [SrsGenState.migrationFailed]（主进程）：上次没完成，可重新升级。原因由内核判定、随打开错误带来
///   （[SrsStoreNotMigrated.failure]，[SrsGen4MigrationFailureReason]），页面只按它说明、不读报告文件，四种各一句
///   （互斥，不叠两段）：对拍有差异 / 对拍没法做全 / 准备时出错（三种都已撤回、有报告）/ 只剩迁移临时文件。
///   本进程里跑出了结论就只说结论（结论取代「上次」的说明，同一件事不说两遍，[SrsGen4MigrationController.failureFor]）。
/// - 中止的诊断报告（只含 ID 与计数）不印私有目录路径（手机上用户拿不到）：给「把报告发给开发者」（反馈提交页，
///   报告自动附上）与「分享报告 / 保存报告」（srs_gen4_report_actions.dart）。
/// - [SrsGenState.sealedOldOnly]：只剩封存旧库，不自动重建，给恢复说明。
/// - [SrsStoreMigrating]（-5）/ [SrsGenState.migratingElsewhere]：别的窗口在迁移，稍后重试。
/// - [SrsStoreLegacyUnmigrated]（-6）：旁边有没迁移的旧库，两份都原样保留。
/// - [SrsLegacyMainDatabasePending]：协议 1 的数据还在主库里，原样保留。
/// - 非主进程（弹窗 / 查词窗）：只提示去主窗口完成升级，不在这里迁移。
///
/// 文案不吓人：迁移无损，旧库封存不删。MD3 与 Apple 两套都走 [FushiPlaceholderMessage] 与 Fushi 按钮，
/// 区块错峰进场（[FushiEntranceScope] + [FushiStaggeredEntrance]），按钮按压缩放（[FushiPressScale]）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_storage.dart'
    show SrsLegacyMainDatabasePending;
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart'
    show openFeedbackComposeWith;
import 'package:fushi/src/pages/implementations/srs/srs_gen4_report_actions.dart';
import 'package:fushi/src/srs/srs_gen4_migration_controller.dart';
import 'package:fushi/src/srs/srs_generation_kind.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';

export 'package:fushi/src/srs/srs_generation_kind.dart';

/// 恢复页用的报告动作（测试覆盖成假的）。放在页面这一层：它注入的反馈提交页在 import 大环里，
/// 报告动作本身（`srs_gen4_report_actions.dart`）不跟着进环。
final Provider<SrsGen4ReportActions> srsGen4ReportActionsProvider =
    Provider<SrsGen4ReportActions>(
      (Ref ref) =>
          const SrsGen4ReportActions(openFeedback: openFeedbackComposeWith),
    );

/// 迁移步骤的显示名。
String srsGen4StepLabel(SrsGen4MigrationStep step) => switch (step) {
  SrsGen4MigrationStep.space => t.srs_gen4_step_space,
  SrsGen4MigrationStep.lock => t.srs_gen4_step_lock,
  SrsGen4MigrationStep.prepare => t.srs_gen4_step_prepare,
  SrsGen4MigrationStep.precondition => t.srs_gen4_step_precondition,
  SrsGen4MigrationStep.translate => t.srs_gen4_step_translate,
  SrsGen4MigrationStep.salts => t.srs_gen4_step_salts,
  SrsGen4MigrationStep.rebuild => t.srs_gen4_step_rebuild,
  SrsGen4MigrationStep.parity => t.srs_gen4_step_parity,
  SrsGen4MigrationStep.commit => t.srs_gen4_step_commit,
  SrsGen4MigrationStep.seal => t.srs_gen4_step_seal,
};

/// 没提交的结论的说明（提交了页面就换掉了，不出这里）。`blocked` 按内核 `code` 的分类（[SrsGen4BlockedReason]）各给
/// 一句：等一会再来的两类不能与补不了的混为一谈（不能把「旧库没整理好 / 文件坏了」说成「被占用」）。
String srsGen4OutcomeText(SrsGen4MigrationOutcome o) => switch (o.verdict) {
  SrsGen4MigrationVerdict.cancelled => t.srs_gen4_cancelled,
  SrsGen4MigrationVerdict.blocked => switch (o.blockedReason!) {
    SrsGen4BlockedReason.migrating => t.srs_gen4_migrating_elsewhere,
    SrsGen4BlockedReason.busy => t.srs_gen4_blocked,
    SrsGen4BlockedReason.newerBuild => t.srs_gen4_blocked_newer,
    SrsGen4BlockedReason.damaged => t.srs_gen4_blocked_damaged,
    SrsGen4BlockedReason.precondition => t.srs_gen4_blocked_unfinished,
  },
  SrsGen4MigrationVerdict.noSpace => t.srs_gen4_no_space(
    size: FushiByteFormat.bytes(_shortBytes(o)),
  ),
  SrsGen4MigrationVerdict.aborted => srsGen4FailureText(o.failure),
  SrsGen4MigrationVerdict.committed => t.srs_gen4_running,
};

/// 上次 / 这次迁移没完成的说明，按内核给的原因（[SrsGen4MigrationFailureReason]）一种一句：「没通过核对」只说对拍真有
/// 差异的那种，没法核对全与准备出错不混进来。原因读不出来（坏数据）= 笼统的「出错停止了」。
String srsGen4FailureText(SrsGen4MigrationFailure? f) => switch (f?.reason) {
  SrsGen4MigrationFailureReason.fail => t.srs_gen4_aborted_fail,
  SrsGen4MigrationFailureReason.incomplete => t.srs_gen4_aborted_incomplete,
  SrsGen4MigrationFailureReason.error => t.srs_gen4_aborted_error,
  SrsGen4MigrationFailureReason.interrupted => t.srs_gen4_interrupted,
  null => t.srs_gen4_failed,
};

int? _shortBytes(SrsGen4MigrationOutcome o) {
  final int? needed = o.neededBytes;
  final int? free = o.freeBytes;
  if (needed == null) return null;
  if (free == null) return needed;
  final int short = needed - free;
  return short > 0 ? short : needed;
}

/// 代际状态页。[error] 是本机库打开时抛的 [SrsStoreOpenBlocked] 子类或 [SrsLegacyMainDatabasePending]；
/// [onRetry] 是外层的「重新打开」（非迁移状态的「重试」按钮用它）。
class SrsGenerationView extends ConsumerWidget {
  const SrsGenerationView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  /// 测试与焦点驱动按这些 key 找按钮。
  static const Key startKey = ValueKey<String>('srs-gen4-start');
  static const Key cancelKey = ValueKey<String>('srs-gen4-cancel');
  static const Key retryKey = ValueKey<String>('srs-gen4-retry');
  static const Key reportSendKey = ValueKey<String>('srs-gen4-report-send');
  static const Key reportExportKey = ValueKey<String>('srs-gen4-report-export');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SrsGenerationKind kind = srsGenerationKindOf(
      error,
      isMainProcess: ref.watch(srsGen4IsMainProcessProvider),
    );
    final Widget body = switch (kind) {
      SrsGenerationKind.migrate ||
      SrsGenerationKind.retryFailed => _MigrationPanel(
        controller: ref.watch(srsGen4MigrationProvider),
        failedBefore: kind == SrsGenerationKind.retryFailed,
        previousFailure: switch (error) {
          SrsStoreNotMigrated(:final SrsGen4MigrationFailure? failure) =>
            failure,
          _ => null,
        },
      ),
      _ => _StaticState(kind: kind, onRetry: onRetry),
    };
    final double page = FushiDesignTokens.of(context).spacing.page;
    return SafeArea(
      bottom: false,
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(page),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: FushiEntranceScope(replayKey: kind, child: body),
          ),
        ),
      ),
    );
  }
}

/// 不能在这里迁移的状态：说明 + 可选的「重试」。
class _StaticState extends StatelessWidget {
  const _StaticState({required this.kind, required this.onRetry});

  final SrsGenerationKind kind;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String detail, bool retry) = switch (kind) {
      SrsGenerationKind.openMainWindow => (
        FushiIcons.info,
        t.srs_gen4_secondary_needs_migration,
        true,
      ),
      SrsGenerationKind.migratingElsewhere => (
        FushiIcons.sync,
        t.srs_gen4_migrating_elsewhere,
        true,
      ),
      SrsGenerationKind.sealedOldOnly => (
        FushiIcons.lock,
        t.srs_gen4_sealed_old_only,
        false,
      ),
      SrsGenerationKind.legacyUnmigrated => (
        FushiIcons.storage,
        t.srs_gen4_legacy_unmigrated,
        true,
      ),
      SrsGenerationKind.legacyMainDatabase => (
        FushiIcons.storage,
        t.srs_gen4_legacy_main_db,
        true,
      ),
      SrsGenerationKind.ready ||
      SrsGenerationKind.migrate ||
      SrsGenerationKind.retryFailed => (FushiIcons.refresh, '', true),
    };
    final VoidCallback? onRetry = this.onRetry;
    return FushiStaggeredEntrance(
      index: 0,
      child: FushiPlaceholderMessage(
        icon: icon,
        message: t.srs_gen4_title,
        detail: detail.isEmpty ? null : detail,
        detailMaxLines: null,
        action: !retry || onRetry == null
            ? null
            : FushiPressScale(
                child: FushiFilledButton.tonalIcon(
                  key: SrsGenerationView.retryKey,
                  onPressed: onRetry,
                  icon: const FushiIcon(FushiIcons.refresh),
                  label: Text(t.retry),
                ),
              ),
      ),
    );
  }
}

/// 迁移面板：说明 → 进度（步骤 + 进度条 + 取消）→ 结论（对拍不过时带报告的两个出口）。
class _MigrationPanel extends StatelessWidget {
  const _MigrationPanel({
    required this.controller,
    required this.failedBefore,
    required this.previousFailure,
  });

  final SrsGen4MigrationController controller;
  final bool failedBefore;

  /// 上次没完成的原因（内核判定，随打开错误带来）；不是 [SrsGenState.migrationFailed] = null。
  final SrsGen4MigrationFailure? previousFailure;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, _) => _buildFor(context),
    );
  }

  /// 页面上唯一一段主说明：在跑 > 本次结论 > 本次出错 > 上次没完成（按内核给的原因四选一）> 要升级。互斥，不叠说明。
  String _headline(SrsGen4MigrationController c) {
    if (c.phase != SrsGen4MigrationPhase.idle) return t.srs_gen4_running;
    final SrsGen4MigrationOutcome? outcome = c.outcome;
    if (outcome != null) return srsGen4OutcomeText(outcome);
    if (c.error != null) return t.srs_gen4_failed;
    if (failedBefore) return srsGen4FailureText(previousFailure);
    return t.srs_gen4_needs_migration;
  }

  Widget _buildFor(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    final bool running = controller.phase != SrsGen4MigrationPhase.idle;
    final SrsGen4MigrationOutcome? outcome = controller.outcome;
    final Object? error = controller.error;
    final SrsGen4BlockedReason? blocked = outcome?.blockedReason;
    // 重试不会变的三类（更新版本写的 / 文件坏了 / 并入没做完）：不给「重新升级」，免得引用户反复点。
    final bool retryable = blocked?.retryable ?? true;
    // 等一会再来的两类说清楚就够；其余给内核原因原文（诊断用）。
    final String reason = outcome?.reason ?? '';
    final bool showReason =
        blocked != null &&
        blocked != SrsGen4BlockedReason.migrating &&
        blocked != SrsGen4BlockedReason.busy &&
        reason.isNotEmpty;
    // 不能开始（主库正在关，或启动还没初始化完）：按钮置灰；只有真的在关才说「正在关闭数据库」。
    final bool blockedStart = !running && !controller.canStart;
    final String? report = controller.failureFor(previousFailure)?.reportPath;
    final List<String> details = <String>[
      if (!running && showReason) reason,
      if (!running && error != null) '$error',
      if (blockedStart && controller.databaseClosing) t.srs_gen4_closing,
    ];
    final bool failed = !running && (error != null || report != null);
    final Widget head = FushiPlaceholderMessage(
      icon: running
          ? FushiIcons.sync
          : (failed ? FushiIcons.error : FushiIcons.storage),
      tone: failed ? FushiPlaceholderTone.error : FushiPlaceholderTone.neutral,
      message: t.srs_gen4_title,
      detail: _headline(controller),
      details: details,
      detailMaxLines: null,
    );
    final VoidCallback? start = blockedStart ? null : controller.start;
    final List<Widget> blocks = <Widget>[
      head,
      if (running) _ProgressBlock(controller: controller),
      if (report != null) _ReportActions(reportPath: report),
      if (!running && retryable)
        Center(
          child: FushiPressScale(
            enabled: !blockedStart,
            // 主库已关 / 正在关：置灰（关库前的静默已经等过这个控制器，之后开始的迁移没人等）。有报告时「发给开发者」
            // 是主动作：对拍不过多半每次都一样，重新升级退为次要。
            child: report != null
                ? FushiFilledButton.tonalIcon(
                    key: SrsGenerationView.startKey,
                    onPressed: start,
                    icon: const FushiIcon(FushiIcons.refresh),
                    label: Text(t.srs_gen4_restart),
                  )
                : FushiFilledButton.icon(
                    key: SrsGenerationView.startKey,
                    onPressed: start,
                    icon: const FushiIcon(FushiIcons.refresh),
                    label: Text(
                      failedBefore || outcome != null || error != null
                          ? t.srs_gen4_restart
                          : t.srs_gen4_start,
                    ),
                  ),
          ),
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < blocks.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: gap * 2),
          FushiStaggeredEntrance(index: i, child: blocks[i]),
        ],
      ],
    );
  }
}

/// 中止报告的两个出口：发给开发者（主）、分享 / 保存（次）。
class _ReportActions extends ConsumerWidget {
  const _ReportActions({required this.reportPath});

  final String reportPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SrsGen4ReportActions actions = ref.watch(
      srsGen4ReportActionsProvider,
    );
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    final bool save = actions.savesToFile;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: gap,
      runSpacing: gap,
      children: <Widget>[
        FushiPressScale(
          child: FushiFilledButton.icon(
            key: SrsGenerationView.reportSendKey,
            onPressed: () => unawaited(actions.send(context, reportPath)),
            icon: const FushiIcon(FushiIcons.forum),
            label: Text(t.srs_gen4_report_send),
          ),
        ),
        FushiPressScale(
          child: FushiTextButton.icon(
            key: SrsGenerationView.reportExportKey,
            onPressed: () => unawaited(actions.export(context, reportPath)),
            icon: FushiIcon(save ? FushiIcons.save : FushiIcons.share),
            label: Text(
              save ? t.srs_gen4_report_save : t.srs_gen4_report_share,
            ),
          ),
        ),
      ],
    );
  }
}

/// 正在跑：当前步骤（第几步 / 共几步）、进度条、取消提示与按钮。
class _ProgressBlock extends StatelessWidget {
  const _ProgressBlock({required this.controller});

  final SrsGen4MigrationController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    final SrsGen4MigrationProgress? p = controller.progress;
    final SrsGen4MigrationStep step = p?.step ?? SrsGen4MigrationStep.space;
    final int stepCount = SrsGen4MigrationStep.values.length;
    final double? value = p == null || p.total <= 0
        ? null
        : (p.done / p.total).clamp(0.0, 1.0);
    final bool beforeCommit = step.cancellable;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '${step.index + 1}/$stepCount  ${srsGen4StepLabel(step)}',
          style: text.titleSmall,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: gap),
        FushiLinearProgressIndicator(
          value: value,
          semanticsLabel: srsGen4StepLabel(step),
        ),
        if (beforeCommit) ...<Widget>[
          SizedBox(height: gap),
          Text(
            t.srs_gen4_cancel_hint,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: gap),
          Center(
            child: FushiPressScale(
              enabled: controller.canCancel,
              child: FushiTextButton(
                key: SrsGenerationView.cancelKey,
                onPressed: controller.canCancel ? controller.cancel : null,
                child: Text(t.cancel),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
