/// 一次刮削记录的可操作详情。
///
/// 「待确认 2，失败 4」以前只是摘要行上的两个死数字：产生它们的候选列表随批次
/// 结束就没了，run 表里只剩计数，用户既看不到是哪几个作品、也没有任何入口去处理
/// （BUG-1720 / BUG-1721）。本对话框把 summaryJson 里逐条作品级事实读回来，并给
/// 每条提供**手动指定作品**——选中的身份走 rescrapeWorkWithLookup，与批次内确认、
/// 与下载导入后的精确刮削共用同一条落库路径，不新开第二套绑定保存。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_candidate_tile.dart';
import 'package:fushi/src/media/video/metadata/video_manual_identity_query.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_issue_text.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 与后台任务面板、来源摘要行共用的 run 状态文案。
String videoSourceScrapeRunStatusLabel(String status) => switch (status) {
      'completed' => t.download_task_status_completed,
      'cancelled' => t.download_status_cancelled,
      'interrupted' => t.video_source_scrape_status_interrupted,
      'failed' => t.download_task_status_error,
      'running' => t.video_source_scrape_action,
      _ => status,
    };

/// 返回 true 表示这次交互改动了库（重刮了来源或手动绑定了作品），调用方应刷新。
Future<bool> showVideoSourceScrapeRunDetailDialog({
  required BuildContext context,
  required VideoSourceScrapeRunRow run,
  SourceLibraryRow? source,
  VideoSourceScrapeTaskController? controller,
  Future<void> Function(SourceLibraryRow source)? onRescrapeSource,
}) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => _VideoSourceScrapeRunDetailDialog(
        run: run,
        source: source,
        controller: controller,
        onRescrapeSource: onRescrapeSource,
      ),
    ) ??
    false;

class _VideoSourceScrapeRunDetailDialog extends StatefulWidget {
  const _VideoSourceScrapeRunDetailDialog({
    required this.run,
    required this.source,
    required this.controller,
    required this.onRescrapeSource,
  });

  final VideoSourceScrapeRunRow run;
  final SourceLibraryRow? source;
  final VideoSourceScrapeTaskController? controller;
  final Future<void> Function(SourceLibraryRow source)? onRescrapeSource;

  @override
  State<_VideoSourceScrapeRunDetailDialog> createState() =>
      _VideoSourceScrapeRunDetailDialogState();
}

