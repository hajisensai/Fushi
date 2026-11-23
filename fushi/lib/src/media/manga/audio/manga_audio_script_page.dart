/// 漫画有声演出稿：发起 AI 标注（本卷 / 整卷重标 / 按系列）、处理没标成的部分（重试 /
/// 换一家提供商重试 / 手工标），逐页复核行（说话人、类型、一拍、顺序、手填念法）与
/// 页停留。改动直接写进会话里的演出稿并立即落盘；用户改过的行与页指令重标时保留。
///
/// 标注本身在进程级任务表 [MangaAnnotateTasks] 里跑，本页只是观察者：打开时接上本卷
/// 正在跑的任务显示进度，离开页面不停，只有点「停止」才停；跑完由任务表弹全局提示。
/// 本卷有任务在跑时复核编辑锁住（任务用自己的会话落盘），跑完重读，新会话装上后才解锁
/// （[MangaReviewEditGate]）；存盘再按读盘修订校验（[MangaAudioAnnotateSession.saveEdits]），
/// 不拿整份旧稿连同旧账本盖掉别处刚写的结果。
library;

import 'dart:async';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/ai/ai_manga_audio_assistant.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_series_run.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_flow.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_line_editor.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_review_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

Future<void> openMangaAudioScriptPage(
  BuildContext context, {
  required AppModel appModel,
  required String bookKey,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => MangaAudioScriptPage(appModel: appModel, bookKey: bookKey),
  ),
);

class MangaAudioScriptPage extends StatefulWidget {
  const MangaAudioScriptPage({
    required this.appModel,
    required this.bookKey,
    super.key,
  });

  final AppModel appModel;
  final String bookKey;

  @override
  State<MangaAudioScriptPage> createState() => _MangaAudioScriptPageState();
}

enum _FailureAction { retry, retryOther, hand }

class _MangaAudioScriptPageState extends State<MangaAudioScriptPage> {
  MangaAudioAnnotateSession? _session;
  String? _loadError;
  List<EpubBookRow> _seriesVolumes = const <EpubBookRow>[];
  int _page = 0;

  /// 标注在进程级任务表里跑，本页只观察：离开页面不停，只有点「停止」才停。
  late final MangaAnnotateTasks _tasks = mangaAnnotateTasksFor(_app);

  /// 本卷正在跑的标注任务（单卷 / 重试 / 按系列跑到本卷）。
  MangaAnnotateTask? _task;

  /// 本系列正在跑的漫画按系列跑（不一定正跑到本卷）。
  TtsSeriesRun? _seriesRun;

  AppModel get _app => widget.appModel;

  /// 本卷有任务在跑（显示进度与「停止」）。
  bool get _busy => _task != null;

  /// 能不能改稿：任务在跑、或任务刚结束 / 从复核回来后新会话还没装上时都不能
  /// （见 [MangaReviewEditGate]）。
  final MangaReviewEditGate _gate = MangaReviewEditGate();

  /// 复核编辑全部锁住（任务用自己的会话落盘；旧会话还在屏幕上时也不能改）。
  bool get _locked => !_gate.editable;

  @override
  void initState() {
    super.initState();
    _tasks.addListener(_syncTasks);
    _syncTasks();
    unawaited(_load(_gate.beginLoad()));
  }

  @override
  void dispose() {
    // 只摘掉观察者；任务照跑（已标的页随时落盘，跑完弹全局提示）。
    _tasks.removeListener(_syncTasks);
    _task?.removeListener(_onTaskChanged);
    _seriesRun?.removeListener(_onTaskChanged);
    super.dispose();
  }

