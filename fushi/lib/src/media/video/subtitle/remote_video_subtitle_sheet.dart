/// 互联远端视频的「生成日语字幕」面板：管线在放视频的 host 上跑
/// （[RemoteVideoSubtitleService]），本面板只选分段方式 / AI 校对、显示 host 的阶段
/// 进度与报错、取消与继续。识别模型、MOSS、AI 提供商都是 host 自己的，所以没有本机
/// 面板里的模型下载与费用预估。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show VideoSubtitleEpisodeResult, VideoSubtitleEpisodeStatus;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_host_job_runner.dart'
    show kVideoSubtitleJobKind;

import 'package:fushi/src/media/video/subtitle/remote_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_generate_sheet.dart'
    show
        VideoSubtitleGeneratePrefs,
        videoSubtitleEpisodeStatusLabel,
        videoSubtitleStageLabel;
import 'package:fushi/src/sync/interconnect_job_client.dart' show HostJobTarget;
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 远端一集的最终去向文案（host summary 的状态名；认不出就原样显示）。null = 还没结束。
String? remoteVideoSubtitleEpisodeResultLabel(
  RemoteVideoSubtitleEpisodeProgress e,
) {
  final String? status = e.status;
  if (!e.done || status == null) return null;
  final VideoSubtitleEpisodeStatus? known = VideoSubtitleEpisodeStatus.values
      .where((VideoSubtitleEpisodeStatus s) => s.name == status)
      .firstOrNull;
  if (known == null) {
    return e.reason == null ? status : '$status (${e.reason})';
  }
  return videoSubtitleEpisodeStatusLabel(
    VideoSubtitleEpisodeResult(
      videoPath: e.episode.title,
      status: known,
      outputPath: e.subtitle?.path,
    ),
  );
}

/// 打开远端面板。[onJobStarted]：任务一起就回调（视频页据此在结束时加载字幕）。
Future<void> showRemoteVideoSubtitleSheet({
  required BuildContext context,
  required RemoteVideoSubtitleService service,
  required RemoteVideoSubtitleTarget target,
  required VideoSubtitleGeneratePrefs prefs,
  void Function(RemoteVideoSubtitleJob job)? onJobStarted,
}) {
  Widget build(BuildContext ctx) => RemoteVideoSubtitleSheet(
    service: service,
    target: target,
    prefs: prefs,
    onJobStarted: onJobStarted,
  );
  if (isDesktopPlatform) {
    return showAppDialog<void>(
      context: context,
      builder: (BuildContext ctx) => FushiDialogFrame(
        maxWidth: 560,
        maxHeightFactor: 0.85,
        scrollable: false,
        child: build(ctx),
      ),
    );
  }
  return adaptiveModalSheet<void>(
    context: context,
    showDragHandle: true,
    builder: build,
  );
}

class RemoteVideoSubtitleSheet extends StatefulWidget {
  const RemoteVideoSubtitleSheet({
    super.key,
    required this.service,
    required this.target,
    required this.prefs,
    this.onJobStarted,
  });

  final RemoteVideoSubtitleService service;
  final RemoteVideoSubtitleTarget target;
  final VideoSubtitleGeneratePrefs prefs;
  final void Function(RemoteVideoSubtitleJob job)? onJobStarted;

  @override
  State<RemoteVideoSubtitleSheet> createState() =>
      _RemoteVideoSubtitleSheetState();
}

class _RemoteVideoSubtitleSheetState extends State<RemoteVideoSubtitleSheet> {
  late bool _proofread = widget.prefs.proofread;
  late VideoSubtitleSegmenterMode _segmenter = widget.prefs.segmenter;
  bool _probing = true;
  HostJobTarget? _host;
  RemoteVideoSubtitleJob? _job;
  String? _startError;

  @override
  void initState() {
    super.initState();
    final RemoteVideoSubtitleJob? latest = widget.service.latestJobFor(
      widget.target,
    );
    if (latest != null) _attach(latest);
    unawaited(_probe());
  }

  @override
  void dispose() {
    _job?.removeListener(_onJob);
    super.dispose();
  }

  void _attach(RemoteVideoSubtitleJob job) {
    _job?.removeListener(_onJob);
    _job = job..addListener(_onJob);
  }

  void _onJob() {
    if (mounted) setState(() {});
  }

  Future<void> _probe() async {
    HostJobTarget? host;
    try {
      host = await widget.service.probe();
    } catch (error, stack) {
      // 探测失败按「没有可用的电脑」显示，真实原因进日志。
      ErrorLogService.instance.log('video.subtitleRemoteProbe', error, stack);
      host = null;
    }
    if (!mounted) return;
    setState(() {
      _host = host;
      _probing = false;
    });
  }

  bool get _supported => _host?.supports(kVideoSubtitleJobKind) ?? false;
  bool get _running => _job?.isRunning ?? false;

