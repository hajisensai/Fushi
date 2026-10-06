import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_pending_note.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_issue_text.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_candidate_tile.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_run_detail_dialog.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 打开可重复进入的后台刮削任务面板。任务由应用级 controller 持有，关闭面板只
/// 隐藏观察器，不会取消网络请求、数据库写入或 sidecar 输出。
Future<void> showVideoSourceScrapeTaskPanel({
  required BuildContext context,
  required VideoSourceScrapeTaskController controller,
  required Future<List<VideoSourceScrapeRunRow>> Function() loadRuns,
  Future<void> Function(VideoSourceScrapeRunRow run)? onRetry,
  Future<SourceLibraryRow?> Function(int sourceId)? loadSource,
  Future<List<VideoPendingScrapeWork>> Function()? loadPendingWorks,
}) =>
    showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => _VideoSourceScrapeTaskPanel(
        controller: controller,
        loadRuns: loadRuns,
        onRetry: onRetry,
        loadSource: loadSource,
        loadPendingWorks: loadPendingWorks,
      ),
    );

class _VideoSourceScrapeTaskPanel extends StatefulWidget {
  const _VideoSourceScrapeTaskPanel({
    required this.controller,
    required this.loadRuns,
    this.onRetry,
    this.loadSource,
    this.loadPendingWorks,
  });

  final VideoSourceScrapeTaskController controller;
  final Future<List<VideoSourceScrapeRunRow>> Function() loadRuns;
  final Future<void> Function(VideoSourceScrapeRunRow run)? onRetry;
  final Future<SourceLibraryRow?> Function(int sourceId)? loadSource;

  /// 待确认队列数据源：当前计划里「从未刮出规范身份」的作品。null = 不展示。
  final Future<List<VideoPendingScrapeWork>> Function()? loadPendingWorks;

  @override
  State<_VideoSourceScrapeTaskPanel> createState() =>
      _VideoSourceScrapeTaskPanelState();
}