class _VideoSourceScrapeRunDetailDialogState
    extends State<_VideoSourceScrapeRunDetailDialog> {
  late final SourceScrapeReport? _report =
      decodeSourceScrapeReport(widget.run.summaryJson);

  /// 已经手动绑定过、不必再出现在待办里的作品名。
  final Set<String> _resolved = <String>{};
  final Set<String> _busyWorkTitles = <String>{};
  bool _rescrapingSource = false;
  String? _error;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_taskChanged);
  }

  void _taskChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_taskChanged);
    super.dispose();
  }

  bool get _canBindManually =>
      widget.source != null &&
      (widget.controller?.supportsManualBinding ?? false);

  List<(SourceScrapeIssue, bool)> get _issues {
    final SourceScrapeReport? report = _report;
    if (report == null) return const <(SourceScrapeIssue, bool)>[];
    return <(SourceScrapeIssue, bool)>[
      for (final SourceScrapeIssue issue in report.warnings)
        if (!_resolved.contains(issue.workTitle)) (issue, false),
      for (final SourceScrapeIssue issue in report.errors)
        if (!_resolved.contains(issue.workTitle)) (issue, true),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final VideoSourceScrapeRunRow run = widget.run;
    final SourceLibraryRow? source = widget.source;
    final List<(SourceScrapeIssue, bool)> issues = _issues;
    final String? lastError = run.lastError?.trim();
    final ColorScheme cs = Theme.of(context).colorScheme;
    // 时间线：第一个节点是这次 run 本身（状态色圆点 + 摘要卡），其后每条作品级
    // 警告 / 错误一个节点（竖线串起；错误 = error 圆点 + errorContainer 卡，
    // 警告 = tertiary 圆点 + secondaryContainer 卡）。
    final List<Widget> nodes = <Widget>[
      _TimelineNode(
        dotColor: _runStatusColor(cs, run.status),
        isFirst: true,
        isLast: issues.isEmpty,
        child: _buildRunSummary(run, lastError),
      ),
      for (int i = 0; i < issues.length; i++)
        _TimelineNode(
          key: ValueKey<String>(
            'video-source-run-issue-${issues[i].$1.workTitle}',
          ),
          dotColor: issues[i].$2 ? cs.error : cs.tertiary,
          isFirst: false,
          isLast: i == issues.length - 1,
          child: _buildIssue(issues[i].$1, issues[i].$2),
        ),
    ];
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.checklist),
      title: Text(t.video_source_scrape_run_detail_title),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: FushiEntranceScope(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < nodes.length; i++)
                    FushiStaggeredEntrance(index: i, child: nodes[i]),
                  if (issues.isEmpty)
                    FushiStaggeredEntrance(
                      index: nodes.length,
                      child: FushiPlaceholderMessage(
                        icon: FushiIcons.success,
                        message: t.video_source_scrape_run_no_issues,
                      ),
                    ),
                  if (_error case final String error) ...<Widget>[
                    const SizedBox(height: 12),
                    FushiCard(
                      tone: FushiCardTone.error,
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const FushiIcon(FushiIcons.error, size: 20),
                          const SizedBox(width: 10),
                          Expanded(child: SelectableText(error)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_close,
          onPressed: () => Navigator.of(context).pop(_changed),
        ),
        if (source != null && widget.onRescrapeSource != null)
          FushiDialogAction(
            key: const ValueKey<String>('video-source-run-rescrape'),
            label: t.video_source_scrape_rescrape_source,
            onPressed:
                !_rescrapingSource && !(widget.controller?.isBusy ?? false)
                    ? () => unawaited(_rescrapeSource(source))
                    : null,
          ),
      ],
    );
  }

  /// run 状态 → 时间线首节点圆点色。
  static Color _runStatusColor(ColorScheme cs, String status) =>
      switch (status) {
        'completed' => cs.primary,
        'failed' => cs.error,
        'cancelled' || 'interrupted' => cs.outline,
        _ => cs.tertiary,
      };

  /// run 状态 → 摘要卡色块。
  static FushiCardTone _runStatusTone(String status) => switch (status) {
        'completed' => FushiCardTone.primary,
        'failed' => FushiCardTone.error,
        'cancelled' || 'interrupted' => FushiCardTone.neutral,
        _ => FushiCardTone.tertiary,
      };

  Widget _buildRunSummary(VideoSourceScrapeRunRow run, String? lastError) {
    final FushiTypography type = context.fushiType;
    return FushiCard(
      tone: _runStatusTone(run.status),
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  videoSourceScrapeRunStatusLabel(run.status),
                  style: type.titleMediumEmphasized,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                FushiTimeFormat.dateHourMinute(
                  DateTime.fromMillisecondsSinceEpoch(run.startedAt),
                ),
                style: type.labelMedium.tabular,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            t.video_source_scrape_last_summary(
              status: videoSourceScrapeRunStatusLabel(run.status),
              succeeded: run.succeededWorks,
              pending: run.pendingConfirmations,
              failed: run.failedWorks,
            ),
            style: type.bodyMedium,
          ),
          if (lastError != null && lastError.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            SelectableText(lastError, style: type.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _buildIssue(SourceScrapeIssue issue, bool isError) {
    final bool busy = _busyWorkTitles.contains(issue.workTitle) ||
        (widget.source != null &&
            (widget.controller?.isManualRequestPending(
                  sourceId: widget.source!.id,
                  workTitle: issue.workTitle,
                ) ??
                false));
    final FushiTypography type = context.fushiType;
    return FushiCard(
      tone: isError ? FushiCardTone.error : FushiCardTone.secondary,
      padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    FushiIcon(
                      isError ? FushiIcons.error : FushiIcons.info,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        issue.workTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: type.titleSmallEmphasized,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SelectableText(
                  issue.path == null
                      ? describeVideoScrapeIssueMessage(issue.message)
                      : '${describeVideoScrapeIssueMessage(issue.message)}\n${issue.path}',
                  style: type.bodySmall,
                  maxLines: 4,
                ),
              ],
            ),
          ),
          if (_canBindManually)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 4),
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 18,
                        child: FushiCircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : FushiIconButtonControl(
                      tooltip: t.video_source_scrape_manual_search_title,
                      onPressed: () => unawaited(_bindManually(issue)),
                      icon: const FushiIcon(FushiIcons.search),
                    ),
            ),
        ],
      ),
    );
  }

  Future<void> _rescrapeSource(SourceLibraryRow source) async {
    final Future<void> Function(SourceLibraryRow source)? rescrape =
        widget.onRescrapeSource;
    if (rescrape == null || (widget.controller?.isBusy ?? false)) return;
    setState(() => _rescrapingSource = true);
    try {
      await rescrape(source);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _rescrapingSource = false);
    }
  }

  Future<void> _bindManually(SourceScrapeIssue issue) async {
    final SourceLibraryRow? source = widget.source;
    final VideoSourceScrapeTaskController? controller = widget.controller;
    if (source == null || controller == null) return;
    final VideoSourceScrapeConfirmationCandidate? candidate =
        await showVideoSourceScrapeManualBindingDialog(
      context: context,
      controller: controller,
      source: source,
      workTitle: issue.workTitle,
    );
    if (candidate == null || !mounted) return;
    setState(() {
      _busyWorkTitles.add(issue.workTitle);
      _error = null;
    });
    try {
      await controller.rescrapeWorkWithLookup(
        source: source,
        workTitle: issue.workTitle,
        lookup: candidate.lookup,
      );
      if (!mounted) return;
      setState(() {
        _changed = true;
        _resolved.add(issue.workTitle);
      });
    } on VideoSourceScrapeCancelled {
      // 在任务面板撤回尚未执行的绑定，不应在详情页显示失败。
    } on VideoSourceScrapeWorkAmbiguous {
      if (!mounted) return;
      setState(() => _error = t.video_source_scrape_manual_ambiguous);
    } on VideoSourceScrapeWorkNotFound {
      // 历史 run 记的是当时的作品标题；文件改名/移动/删除后它就不在当前计划
      // 里了。给用户能照着做的中文说明，而不是裸异常（BUG-1998）。
      if (!mounted) return;
      setState(() => _error = t.video_source_scrape_work_missing);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busyWorkTitles.remove(issue.workTitle));
    }
  }
}