  Future<void> _setProofread(bool on) async {
    if (on && !widget.prefs.consented) {
      final bool ok = await showFushiConfirmDialog(
        context: context,
        title: t.video_subtitle_ai_consent_title,
        message: t.video_subtitle_ai_consent_body,
        confirmLabel: t.video_subtitle_ai_consent_confirm,
        cancelLabel: t.cancel,
        icon: FushiIcons.ai,
      );
      if (!ok || !mounted) return;
      await widget.prefs.setConsented(true);
    }
    setState(() => _proofread = on);
    await widget.prefs.setProofread(on);
  }

  Future<void> _setSegmenter(VideoSubtitleSegmenterMode mode) async {
    setState(() => _segmenter = mode);
    await widget.prefs.setSegmenter(mode);
  }

  void _start() {
    setState(() => _startError = null);
    try {
      final RemoteVideoSubtitleJob job = widget.service.start(
        widget.target,
        RemoteVideoSubtitleOptions(
          proofread: _proofread,
          segmenter: _segmenter,
          mossBackend: widget.prefs.mossBackend,
        ),
      );
      setState(() => _attach(job));
      widget.onJobStarted?.call(job);
    } on StateError {
      setState(
        () => _startError = t.video_subtitle_ai_busy(
          title: widget.service.activeJob?.target.title ?? '',
        ),
      );
    }
  }

  Widget _hint(String text, {Key? key, bool error = false}) => Text(
    text,
    key: key,
    style: FushiDesignTokens.of(context).type.metadata.copyWith(
      color: error ? Theme.of(context).colorScheme.error : null,
    ),
  );

