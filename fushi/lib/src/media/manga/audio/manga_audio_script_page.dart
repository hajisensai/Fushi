/// 漫画有声演出稿：发起 AI 标注（本卷 / 整卷重标 / 按系列）、处理没标成的部分（重试 /
/// 换一家提供商重试 / 手工标），逐页复核行（说话人、类型、一拍、顺序、手填念法）与
/// 页停留。改动直接写进会话里的演出稿并立即落盘；用户改过的行与页指令重标时保留。
library;

import 'dart:async';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/ai/ai_manga_audio_assistant.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_flow.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
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

enum _LineAction { speaker, kind, beat, say, clearSay, up, down }

enum _FailureAction { retry, retryOther, hand }

class _MangaAudioScriptPageState extends State<MangaAudioScriptPage> {
  MangaAudioAnnotateSession? _session;
  String? _loadError;
  List<EpubBookRow> _seriesVolumes = const <EpubBookRow>[];
  int _page = 0;
  bool _running = false;
  bool _cancelled = false;
  String _progress = '';

  AppModel get _app => widget.appModel;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    // 离开页面即停止本次标注（已标的页已落盘，下次接着标）。
    _cancelled = true;
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final MangaAudioAnnotateSession s = await MangaAudioAnnotateSession.open(
        _app,
        widget.bookKey,
      );
      final List<EpubBookRow> volumes = s.seriesKey == null
          ? const <EpubBookRow>[]
          : await mangaSeriesVolumes(_app, s.seriesKey!);
      if (!mounted) return;
      setState(() {
        _session = s;
        _seriesVolumes = volumes;
        _loadError = null;
        _page = _initialPage(s);
      });
    } on MangaAudioAnnotateError catch (e) {
      if (mounted) setState(() => _loadError = e.code);
    }
  }

  int _initialPage(MangaAudioAnnotateSession s) {
    final List<int> ordered = _orderedPages(s);
    return ordered.isEmpty ? 0 : ordered.first;
  }

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

  void _toast(String msg, {ToastSeverity severity = ToastSeverity.neutral}) =>
      FushiToast.show(msg: msg, severity: severity);

  Future<void> _save() async {
    await _session?.saveAll();
    if (mounted) setState(() {});
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

  void _onProgress(MangaAnnotatePhase phase, int done, int total) {
    if (!mounted) return;
    setState(() {
      final String text = switch (phase) {
        MangaAnnotatePhase.roster => t.manga_audio_progress_roster,
        MangaAnnotatePhase.pages => t.manga_audio_progress_pages(
          done: done,
          total: total,
        ),
        MangaAnnotatePhase.review => t.manga_audio_progress_review(
          done: done,
          total: total,
        ),
      };
      _progress = _volumeLabel.isEmpty ? text : '$_volumeLabel · $text';
    });
  }

  /// 按系列跑时当前是第几卷（单卷为空）。
  String _volumeLabel = '';

  Future<void> _run(Future<String> Function() body) async {
    setState(() {
      _running = true;
      _cancelled = false;
      _progress = '';
    });
    try {
      final String done = await body();
      _toast(done, severity: ToastSeverity.success);
    } on MangaAnnotateAbort catch (e) {
      _toast(
        e.code == 'cancelled'
            ? t.manga_audio_cancelled
            : t.manga_audio_aborted(reason: aiFailureText(e.code)),
        severity: e.code == 'cancelled'
            ? ToastSeverity.neutral
            : ToastSeverity.error,
      );
    } finally {
      _volumeLabel = '';
      if (mounted) {
        setState(() => _running = false);
        await _load();
      }
    }
  }

  String _summaryText(MangaAnnotateRunSummary s) => t.manga_audio_done(
    pages: s.annotatedPages.length,
    failed: s.failedPages.length,
  );

  Future<void> _annotate({required bool wholeVolume}) async {
    final MangaAudioAnnotateSession? s = _session;
    if (s == null || _running) return;
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
    await _run(() async {
      final MangaAnnotateRunSummary summary = await s.annotate(
        provider: provider,
        pages: pages,
        withRoster: withRoster,
        isCancelled: () => _cancelled,
        onProgress: _onProgress,
      );
      return _summaryText(summary);
    });
  }

  Future<void> _annotateSeries() async {
    if (_running || _seriesVolumes.isEmpty) return;
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
    await _run(() async {
      final List<MangaSeriesVolumeResult> results = await annotateMangaSeries(
        appModel: _app,
        volumes: _seriesVolumes,
        provider: provider,
        isCancelled: () => _cancelled,
        onVolume: (int i, int n) {
          if (mounted) {
            setState(
              () => _progress = _volumeLabel = t.manga_audio_progress_volume(
                done: i + 1,
                total: n,
              ),
            );
          }
        },
        onProgress: _onProgress,
      );
      return t.manga_audio_series_done(
        volumes: results
            .where((MangaSeriesVolumeResult r) => r.summary != null)
            .length,
        skipped: results
            .where((MangaSeriesVolumeResult r) => r.skipped != null)
            .length,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // 没标成的部分
  // ---------------------------------------------------------------------------

  Future<void> _onFailure(MangaAnnotateFailure failure) async {
    final MangaAudioAnnotateSession? s = _session;
    if (s == null || _running) return;
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
    if (action == null || !mounted) return;
    if (action == _FailureAction.hand) {
      s.handAnnotatePage(failure.page);
      setState(() => _page = failure.page);
      await _save();
      return;
    }
    final AiProviderConfig? provider = action == _FailureAction.retry
        ? current
        : next;
    if (provider == null || !await ensureMangaAudioUploadConsent(context)) {
      return;
    }
    await _run(() async {
      final MangaAnnotateRunSummary summary = await s.retry(
        failure,
        provider: provider,
        isCancelled: () => _cancelled,
        onProgress: _onProgress,
      );
      return _summaryText(summary);
    });
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

  Future<int?> _askMs(String title, int? current) async {
    final String? typed = await showFushiTextInputDialog(
      context: context,
      title: title,
      message: t.manga_audio_ms_hint,
      initialValue: current?.toString() ?? '',
      keyboardType: TextInputType.number,
      allowEmpty: true,
      icon: FushiIcons.timer,
    );
    if (typed == null) return null;
    // -1 = 清空（用默认值）。
    return typed.isEmpty ? -1 : int.tryParse(typed);
  }

  Future<void> _editDirective({required bool hold}) async {
    final MangaAudioAnnotateSession? s = _session;
    if (s == null) return;
    final MangaPageDirective old =
        s.script.pages[_page] ?? const MangaPageDirective();
    final int? ms = await _askMs(
      hold ? t.manga_audio_page_hold : t.manga_audio_page_lead,
      hold ? old.holdMs : old.leadMs,
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
    await _save();
  }

  int _indexOf(MangaScriptLine line) => _session!.script.lines.indexWhere(
    (MangaScriptLine l) => l.lineId == line.lineId,
  );

  void _replace(MangaScriptLine line, MangaScriptLine next) {
    final int i = _indexOf(line);
    if (i >= 0) _session!.script.lines[i] = next;
  }

  Future<void> _editLine(MangaScriptLine line) async {
    final MangaAudioAnnotateSession s = _session!;
    final List<MangaScriptLine> onPage = s.script.linesOnPage(line.page);
    final int pos = onPage.indexWhere(
      (MangaScriptLine l) => l.lineId == line.lineId,
    );
    final _LineAction? action = await showFushiChoiceDialog<_LineAction>(
      context: context,
      title: t.manga_audio_page(page: line.page + 1),
      message: s.textOf(line),
      options: <FushiChoiceOption<_LineAction>>[
        FushiChoiceOption<_LineAction>(
          value: _LineAction.speaker,
          label: t.manga_audio_line_speaker,
          subtitle: _speakerLabel(line.speaker),
          icon: FushiIcons.person,
        ),
        FushiChoiceOption<_LineAction>(
          value: _LineAction.kind,
          label: t.manga_audio_line_kind,
          subtitle: mangaLineKindLabel(line.kind),
          icon: FushiIcons.textFields,
        ),
        FushiChoiceOption<_LineAction>(
          value: _LineAction.beat,
          label: t.manga_audio_line_beat,
          subtitle: t.manga_audio_ms_value(ms: line.beatMs),
          icon: FushiIcons.timer,
        ),
        FushiChoiceOption<_LineAction>(
          value: _LineAction.say,
          label: t.manga_audio_line_say,
          icon: FushiIcons.edit,
        ),
        if (line.say != null)
          FushiChoiceOption<_LineAction>(
            value: _LineAction.clearSay,
            label: t.manga_audio_line_say_clear,
            icon: FushiIcons.undo,
          ),
        FushiChoiceOption<_LineAction>(
          value: _LineAction.up,
          label: t.manga_audio_line_move_up,
          icon: FushiIcons.arrowUp,
          enabled: pos > 0,
        ),
        FushiChoiceOption<_LineAction>(
          value: _LineAction.down,
          label: t.manga_audio_line_move_down,
          icon: FushiIcons.arrowDown,
          enabled: pos >= 0 && pos < onPage.length - 1,
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _LineAction.speaker:
        final String? speaker = await _pickSpeaker(line);
        if (speaker == null || speaker == line.speaker) return;
        _replace(
          line,
          line.copyWith(speaker: speaker, source: TtsCastSource.user),
        );
      case _LineAction.kind:
        final CastLineKind? kind = await showFushiChoiceDialog<CastLineKind>(
          context: context,
          title: t.manga_audio_line_kind,
          message: s.textOf(line),
          selected: line.kind,
          options: <FushiChoiceOption<CastLineKind>>[
            for (final CastLineKind k in CastLineKind.values)
              FushiChoiceOption<CastLineKind>(
                value: k,
                label: mangaLineKindLabel(k),
              ),
          ],
        );
        if (kind == null || kind == line.kind) return;
        _replace(line, line.copyWith(kind: kind, source: TtsCastSource.user));
      case _LineAction.beat:
        final int? ms = await _askMs(t.manga_audio_line_beat, line.beatMs);
        if (ms == null) return;
        _replace(
          line,
          line.copyWith(
            beatMs: ms < 0 ? 0 : ms.clamp(0, MangaScriptLimits.maxBeatMs),
            source: TtsCastSource.user,
          ),
        );
      case _LineAction.say:
        final String? typed = await showFushiTextInputDialog(
          context: context,
          title: t.manga_audio_line_say,
          initialValue: s.textOf(line),
          maxLines: 4,
          icon: FushiIcons.edit,
        );
        if (typed == null || typed.isEmpty) return;
        _replace(line, line.copyWith(say: typed, source: TtsCastSource.user));
      case _LineAction.clearSay:
        _replace(
          line,
          line.copyWith(clearSay: true, source: TtsCastSource.user),
        );
      case _LineAction.up:
      case _LineAction.down:
        final MangaScriptLine other =
            onPage[action == _LineAction.up ? pos - 1 : pos + 1];
        final int a = _indexOf(line);
        final int b = _indexOf(other);
        final List<MangaScriptLine> lines = s.script.lines;
        // 调序也是用户的判断：两行都记为手改，重标时保留顺序。
        lines[a] = other.copyWith(source: TtsCastSource.user);
        lines[b] = line.copyWith(source: TtsCastSource.user);
    }
    await _save();
  }

  String _speakerLabel(String speaker) => switch (speaker) {
    kTtsNarrator => t.audiobook_studio_cast_narrator,
    kTtsUnknown => t.audiobook_studio_cast_unknown,
    _ => speaker,
  };

  Future<String?> _pickSpeaker(MangaScriptLine line) async {
    const String newSpeaker = '\u0000new';
    final MangaAudioAnnotateSession s = _session!;
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: t.manga_audio_line_speaker,
      message: s.textOf(line),
      selected: line.speaker,
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(
          value: kTtsNarrator,
          label: t.audiobook_studio_cast_narrator,
        ),
        for (final TtsCastCharacter c in s.roster.values)
          FushiChoiceOption<String>(
            value: c.name,
            label: c.name,
            subtitle: c.aliases.isEmpty ? null : c.aliases.join('、'),
          ),
        FushiChoiceOption<String>(
          value: kTtsUnknown,
          label: t.audiobook_studio_cast_unknown,
        ),
        FushiChoiceOption<String>(
          value: newSpeaker,
          label: t.audiobook_studio_cast_new_speaker,
          icon: FushiIcons.add,
        ),
      ],
    );
    if (picked != newSpeaker || !mounted) return picked;
    final String? typed = await showFushiTextInputDialog(
      context: context,
      title: t.audiobook_studio_cast_new_speaker,
      labelText: t.manga_audio_line_speaker,
      icon: FushiIcons.personAdd,
    );
    if (typed == null || typed.isEmpty) return null;
    s.addCharacter(typed);
    return typed;
  }

  String _lineSubtitle(MangaScriptLine line) => <String>[
    _speakerLabel(line.speaker),
    mangaLineKindLabel(line.kind),
    if (line.beatMs > 0) '+${t.manga_audio_ms_value(ms: line.beatMs)}',
    if (line.emotion != null)
      '${line.emotion!.wire}${line.intensity == null ? '' : ' ${line.intensity}'}',
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
          if (_running)
            AdaptiveSettingsRow(
              key: const ValueKey<String>('manga-audio-progress'),
              icon: FushiIcons.stop,
              showIcon: true,
              title: _progress.isEmpty ? '…' : _progress,
              subtitle: t.stop,
              onTap: () => setState(() => _cancelled = true),
            )
          else ...<Widget>[
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
            if (_seriesVolumes.length > 1)
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
                onTap: _running ? null : () => unawaited(_onFailure(f)),
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
            onTap: () => unawaited(_editDirective(hold: true)),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('manga-audio-page-lead'),
            title: t.manga_audio_page_lead,
            subtitle: directive.leadMs == null
                ? t.manga_audio_ms_default
                : t.manga_audio_ms_value(ms: directive.leadMs!),
            onTap: () => unawaited(_editDirective(hold: false)),
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
          onTap: _running ? null : () => unawaited(_editLine(line)),
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
                    const Center(child: CircularProgressIndicator()),
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
