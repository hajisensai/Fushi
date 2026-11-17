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
/// - [SrsGenState.migrationFailed]（主进程）：上次没完成，可重新升级。
/// - [SrsGenState.sealedOldOnly]：只剩封存旧库，不自动重建，给恢复说明。
/// - [SrsStoreMigrating]（-5）/ [SrsGenState.migratingElsewhere]：别的窗口在迁移，稍后重试。
/// - [SrsStoreLegacyUnmigrated]（-6）：旁边有没迁移的旧库，两份都原样保留。
/// - [SrsLegacyMainDatabasePending]：协议 1 的数据还在主库里，原样保留。
/// - 非主进程（弹窗 / 查词窗）：只提示去主窗口完成升级，不在这里迁移。
///
/// 文案不吓人：迁移无损，旧库封存不删。MD3 与 Apple 两套都走 [FushiPlaceholderMessage] 与 Fushi 按钮，
/// 区块错峰进场（[FushiEntranceScope] + [FushiStaggeredEntrance]），按钮按压缩放（[FushiPressScale]）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_storage.dart'
    show SrsLegacyMainDatabasePending;
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_gen4_migration_controller.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';

/// 页面按哪一种状态出内容（由打开错误 + 是否主进程决定）。
enum SrsGenerationKind {
  /// 主进程、要迁移：迁移面板。
  migrate,

  /// 主进程、上次迁移没完成：迁移面板（「重新升级」）。
  retryFailed,

  /// 非主进程、要迁移 / 上次没完成：去主窗口。
  openMainWindow,

  /// 别的窗口 / 进程在迁移。
  migratingElsewhere,

  /// 只剩封存旧库。
  sealedOldOnly,

  /// 旁边有没迁移的协议 3 旧库（-6）。
  legacyUnmigrated,

  /// 协议 1 的数据还在主库里。
  legacyMainDatabase,

  /// 已经可以用了（状态在页面挂着时变了）：只给重试。
  ready,
}

/// [error] 在本进程（[isMainProcess]）里该出哪一种内容。
SrsGenerationKind srsGenerationKindOf(
  Object error, {
  required bool isMainProcess,
}) {
  return switch (error) {
    SrsLegacyMainDatabasePending() => SrsGenerationKind.legacyMainDatabase,
    SrsStoreMigrating() => SrsGenerationKind.migratingElsewhere,
    SrsStoreLegacyUnmigrated() => SrsGenerationKind.legacyUnmigrated,
    SrsStoreNotMigrated(:final SrsGenState state) => switch (state) {
      SrsGenState.needsMigration =>
        isMainProcess
            ? SrsGenerationKind.migrate
            : SrsGenerationKind.openMainWindow,
      SrsGenState.migrationFailed =>
        isMainProcess
            ? SrsGenerationKind.retryFailed
            : SrsGenerationKind.openMainWindow,
      SrsGenState.migratingElsewhere => SrsGenerationKind.migratingElsewhere,
      SrsGenState.sealedOldOnly => SrsGenerationKind.sealedOldOnly,
      SrsGenState.ready => SrsGenerationKind.ready,
    },
    _ => SrsGenerationKind.ready,
  };
}

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
  SrsGen4MigrationVerdict.aborted => t.srs_gen4_aborted(
    path: o.reportPath ?? '',
  ),
  SrsGen4MigrationVerdict.committed => t.srs_gen4_running,
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

/// 迁移面板：说明 → 进度（步骤 + 进度条 + 取消）→ 结论。
class _MigrationPanel extends StatelessWidget {
  const _MigrationPanel({required this.controller, required this.failedBefore});

  final SrsGen4MigrationController controller;
  final bool failedBefore;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, _) => _buildFor(context),
    );
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
    final List<String> details = <String>[
      if (!running && outcome != null) srsGen4OutcomeText(outcome),
      if (!running && showReason) reason,
      if (!running && error != null) ...<String>[t.srs_gen4_failed, '$error'],
      if (blockedStart && controller.databaseClosing) t.srs_gen4_closing,
    ];
    final Widget head = FushiPlaceholderMessage(
      icon: running
          ? FushiIcons.sync
          : (error != null ? FushiIcons.error : FushiIcons.storage),
      tone: !running && error != null
          ? FushiPlaceholderTone.error
          : FushiPlaceholderTone.neutral,
      message: t.srs_gen4_title,
      detail: running
          ? t.srs_gen4_running
          : (failedBefore
                ? t.srs_gen4_migration_failed_state
                : t.srs_gen4_needs_migration),
      details: details,
      detailMaxLines: null,
    );
    final List<Widget> blocks = <Widget>[
      head,
      if (running) _ProgressBlock(controller: controller),
      if (!running && retryable)
        Center(
          child: FushiPressScale(
            enabled: !blockedStart,
            child: FushiFilledButton.icon(
              key: SrsGenerationView.startKey,
              // 主库已关 / 正在关：置灰（关库前的静默已经等过这个控制器，之后开始的迁移没人等）。
              onPressed: blockedStart ? null : controller.start,
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