/// 时间线的一个节点：左侧轨道（竖线 + 状态色圆点）+ 右侧内容卡。轨道用
/// [CustomPaint] 画在节点自身的高度上，不靠 IntrinsicHeight 量内容。
class _TimelineNode extends StatelessWidget {
  const _TimelineNode({
    super.key,
    required this.dotColor,
    required this.isFirst,
    required this.isLast,
    required this.child,
  });

  final Color dotColor;
  final bool isFirst;
  final bool isLast;
  final Widget child;

  static const double _railWidth = 28;
  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return CustomPaint(
      painter: _TimelineRailPainter(
        dotColor: dotColor,
        lineColor: cs.outlineVariant,
        haloColor: cs.surfaceContainerHigh,
        isFirst: isFirst,
        isLast: isLast,
        railWidth: _railWidth,
        gap: _gap,
        textDirection: Directionality.of(context),
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: _railWidth + 6,
          bottom: isLast ? 0 : _gap,
        ),
        child: child,
      ),
    );
  }
}

class _TimelineRailPainter extends CustomPainter {
  const _TimelineRailPainter({
    required this.dotColor,
    required this.lineColor,
    required this.haloColor,
    required this.isFirst,
    required this.isLast,
    required this.railWidth,
    required this.gap,
    required this.textDirection,
  });

  final Color dotColor;
  final Color lineColor;
  final Color haloColor;
  final bool isFirst;
  final bool isLast;
  final double railWidth;
  final double gap;
  final TextDirection textDirection;