  /// 任务表变了（有任务开始 / 结束）：接上本卷的任务与本系列的按系列跑。
  void _syncTasks() {
    final MangaAnnotateTask? task = _tasks.runningFor(widget.bookKey);
    if (!identical(task, _task)) {
      // 任务跑完：同一拍里先开新一轮读盘，锁一直挂到新会话装上（[_load]）。
      final bool ended = _gate.taskChanged(running: task != null);
      _task?.removeListener(_onTaskChanged);
      task?.addListener(_onTaskChanged);
      _task = task;
      if (ended) unawaited(_load(_gate.beginLoad()));
    }
    final TtsSeriesRun? active = activeTtsSeriesRun;
    final String? seriesKey = _session?.seriesKey;
    final TtsSeriesRun? run =
        active != null &&
            active.running &&
            active.kind == TtsRenderJobKind.manga &&
            seriesKey != null &&
            active.seriesKey == seriesKey
        ? active
        : null;
    if (!identical(run, _seriesRun)) {
      _seriesRun?.removeListener(_onTaskChanged);
      run?.addListener(_onTaskChanged);
      _seriesRun = run;
    }
    if (mounted) setState(() {});
  }

  void _onTaskChanged() {
    final TtsSeriesRun? run = _seriesRun;
    if (run != null && !run.running) {
      run.removeListener(_onTaskChanged);
      _seriesRun = null;
    }
    if (mounted) setState(() {});
  }

  /// 开一份新会话并装上；[load] 是 [MangaReviewEditGate.beginLoad] 给的代号，期间又
  /// 请求了更新的读盘时丢掉这次的结果。[keepPage]：重读后停在当前页（从逐句复核回来、
  /// 存盘冲突重读时），否则跳到第一处要处理的页。
  Future<void> _load(int load, {bool keepPage = false}) async {
    try {
      final MangaAudioAnnotateSession s = await MangaAudioAnnotateSession.open(
        _app,
        widget.bookKey,
      );
      final List<EpubBookRow> volumes = s.seriesKey == null
          ? const <EpubBookRow>[]
          : await mangaSeriesVolumes(_app, s.seriesKey!);
      if (!mounted || !_gate.isLatest(load)) return;
      setState(() {
        _gate.install(load);
        _session = s;
        _seriesVolumes = volumes;
        _loadError = null;
        _page = keepPage && _page < s.pageCount ? _page : _initialPage(s);
      });
      _syncTasks();
    } on MangaAudioAnnotateError catch (e) {
      if (mounted && _gate.isLatest(load)) {
        setState(() => _loadError = e.code);
      }
    }
  }

  int _initialPage(MangaAudioAnnotateSession s) {
    final List<int> ordered = _orderedPages(s);
    return ordered.isEmpty ? 0 : ordered.first;
  }

  int _pendingCount(MangaAudioAnnotateSession s) =>
      s.script.lines.where(mangaLineNeedsReview).length;

  int _reviewCount(MangaAudioAnnotateSession s, int page) =>
      s.script.linesOnPage(page).where(mangaLineNeedsReview).length;

  /// 页的排列：有失败 / 待复核的在前（页序），其余按页序。
  List<int> _orderedPages(MangaAudioAnnotateSession s) {
    final Set<int> failed = s.ledger.failedPages.toSet();
    final List<int> first = <int>[];
    final List<int> rest = <int>[];
    for (int p = 0; p < s.pageCount; p++) {
      (failed.contains(p) ||
                  _reviewCount(s, p) > 0 ||
                  s.ledger.rejected.containsKey(p)
              ? first
              : rest)
          .add(p);
    }
    return <int>[...first, ...rest];
  }

  /// 对照原页逐句复核；回来后重读（复核页用自己的会话写盘）。
  Future<void> _openReview() async {
    if (_session == null || _locked) return;
    await openMangaAudioReviewPage(
      context,
      appModel: _app,
      bookKey: widget.bookKey,
      startPage: _page,
    );
    if (mounted) await _load(_gate.beginLoad(), keepPage: true);
  }

  void _toast(String msg, {ToastSeverity severity = ToastSeverity.neutral}) =>
      FushiToast.show(msg: msg, severity: severity);