  Widget _section(int index, int count, String label, Widget child) =>
      FushiStaggeredEntrance(
        index: index,
        child: FushiGroupedListItem(
          index: index,
          count: count,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(label, style: context.fushiType.titleSmallEmphasized),
                const SizedBox(height: 8),
                child,
              ],
            ),
          ),
        ),
      );

  Widget _hostLine() {
    if (_probing) return _hint(t.video_subtitle_ai_remote_probing);
    final HostJobTarget? host = _host;
    if (host == null) {
      return _hint(
        t.video_subtitle_ai_remote_unreachable,
        key: const ValueKey<String>('remote-subtitle-unreachable'),
        error: true,
      );
    }
    if (!_supported) {
      return _hint(
        t.video_subtitle_ai_remote_unsupported,
        key: const ValueKey<String>('remote-subtitle-unsupported'),
        error: true,
      );
    }
    return _hint(
      t.video_subtitle_ai_remote_host(host: host.label),
      key: const ValueKey<String>('remote-subtitle-host'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final RemoteVideoSubtitleTarget target = widget.target;
    final List<Widget> sections = <Widget>[
      _section(
        0,
        3,
        t.video_subtitle_ai_target_label,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: <Widget>[
            Text(target.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (target.wholeSeason)
              _hint(
                t.video_subtitle_ai_season_summary(
                  n: target.episodes.length + target.skippedExisting.length,
                  skipped: target.skippedExisting.length,
                ),
              ),
            _hostLine(),
          ],
        ),
      ),
      _section(
        1,
        3,
        t.video_subtitle_ai_segmenter_label,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiSegmentedButton<VideoSubtitleSegmenterMode>(
              key: const ValueKey<String>('remote-subtitle-segmenter'),
              segments: <ButtonSegment<VideoSubtitleSegmenterMode>>[
                ButtonSegment<VideoSubtitleSegmenterMode>(
                  value: VideoSubtitleSegmenterMode.auto,
                  label: Text(t.video_subtitle_ai_segmenter_auto),
                ),
                ButtonSegment<VideoSubtitleSegmenterMode>(
                  value: VideoSubtitleSegmenterMode.moss,
                  label: Text(t.video_subtitle_ai_segmenter_moss),
                ),
                ButtonSegment<VideoSubtitleSegmenterMode>(
                  value: VideoSubtitleSegmenterMode.window,
                  label: Text(t.video_subtitle_ai_segmenter_window),
                ),
              ],
              selected: <VideoSubtitleSegmenterMode>{_segmenter},
              showSelectedIcon: false,
              onSelectionChanged: _running
                  ? null
                  : (Set<VideoSubtitleSegmenterMode> s) =>
                        unawaited(_setSegmenter(s.first)),
            ),
            const SizedBox(height: 8),
            _hint(t.video_subtitle_ai_remote_segmenter_hint),
          ],
        ),
      ),
      _section(
        2,
        3,
        t.video_subtitle_ai_proofread_label,
        Row(
          children: <Widget>[
            Expanded(child: _hint(t.video_subtitle_ai_remote_proofread_hint)),
            SizedBox(width: tokens.spacing.gap),
            KeyedSubtree(
              key: const ValueKey<String>('remote-subtitle-proofread'),
              child: adaptiveSwitch(
                context: context,
                value: _proofread,
                onChanged: _running
                    ? null
                    : (bool v) => unawaited(_setProofread(v)),
              ),
            ),
          ],
        ),
      ),
    ];
    final RemoteVideoSubtitleJob? job = _job;
    return FushiModalSheetFrame(
      title: target.wholeSeason
          ? t.video_subtitle_ai_season_title
          : t.video_subtitle_ai_title,
      leadingIcon: FushiIcons.subtitles,
      scrollable: true,
      bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      body: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ...sections,
            FushiAnimatedSize(
              duration: context.fushiMotion.spatialDefault.duration,
              curve: context.fushiMotion.spatialDefault.curve,
              alignment: Alignment.topCenter,
              child: job == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: EdgeInsets.only(top: tokens.spacing.rowVertical),
                      child: FushiStaggeredEntrance(
                        index: sections.length,
                        child: _jobCard(job),
                      ),
                    ),
            ),
            if (_startError != null)
              Padding(
                padding: EdgeInsets.only(top: tokens.spacing.gap),
                child: _hint(_startError!, error: true),
              ),
          ],
        ),
      ),
      footer: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: _footer(job),
      ),
    );
  }

  String _statusLine(RemoteVideoSubtitleJob job) => switch (job.status) {
    RemoteVideoSubtitleJobStatus.probing => t.video_subtitle_ai_remote_probing,
    RemoteVideoSubtitleJobStatus.running =>
      job.cancelRequested
          ? t.video_subtitle_ai_status_cancelling
          : job.episodes[job.current].stage == null
          ? t.video_subtitle_ai_status_starting
          : videoSubtitleStageLabel(job.episodes[job.current].stage!),
    RemoteVideoSubtitleJobStatus.succeeded => t.video_subtitle_ai_status_done(
      n: job.episodes
          .where((RemoteVideoSubtitleEpisodeProgress e) => e.subtitle != null)
          .length,
    ),
    RemoteVideoSubtitleJobStatus.unsupported =>
      t.video_subtitle_ai_remote_unsupported,
    RemoteVideoSubtitleJobStatus.unreachable =>
      t.video_subtitle_ai_remote_unreachable,
    RemoteVideoSubtitleJobStatus.failed =>
      t.video_subtitle_ai_remote_host_error(reason: job.error ?? ''),
    RemoteVideoSubtitleJobStatus.cancelled =>
      t.video_subtitle_ai_status_cancelled,
  };

  String _episodeState(
    RemoteVideoSubtitleEpisodeProgress e,
    int index,
    int current,
  ) {
    final String? result = remoteVideoSubtitleEpisodeResultLabel(e);
    if (result != null) return result;
    if (e.stage != null) return videoSubtitleStageLabel(e.stage!);
    return index < current ? '' : t.video_subtitle_ai_episode_pending;
  }

  Widget _jobCard(RemoteVideoSubtitleJob job) {
    final bool bad =
        job.status == RemoteVideoSubtitleJobStatus.failed ||
        job.status == RemoteVideoSubtitleJobStatus.unsupported ||
        job.status == RemoteVideoSubtitleJobStatus.unreachable;
    return FushiCard(
      key: const ValueKey<String>('remote-subtitle-job-card'),
      tone: bad
          ? FushiCardTone.error
          : job.isRunning
          ? FushiCardTone.secondary
          : FushiCardTone.primary,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 6,
        children: <Widget>[
          Text(
            _statusLine(job),
            key: const ValueKey<String>('remote-subtitle-status'),
            style: context.fushiType.bodyMedium,
          ),
          if (job.isRunning) ...<Widget>[
            if (job.episodes[job.current].message != null)
              _hint(job.episodes[job.current].message!),
            FushiLinearProgressIndicator(
              value: job.status == RemoteVideoSubtitleJobStatus.running
                  ? job.episodes[job.current].progress
                  : null,
            ),
          ],
          if (widget.target.wholeSeason || !job.isRunning)
            for (int i = 0; i < job.episodes.length; i++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      job.episodes[i].episode.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _episodeState(job.episodes[i], i, job.current),
                      textAlign: TextAlign.end,
                      style: context.fushiType.bodySmall,
                    ),
                  ),
                ],
              ),
        ],
      ),
    );
  }

  List<Widget> _footer(RemoteVideoSubtitleJob? job) {
    final List<Widget> buttons = <Widget>[
      FushiTextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(_running ? t.video_subtitle_ai_hide : t.dialog_close),
      ),
    ];
    if (job != null && job.isRunning) {
      buttons.add(
        FushiFilledButton.icon(
          key: const ValueKey<String>('remote-subtitle-cancel'),
          icon: const FushiIcon(FushiIcons.stop, size: 18),
          label: Text(t.cancel),
          onPressed: job.cancelRequested ? null : job.cancel,
        ),
      );
      return buttons;
    }
    if (job?.status == RemoteVideoSubtitleJobStatus.succeeded) return buttons;
    final bool resumable = job != null;
    buttons.add(
      FushiPressScale(
        child: FushiFilledButton.icon(
          key: ValueKey<String>(
            resumable ? 'remote-subtitle-resume' : 'remote-subtitle-start',
          ),
          icon: FushiIcon(
            resumable ? FushiIcons.refresh : FushiIcons.play,
            size: 18,
          ),
          label: Text(
            resumable ? t.video_subtitle_ai_resume : t.video_subtitle_ai_start,
          ),
          onPressed: _supported && !_running ? _start : null,
        ),
      ),
    );
    return buttons;
  }
}