  /// 圆点圆心距节点顶部的距离：对齐内容卡第一行文字。
  static const double _dotCenterY = 22;
  static const double _dotRadius = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final double x = textDirection == TextDirection.rtl
        ? size.width - railWidth / 2
        : railWidth / 2;
    final Paint line = Paint()
      ..color = lineColor
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final double top = isFirst ? _dotCenterY : 0;
    final double bottom = isLast ? _dotCenterY : size.height;
    if (bottom > top) {
      canvas.drawLine(Offset(x, top), Offset(x, bottom), line);
    }
    canvas.drawCircle(
      Offset(x, _dotCenterY),
      _dotRadius + 3,
      Paint()..color = haloColor,
    );
    canvas.drawCircle(
      Offset(x, _dotCenterY),
      _dotRadius,
      Paint()..color = dotColor,
    );
  }

  @override
  bool shouldRepaint(_TimelineRailPainter oldDelegate) =>
      oldDelegate.dotColor != dotColor ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.haloColor != haloColor ||
      oldDelegate.isFirst != isFirst ||
      oldDelegate.isLast != isLast ||
      oldDelegate.railWidth != railWidth ||
      oldDelegate.gap != gap ||
      oldDelegate.textDirection != textDirection;
}

/// 候选搜索原语：按用户输入（标题或 `mal:123` 这类身份串）返回候选。
typedef VideoMetadataCandidateSearch
    = Future<List<VideoSourceScrapeConfirmationCandidate>> Function(
  String query,
);

/// 手动搜索资料源并挑一个作品（共享入口：run 详情与待确认队列都用它）。
/// 返回选中的候选；取消返回 null。[source] 为 null = 本机没有这部作品的来源库
/// （互联 7b 客户端代 host 刮削），provider 取全局主源。
Future<VideoSourceScrapeConfirmationCandidate?>
    showVideoSourceScrapeManualBindingDialog({
  required BuildContext context,
  required VideoSourceScrapeTaskController controller,
  SourceLibraryRow? source,
  required String workTitle,
  String? workStableKey,
}) =>
        showVideoMetadataCandidateSearchDialog(
          context: context,
          workTitle: workTitle,
          search: (String query) => controller.searchManualCandidates(
            source: source,
            workTitle: workTitle,
            workStableKey: workStableKey,
            query: query,
          ),
        );

/// 同一个候选搜索 UI，但候选来源由 [search] 注入——互联 7a「在 host 上刮削」把
/// 搜索打到对端端点，本机不需要有刮削链。
///
/// [title] / [hint] 缺省是「手动指定作品」语境的文案；借这个搜索框做别的事（例如
/// 在线搜封面，选中只取封面图、不改作品身份）的调用方传自己的文案，免得用户以为
/// 选一条就会重绑作品。
Future<VideoSourceScrapeConfirmationCandidate?>
    showVideoMetadataCandidateSearchDialog({
  required BuildContext context,
  required String workTitle,
  required VideoMetadataCandidateSearch search,
  String? title,
  String? hint,
}) =>
        showAppDialog<VideoSourceScrapeConfirmationCandidate>(
          context: context,
          builder: (BuildContext context) => _ManualBindingDialog(
            search: search,
            workTitle: workTitle,
            title: title,
            hint: hint,
          ),
        );

/// 手动搜索资料源并挑一个作品。结果行与批次内确认是同一个
/// [VideoSourceScrapeCandidateTile]，选中后返回同一种候选对象。
class _ManualBindingDialog extends StatefulWidget {
  const _ManualBindingDialog({
    required this.search,
    required this.workTitle,
    this.title,
    this.hint,
  });

  final VideoMetadataCandidateSearch search;
  final String workTitle;

  /// null = 手动指定作品的标题 / 提示（见 [showVideoMetadataCandidateSearchDialog]）。
  final String? title;
  final String? hint;

  @override
  State<_ManualBindingDialog> createState() => _ManualBindingDialogState();
}

class _ManualBindingDialogState extends State<_ManualBindingDialog> {
  late final TextEditingController _query =
      TextEditingController(text: widget.workTitle);
  List<VideoSourceScrapeConfirmationCandidate>? _results;
  bool _searching = false;
  bool _byId = false;
  VideoManualIdentitySource _idSource = VideoManualIdentitySource.mal;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String _manualQuery() => _byId
      ? videoManualIdentityQuery(_query.text, _idSource)
      : _query.text.trim();

