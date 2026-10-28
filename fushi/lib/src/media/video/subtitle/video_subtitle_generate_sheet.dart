/// 「生成日语字幕」面板（视频页单集 / 合集页整季共用）：识别模型与 MOSS 的就绪状态、
/// 分段方式、AI 校对开关（默认关，首次开启说明会发送什么）、当前提供商、费用预估、
/// 专名表入口、阶段进度、取消，以及 AI 失败 / 专名表校验失败后的「继续」。
///
/// 编排全部在 [AppVideoSubtitleService]：面板只渲染它的状态、把用户的选择交给它。
/// 关掉面板不会停任务（任务属于服务；重开面板会接回同一个任务）。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart'
    show SubtitleAiUsageTally, kSubtitleAiReplyIncomplete;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart'
    show SubtitleGlossaryProblem;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/moss_provisioning.dart'
    show MossUnavailableCode;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_glossary_page.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_model_ports.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 面板读写的偏好（生产实现包 [PreferencesRepository]，测试注入 fake）。
abstract interface class VideoSubtitleGeneratePrefs {
  bool get proofread;
  Future<void> setProofread(bool value);

  /// 已看过「会发送什么」说明。
  bool get consented;
  Future<void> setConsented(bool value);

  VideoSubtitleSegmenterMode get segmenter;
  Future<void> setSegmenter(VideoSubtitleSegmenterMode value);

  MossBackendPreference get mossBackend;
}

class PrefsRepoVideoSubtitleGeneratePrefs
    implements VideoSubtitleGeneratePrefs {
  const PrefsRepoVideoSubtitleGeneratePrefs(this.prefs);

  final PreferencesRepository prefs;

  @override
  bool get proofread => prefs.videoSubtitleAiProofread;

  @override
  Future<void> setProofread(bool value) =>
      prefs.setVideoSubtitleAiProofread(value);

  @override
  bool get consented => prefs.videoSubtitleAiConsented;

  @override
  Future<void> setConsented(bool value) =>
      prefs.setVideoSubtitleAiConsented(value);

  @override
  VideoSubtitleSegmenterMode get segmenter => prefs.videoSubtitleSegmenter;

  @override
  Future<void> setSegmenter(VideoSubtitleSegmenterMode value) =>
      prefs.setVideoSubtitleSegmenter(value);

  @override
  MossBackendPreference get mossBackend => prefs.videoSubtitleMossBackend;
}

/// AI 失败短码 → 文案（管线自己的 `reply_incomplete` 在通用映射里没有）。
String videoSubtitleAiFailureText(String code) =>
    code == kSubtitleAiReplyIncomplete
    ? t.video_subtitle_ai_error_reply_incomplete
    : aiFailureText(code);

/// 阶段名（面板与专名表页共用）。歌曲判定归在「拆分」里显示。
String videoSubtitleStageLabel(VideoSubtitleStage stage) => switch (stage) {
  VideoSubtitleStage.recognize => t.video_subtitle_ai_stage_recognize,
  VideoSubtitleStage.glossary => t.video_subtitle_ai_stage_glossary,
  VideoSubtitleStage.proofread => t.video_subtitle_ai_stage_proofread,
  VideoSubtitleStage.consistency => t.video_subtitle_ai_stage_consistency,
  VideoSubtitleStage.songCheck ||
  VideoSubtitleStage.split => t.video_subtitle_ai_stage_split,
  VideoSubtitleStage.export => t.video_subtitle_ai_stage_export,
};

/// 一集最终去向的文案。
String videoSubtitleEpisodeStatusLabel(VideoSubtitleEpisodeResult r) {
  final String label = _episodeStatusLabel(r);
  final String? reference = r.styleReference;
  return r.styledOutputPath == null || reference == null
      ? label
      : '$label · ${t.video_subtitle_ai_episode_styled_from(name: reference)}';
}