class _VideoSourceScrapeTaskPanelState
    extends State<_VideoSourceScrapeTaskPanel> {
  List<VideoSourceScrapeRunRow> _runs = const <VideoSourceScrapeRunRow>[];
  Object? _historyError;
  bool _loadingHistory = true;
  VideoSourceScrapePhase _lastPhase = VideoSourceScrapePhase.idle;
  final Set<int> _retrying = <int>{};
  List<VideoPendingScrapeWork> _pendingWorks = const <VideoPendingScrapeWork>[];
  final Set<String> _bindingStableKeys = <String>{};

  /// 待确认页顶部的一行说明：手动指定 / AI 识别的失败原因或 AI 识别的结论。
  String? _pendingNotice;
  bool _loadingPending = true;
  Object? _pendingError;
  int _pendingLoadGeneration = 0;
  int _historyLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _lastPhase = widget.controller.progress.phase;
    unawaited(_reloadHistory());
    unawaited(_reloadPendingWorks());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final VideoSourceScrapePhase next = widget.controller.progress.phase;
    final bool becameTerminal = next != _lastPhase &&
        !widget.controller.progress.isRunning &&
        next != VideoSourceScrapePhase.idle;
    _lastPhase = next;
    if (mounted) setState(() {});
    if (becameTerminal) {
      unawaited(_reloadHistory());
      // 批次可能刚认领了一批待确认作品，队列跟着刷新。
      unawaited(_reloadPendingWorks());
    }
  }

  Future<void> _reloadPendingWorks() async {
    final int generation = ++_pendingLoadGeneration;
    final Future<List<VideoPendingScrapeWork>> Function()? load =
        widget.loadPendingWorks;
    if (load == null) {
      if (mounted) setState(() => _loadingPending = false);
      return;
    }
    if (mounted) {
      setState(() {
        _loadingPending = true;
        _pendingError = null;
      });
    }
    try {
      final List<VideoPendingScrapeWork> pending = await load();
      if (!mounted || generation != _pendingLoadGeneration) return;
      setState(() => _pendingWorks = pending);
    } on Object catch (error) {
      if (mounted && generation == _pendingLoadGeneration) {
        setState(() => _pendingError = error);
      }
    } finally {
      if (mounted && generation == _pendingLoadGeneration) {
        setState(() => _loadingPending = false);
      }
    }
  }

  Future<void> _reloadHistory() async {
    final int generation = ++_historyLoadGeneration;
    if (mounted) {
      setState(() {
        _loadingHistory = true;
        _historyError = null;
      });
    }
    try {
      final List<VideoSourceScrapeRunRow> runs = await widget.loadRuns();
      if (!mounted || generation != _historyLoadGeneration) return;
      setState(() {
        _runs = runs;
        _loadingHistory = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _historyLoadGeneration) return;
      setState(() {
        _historyError = error;
        _loadingHistory = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool running = widget.controller.isRunning;
    final VideoSourceScrapeConfirmation? confirmation =
        widget.controller.pendingConfirmation;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    return DefaultTabController(
      length: 3,
      child: FushiAlertDialog(
        icon: const FushiIcon(FushiIcons.manageSearch),
        title: Text(t.video_source_scrape_tasks_open),
        content: SizedBox(
          width: 880,
          height: (MediaQuery.sizeOf(context).height * .65).clamp(240, 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                t.video_source_scrape_background_hint,
                style: type.bodyMedium.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              FushiTabBar(
                isScrollable: false,
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                tabs: <Widget>[
                  Tab(
                    key: const ValueKey<String>('video-source-tab-activity'),
                    text: t.video_source_scrape_tasks_current,
                  ),
                  Tab(
                    key: const ValueKey<String>('video-source-tab-pending'),
                    text: t.video_source_scrape_pending_tab,
                  ),
                  Tab(
                    key: const ValueKey<String>('video-source-tab-history'),
                    text: t.video_source_scrape_tasks_history,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TabBarView(
                  children: <Widget>[
                    _buildActivity(),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            FushiTag(
                              dense: true,
                              tone: _pendingWorks.isEmpty
                                  ? FushiTagTone.neutral
                                  : FushiTagTone.accent,
                              text: '${_pendingWorks.length}',
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                t.video_source_scrape_pending_works_hint,
                                style: type.bodyMedium.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_pendingNotice
                            case final String notice) ...<Widget>[
                          FushiCard(
                            tone: FushiCardTone.tertiary,
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                const FushiIcon(FushiIcons.ai, size: 20),
                                const SizedBox(width: 10),
                                Expanded(child: SelectableText(notice)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Expanded(child: _buildPendingWorks()),
                      ],
                    ),
                    _buildHistory(),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          FushiDialogAction(
            label: t.dialog_close,
            onPressed: () => Navigator.of(context).pop(),
          ),
          if (running)
            FushiDialogAction(
              label: t.video_source_scrape_queue_cancel_all,
              onPressed: widget.controller.cancel,
            ),
          if (confirmation != null)
            FushiDialogAction(
              key: const ValueKey<String>('video-source-confirmation-skip'),
              label: t.video_source_scrape_confirmation_skip,
              onPressed: widget.controller.skipPendingConfirmation,
            ),
        ],
      ),
    );
  }

  /// 「当前任务」tab 是**一个**平铺的列表：状态头 → 报告说明行 / 待确认候选
  /// → 排队请求，全部是同一个 `ListView` 的条目，占满 tab 的整个高度。
  ///
  /// 以前把报告说明和候选各自套一层 `ConstrainedBox(maxHeight: 260/300)` +
  /// `shrinkWrap` 内嵌列表：外层列表无界高度，内层只能硬截，弹窗下半截永远
  /// 空着、上半截 260px 里再滚（BUG-2594）。
  Widget _buildActivity() {
    final VideoSourceScrapeProgress progress = widget.controller.progress;
    final VideoSourceScrapeConfirmation? confirmation =
        widget.controller.pendingConfirmation;
    final SourceScrapeReport? report = progress.report;
    final List<VideoSourceScrapeManualRequest> queued =
        widget.controller.queuedManualRequests;
    final List<Widget> rows = <Widget>[
      if (widget.controller.isScanning)
        _buildStatusCard(
          icon: FushiIcons.folderOpen,
          tone: FushiCardTone.primary,
          title: t.video_source_scrape_phase_scanning,
          progressValue: null,
          showProgress: true,
        )
      else if (confirmation != null)
        ..._confirmationRows(confirmation)
      else if (report != null)
        ..._reportRows(progress.phase, report)
      else
        _buildProgress(progress),
      if (queued.isNotEmpty) ...<Widget>[
        const SizedBox(height: 20),
        _sectionHeader(
          FushiIcons.schedule,
          '${t.video_source_scrape_queue_waiting} (${queued.length})',
        ),
        for (int index = 0; index < queued.length; index++)
          FushiGroupedListItem(
            key: ObjectKey(queued[index]),
            index: index,
            count: queued.length,
            child: FushiListItem(
              density: FushiListDensity.compact,
              leading: _QueuePositionBadge(position: index + 1),
              title: Text(queued[index].workTitle),
              subtitle: Text(_queuedSubtitle(queued[index])),
              trailing: FushiIconButtonControl(
                tooltip: t.video_source_scrape_queue_remove,
                onPressed: () =>
                    widget.controller.cancelQueuedManualRequest(queued[index]),
                icon: const FushiIcon(FushiIcons.close),
              ),
            ),
          ),
      ],
    ];
    // 进场窗口跟着「当前在看什么」走：换到下一部待确认作品 / 批次结束出报告时
    // 重开一次，新的一屏也错峰进场；进度刷新（同一阶段）不重播。
    final Object replayKey = confirmation ??
        report ??
        (widget.controller.isScanning ? 'scanning' : progress.phase);
    return FushiEntranceScope(
      replayKey: replayKey,
      child: ListView.builder(
        key: const PageStorageKey<String>('video-source-activity-list'),
        itemCount: rows.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => rows[index],
        ),
      ),
    );
  }

  /// 区块小标题：图标 + titleSmall emphasized（分段卡片组之上）。
  Widget _sectionHeader(IconData icon, String label) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
      child: Row(
        children: <Widget>[
          FushiIcon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: context.fushiType.titleSmallEmphasized),
          ),
        ],
      ),
    );
  }

  /// 当前任务状态卡：M3E 饱和色块 + 状态图标 + 标题，[showProgress] 时带
  /// 波浪进度条（[progressValue] null = 不定进度），[percent] 给出时右侧
  /// Display 大数字百分比。其余说明行放 [details]。
  Widget _buildStatusCard({
    required IconData icon,
    required FushiCardTone tone,
    required String title,
    required double? progressValue,
    required bool showProgress,
    int? percent,
    List<Widget> details = const <Widget>[],
  }) {
    final FushiTypography type = context.fushiType;
    // fushiType 的槽位自带页面前景色，会盖掉饱和卡写进 DefaultTextStyle 的
    // 配对前景（HBK-AUDIT-022）；中性卡 onCard 为 null 保持原色。
    final Color? onCard = fushiCardToneColors(context, tone)?.onContainer;
    return FushiCard(
      tone: tone,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              FushiIcon(icon, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: type.titleMediumEmphasized.copyWith(color: onCard),
                ),
              ),
              if (percent != null)
                Text(
                  '$percent%',
                  style: type.headlineSmallEmphasized.tabular
                      .copyWith(color: onCard),
                ),
            ],
          ),
          if (showProgress) ...<Widget>[
            const SizedBox(height: 12),
            FushiLinearProgressIndicator(value: progressValue),
          ],
          for (final Widget detail in details) ...<Widget>[
            const SizedBox(height: 6),
            detail,
          ],
        ],
      ),
    );
  }

  Widget _buildProgress(VideoSourceScrapeProgress progress) {
    final int total = progress.total;
    final double? value = total <= 0 ? null : progress.current / total;
    final String phase = _phaseLabel(progress.phase);
    // 说明行落在 [_buildStatusCard] 的饱和卡上：跟卡片配对前景。
    final Color? onCard =
        fushiCardToneColors(context, _phaseTone(progress.phase))?.onContainer;
    final TextStyle detailStyle =
        context.fushiType.bodyMedium.copyWith(color: onCard);
    return _buildStatusCard(
      icon: _phaseIcon(progress.phase),
      tone: _phaseTone(progress.phase),
      title: t.video_source_scrape_progress(
        phase: phase,
        current: progress.current,
        total: total,
      ),
      progressValue: value,
      showProgress: progress.isRunning,
      percent: progress.isRunning && value != null
          ? (value * 100).round().clamp(0, 100).toInt()
          : null,
      details: <Widget>[
        if (progress.sourceLabel case final String label)
          Text(label, style: detailStyle),
        if (progress.currentWorkTitle case final String title)
          Text(
            t.scrape_all_item(title: title),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: detailStyle,
          ),
        if (progress.message case final String message)
          SelectableText(
            message,
            style: context.fushiType.bodySmall.copyWith(color: onCard),
          ),
      ],
    );
  }

  /// 待确认队列：条目来自当前计划（不是历史 run 快照），手动指定按 stableKey
  /// 对应的真实作品执行——绑定入口永远不会指向已消失的作品。
  Widget _buildPendingWorks() {
    if (_loadingPending) {
      return const FushiLoadingView();
    }
    if (_pendingError case final Object error) {
      return _buildLoadError(error, _reloadPendingWorks);
    }
    if (_pendingWorks.isEmpty) {
      return FushiPlaceholderMessage(
        icon: FushiIcons.success,
        message: t.video_source_scrape_pending_empty,
      );
    }
    final int count = _pendingWorks.length;
    return FushiEntranceScope(
      child: ListView.builder(
        key: const PageStorageKey<String>('video-source-pending-list'),
        itemCount: count,
        itemBuilder: fushiStaggeredItemBuilder((
          BuildContext context,
          int index,
        ) {
          final VideoPendingScrapeWork entry = _pendingWorks[index];
          final bool pending = widget.controller.isManualRequestPending(
            sourceId: entry.source.id,
            workTitle: entry.work.title,
            workStableKey: entry.work.stableKey,
          );
          // 为什么还没认出来：最近一次刮削留下的原因 + AI 结果；没刮过就如实说。
          final VideoScrapePendingNote? note = entry.pendingNote;
          final String reason = note == null
              ? t.video_scrape_pending_record_missing
              : describeVideoScrapePendingNote(note);
          return FushiGroupedListItem(
            index: index,
            count: count,
            child: FushiListItem(
              key: ValueKey<String>(
                'video-source-pending-work-${entry.work.stableKey}',
              ),
              density: FushiListDensity.compact,
              leading: const FushiListLeadingIcon(
                FushiIcons.folder,
                size: 36,
                iconSize: 20,
              ),
              title: Text(entry.work.title),
              subtitle: Text(
                '${entry.source.label}\n$reason',
                key: ValueKey<String>(
                  'video-source-pending-reason-${entry.work.stableKey}',
                ),
              ),
              trailing: pending ||
                      _bindingStableKeys.contains(entry.work.stableKey)
                  ? FushiTag(
                      dense: true,
                      tone: FushiTagTone.accent,
                      icon: FushiIcons.pending,
                      text: t.video_source_scrape_queue_submitted,
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (widget.controller.supportsAiIdentify)
                          FushiIconButtonControl(
                            key: ValueKey<String>(
                              'video-source-pending-ai-${entry.work.stableKey}',
                            ),
                            tooltip: t.video_source_scrape_ai_identify,
                            onPressed: () =>
                                unawaited(_identifyPendingWork(entry)),
                            icon: const FushiIcon(FushiIcons.ai),
                          ),
                        FushiIconButtonControl(
                          tooltip: t.video_source_scrape_manual_search_title,
                          onPressed: () => unawaited(_bindPendingWork(entry)),
                          icon: const FushiIcon(FushiIcons.search),
                        ),
                      ],
                    ),
            ),
          );
        }),
      ),
    );
  }

  String _queuedSubtitle(
    VideoSourceScrapeManualRequest request,
  ) =>
      switch (request.lookup) {
        final VideoMetadataLookup lookup =>
          '${request.source.label} · ${lookup.provider.name.toUpperCase()} ${lookup.externalId}',
        null =>
          '${request.source.label} · ${t.video_source_scrape_ai_identify}',
      };

  /// 「AI 识别」：对这一部重跑识别并强制重问 AI（歧义时在候选里挑、查无时
  /// 让 AI 给正式标题再搜）。入口对没指派 AI 的用户也可见，点了只引导去
  /// 「设置 › AI」，不发任何 AI 请求（BUG-2694 的约定）。
  Future<void> _identifyPendingWork(VideoPendingScrapeWork entry) async {
    if (!widget.controller.aiIdentityAvailable) {
      setState(() => _pendingNotice = t.ai_assist_no_provider);
      return;
    }
    await _runPendingWork(
      entry,
      () => widget.controller.identifyWorkWithAi(
        source: entry.source,
        workTitle: entry.work.title,
        workStableKey: entry.work.stableKey,
      ),
      describeOutcome: _aiOutcome,
    );
  }

  /// AI 识别的结论：AI 的每一步（采用 / 不采用 / 失败 / 重搜）都在报告里留了
  /// `ai:*` 标记，逐条译成文案；一条都没有时退回整体汇总。
  static String _aiOutcome(SourceScrapeReport report) {
    final List<String> notes = <String>[
      for (final SourceScrapeIssue issue in report.warnings)
        if (parseVideoScrapeAiIdentityNote(issue.message) != null)
          describeVideoScrapeIssueMessage(issue.message),
    ];
    final String summary = t.scrape_all_done(
      applied: report.succeededWorks,
      review: report.pendingConfirmations,
      skipped: report.protectedArtifacts,
      failed: report.failedWorks,
    );
    return <String>[summary, ...notes].join('\n');
  }

  Future<void> _bindPendingWork(VideoPendingScrapeWork entry) async {
    final VideoSourceScrapeConfirmationCandidate? candidate =
        await showVideoSourceScrapeManualBindingDialog(
      context: context,
      controller: widget.controller,
      source: entry.source,
      workTitle: entry.work.title,
      workStableKey: entry.work.stableKey,
    );
    if (candidate == null || !mounted) return;
    await _runPendingWork(
      entry,
      () => widget.controller.rescrapeWorkWithLookup(
        source: entry.source,
        workTitle: entry.work.title,
        workStableKey: entry.work.stableKey,
        lookup: candidate.lookup,
      ),
    );
  }

  /// 待确认作品的单作品操作（手动指定 / AI 识别）共用的执行与收尾。
  Future<void> _runPendingWork(
    VideoPendingScrapeWork entry,
    Future<SourceScrapeReport> Function() operation, {
    String Function(SourceScrapeReport report)? describeOutcome,
  }) async {
    setState(() {
      _bindingStableKeys.add(entry.work.stableKey);
      _pendingNotice = null;
    });
    try {
      final SourceScrapeReport report = await operation();
      if (describeOutcome != null && mounted) {
        setState(() => _pendingNotice = describeOutcome(report));
      }
      await _reloadHistory();
      await _reloadPendingWorks();
    } on VideoSourceScrapeCancelled {
      // 撤回排队是用户操作，不把它显示成一次失败。
    } on VideoSourceScrapeWorkNotFound {
      if (!mounted) return;
      setState(() => _pendingNotice = t.video_source_scrape_work_missing);
      unawaited(_reloadPendingWorks());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _pendingNotice = error.toString());
    } finally {
      if (mounted) {
        setState(() => _bindingStableKeys.remove(entry.work.stableKey));
      }
    }
  }

  Widget _buildHistory() {
    if (_loadingHistory) {
      return const FushiLoadingView();
    }
    if (_historyError case final Object error) {
      return _buildLoadError(error, _reloadHistory);
    }
    if (_runs.isEmpty) {
      return FushiPlaceholderMessage(
        icon: FushiIcons.history,
        message: t.video_source_scrape_tasks_empty,
      );
    }
    final int count = _runs.length;
    return FushiEntranceScope(
      child: ListView.builder(
        key: const PageStorageKey<String>('video-source-history-list'),
        itemCount: count,
        itemBuilder: fushiStaggeredItemBuilder((
          BuildContext context,
          int index,
        ) {
          final VideoSourceScrapeRunRow run = _runs[index];
          return FushiGroupedListItem(
            index: index,
            count: count,
            child: FushiListItem(
              key: ValueKey<String>('video-source-scrape-run-${run.id}'),
              density: FushiListDensity.compact,
              leading: FushiListLeadingIcon(
                _runIcon(run.status),
                tone: _runTone(run.status),
                size: 36,
                iconSize: 20,
              ),
              title: Text(
                '${videoSourceScrapeRunStatusLabel(run.status)} · '
                '${run.provider?.toUpperCase() ?? t.nav_video}',
              ),
              subtitle: Text(_runSubtitle(run)),
              subtitleMaxLines: 3,
              onTap: () => unawaited(_openRunDetail(run)),
              trailing: widget.onRetry != null &&
                      run.sourceId != null &&
                      scrapeRunHasUnresolvedWorks(run)
                  ? FushiIconButtonControl(
                      tooltip: t.video_source_scrape_rescrape_source,
                      onPressed:
                          _retrying.contains(run.id) || widget.controller.isBusy
                              ? null
                              : () => unawaited(_retry(run)),
                      icon: _retrying.contains(run.id)
                          ? const SizedBox.square(
                              dimension: 18,
                              child: FushiCircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const FushiIcon(FushiIcons.replay),
                    )
                  : null,
            ),
          );
        }),
      ),
    );
  }

  /// 列表加载失败：全应用统一的错误态（errorContainer 色块图标 + 原因 + 重试）。
  /// 外层 ListView 让小窗口下也能滚到「重新加载」按钮。
  Widget _buildLoadError(Object error, Future<void> Function() reload) =>
      ListView(
        children: <Widget>[
          FushiPlaceholderMessage(
            tone: FushiPlaceholderTone.error,
            icon: FushiIcons.error,
            message: t.video_source_scrape_list_load_failed,
            detail: error.toString(),
            action: FushiFilledButton.tonalIcon(
              onPressed: () => unawaited(reload()),
              icon: const FushiIcon(FushiIcons.refresh, size: 18),
              label: Text(t.video_source_scrape_list_reload),
            ),
          ),
        ],
      );

  String _runSubtitle(VideoSourceScrapeRunRow run) {
    final String started = FushiTimeFormat.dateHourMinute(
      DateTime.fromMillisecondsSinceEpoch(run.startedAt),
    );
    final String summary = t.video_source_scrape_last_summary(
      status: videoSourceScrapeRunStatusLabel(run.status),
      succeeded: run.succeededWorks,
      pending: run.pendingConfirmations,
      failed: run.failedWorks,
    );
    final String? error = run.lastError?.trim();
    return error == null || error.isEmpty
        ? '$started\n$summary'
        : '$started\n$summary\n$error';
  }

  Future<void> _retry(VideoSourceScrapeRunRow run) async {
    final Future<void> Function(VideoSourceScrapeRunRow run)? retry =
        widget.onRetry;
    if (retry == null) return;
    setState(() => _retrying.add(run.id));
    try {
      await retry(run);
      await _reloadHistory();
    } finally {
      if (mounted) setState(() => _retrying.remove(run.id));
    }
  }

  /// 点历史条目 = 打开这次 run 的可操作详情：逐条作品的待确认/失败原因，
  /// 以及「手动指定作品」和「重新刮削此来源」。
  Future<void> _openRunDetail(VideoSourceScrapeRunRow run) async {
    final int? sourceId = run.sourceId;
    final Future<SourceLibraryRow?> Function(int sourceId)? loadSource =
        widget.loadSource;
    final SourceLibraryRow? source = sourceId == null || loadSource == null
        ? null
        : await loadSource(sourceId);
    if (!mounted) return;
    final Future<void> Function(VideoSourceScrapeRunRow run)? retry =
        widget.onRetry;
    final bool changed = await showVideoSourceScrapeRunDetailDialog(
      context: context,
      run: run,
      source: source,
      controller: widget.controller,
      onRescrapeSource: retry == null || source == null
          ? null
          : (SourceLibraryRow _) => retry(run),
    );
    if (changed && mounted) await _reloadHistory();
  }

  String _phaseLabel(VideoSourceScrapePhase phase) => switch (phase) {
        VideoSourceScrapePhase.planning => t.video_source_scrape_phase_planning,
        VideoSourceScrapePhase.recognizing =>
          t.video_source_scrape_phase_recognizing,
        VideoSourceScrapePhase.fetching => t.video_source_scrape_phase_fetching,
        VideoSourceScrapePhase.applying => t.video_source_scrape_phase_applying,
        VideoSourceScrapePhase.writingSidecars =>
          t.video_source_scrape_phase_writing_sidecars,
        VideoSourceScrapePhase.completed => t.download_task_status_completed,
        VideoSourceScrapePhase.cancelled => t.download_status_cancelled,
        VideoSourceScrapePhase.interrupted =>
          t.video_source_scrape_status_interrupted,
        VideoSourceScrapePhase.failed => t.download_task_status_error,
        VideoSourceScrapePhase.idle => t.video_source_scrape_tasks_empty,
      };

  IconData _runIcon(String status) => switch (status) {
        'completed' => FushiIcons.success,
        'failed' => FushiIcons.error,
        'cancelled' => FushiIcons.block,
        'interrupted' => FushiIcons.pause,
        _ => FushiIcons.sync,
      };

  FushiCardTone _runTone(String status) => switch (status) {
        'completed' => FushiCardTone.primary,
        'failed' => FushiCardTone.error,
        'cancelled' || 'interrupted' => FushiCardTone.neutral,
        _ => FushiCardTone.tertiary,
      };

  IconData _phaseIcon(VideoSourceScrapePhase phase) => switch (phase) {
        VideoSourceScrapePhase.completed => FushiIcons.success,
        VideoSourceScrapePhase.failed => FushiIcons.error,
        VideoSourceScrapePhase.cancelled => FushiIcons.block,
        VideoSourceScrapePhase.interrupted => FushiIcons.pause,
        VideoSourceScrapePhase.idle => FushiIcons.schedule,
        VideoSourceScrapePhase.planning => FushiIcons.checklist,
        VideoSourceScrapePhase.recognizing => FushiIcons.manageSearch,
        VideoSourceScrapePhase.fetching => FushiIcons.cloudDownload,
        VideoSourceScrapePhase.applying => FushiIcons.save,
        VideoSourceScrapePhase.writingSidecars => FushiIcons.file,
      };

  FushiCardTone _phaseTone(VideoSourceScrapePhase phase) => switch (phase) {
        VideoSourceScrapePhase.completed => FushiCardTone.primary,
        VideoSourceScrapePhase.failed => FushiCardTone.error,
        VideoSourceScrapePhase.cancelled ||
        VideoSourceScrapePhase.interrupted ||
        VideoSourceScrapePhase.idle =>
          FushiCardTone.neutral,
        _ => FushiCardTone.primary,
      };

  /// 待确认区块的行：说明卡 + 分段候选卡（AI 倾向的那条带置信度色块）。
  List<Widget> _confirmationRows(VideoSourceScrapeConfirmation confirmation) {
    final VideoSourceScrapeAiSuggestion? ai = confirmation.aiSuggestion;
    String? aiLabel(int index) {
      if (ai == null || ai.candidateIndex != index) return null;
      final String headline = t.video_source_scrape_ai_suggested(
        percent: ai.confidencePercent,
      );
      return ai.reason.isEmpty ? headline : '$headline\n${ai.reason}';
    }

    final FushiTypography type = context.fushiType;
    // 说明卡是 tertiary 饱和色块：fushiType 自带页面前景，需显式跟卡片配对前景。
    final Color? onCard =
        fushiCardToneColors(context, FushiCardTone.tertiary)?.onContainer;
    final int count = confirmation.candidates.length;
    return <Widget>[
      FushiCard(
        tone: FushiCardTone.tertiary,
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const FushiListLeadingIcon(
              FushiIcons.help,
              shape: FushiLeadingShape.cookie,
              tone: FushiCardTone.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t.video_source_scrape_waiting_confirmation,
                    style: type.titleMediumEmphasized.copyWith(color: onCard),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    confirmation.localWorkTitle,
                    style: type.bodyLarge.copyWith(color: onCard),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t.video_source_scrape_confirmation_hint,
                    style: type.bodySmall.copyWith(color: onCard),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      for (int index = 0; index < count; index++)
        VideoSourceScrapeCandidateTile(
          candidate: confirmation.candidates[index],
          onSelected: widget.controller.confirmPending,
          aiSuggestion: aiLabel(index),
          aiConfidencePercent: ai != null && ai.candidateIndex == index
              ? ai.confidencePercent
              : null,
          groupIndex: index,
          groupCount: count,
        ),
    ];
  }

  /// 已完成区块的行：阶段 + 汇总的状态卡，其下每条警告 / 错误一格分段卡。
  List<Widget> _reportRows(
    VideoSourceScrapePhase phase,
    SourceScrapeReport report,
  ) {
    final List<(SourceScrapeIssue, bool)> issues = <(SourceScrapeIssue, bool)>[
      for (final SourceScrapeIssue issue in report.warnings) (issue, false),
      for (final SourceScrapeIssue issue in report.errors) (issue, true),
    ];
    return <Widget>[
      _buildStatusCard(
        icon: _phaseIcon(phase),
        tone: _phaseTone(phase),
        title: _phaseLabel(phase),
        progressValue: null,
        showProgress: false,
        details: <Widget>[
          Text(
            t.scrape_all_done(
              applied: report.succeededWorks,
              review: report.pendingConfirmations,
              skipped: report.protectedArtifacts,
              failed: report.failedWorks,
            ),
            style: context.fushiType.bodyMedium.copyWith(
              color:
                  fushiCardToneColors(context, _phaseTone(phase))?.onContainer,
            ),
          ),
        ],
      ),
      if (issues.isNotEmpty) const SizedBox(height: 12),
      for (int index = 0; index < issues.length; index++)
        FushiGroupedListItem(
          index: index,
          count: issues.length,
          child: FushiListItem(
            density: FushiListDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            leading: FushiListLeadingIcon(
              issues[index].$2 ? FushiIcons.error : FushiIcons.info,
              tone: issues[index].$2
                  ? FushiCardTone.error
                  : FushiCardTone.secondary,
              size: 32,
              iconSize: 18,
            ),
            title: Text(issues[index].$1.workTitle),
            subtitle: SelectableText(
              issues[index].$1.path == null
                  ? describeVideoScrapeIssueMessage(issues[index].$1.message)
                  : '${describeVideoScrapeIssueMessage(issues[index].$1.message)}'
                      '\n${issues[index].$1.path}',
            ),
          ),
        ),
    ];
  }
}

/// 排队请求的位置徽标：secondaryContainer 圆底 + 等宽序号（墨水屏描边无底）。
class _QueuePositionBadge extends StatelessWidget {
  const _QueuePositionBadge({required this.position});

  final int position;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: eink ? Colors.transparent : cs.secondaryContainer,
        shape: CircleBorder(
          side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
        ),
      ),
      child: Text(
        '$position',
        style: context.fushiType.labelLarge.tabular.copyWith(
          color: eink ? cs.onSurface : cs.onSecondaryContainer,
        ),
      ),
    );
  }
}