  Future<void> _search() async {
    if (_searching) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final List<VideoSourceScrapeConfirmationCandidate> results =
          await widget.search(_manualQuery());
      if (!mounted) return;
      setState(() => _results = results);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _results = const <VideoSourceScrapeConfirmationCandidate>[];
        _error = error is FormatException
            ? t.video_source_scrape_manual_id_invalid
            : error is VideoSourceScrapeWorkAmbiguous
                ? t.video_source_scrape_manual_ambiguous
                : error is VideoSourceScrapeWorkNotFound
                    ? t.video_source_scrape_work_missing
                    : error.toString();
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<VideoSourceScrapeConfirmationCandidate>? results = _results;
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.manageSearch),
      title: Text(widget.title ?? t.video_source_scrape_manual_search_title),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FushiCard(
                  tone: FushiCardTone.secondary,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: <Widget>[
                      const FushiListLeadingIcon(
                        FushiIcons.video,
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
                              t.video_source_scrape_manual_current_work,
                              style: type.labelMedium,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.workTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: type.titleMediumEmphasized,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                FushiSegmentedButton<bool>(
                  segments: <ButtonSegment<bool>>[
                    ButtonSegment<bool>(
                        value: false,
                        label: Text(t.video_source_scrape_manual_by_title)),
                    ButtonSegment<bool>(
                        value: true,
                        label: Text(t.video_source_scrape_manual_by_id)),
                  ],
                  selected: <bool>{_byId},
                  onSelectionChanged: _searching
                      ? null
                      : (Set<bool> selection) {
                          setState(() {
                            _byId = selection.single;
                            _query.text = _byId ? '' : widget.workTitle;
                            _results = null;
                            _error = null;
                          });
                        },
                ),
                const SizedBox(height: 12),
                if (_byId) ...<Widget>[
                  FushiDropdownButtonFormField<VideoManualIdentitySource>(
                    key:
                        const ValueKey<String>('video-source-manual-id-source'),
                    initialValue: _idSource,
                    items: <DropdownMenuItem<VideoManualIdentitySource>>[
                      const DropdownMenuItem(
                        value: VideoManualIdentitySource.mal,
                        child: Text('MAL'),
                      ),
                      DropdownMenuItem(
                        value: VideoManualIdentitySource.tmdbMovie,
                        child: Text(t.video_source_scrape_manual_tmdb_movie),
                      ),
                      DropdownMenuItem(
                        value: VideoManualIdentitySource.tmdbTv,
                        child: Text(t.video_source_scrape_manual_tmdb_tv),
                      ),
                    ],
                    onChanged: _searching
                        ? null
                        : (VideoManualIdentitySource? value) {
                            if (value == null) return;
                            setState(() {
                              _idSource = value;
                              _results = null;
                              _error = null;
                            });
                          },
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  widget.hint ?? t.video_source_scrape_manual_query_hint,
                  style: type.bodyMedium.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                FushiTextFieldControl(
                  key: const ValueKey<String>('video-source-manual-query'),
                  controller: _query,
                  enabled: !_searching,
                  onChanged: (_) => setState(() {
                    _results = null;
                    _error = null;
                  }),
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => unawaited(_search()),
                  decoration: InputDecoration(
                    labelText: _byId
                        ? t.video_source_scrape_manual_by_id
                        : t.video_source_scrape_manual_by_title,
                  ),
                ),
                const SizedBox(height: 12),
                if (_searching)
                  const FushiLoadingView()
                else if (results != null && results.isEmpty && _error == null)
                  FushiPlaceholderMessage(
                    icon: FushiIcons.searchOff,
                    message: t.video_source_scrape_manual_search_empty,
                  )
                else if (results != null)
                  // 结果每次搜索整组换新：replayKey 跟着结果列表走，新一批也错峰进场。
                  FushiEntranceScope(
                    replayKey: results,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (int i = 0; i < results.length; i++)
                          FushiStaggeredEntrance(
                            index: i,
                            child: VideoSourceScrapeCandidateTile(
                              candidate: results[i],
                              groupIndex: i,
                              groupCount: results.length,
                              onSelected: (
                                VideoSourceScrapeConfirmationCandidate selected,
                              ) =>
                                  Navigator.of(context).pop(selected),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_error case final String error) ...<Widget>[
                  const SizedBox(height: 12),
                  FushiCard(
                    tone: FushiCardTone.error,
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const FushiIcon(FushiIcons.error, size: 20),
                        const SizedBox(width: 10),
                        Expanded(child: SelectableText(error)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('video-source-manual-search'),
          kind: FushiDialogActionKind.primary,
          label: t.video_source_scrape_manual_search_action,
          onPressed: _searching ? null : () => unawaited(_search()),
        ),
      ],
    );
  }
}
