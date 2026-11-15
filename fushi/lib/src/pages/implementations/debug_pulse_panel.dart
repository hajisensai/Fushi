/// 更新中心「应用新版」域顶部的调试版流水线面板（debug 通道才挂）。
///
/// 给调试版用户回答三件事：我装的是哪个、后面出了哪些包（各含哪些 PR）、
/// 已经合进 develop 但还没进包的有哪些、我这个平台的下一个包在排队 / 构建 / 被顶掉。
/// 数据见 `docs/specs/2026-11-10-debug-pulse.md`。
///
/// 刻意不放：各平台下载按钮（更新走应用内检查更新）、「我装的版本」选择框（本机
/// 自己知道 seq）、别的平台的出包状态、正式版 / 预发布网格（「查看更新日志」页有）。
library;

import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart'
    show ActivityRelativeTime, ActivityRelativeUnit, activityRelativeTime;
import 'package:fushi/src/updates/debug_pulse_service.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/updates/debug_pulse.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';

class DebugPulsePanel extends StatefulWidget {
  const DebugPulsePanel({
    super.key,
    required this.service,
    required this.installedSeq,
    required this.platform,
    this.customProxy = '',
    this.onUpdate,
  });

  final DebugPulseService service;

  /// 本机构建的 release sequence；不是调试版 / 取不到时 null（不标新旧）。
  final int? installedSeq;

  /// 本机平台；没有调试包的平台为 null（不显示出包状态）。
  final DebugPulsePlatform? platform;
  final String customProxy;

  /// 「更新到 debug.X」：走应用内检查更新。null 不显示按钮。
  final VoidCallback? onUpdate;

  @override
  State<DebugPulsePanel> createState() => _DebugPulsePanelState();
}

class _DebugPulsePanelState extends State<DebugPulsePanel> {
  DebugPulseReport? _report;
  bool _loading = false;
  bool _failed = false;

  /// 用户手动展开 / 收起过的包；没动过的按 [_defaultExpanded]。
  final Map<int, bool> _expanded = <int, bool>{};