String _episodeStatusLabel(VideoSubtitleEpisodeResult r) => switch (r.status) {
  VideoSubtitleEpisodeStatus.exported => t.video_subtitle_ai_episode_exported(
    name: p.basename(r.styledOutputPath ?? r.outputPath ?? ''),
  ),
  VideoSubtitleEpisodeStatus.exportedAsAsr =>
    t.video_subtitle_ai_episode_exported_asr(
      name: p.basename(r.styledOutputPath ?? r.outputPath ?? ''),
    ),
  VideoSubtitleEpisodeStatus.skippedExistingSubtitle =>
    t.video_subtitle_ai_episode_skipped_existing,
  VideoSubtitleEpisodeStatus.skippedBothExist =>
    t.video_subtitle_ai_episode_skipped_both,
  VideoSubtitleEpisodeStatus.skippedSong =>
    t.video_subtitle_ai_episode_skipped_song,
  VideoSubtitleEpisodeStatus.skippedNoDialogue =>
    t.video_subtitle_ai_episode_skipped_no_dialogue,
};

/// MOSS 用不上的原因 → 文案（有分类按分类，否则显示排查原文）。
String videoSubtitleMossProblemText(VideoSubtitleMossProblem problem) {
  final String? text = switch (problem.code) {
    null => null,
    MossUnavailableCode.unsupportedPlatform =>
      t.video_subtitle_ai_moss_code_unsupported_platform,
    MossUnavailableCode.cudaUnavailable =>
      t.video_subtitle_ai_moss_code_cuda_unavailable,
    MossUnavailableCode.noGpu => t.video_subtitle_ai_moss_code_no_gpu,
    MossUnavailableCode.noRuntimeForBackend =>
      t.video_subtitle_ai_moss_code_no_runtime_for_backend,
    MossUnavailableCode.runtimeMissing =>
      t.video_subtitle_ai_moss_code_runtime_missing,
    MossUnavailableCode.modelMissing =>
      t.video_subtitle_ai_moss_code_model_missing,
  };
  return t.video_subtitle_ai_moss_unavailable(reason: text ?? problem.reason);
}

/// token 数的紧凑写法（`12.3k` / `1.2M`）。
String videoSubtitleTokenCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 100000 ? 0 : 1)}k';
  return '$n';
}