  /// 存 [s]（发起改动时的会话）。改动期间（对话框开着时）任务开始了、换了会话，或这卷
  /// 读盘后被别处存过，都不写：重读最新稿并提示重做，不拿整份旧稿盖掉新结果。
  Future<void> _save(MangaAudioAnnotateSession s) async {
    final bool written =
        identical(s, _session) && !_locked && await s.saveEdits();
    if (!mounted) return;
    if (!written) {
      final int load = _gate.beginLoad();
      setState(() {});
      _toast(t.manga_audio_review_conflict, severity: ToastSeverity.warning);
      await _load(load, keepPage: true);
      return;
    }
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // 发起标注
  // ---------------------------------------------------------------------------

  AiProviderConfig? _provider() {
    final AiProviderConfig? provider = resolveMangaAudioProvider(_app);
    if (provider == null) {
      _toast(t.manga_audio_error_no_provider, severity: ToastSeverity.warning);
    }
    return provider;
  }

  /// 进度行文字：按系列跑时带「第几卷」。
  String _progressText() {
    final MangaAnnotateTask? task = _task;
    final TtsSeriesRun? run = _seriesRun;
    if (task == null) {
      // 按系列跑正在标别的卷。
      return run == null
          ? ''
          : t.audiobook_studio_series_run_progress(
              done: run.index + 1,
              total: run.books.length,
              title: run.title,
            );
    }
    final String volume = run == null
        ? ''
        : t.manga_audio_progress_volume(
            done: run.index + 1,
            total: run.books.length,
          );
    final String text = switch (task.phase) {
      null => '',
      MangaAnnotatePhase.roster => t.manga_audio_progress_roster,
      MangaAnnotatePhase.pages => t.manga_audio_progress_pages(
        done: task.progressDone,
        total: task.progressTotal,
      ),
      MangaAnnotatePhase.review => t.manga_audio_progress_review(
        done: task.progressDone,
        total: task.progressTotal,
      ),
    };
    if (volume.isEmpty) return text;
    return text.isEmpty ? volume : '$volume · $text';
  }

  /// 「停止」：按系列跑整个停（连同本卷）；否则只停本卷任务。
  void _stop() {
    final TtsSeriesRun? run = _seriesRun;
    if (run != null) {
      run.cancel();
    } else {
      _tasks.cancel(widget.bookKey);
    }
    setState(() {});
  }

  /// 把已确认的请求交给任务表；结果由任务表弹全局提示，本页只跟进度。
  void _start(MangaAnnotateRequest request) {
    try {
      _tasks.start(request);
    } on MangaAnnotateBusy {
      _toast(t.manga_audio_annotate_busy);
    }
  }

  Future<void> _annotate({required bool wholeVolume}) async {
    final MangaAudioAnnotateSession? s = _session;
    if (s == null || _locked) return;
    final AiProviderConfig? provider = _provider();
    if (provider == null || !await ensureMangaAudioUploadConsent(context)) {
      return;
    }
    final List<int> pages = s.pagesToAnnotate(skipAnnotated: !wholeVolume);
    final bool withRoster =
        wholeVolume || s.script.annotatedPages.isEmpty || s.isStale;
    if (!mounted ||
        !await confirmMangaAnnotationEstimate(
          context,
          estimate: s.estimate(pages, withRoster: withRoster),
          provider: provider,
        )) {
      return;
    }
    _start(
      MangaAnnotateRequest.annotate(
        bookKey: widget.bookKey,
        provider: provider,
        pages: pages,
        withRoster: withRoster,
      ),
    );
  }

  /// 按系列跑（与制作台同一个 [TtsSeriesRun]，只标注）：逐卷只标还没标过的页，每卷
  /// 经同一张任务表跑；离开页面不停。
  Future<void> _annotateSeries() async {
    final String? seriesKey = _session?.seriesKey;
    if (_seriesRun != null || seriesKey == null || _seriesVolumes.isEmpty) {
      return;
    }
    final AiProviderConfig? provider = _provider();
    if (provider == null || !await ensureMangaAudioUploadConsent(context)) {
      return;
    }
    // 预估：逐卷读 OCR（不发请求），只算还没标的页。
    int pages = 0;
    int rosters = 0;
    int reviews = 0;
    for (final EpubBookRow row in _seriesVolumes) {
      try {
        final MangaAudioAnnotateSession v =
            await MangaAudioAnnotateSession.open(_app, row.bookKey);
        final MangaAnnotationEstimate e = v.estimate(
          v.pagesToAnnotate(),
          withRoster: v.script.annotatedPages.isEmpty || v.isStale,
        );
        pages += e.pageRequests;
        rosters += e.rosterRequests;
        reviews += e.reviewRequests;
      } on MangaAudioAnnotateError {
        continue;
      }
    }
    if (!mounted ||
        !await confirmMangaAnnotationEstimate(
          context,
          estimate: MangaAnnotationEstimate(
            rosterRequests: rosters,
            pageRequests: pages,
            reviewRequests: reviews,
          ),
          provider: provider,
        )) {
      return;
    }
    final TtsSeriesRun? active = activeTtsSeriesRun;
    if (active != null && active.running) {
      _toast(t.audiobook_studio_series_run_busy);
      _syncTasks();
      return;
    }
    final TtsSeriesRun run = TtsSeriesRun.start(
      appModel: _app,
      seriesKey: seriesKey,
      books: <String>[
        for (final EpubBookRow row in _seriesVolumes) row.bookKey,
      ],
      mode: TtsSeriesRunMode.annotate,
      kind: TtsRenderJobKind.manga,
      render: (
        presetId: '',
        verify: false,
        pausePreset: 'standard',
        normalizeLoudness: false,
      ),
    );
    // 结果弹全局提示（页面在不在都弹）。
    unawaited(run.done.then((_) => _announceSeriesRun(run)));
    _syncTasks();
  }

  // ---------------------------------------------------------------------------
  // 没标成的部分
  // ---------------------------------------------------------------------------

  Future<void> _onFailure(MangaAnnotateFailure failure) async {
    final MangaAudioAnnotateSession? s = _session;
    if (s == null || _locked) return;
    final AiProviderConfig? current = resolveMangaAudioProvider(_app);
    final List<AiProviderConfig> usable = mangaAudioUsableProviders(_app);
    final String? nextId = failure.nextRetryProvider(<String>[
      for (final AiProviderConfig c in usable)
        if (c.id != current?.id) c.id,
    ]);
    final AiProviderConfig? next = nextId == null
        ? null
        : resolveMangaAudioProvider(_app, providerId: nextId);
    final _FailureAction? action = await showFushiChoiceDialog<_FailureAction>(
      context: context,
      title: mangaAnnotateFailureTitle(failure),
      message: _failureSubtitle(failure),
      options: <FushiChoiceOption<_FailureAction>>[
        if (current != null)
          FushiChoiceOption<_FailureAction>(
            value: _FailureAction.retry,
            label: t.manga_audio_retry,
            subtitle: mangaAudioProviderLabel(current),
            icon: FushiIcons.refresh,
          ),
        if (next != null)
          FushiChoiceOption<_FailureAction>(
            value: _FailureAction.retryOther,
            label: t.manga_audio_retry_with(
              provider: mangaAudioProviderLabel(next),
            ),
            icon: FushiIcons.swap,
          ),
        if (failure.stage == MangaAnnotateStage.page)
          FushiChoiceOption<_FailureAction>(
            value: _FailureAction.hand,
            label: t.manga_audio_hand_annotate,
            icon: FushiIcons.edit,
          ),
      ],
    );
    if (action == null || !mounted || _locked || !identical(s, _session)) {
      return;
    }
    if (action == _FailureAction.hand) {
      s.handAnnotatePage(failure.page);
      setState(() => _page = failure.page);
      await _save(s);
      return;
    }
    final AiProviderConfig? provider = action == _FailureAction.retry
        ? current
        : next;
    if (provider == null || !await ensureMangaAudioUploadConsent(context)) {
      return;
    }
    _start(
      MangaAnnotateRequest.retry(
        bookKey: widget.bookKey,
        provider: provider,
        failure: failure,
      ),
    );
  }

  String _failureSubtitle(MangaAnnotateFailure f) {
    final MangaAnnotateAttempt? last = f.last;
    final String reason = last == null ? '' : mangaAnnotateFailureText(last);
    final List<String> tried = <String>{
      for (final MangaAnnotateAttempt a in f.attempts)
        a.model.isEmpty ? a.providerId : a.model,
    }.toList();
    return tried.isEmpty
        ? reason
        : '$reason\n${t.manga_audio_failure_tried(providers: tried.join('、'))}';
  }

  // ---------------------------------------------------------------------------
  // 复核
  // ---------------------------------------------------------------------------

  Future<void> _pickPage() async {
    final MangaAudioAnnotateSession? s = _session;
    if (s == null) return;
    final int? picked = await showFushiChoiceDialog<int>(
      context: context,
      title: t.manga_audio_script_title,
      selected: _page,
      options: <FushiChoiceOption<int>>[
        for (final int p in _orderedPages(s))
          FushiChoiceOption<int>(
            value: p,
            label: t.manga_audio_page(page: p + 1),
            subtitle: _pageSubtitle(s, p),
          ),
      ],
    );
    if (picked != null && mounted) setState(() => _page = picked);
  }

  String _pageSubtitle(MangaAudioAnnotateSession s, int page) {
    if (s.ledger.failureOf(MangaAnnotateStage.page, page) case final f?) {
      final MangaAnnotateAttempt? last = f.last;
      return last == null ? '' : mangaAnnotateFailureText(last);
    }
    if (!s.script.annotatedPages.contains(page)) {
      return t.manga_audio_page_not_annotated;
    }
    final int review = _reviewCount(s, page);
    if (review > 0) return t.manga_audio_page_review_count(n: review);
    return s.script.linesOnPage(page).isEmpty ? t.manga_audio_page_empty : '';
  }

  Future<void> _editDirective({required bool hold}) async {
    final MangaAudioAnnotateSession? s = _session;
    if (s == null) return;
    final MangaPageDirective old =
        s.script.pages[_page] ?? const MangaPageDirective();
    final int? ms = await askMangaAudioMs(
      context,
      title: hold ? t.manga_audio_page_hold : t.manga_audio_page_lead,
      current: hold ? old.holdMs : old.leadMs,
    );
    if (ms == null || !mounted) return;
    final int? value = ms < 0
        ? null
        : ms.clamp(
            0,
            hold ? MangaScriptLimits.maxHoldMs : MangaScriptLimits.maxLeadMs,
          );
    s.script.pages[_page] = MangaPageDirective(
      holdMs: hold ? value : old.holdMs,
      leadMs: hold ? old.leadMs : value,
      source: TtsCastSource.user,
    );
    await _save(s);
  }

  /// 改一句（与阅读页右键「编辑这句配音」同一份对话框）。改动落在发起改动时的会话 [s]
  /// 上（对话框开着时会话可能被重读换掉，见 [_save]）。
  Future<void> _editLine(MangaScriptLine line) async {
    final MangaAudioAnnotateSession s = _session!;
    final MangaLineEditAction? action = await showMangaLineEditDialog(
      context,
      session: s,
      line: line,
    );
    if (action == null || !mounted) return;
    await _save(s);
  }

  String _speakerLabel(String speaker) => switch (speaker) {
    kTtsNarrator => t.audiobook_studio_cast_narrator,
    kTtsUnknown => t.audiobook_studio_cast_unknown,
    _ => speaker,
  };

  String _lineSubtitle(MangaScriptLine line) => <String>[
    _speakerLabel(line.speaker),
    mangaLineKindLabel(line.kind),
    if (line.beatMs > 0) '+${t.manga_audio_ms_value(ms: line.beatMs)}',
    ?mangaLineToneLabel(line),
    if (mangaLineNeedsReview(line) && line.speaker != kTtsUnknown)
      t.manga_audio_low_confidence,
    if (line.source == TtsCastSource.user) t.manga_audio_user_edited,
    if (line.say != null) t.manga_audio_manual_text,
  ].join(' · ');

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  List<Widget> _items(MangaAudioAnnotateSession s) {
    final MangaPageDirective directive =
        s.script.pages[_page] ?? const MangaPageDirective();
    final List<MangaScriptLine> lines = s.script.linesOnPage(_page);
    final List<MangaRejectedNote> rejected =
        s.ledger.rejected[_page] ?? const <MangaRejectedNote>[];
    final List<MangaAnnotateFailure> failures = s.ledger.sortedFailures;
    return <Widget>[
      AdaptiveSettingsSection(
        key: const ValueKey<String>('manga-audio-actions'),
        children: <Widget>[
          AdaptiveSettingsRow(
            key: const ValueKey<String>('manga-audio-status'),
            icon: s.isStale ? FushiIcons.warning : FushiIcons.voice,
            showIcon: true,
            title: t.manga_audio_status(
              done: s.script.annotatedPages.length,
              total: s.pageCount,
            ),
            subtitle: s.isStale ? t.manga_audio_stale : null,
          ),
          if (_busy || _seriesRun != null)
            AdaptiveSettingsRow(
              key: const ValueKey<String>('manga-audio-progress'),
              icon: FushiIcons.stop,
              showIcon: true,
              title: _progressText().isEmpty ? '…' : _progressText(),
              subtitle: t.stop,
              onTap:
                  (_task?.cancelRequested ?? false) ||
                      (_seriesRun?.cancelled ?? false)
                  ? null
                  : _stop,
            ),
          if (!_busy) ...<Widget>[
            if (s.script.lines.isNotEmpty)
              AdaptiveSettingsRow(
                key: const ValueKey<String>('manga-audio-review'),
                icon: FushiIcons.image,
                showIcon: true,
                title: t.manga_audio_review_action,
                subtitle: _pendingCount(s) == 0
                    ? null
                    : t.manga_audio_page_review_count(n: _pendingCount(s)),
                onTap: () => unawaited(_openReview()),
              ),
            AdaptiveSettingsRow(
              key: const ValueKey<String>('manga-audio-annotate'),
              icon: FushiIcons.ai,
              showIcon: true,
              title: t.manga_audio_annotate_action,
              onTap: () => unawaited(_annotate(wholeVolume: false)),
            ),
            AdaptiveSettingsRow(
              key: const ValueKey<String>('manga-audio-annotate-all'),
              icon: FushiIcons.refresh,
              showIcon: true,
              title: t.manga_audio_annotate_all_action,
              onTap: () => unawaited(_annotate(wholeVolume: true)),
            ),
            if (_seriesVolumes.length > 1 && _seriesRun == null)
              AdaptiveSettingsRow(
                key: const ValueKey<String>('manga-audio-annotate-series'),
                icon: FushiIcons.collections,
                showIcon: true,
                title: t.manga_audio_annotate_series_action,
                subtitle: t.manga_audio_annotate_series_summary(
                  n: _seriesVolumes.length,
                ),
                onTap: () => unawaited(_annotateSeries()),
              ),
          ],
        ],
      ),
      if (failures.isNotEmpty)
        AdaptiveSettingsSection(
          key: const ValueKey<String>('manga-audio-failures'),
          title: t.manga_audio_failures_section,
          children: <Widget>[
            for (final MangaAnnotateFailure f in failures)
              AdaptiveSettingsRow(
                key: ValueKey<String>('manga-audio-failure-${f.key}'),
                icon: FushiIcons.error,
                showIcon: true,
                title: mangaAnnotateFailureTitle(f),
                subtitle: _failureSubtitle(f),
                subtitleMaxLines: 3,
                onTap: _locked ? null : () => unawaited(_onFailure(f)),
              ),
          ],
        ),
      AdaptiveSettingsSection(
        key: ValueKey<String>('manga-audio-page-$_page'),
        children: <Widget>[
          AdaptiveSettingsRow(
            key: const ValueKey<String>('manga-audio-page-picker'),
            icon: FushiIcons.chevronRight,
            showIcon: true,
            title: t.manga_audio_page(page: _page + 1),
            subtitle: _pageSubtitle(s, _page),
            onTap: () => unawaited(_pickPage()),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('manga-audio-page-hold'),
            title: t.manga_audio_page_hold,
            subtitle: directive.holdMs == null
                ? t.manga_audio_ms_default
                : t.manga_audio_ms_value(ms: directive.holdMs!),
            onTap: _locked ? null : () => unawaited(_editDirective(hold: true)),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('manga-audio-page-lead'),
            title: t.manga_audio_page_lead,
            subtitle: directive.leadMs == null
                ? t.manga_audio_ms_default
                : t.manga_audio_ms_value(ms: directive.leadMs!),
            onTap: _locked
                ? null
                : () => unawaited(_editDirective(hold: false)),
          ),
        ],
      ),
      for (final MangaRejectedNote n in rejected)
        AdaptiveSettingsRow(
          key: ValueKey<String>(
            'manga-audio-rejected-$_page-${n.blocks.join('.')}-${n.reason.name}',
          ),
          icon: FushiIcons.warning,
          showIcon: true,
          title: t.manga_audio_rejected(
            blocks: n.blocks.join(', '),
            reason: n.detail == null
                ? n.reason.name
                : '${n.reason.name}: ${n.detail}',
          ),
        ),
      for (final MangaScriptLine line in lines)
        AdaptiveSettingsRow(
          key: ValueKey<String>('manga-audio-line-${line.lineId}'),
          icon: mangaLineNeedsReview(line) ? FushiIcons.warning : null,
          showIcon: mangaLineNeedsReview(line),
          title: s.textOf(line).isEmpty ? '—' : s.textOf(line),
          titleMaxLines: 6,
          subtitle: _lineSubtitle(line),
          onTap: _locked ? null : () => unawaited(_editLine(line)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    final MangaAudioAnnotateSession? s = _session;
    return SettingsKitScaffold(
      title: t.manga_audio_script_title,
      leadingIcon: FushiIcons.voice,
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) {
            final EdgeInsets padding = EdgeInsets.fromLTRB(
              inset,
              tokens.spacing.gap + MediaQuery.paddingOf(context).top,
              inset,
              tokens.spacing.page + bottomSafeInsetOf(context),
            );
            if (s == null) {
              return ListView(
                controller: controller,
                padding: padding,
                children: <Widget>[
                  if (_loadError != null)
                    AdaptiveSettingsRow(
                      key: const ValueKey<String>('manga-audio-load-error'),
                      icon: FushiIcons.warning,
                      showIcon: true,
                      title: mangaAudioErrorText(_loadError!),
                    )
                  else
                    const Center(child: FushiCircularProgressIndicator()),
                ],
              );
            }
            final List<Widget> items = _items(s);
            return FushiEntranceScope(
              replayKey: _page,
              child: ListView.builder(
                key: const ValueKey<String>('manga-audio-script-list'),
                controller: controller,
                padding: padding,
                itemCount: items.length,
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int index) => items[index],
                ),
              ),
            );
          },
    );
  }
}

/// 页面发起的按系列标注结束时的全局提示（页面在不在都弹）。
void _announceSeriesRun(TtsSeriesRun run) {
  final List<TtsSeriesRunFailure> failures = run.failures;
  final String? stop = failures
      .map((TtsSeriesRunFailure f) => f.code)
      .where(ttsSeriesRunStopsOn)
      .firstOrNull;
  if (stop == 'cancelled') {
    FushiToast.show(msg: t.manga_audio_cancelled);
  } else if (stop != null && stop.startsWith(kTtsSeriesRunAbortPrefix)) {
    FushiToast.show(
      msg: t.manga_audio_aborted(
        reason: aiFailureText(stop.substring(kTtsSeriesRunAbortPrefix.length)),
      ),
      severity: ToastSeverity.error,
    );
  } else if (stop != null) {
    FushiToast.show(
      msg: mangaAudioErrorText(stop),
      severity: ToastSeverity.error,
    );
  } else {
    FushiToast.show(
      msg: t.manga_audio_series_done(
        volumes: run.annotated.length,
        skipped: failures.length,
      ),
      severity: failures.isEmpty
          ? ToastSeverity.success
          : ToastSeverity.warning,
    );
  }
}