  @override
  void initState() {
    super.initState();
    _report = widget.service.cached;
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final DebugPulseReport? fresh = await widget.service.refresh(
      customProxy: widget.customProxy,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (fresh != null) {
        _report = fresh;
      } else {
        _failed = true;
      }
    });
  }

  /// 默认展开：比本机新的包；本机 seq 未知或已是最新时只展开最新一个。
  bool _defaultExpanded(DebugPulseReport report, DebugPulseBuild build) {
    final int? mine = widget.installedSeq;
    if (mine != null && report.newerThan(mine).isNotEmpty) {
      return build.seq > mine;
    }
    return identical(build, report.latest);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final DebugPulseReport? report = _report;
    final List<Widget> children = <Widget>[
      _SummaryCard(
        report: report,
        installedSeq: widget.installedSeq,
        platform: widget.platform,
        loading: _loading,
        failed: _failed,
        onRefresh: _loading ? null : () => unawaited(_refresh()),
        onUpdate: widget.onUpdate,
      ),
      if (report?.pending case final DebugPulsePending pending
          when !pending.isEmpty && report != null)
        _PendingCard(
          report: report,
          pending: pending,
          platform: widget.platform,
        ),
      if (report != null)
        for (final DebugPulseBuild build in report.builds)
          _BuildCard(
            report: report,
            item: build,
            platform: widget.platform,
            installed: build.seq == widget.installedSeq,
            newer:
                widget.installedSeq != null && build.seq > widget.installedSeq!,
            expanded: _expanded[build.seq] ?? _defaultExpanded(report, build),
            onToggle: () => setState(() {
              _expanded[build.seq] =
                  !(_expanded[build.seq] ?? _defaultExpanded(report, build));
            }),
          ),
    ];
    return FushiEntranceScope(
      replayKey: report?.generatedAt,
      child: Padding(
        padding: EdgeInsets.only(bottom: tokens.spacing.section),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < children.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  bottom: i == children.length - 1 ? 0 : tokens.spacing.gap,
                ),
                child: FushiStaggeredEntrance(index: i, child: children[i]),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────── summary

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.report,
    required this.installedSeq,
    required this.platform,
    required this.loading,
    required this.failed,
    required this.onRefresh,
    required this.onUpdate,
  });

  final DebugPulseReport? report;
  final int? installedSeq;
  final DebugPulsePlatform? platform;
  final bool loading;
  final bool failed;
  final VoidCallback? onRefresh;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final DebugPulseReport? report = this.report;
    final DebugPulseBuild? target = report?.latestAvailableFor(platform);
    final int newerBuilds = report?.newerThan(installedSeq).length ?? 0;
    // 本机平台没有调试包（platform == null，如 Linux）时，[target] 只是「最新一个包」
    // 的展示用标题，不是本机能装的包：不给更新按钮，也不把卡片染成「可更新」。
    final bool canUpdate =
        platform != null &&
        installedSeq != null &&
        target != null &&
        target.seq > installedSeq!;

    final String status;
    if (report == null) {
      status = failed ? t.updates_pulse_load_failed : '';
    } else if (installedSeq == null) {
      status = t.updates_pulse_not_debug;
    } else if (newerBuilds == 0) {
      status = t.updates_pulse_up_to_date;
    } else {
      status = t.updates_pulse_newer(
        builds: newerBuilds,
        prs: report.newPrCount(installedSeq),
      );
    }
    final String meta = <String>[
      if (installedSeq != null)
        t.updates_pulse_installed(build: 'debug.$installedSeq'),
      if (report?.generatedAt case final DateTime at)
        t.updates_pulse_generated(time: _relative(at)),
      if (failed && report != null) t.updates_pulse_load_failed,
    ].join(' · ');

    return FushiCard(
      tone: canUpdate ? FushiCardTone.primary : FushiCardTone.neutral,
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.updates_pulse_title,
                  style: context.fushiType.labelLargeEmphasized.copyWith(
                    color: canUpdate ? null : scheme.primary,
                  ),
                ),
              ),
              FushiIconButton(
                key: const ValueKey<String>('debug_pulse_refresh'),
                icon: FushiIcons.refresh,
                tooltip: t.refresh,
                busy: loading,
                enabled: onRefresh != null,
                onTap: onRefresh,
              ),
            ],
          ),
          if (target != null)
            Text(
              target.label,
              style: context.fushiType.headlineMediumEmphasized.tabular,
            ),
          if (status.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(status, style: context.fushiType.titleSmallEmphasized),
          ],
          if (meta.isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              meta,
              style: context.fushiType.bodySmall.copyWith(
                color: canUpdate ? null : scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (canUpdate && onUpdate != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            FushiFilledButton.icon(
              key: const ValueKey<String>('debug_pulse_update'),
              onPressed: onUpdate,
              icon: const FushiIcon(FushiIcons.sync),
              label: Text(t.updates_pulse_update_to(build: target.label)),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────── pending

class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.report,
    required this.pending,
    required this.platform,
  });

  final DebugPulseReport report;
  final DebugPulsePending pending;
  final DebugPulsePlatform? platform;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final DebugPulseBuild? latest = report.latest;
    final DebugPulsePlatform? platform = this.platform;
    return FushiCard(
      variant: FushiCardVariant.outlined,
      borderColor: fushiStatusColor(context, FushiStatusTone.warning),
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FushiTag(
                text: t.updates_pulse_pending_badge,
                icon: FushiIcons.schedule,
                tone: FushiTagTone.warning,
                dense: true,
              ),
              if (latest != null)
                Text(
                  t.updates_pulse_pending_summary(
                    count: pending.prNumbers.length,
                    build: latest.label,
                  ),
                  style: context.fushiType.bodyMedium,
                ),
            ],
          ),
          if (pending.headSeq != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              t.updates_pulse_pending_next(build: 'debug.${pending.headSeq}'),
              style: context.fushiType.bodySmall.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          // develop 尖端没触发发布（比如只改了服务端）时四个平台都是 none：
          // 那不是「没出包」的坏消息，只是还没轮到，整行不画。
          if (DebugPulsePlatform.values.any(
            (DebugPulsePlatform p) =>
                pending.platform(p).state != DebugPulsePlatformState.none,
          )) ...<Widget>[
            const SizedBox(height: 6),
            _PlatformStates(changes: pending, mine: platform),
          ],
          SizedBox(height: tokens.spacing.gap),
          _ChangeList(report: report, changes: pending),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────── builds

class _BuildCard extends StatelessWidget {
  const _BuildCard({
    required this.report,
    required this.item,
    required this.platform,
    required this.installed,
    required this.newer,
    required this.expanded,
    required this.onToggle,
  });

  final DebugPulseReport report;
  final DebugPulseBuild item;
  final DebugPulsePlatform? platform;
  final bool installed;
  final bool newer;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final DebugPulsePlatform? platform = this.platform;
    final String meta = <String>[
      if (item.publishedAt case final DateTime at) _relative(at),
      if (!item.unknown) t.updates_pulse_pr_count(count: item.prNumbers.length),
    ].join(' · ');
    final Widget header = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: 12,
      ),
      child: Row(
        children: <Widget>[
          AnimatedRotation(
            turns: expanded ? 0.25 : 0,
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            child: FushiIcon(
              FushiIcons.chevronRight,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      item.label,
                      style: context.fushiType.titleMediumEmphasized.tabular,
                    ),
                    if (meta.isNotEmpty)
                      Text(
                        meta,
                        style: context.fushiType.bodySmall.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    if (installed)
                      FushiTag(
                        text: t.updates_pulse_installed_tag,
                        tone: FushiTagTone.accent,
                        dense: true,
                      ),
                    if (newer)
                      FushiTag(
                        text: t.updates_pulse_new_tag,
                        tone: FushiTagTone.success,
                        dense: true,
                      ),
                  ],
                ),
                if (!item.unknown || item.platforms.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  _PlatformStates(
                    changes: item,
                    mine: platform,
                    testflight: item.testflight,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return FushiCard(
      padding: EdgeInsets.zero,
      tone: FushiCardTone.neutral,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            button: true,
            expanded: expanded,
            // 标题行用一张透明卡承接点按：状态层 / 悬停 / 焦点按设计系统各自分派
            // （Apple 不出水波），不在这里手搭 InkWell。
            child: FushiCard(
              key: ValueKey<String>('debug_pulse_build_${item.seq}'),
              onTap: onToggle,
              padding: EdgeInsets.zero,
              color: Colors.transparent,
              pressScale: false,
              child: header,
            ),
          ),
          FushiAnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.standard,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.card,
                      0,
                      tokens.spacing.card,
                      tokens.spacing.card,
                    ),
                    child: item.unknown
                        ? Text(
                            t.updates_pulse_unknown_contents,
                            style: context.fushiType.bodySmall,
                          )
                        : _ChangeList(report: report, changes: item),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────── shared pieces

/// 一组改动：PR 按类别分组（新功能 → 修复 → 优化 → 其他），末尾直推提交数。
class _ChangeList extends StatelessWidget {
  const _ChangeList({required this.report, required this.changes});

  final DebugPulseReport report;
  final DebugPulseChangeSet changes;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Map<DebugPulsePrKind, List<DebugPulsePr>> groups =
        <DebugPulsePrKind, List<DebugPulsePr>>{};
    for (final int n in changes.prNumbers) {
      final DebugPulsePr pr = report.pr(n);
      (groups[pr.kind] ??= <DebugPulsePr>[]).add(pr);
    }
    final TextStyle hint = context.fushiType.bodySmall.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (groups.isEmpty) Text(t.updates_pulse_no_prs, style: hint),
        for (final DebugPulsePrKind kind in DebugPulsePrKind.values)
          if (groups[kind] case final List<DebugPulsePr> prs) ...<Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                '${_kindLabel(kind)} · ${prs.length}',
                style: context.fushiType.labelMediumEmphasized.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            for (int i = 0; i < prs.length; i++)
              FushiGroupedListItem(
                index: i,
                count: prs.length,
                onTap: () => unawaited(
                  launchUrl(
                    Uri.parse(report.prUrl(prs[i].number)),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                child: _PrRow(pr: prs[i]),
              ),
          ],
        if (changes.direct.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              t.updates_pulse_direct_commits(count: changes.direct.length),
              style: hint,
            ),
          ),
        if (changes.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(t.updates_pulse_truncated, style: hint),
          ),
      ],
    );
  }
}

class _PrRow extends StatelessWidget {
  const _PrRow({required this.pr});

  final DebugPulsePr pr;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? scope = pr.scope;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: <Widget>[
          FushiTag(
            text: _kindLabel(pr.kind),
            tone: switch (pr.kind) {
              DebugPulsePrKind.feature => FushiTagTone.success,
              DebugPulsePrKind.fix => FushiTagTone.warning,
              DebugPulsePrKind.perf => FushiTagTone.accent,
              DebugPulsePrKind.other => FushiTagTone.neutral,
            },
          ),
          const SizedBox(width: 6),
          if (scope != null) ...<Widget>[
            FushiTag(text: scope, tone: FushiTagTone.neutral),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              pr.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.bodyMedium,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '#${pr.number}',
            style: context.fushiType.labelSmall.tabular.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一个包（或还没进包的 develop）在四个平台上的出包状态。已出包只写平台名，
/// 例外（构建中 / 被顶掉 / 失败……）带上状态字；本机平台加粗。
class _PlatformStates extends StatelessWidget {
  const _PlatformStates({
    required this.changes,
    required this.mine,
    this.testflight = false,
  });

  final DebugPulseChangeSet changes;
  final DebugPulsePlatform? mine;
  final bool testflight;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final DebugPulsePlatform p in DebugPulsePlatform.values)
          _PlatformStateTag(
            platform: p,
            status: changes.platform(p),
            mine: p == mine,
          ),
        if (testflight)
          const FushiTag(
            text: 'TestFlight',
            tone: FushiTagTone.accent,
            dense: true,
          ),
      ],
    );
  }
}

class _PlatformStateTag extends StatelessWidget {
  const _PlatformStateTag({
    required this.platform,
    required this.status,
    required this.mine,
  });

  final DebugPulsePlatform platform;
  final DebugPulsePlatformStatus status;

  /// 本机平台：字加粗。
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final DebugPulsePlatformState state = status.state;
    final (FushiTagTone tone, IconData icon, String label) = switch (state) {
      DebugPulsePlatformState.ok => (
        FushiTagTone.success,
        FushiIcons.check,
        t.updates_pulse_state_ok,
      ),
      DebugPulsePlatformState.queued => (
        FushiTagTone.neutral,
        FushiIcons.schedule,
        t.updates_pulse_state_queued,
      ),
      DebugPulsePlatformState.building => (
        FushiTagTone.accent,
        FushiIcons.pending,
        t.updates_pulse_state_building,
      ),
      DebugPulsePlatformState.built => (
        FushiTagTone.accent,
        FushiIcons.pending,
        t.updates_pulse_state_built,
      ),
      DebugPulsePlatformState.failed => (
        FushiTagTone.error,
        FushiIcons.error,
        t.updates_pulse_state_failed,
      ),
      DebugPulsePlatformState.superseded => (
        FushiTagTone.neutral,
        FushiIcons.block,
        t.updates_pulse_state_superseded,
      ),
      DebugPulsePlatformState.none => (
        FushiTagTone.neutral,
        FushiIcons.block,
        t.updates_pulse_state_none,
      ),
    };
    final String name = _platformLabel(platform);
    return FushiTag(
      key: ValueKey<String>('debug_pulse_platform_${platform.wire}'),
      text: state == DebugPulsePlatformState.ok ? name : '$name $label',
      message: '$name: $label',
      icon: icon,
      tone: tone,
      dense: true,
      style: mine
          ? context.fushiType.labelSmallEmphasized
          : context.fushiType.labelSmall,
    );
  }
}

String _platformLabel(DebugPulsePlatform p) => switch (p) {
  DebugPulsePlatform.android => 'Android',
  DebugPulsePlatform.windows => 'Windows',
  DebugPulsePlatform.macos => 'macOS',
  DebugPulsePlatform.ios => 'iOS',
};

String _kindLabel(DebugPulsePrKind kind) => switch (kind) {
  DebugPulsePrKind.feature => t.updates_pulse_kind_feature,
  DebugPulsePrKind.fix => t.updates_pulse_kind_fix,
  DebugPulsePrKind.perf => t.updates_pulse_kind_perf,
  DebugPulsePrKind.other => t.updates_pulse_kind_other,
};

String _relative(DateTime at) {
  final ActivityRelativeTime rel = activityRelativeTime(
    at.millisecondsSinceEpoch,
    DateTime.now(),
  );
  return switch (rel.unit) {
    ActivityRelativeUnit.justNow => t.activity_just_now,
    ActivityRelativeUnit.minutesAgo => t.activity_minutes_ago(n: rel.value),
    ActivityRelativeUnit.hoursAgo => t.activity_hours_ago(n: rel.value),
    ActivityRelativeUnit.daysAgo => t.activity_days_ago(n: rel.value),
  };
}