/// 打开面板。[onJobStarted]：任务一起就回调（视频页据此在任务结束时把字幕切过去，
/// 面板关了也照样切）。
Future<void> showVideoSubtitleGenerateSheet({
  required BuildContext context,
  required AppVideoSubtitleService service,
  required AppVideoSubtitleTarget target,
  required VideoSubtitleGeneratePrefs prefs,
  required Future<void> Function(BuildContext context) openAiSettings,
  void Function(AppVideoSubtitleJob job)? onJobStarted,
}) {
  Widget build(BuildContext ctx) => VideoSubtitleGenerateSheet(
    service: service,
    target: target,
    prefs: prefs,
    openAiSettings: openAiSettings,
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

class VideoSubtitleGenerateSheet extends StatefulWidget {
  const VideoSubtitleGenerateSheet({
    super.key,
    required this.service,
    required this.target,
    required this.prefs,
    required this.openAiSettings,
    this.onJobStarted,
  });

  final AppVideoSubtitleService service;
  final AppVideoSubtitleTarget target;
  final VideoSubtitleGeneratePrefs prefs;
  final Future<void> Function(BuildContext context) openAiSettings;
  final void Function(AppVideoSubtitleJob job)? onJobStarted;

  @override
  State<VideoSubtitleGenerateSheet> createState() =>
      _VideoSubtitleGenerateSheetState();
}

class _VideoSubtitleGenerateSheetState
    extends State<VideoSubtitleGenerateSheet> {
  AppVideoSubtitleService get _service => widget.service;
  AppVideoSubtitleTarget get _target => widget.target;

  late bool _proofread = widget.prefs.proofread;
  late VideoSubtitleSegmenterMode _segmenter = widget.prefs.segmenter;

  /// 识别模型是否已下载；null = 还在查。
  bool? _modelReady;
  String? _planError;
  ModelDownloadEvent? _asrDownload;
  String? _asrDownloadError;

  VideoSubtitleMossProblem? _mossProblem;
  VideoSubtitleMossState? _mossState;
  ModelDownloadEvent? _mossDownload;
  String? _mossDownloadError;

  AppVideoSubtitleCostEstimate? _estimate;
  bool _estimating = false;

  AppVideoSubtitleJob? _job;
  String? _startError;

  /// 整季：已有 `<视频名>.ja.srt`、管线会跳过的集。initState 里 async 探好后
  /// setState（[_loadExisting]）：这些字幕在视频旁边，常在网络盘上，旧实现作为
  /// late 字段在 build 里逐集同步 stat，冷目录一次数秒、冻结 UI isolate（BUG-3756）。
  Set<String> _existing = const <String>{};

  Future<void> _loadExisting() async {
    if (!_target.wholeSeason) return;
    final Set<String> existing = <String>{
      for (final AppVideoSubtitleEpisode e in _target.episodes)
        if (await File(
          p.join(
            p.dirname(e.videoPath),
            '${p.basenameWithoutExtension(e.videoPath)}.ja.srt',
          ),
        ).exists())
          e.videoPath,
    };
    if (!mounted) return;
    setState(() => _existing = existing);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadExisting());
    final AppVideoSubtitleJob? latest = _service.latestJobFor(_target);
    if (latest != null) _attach(latest);
    unawaited(_refreshPlan());
    unawaited(_refreshMoss());
    if (_proofread) unawaited(_refreshEstimate());
    // 下载归全应用登记表、不归弹层（kZZmXQBv7E）：关掉再打开弹层时接回进行中的
    // 那条，进度照常显示、按钮不再亮——以前这里看不到它，再点一次就起第二条写者。
    final Stream<ModelDownloadEvent>? asr = _service.asrModelPort
        .resumeDownload();
    if (asr != null) {
      _asrDownload = _starting;
      unawaited(_followAsr(asr));
    }
    final Stream<ModelDownloadEvent>? moss = _service.mossPort.resumeEnsure();
    if (moss != null) {
      _mossDownload = _starting;
      unawaited(_followMoss(moss));
    }
  }

  @override
  void dispose() {
    _job?.removeListener(_onJobChanged);
    super.dispose();
  }

  void _attach(AppVideoSubtitleJob job) {
    _job?.removeListener(_onJobChanged);
    _job = job..addListener(_onJobChanged);
  }

  void _onJobChanged() {
    if (!mounted) return;
    setState(() {});
    final AppVideoSubtitleJob? job = _job;
    // 校对结束后费用预估要按缓存重算（已完成的集不再计入）。
    if (job != null && !job.isRunning && _proofread) {
      unawaited(_refreshEstimate());
    }
  }

  bool get _running => _job?.isRunning ?? false;

  Future<void> _refreshPlan() async {
    try {
      final bool ready = await _service.asrModelPort.isReady();
      if (mounted) setState(() => _modelReady = ready);
    } catch (error) {
      if (mounted) setState(() => _planError = '$error');
    }
  }

  Future<void> _refreshMoss() async {
    if (_segmenter == VideoSubtitleSegmenterMode.window) {
      setState(() {
        _mossProblem = null;
        _mossState = null;
      });
      return;
    }
    final MossBackendPreference backend = widget.prefs.mossBackend;
    VideoSubtitleMossProblem? problem;
    try {
      problem = await _service.previewMossProblem(
        mode: _segmenter,
        mossBackend: backend,
      );
    } catch (error, stack) {
      // 只是预览：探测本身出错就不预告，开跑时识别器选择会照实报。
      ErrorLogService.instance.log('video.subtitleMossPreview', error, stack);
      problem = null;
    }
    VideoSubtitleMossState? state;
    try {
      state = await _service.mossPort.status(backend);
    } catch (error) {
      state = VideoSubtitleMossState(ready: false, unavailableReason: '$error');
    }
    if (!mounted) return;
    setState(() {
      _mossProblem = problem;
      _mossState = state;
    });
  }

  Future<void> _refreshEstimate() async {
    if (_estimating) return;
    setState(() => _estimating = true);
    try {
      final AppVideoSubtitleCostEstimate estimate = await _service.estimateCost(
        _target,
      );
      if (mounted) setState(() => _estimate = estimate);
    } catch (error, stack) {
      // 预估只是参考：读不出时长 / 缓存坏了就不显示，不拦用户（但留日志可查）。
      ErrorLogService.instance.log('video.subtitleEstimate', error, stack);
      if (mounted) setState(() => _estimate = null);
    } finally {
      if (mounted) setState(() => _estimating = false);
    }
  }

  static const ModelDownloadEvent _starting = ModelDownloadEvent(
    fileName: '',
    receivedBytes: 0,
    totalBytes: 0,
  );

  void _downloadAsr() {
    setState(() {
      _asrDownloadError = null;
      _asrDownload = _starting;
    });
    unawaited(_followAsr(_service.asrModelPort.download()));
  }

  /// 跟一条识别模型下载的进度。弹层关掉只摘掉这个监听，下载本身继续。
  Future<void> _followAsr(Stream<ModelDownloadEvent> download) async {
    try {
      await for (final ModelDownloadEvent e in download) {
        if (!mounted) return;
        setState(() => _asrDownload = e);
      }
    } catch (error) {
      if (mounted) setState(() => _asrDownloadError = '$error');
    }
    if (!mounted) return;
    setState(() => _asrDownload = null);
    await _refreshPlan();
  }

  void _downloadMoss() {
    setState(() {
      _mossDownloadError = null;
      _mossDownload = _starting;
    });
    unawaited(_followMoss(_service.mossPort.ensure(widget.prefs.mossBackend)));
  }

  /// 跟一条 MOSS 下载的进度（同 [_followAsr]）。
  Future<void> _followMoss(Stream<ModelDownloadEvent> download) async {
    try {
      await for (final ModelDownloadEvent e in download) {
        if (!mounted) return;
        setState(() => _mossDownload = e);
      }
    } catch (error) {
      if (mounted) setState(() => _mossDownloadError = '$error');
    }
    if (!mounted) return;
    setState(() => _mossDownload = null);
    await _refreshMoss();
  }

  Future<void> _setSegmenter(VideoSubtitleSegmenterMode mode) async {
    setState(() => _segmenter = mode);
    await widget.prefs.setSegmenter(mode);
    await _refreshMoss();
  }

  /// 打开 AI 校对：首次先说明会发送什么，同意了才开。
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
    if (on) unawaited(_refreshEstimate());
  }

  Future<void> _openAiSettings() async {
    await widget.openAiSettings(context);
    // 回来后现读指派（build 里求值）。
    if (!mounted) return;
    setState(() {});
    if (_proofread) unawaited(_refreshEstimate());
  }

  Future<void> _openGlossary({bool useCandidate = false}) async {
    final AppVideoSubtitleJob? job = _job;
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => VideoSubtitleGlossaryPage(
          service: _service,
          target: _target,
          candidate: useCandidate ? job?.glossaryFailure?.candidate : null,
          openAiSettings: widget.openAiSettings,
        ),
      ),
    );
    if (mounted && _proofread) unawaited(_refreshEstimate());
  }

  void _start() {
    setState(() => _startError = null);
    try {
      final AppVideoSubtitleJob job = _service.start(
        _target,
        AppVideoSubtitleOptions(
          proofread: _proofread,
          segmenter: _segmenter,
          mossBackend: widget.prefs.mossBackend,
        ),
      );
      setState(() => _attach(job));
      widget.onJobStarted?.call(job);
    } on AppVideoSubtitleStartRefused catch (refused) {
      setState(() {
        _startError = switch (refused.problem) {
          AppVideoSubtitleStartProblem.busy => t.video_subtitle_ai_busy(
            title: refused.activeJob?.target.title ?? '',
          ),
          AppVideoSubtitleStartProblem.noProvider =>
            t.video_subtitle_ai_no_provider,
          AppVideoSubtitleStartProblem.noLocalEpisodes =>
            t.video_subtitle_ai_no_local_episodes,
          AppVideoSubtitleStartProblem.nothingToRerun =>
            t.video_subtitle_ai_nothing_to_rerun,
        };
      });
    }
  }

  // ── 构建 ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> sections = <Widget>[
      _section(0, t.video_subtitle_ai_target_label, _targetSummary(context)),
      _section(1, t.video_subtitle_ai_model_label, _modelStatus(context)),
      _section(2, t.video_subtitle_ai_segmenter_label, _segmenterControl()),
      _section(3, t.video_subtitle_ai_proofread_label, _proofreadControl()),
    ];
    final AppVideoSubtitleJob? job = _job;
    return FushiModalSheetFrame(
      title: _target.wholeSeason
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
                        child: _jobCard(context, job),
                      ),
                    ),
            ),
            if (_startError != null)
              Padding(
                padding: EdgeInsets.only(top: tokens.spacing.gap),
                child: Text(
                  _startError!,
                  key: const ValueKey<String>('video-subtitle-ai-start-error'),
                  style: tokens.type.metadata.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      footer: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: _footerButtons(context),
      ),
    );
  }

  Widget _section(int index, String label, Widget child) =>
      FushiStaggeredEntrance(
        index: index,
        child: FushiGroupedListItem(
          index: index,
          count: 4,
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

  Widget _hint(String text, {Key? key, bool error = false}) => Text(
    text,
    key: key,
    style: FushiDesignTokens.of(context).type.metadata.copyWith(
      color: error ? Theme.of(context).colorScheme.error : null,
    ),
  );

  Widget _targetSummary(BuildContext context) {
    final List<Widget> lines = <Widget>[
      Text(_target.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      if (_target.wholeSeason)
        _hint(
          t.video_subtitle_ai_season_summary(
            n: _target.episodes.length,
            skipped: _existing.length,
          ),
          key: const ValueKey<String>('video-subtitle-ai-season-summary'),
        ),
      for (final AppVideoSubtitleUnavailable u in _target.unavailable)
        _hint(switch (u.reason) {
          AppVideoSubtitleUnavailableReason.remote =>
            t.video_subtitle_ai_unavailable_remote(title: u.title),
          AppVideoSubtitleUnavailableReason.missingFile =>
            t.video_subtitle_ai_unavailable_missing(title: u.title),
        }),
      if (_proofread && _target.missingScrapedData)
        _hint(
          t.video_subtitle_ai_scrape_hint,
          key: const ValueKey<String>('video-subtitle-ai-scrape-hint'),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: lines,
    );
  }

  Widget _downloadProgress(ModelDownloadEvent e) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: FushiLinearProgressIndicator(
      value: e.totalBytes > 0 ? e.receivedBytes / e.totalBytes : null,
    ),
  );

  Widget _modelStatus(BuildContext context) {
    final bool? ready = _modelReady;
    if (_planError != null) return _hint(_planError!, error: true);
    if (ready == null) return const FushiLinearProgressIndicator();
    if (ready) {
      return _hint(
        t.video_subtitle_ai_model_ready,
        key: const ValueKey<String>('video-subtitle-ai-model-ready'),
      );
    }
    final ModelDownloadEvent? progress = _asrDownload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _hint(t.video_subtitle_ai_model_missing),
        const SizedBox(height: 8),
        FushiOutlinedButton.icon(
          key: const ValueKey<String>('video-subtitle-ai-model-download'),
          icon: const FushiIcon(FushiIcons.download, size: 18),
          label: Text(t.audiobook_transcribe_model_download),
          onPressed: progress == null && !_running ? _downloadAsr : null,
        ),
        if (progress != null) _downloadProgress(progress),
        if (_asrDownloadError != null) _hint(_asrDownloadError!, error: true),
      ],
    );
  }

  Widget _segmenterControl() {
    final VideoSubtitleMossState? moss = _mossState;
    final ModelDownloadEvent? progress = _mossDownload;
    final bool canDownload =
        moss != null && !moss.ready && moss.unavailableReason == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiSegmentedButton<VideoSubtitleSegmenterMode>(
          key: const ValueKey<String>('video-subtitle-ai-segmenter'),
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
        if (_mossProblem != null) ...<Widget>[
          const SizedBox(height: 8),
          _hint(
            videoSubtitleMossProblemText(_mossProblem!),
            key: const ValueKey<String>('video-subtitle-ai-moss-problem'),
            error: _segmenter == VideoSubtitleSegmenterMode.moss,
          ),
        ],
        if (moss != null && moss.ready) ...<Widget>[
          const SizedBox(height: 8),
          _hint(t.video_subtitle_ai_moss_ready),
        ],
        if (canDownload) ...<Widget>[
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiOutlinedButton.icon(
              key: const ValueKey<String>('video-subtitle-ai-moss-download'),
              icon: const FushiIcon(FushiIcons.download, size: 18),
              label: Text(
                t.video_subtitle_ai_moss_download(
                  size: FushiByteFormat.bytes(moss.remainingBytes),
                ),
              ),
              onPressed: progress == null && !_running ? _downloadMoss : null,
            ),
          ),
          if (progress != null) _downloadProgress(progress),
        ],
        if (_mossDownloadError != null) _hint(_mossDownloadError!, error: true),
      ],
    );
  }

  Widget _proofreadControl() {
    final AiProviderConfig? provider = _service.proofreadProvider;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: _hint(t.video_subtitle_ai_proofread_hint)),
            SizedBox(width: tokens.spacing.gap),
            KeyedSubtree(
              key: const ValueKey<String>('video-subtitle-ai-proofread'),
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
        FushiAnimatedSize(
          duration: context.fushiMotion.spatialDefault.duration,
          curve: context.fushiMotion.spatialDefault.curve,
          alignment: Alignment.topCenter,
          child: !_proofread
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 8,
                    children: <Widget>[
                      if (provider == null) ...<Widget>[
                        _hint(
                          t.video_subtitle_ai_no_provider,
                          key: const ValueKey<String>(
                            'video-subtitle-ai-no-provider',
                          ),
                          error: true,
                        ),
                        FushiFilledButton.tonalIcon(
                          key: const ValueKey<String>(
                            'video-subtitle-ai-open-settings',
                          ),
                          icon: const FushiIcon(FushiIcons.ai, size: 18),
                          label: Text(t.video_subtitle_ai_open_settings),
                          onPressed: () => unawaited(_openAiSettings()),
                        ),
                      ] else
                        _hint(
                          t.video_subtitle_ai_provider(
                            name: provider.name,
                            model: provider.model,
                          ),
                          key: const ValueKey<String>(
                            'video-subtitle-ai-provider',
                          ),
                        ),
                      _estimateLine(),
                      FushiPressScale(
                        child: FushiOutlinedButton.icon(
                          key: const ValueKey<String>(
                            'video-subtitle-ai-glossary',
                          ),
                          icon: const FushiIcon(FushiIcons.edit, size: 18),
                          label: Text(t.video_subtitle_glossary_open),
                          onPressed: () => unawaited(_openGlossary()),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _estimateLine() {
    final AppVideoSubtitleCostEstimate? estimate = _estimate;
    if (estimate == null) {
      return _estimating
          ? const SizedBox(width: 160, child: FushiLinearProgressIndicator())
          : const SizedBox.shrink();
    }
    if (estimate.basis == AppVideoSubtitleEstimateBasis.nothing) {
      return _hint(t.video_subtitle_ai_estimate_nothing);
    }
    return _hint(
      t.video_subtitle_ai_estimate(
            requests: estimate.cost.batches,
            input: videoSubtitleTokenCount(estimate.cost.inputTokens),
            output: videoSubtitleTokenCount(estimate.cost.outputTokens),
          ) +
          (estimate.basis == AppVideoSubtitleEstimateBasis.duration
              ? t.video_subtitle_ai_estimate_by_duration
              : t.video_subtitle_ai_estimate_by_drafts),
      key: const ValueKey<String>('video-subtitle-ai-estimate'),
    );
  }

  // ── 任务卡 ──────────────────────────────────────────────────────────────

  static const List<VideoSubtitleStage> _shownStages = <VideoSubtitleStage>[
    VideoSubtitleStage.recognize,
    VideoSubtitleStage.glossary,
    VideoSubtitleStage.proofread,
    VideoSubtitleStage.consistency,
    VideoSubtitleStage.split,
    VideoSubtitleStage.export,
  ];

  /// 歌曲判定算在拆分里。
  static int _stageRank(VideoSubtitleStage s) =>
      s == VideoSubtitleStage.songCheck
      ? VideoSubtitleStage.split.index
      : s.index;

  Widget _jobCard(BuildContext context, AppVideoSubtitleJob job) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiCardTone tone = switch (job.status) {
      AppVideoSubtitleJobStatus.running => FushiCardTone.secondary,
      AppVideoSubtitleJobStatus.succeeded => FushiCardTone.primary,
      AppVideoSubtitleJobStatus.cancelled => FushiCardTone.neutral,
      AppVideoSubtitleJobStatus.pausedAiFailure ||
      AppVideoSubtitleJobStatus.glossaryInvalid ||
      AppVideoSubtitleJobStatus.failed => FushiCardTone.error,
    };
    final VideoSubtitleProgress? progress = job.progress;
    final int current = progress == null ? -1 : _stageRank(progress.stage);
    final bool aiStages = job.options.proofread;
    return FushiCard(
      key: const ValueKey<String>('video-subtitle-ai-job-card'),
      tone: tone,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 6,
        children: <Widget>[
          Text(
            _statusLine(job),
            key: const ValueKey<String>('video-subtitle-ai-status'),
            style: context.fushiType.bodyMedium,
          ),
          if (job.isRunning) ...<Widget>[
            for (final VideoSubtitleStage stage in _shownStages)
              if (aiStages ||
                  (stage != VideoSubtitleStage.glossary &&
                      stage != VideoSubtitleStage.proofread &&
                      stage != VideoSubtitleStage.consistency))
                _stageRow(stage, current),
            FushiLinearProgressIndicator(value: progress?.fraction),
          ],
          if (job.mossProblem != null &&
              job.status != AppVideoSubtitleJobStatus.running)
            _hint(videoSubtitleMossProblemText(job.mossProblem!)),
          if (_target.wholeSeason || job.result != null)
            for (final AppVideoSubtitleEpisodeProgress e in job.episodes)
              _episodeRow(job, e),
          if (job.status == AppVideoSubtitleJobStatus.succeeded &&
              job.result != null)
            _hint(_usageLine(job.result!.usage)),
          if (job.status == AppVideoSubtitleJobStatus.glossaryInvalid)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('video-subtitle-ai-edit-candidate'),
                icon: const FushiIcon(FushiIcons.edit, size: 18),
                label: Text(t.video_subtitle_glossary_open),
                onPressed: () => unawaited(_openGlossary(useCandidate: true)),
              ),
            ),
          SizedBox(height: tokens.spacing.gap / 2),
        ],
      ),
    );
  }

  String _statusLine(AppVideoSubtitleJob job) => switch (job.status) {
    AppVideoSubtitleJobStatus.running =>
      job.cancelRequested
          ? t.video_subtitle_ai_status_cancelling
          : job.progress == null
          ? t.video_subtitle_ai_status_starting
          : videoSubtitleStageLabel(job.progress!.stage),
    AppVideoSubtitleJobStatus.succeeded => t.video_subtitle_ai_status_done(
      n:
          job.result?.episodes
              .where((VideoSubtitleEpisodeResult r) => r.exported)
              .length ??
          0,
    ),
    AppVideoSubtitleJobStatus.cancelled => t.video_subtitle_ai_status_cancelled,
    AppVideoSubtitleJobStatus.pausedAiFailure =>
      t.video_subtitle_ai_status_paused(
        reason: videoSubtitleAiFailureText(job.aiFailure?.reason ?? ''),
      ),
    AppVideoSubtitleJobStatus.glossaryInvalid =>
      job.glossaryFailure?.problem == SubtitleGlossaryProblem.wrongWork
          ? t.video_subtitle_ai_status_glossary_wrong_work
          : t.video_subtitle_ai_status_glossary_conflicts,
    AppVideoSubtitleJobStatus.failed => t.video_subtitle_ai_status_failed(
      reason: job.errorMessage ?? '',
    ),
  };

  Widget _stageRow(VideoSubtitleStage stage, int current) {
    final int rank = _stageRank(stage);
    final IconData icon = rank < current
        ? FushiIcons.check
        : rank == current
        ? FushiIcons.play
        : FushiIcons.radioUnchecked;
    return Row(
      children: <Widget>[
        FushiIcon(icon, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            videoSubtitleStageLabel(stage),
            style: rank == current
                ? context.fushiType.titleSmallEmphasized
                : context.fushiType.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _episodeRow(
    AppVideoSubtitleJob job,
    AppVideoSubtitleEpisodeProgress e,
  ) {
    final VideoSubtitleEpisodeResult? result = e.result;
    final String state = result != null
        ? videoSubtitleEpisodeStatusLabel(result)
        : _existing.contains(e.episode.videoPath)
        ? t.video_subtitle_ai_episode_skipped_existing
        : e.stage != null
        ? videoSubtitleStageLabel(e.stage!)
        : t.video_subtitle_ai_episode_pending;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Text(
            e.episode.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.bodySmall,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            state,
            textAlign: TextAlign.end,
            style: context.fushiType.bodySmall,
          ),
        ),
      ],
    );
  }

  String _usageLine(SubtitleAiUsageTally usage) {
    final String line = t.video_subtitle_ai_usage(
      input: videoSubtitleTokenCount(
        usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens,
      ),
      output: videoSubtitleTokenCount(usage.outputTokens),
      calls: usage.calls,
    );
    // 没带用量的调用不能当 0 计（spec 第 9 节）：单独说明有多少次未知。
    return usage.hasUnknown
        ? '$line ${t.video_subtitle_ai_usage_unknown(n: usage.callsWithoutUsage)}'
        : line;
  }

  List<Widget> _footerButtons(BuildContext context) {
    final AppVideoSubtitleJob? job = _job;
    final bool modelReady = _modelReady ?? false;
    final bool providerMissing =
        _proofread && _service.proofreadProvider == null;
    final bool canStart = modelReady && !providerMissing && !_running;
    final List<Widget> buttons = <Widget>[
      FushiTextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(_running ? t.video_subtitle_ai_hide : t.dialog_close),
      ),
    ];
    if (job != null && job.isRunning) {
      buttons.add(
        FushiFilledButton.icon(
          key: const ValueKey<String>('video-subtitle-ai-cancel'),
          icon: const FushiIcon(FushiIcons.stop, size: 18),
          label: Text(t.cancel),
          onPressed: job.cancelRequested ? null : job.cancel,
        ),
      );
      return buttons;
    }
    // 已成功：缓存里各集都有 final.json，再跑只是原样重导出，不给按钮。
    if (job?.status == AppVideoSubtitleJobStatus.succeeded) return buttons;
    final bool resumable =
        job != null &&
        (job.status == AppVideoSubtitleJobStatus.pausedAiFailure ||
            job.status == AppVideoSubtitleJobStatus.glossaryInvalid ||
            job.status == AppVideoSubtitleJobStatus.cancelled ||
            job.status == AppVideoSubtitleJobStatus.failed);
    buttons.add(
      FushiPressScale(
        child: FushiFilledButton.icon(
          key: ValueKey<String>(
            resumable ? 'video-subtitle-ai-resume' : 'video-subtitle-ai-start',
          ),
          icon: FushiIcon(
            resumable ? FushiIcons.refresh : FushiIcons.play,
            size: 18,
          ),
          label: Text(
            resumable ? t.video_subtitle_ai_resume : t.video_subtitle_ai_start,
          ),
          onPressed: canStart ? _start : null,
        ),
      ),
    );
    return buttons;
  }
}
