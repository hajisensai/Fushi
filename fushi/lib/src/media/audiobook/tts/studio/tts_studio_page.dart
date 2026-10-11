/// 「制作有声书」工作台：选声音 / 章节 / 校对 / 发音词典 → 排进制作队列；
/// 看本书最近一个任务的进度与校对结果，勾选被标出的句子重新生成。
///
/// 句序必须与制作流程同一口径，计划一律经 [buildStudioPlan] 构建。
library;

import 'dart:async';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/engine_listenable.dart';
import 'package:fushi/utils.dart';

Future<void> openTtsStudioPage(
  BuildContext context, {
  required AppModel appModel,
  required String bookKey,
}) async {
  final NavigatorState navigator = Navigator.of(context);
  await TtsServices.of(appModel.prefsRepo).seedBuiltinVoiceIfUnset();
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => TtsStudioPage(appModel: appModel, bookKey: bookKey),
    ),
  );
}

/// 任务失败码 → 文案（码由制作流程写进任务清单）。
String ttsRenderFailureText(String? code) {
  switch (code) {
    case 'voice_missing':
      return t.audiobook_studio_failure_voice_missing;
    case 'voice_unavailable':
      return t.audiobook_studio_failure_voice_unavailable;
    case 'book_missing':
      return t.audiobook_studio_failure_book_missing;
    case 'encode_failed':
      return t.audiobook_studio_failure_encode_failed;
    case 'voice_incomplete':
      return t.audiobook_tts_voice_incomplete;
    case 'empty_book':
      return t.audiobook_tts_empty_book;
    case 'cache_busy':
      return t.audiobook_studio_failure_cache_busy;
    case 'verify_failed':
      return t.audiobook_studio_failure_verify_failed;
  }
  if (code != null && code.startsWith('tts_')) {
    final String name = code.substring(4);
    for (final TtsFailureCode value in TtsFailureCode.values) {
      if (value.name == name) return ttsFailureText(TtsFailure(value));
    }
  }
  return t.audiobook_studio_failure_internal;
}

/// 任务状态行文案（运行中按阶段带进度）。
String ttsRenderJobStatusText(TtsRenderJob job) => switch (job.status) {
  TtsRenderJobStatus.queued => t.audiobook_studio_status_queued,
  TtsRenderJobStatus.done => t.audiobook_studio_status_done,
  TtsRenderJobStatus.cancelled => t.audiobook_studio_status_cancelled,
  TtsRenderJobStatus.failed => t.audiobook_studio_status_failed(
    reason: ttsRenderFailureText(job.error),
  ),
  TtsRenderJobStatus.running => switch (job.phase) {
    null || TtsRenderJobPhase.planning => t.audiobook_studio_phase_planning,
    TtsRenderJobPhase.synthesizing => t.audiobook_studio_phase_synthesizing(
      done: job.done,
      total: job.total,
    ),
    TtsRenderJobPhase.encoding => t.audiobook_studio_phase_encoding(
      done: job.done,
      total: job.total,
    ),
    TtsRenderJobPhase.verifying => t.audiobook_studio_phase_verifying(
      done: job.done,
      total: job.total,
    ),
    TtsRenderJobPhase.importing => t.audiobook_studio_phase_importing,
  },
};

/// 进度条取值：null = 不定进度；任务结束不显示进度条时调用方不用它。
double? ttsRenderJobProgress(TtsRenderJob job) {
  if (job.status == TtsRenderJobStatus.done) return 1;
  if (job.status != TtsRenderJobStatus.running || job.total <= 0) return null;
  return (job.done / job.total).clamp(0.0, 1.0);
}

class TtsStudioPage extends StatefulWidget {
  const TtsStudioPage({
    required this.appModel,
    required this.bookKey,
    super.key,
  });

  final AppModel appModel;
  final String bookKey;

  @override
  State<TtsStudioPage> createState() => _TtsStudioPageState();
}

/// 计划里一章的统计（只列有句子的章）。
class _StudioChapter {
  _StudioChapter(this.section, this.label);

  final int section;
  final String label;
  int sentences = 0;
  int chars = 0;
}

class _TtsStudioPageState extends State<TtsStudioPage> {
  late final TtsServices _tts = TtsServices.of(widget.appModel.prefsRepo);
  late final TtsRenderQueue _queue = ttsRenderQueueFor(widget.appModel);

  List<TtsVoicePreset> _presets = const <TtsVoicePreset>[];
  String? _presetId;

  ({EpubBookRow row, EpubBook book})? _loaded;
  bool _bookMissing = false;
  bool _hasAudiobook = false;

  TtsBookPlan? _plan;
  List<_StudioChapter> _chapters = const <_StudioChapter>[];
  bool _planning = false;
  bool _planFailed = false;
  int _planGeneration = 0;

  /// 选中的章（spine 下标）。
  Set<int> _selected = <int>{};
  bool _selectionTouched = false;

  late bool _verify = isAsrSupported;
  List<TtsPronunciationRule> _rules = const <TtsPronunciationRule>[];
  bool _starting = false;

  /// 校对结果里勾选重新生成的句序；随任务 id 换掉。
  final Set<int> _regenSelected = <int>{};
  String? _regenJobId;

  AudioPlayer? _previewPlayer;
  StreamSubscription<PlayerState>? _previewSub;
  TtsCancelToken? _previewCancel;
  VoidCallback? _previewUnpin;

  /// 正在取音频（合成 / 读缓存）的句序。
  int? _previewing;

  @override
  void initState() {
    super.initState();
    _reloadPresets(preferJobPreset: true);
    _rules = _tts.pronunciation.load();
    unawaited(_loadBook());
  }

  @override
  void dispose() {
    _previewCancel?.cancel();
    unawaited(_releasePreview());
    super.dispose();
  }

  TtsVoicePreset? get _preset =>
      _presets.where((TtsVoicePreset p) => p.id == _presetId).firstOrNull;

  TtsProviderDescriptor? get _descriptor {
    final TtsVoicePreset? preset = _preset;
    return preset == null ? null : _tts.registry[preset.providerId];
  }

  bool get _voiceUsable {
    final TtsVoicePreset? preset = _preset;
    final TtsProviderDescriptor? descriptor = _descriptor;
    return preset != null &&
        descriptor != null &&
        descriptor.isAvailable &&
        descriptor.validate(preset).isEmpty;
  }

  void _reloadPresets({bool preferJobPreset = false}) {
    final List<TtsVoicePreset> presets = _tts.store.loadPresets();
    String? id = _presetId;
    if (preferJobPreset) {
      id = _queue.latestFor(widget.bookKey)?.presetId;
    }
    if (id == null || !presets.any((TtsVoicePreset p) => p.id == id)) {
      id = _tts.store.activePreset()?.id;
    }
    if (id == null || !presets.any((TtsVoicePreset p) => p.id == id)) {
      id = presets.isEmpty ? null : presets.first.id;
    }
    _presets = presets;
    _presetId = id;
  }

  Future<void> _loadBook() async {
    final FushiDatabase db = widget.appModel.database;
    final ({EpubBookRow row, EpubBook book})? loaded = await loadEpubForStudio(
      db,
      widget.bookKey,
    );
    final Audiobook? existing = await AudiobookRepository(
      db,
    ).findByBookKey(widget.bookKey);
    if (!mounted) return;
    setState(() {
      _loaded = loaded;
      _bookMissing = loaded == null;
      _hasAudiobook = existing != null;
    });
    await _rebuildPlan();
  }

  Future<void> _rebuildPlan() async {
    final ({EpubBookRow row, EpubBook book})? loaded = _loaded;
    final TtsProviderDescriptor? descriptor = _descriptor;
    if (loaded == null || descriptor == null) return;
    final int generation = ++_planGeneration;
    setState(() {
      _planning = true;
      _planFailed = false;
    });
    try {
      final TtsBookPlan plan = await buildStudioPlan(loaded.book, _tts);
      if (!mounted || generation != _planGeneration) return;
      final List<_StudioChapter> chapters = _chaptersOf(loaded.book, plan);
      final Set<int> sections = <int>{
        for (final _StudioChapter c in chapters) c.section,
      };
      setState(() {
        _plan = plan;
        _chapters = chapters;
        _selected = _selectionTouched
            ? _selected.intersection(sections)
            : sections;
        _planning = false;
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsStudio.buildPlan', e, stack);
      if (!mounted || generation != _planGeneration) return;
      setState(() {
        _planning = false;
        _planFailed = true;
      });
    }
  }

  static List<_StudioChapter> _chaptersOf(EpubBook book, TtsBookPlan plan) {
    final Map<int, String> tocLabels = <int, String>{};
    void walk(List<EpubTocItem> items) {
      for (final EpubTocItem item in items) {
        final int index = book.chapterIndexForHref(item.href);
        final String label = item.label.trim();
        if (index >= 0 && label.isNotEmpty) {
          tocLabels.putIfAbsent(index, () => label);
        }
        walk(item.children);
      }
    }

    walk(book.toc);
    final Map<int, _StudioChapter> bySection = <int, _StudioChapter>{};
    for (final TtsPlanSentence s in plan.sentences) {
      final _StudioChapter chapter = bySection.putIfAbsent(
        s.section,
        () => _StudioChapter(
          s.section,
          tocLabels[s.section] ?? t.auto_chapter(n: bySection.length + 1),
        ),
      );
      chapter
        ..sentences += 1
        ..chars += s.text.length;
    }
    return bySection.values.toList()..sort(
      (_StudioChapter a, _StudioChapter b) => a.section.compareTo(b.section),
    );
  }

  Future<void> _pickPreset() async {
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: t.audiobook_studio_voice,
      icon: FushiIcons.voice,
      selected: _presetId,
      options: <FushiChoiceOption<String>>[
        for (final TtsVoicePreset p in _presets)
          FushiChoiceOption<String>(
            value: p.id,
            label: _presetName(p),
            subtitle: ttsProviderLabel(p.providerId),
          ),
      ],
    );
    if (picked == null || picked == _presetId || !mounted) return;
    final int? oldMax = _descriptor?.capabilities.maxInputLength;
    setState(() => _presetId = picked);
    // 计划切句只看单句长度上限：上限没变就不用重切。
    if (_descriptor?.capabilities.maxInputLength != oldMax) {
      await _rebuildPlan();
    }
  }

  Future<void> _openVoiceSettings() async {
    final int? oldMax = _descriptor?.capabilities.maxInputLength;
    await openTtsVoiceSettingsPage(context, _tts);
    if (!mounted) return;
    setState(_reloadPresets);
    if (_plan == null || _descriptor?.capabilities.maxInputLength != oldMax) {
      await _rebuildPlan();
    }
  }

  static String _presetName(TtsVoicePreset p) =>
      p.name.isEmpty ? ttsProviderLabel(p.providerId) : p.name;

  void _toggleSection(int section) {
    setState(() {
      _selectionTouched = true;
      if (!_selected.remove(section)) _selected.add(section);
    });
  }

  void _selectAll(bool all) {
    setState(() {
      _selectionTouched = true;
      _selected = all
          ? <int>{for (final _StudioChapter c in _chapters) c.section}
          : <int>{};
    });
  }

  Future<void> _editRule([int? index]) async {
    final TtsPronunciationRule? current = index == null ? null : _rules[index];
    final TtsPronunciationRule? edited =
        await showAppDialog<TtsPronunciationRule>(
          context: context,
          builder: (_) => _PronunciationRuleDialog(initial: current),
        );
    if (edited == null || !mounted) return;
    final List<TtsPronunciationRule> next = List<TtsPronunciationRule>.of(
      _rules,
    );
    if (index == null) {
      next.add(edited);
    } else {
      next[index] = edited;
    }
    await _saveRules(next);
  }

  Future<void> _deleteRule(int index) async {
    final List<TtsPronunciationRule> next = List<TtsPronunciationRule>.of(
      _rules,
    )..removeAt(index);
    await _saveRules(next);
  }

  Future<void> _saveRules(List<TtsPronunciationRule> next) async {
    setState(() => _rules = next);
    await _tts.pronunciation.save(next);
    if (mounted) await _rebuildPlan();
  }

  Future<void> _start() async {
    final TtsVoicePreset? preset = _preset;
    final ({EpubBookRow row, EpubBook book})? loaded = _loaded;
    if (preset == null || loaded == null || _selected.isEmpty) return;
    if (_hasAudiobook) {
      final bool confirmed = await showFushiConfirmDialog(
        context: context,
        title: t.audiobook_studio_title,
        message: t.audiobook_studio_replace_warning,
        confirmLabel: t.audiobook_studio_start,
        icon: FushiIcons.warning,
      );
      if (!confirmed || !mounted) return;
    }
    final bool all = _selected.length == _chapters.length;
    setState(() => _starting = true);
    try {
      await _queue.enqueue(
        bookKey: widget.bookKey,
        title: loaded.row.title.isEmpty ? loaded.book.title : loaded.row.title,
        presetId: preset.id,
        sections: all ? const <int>[] : (_selected.toList()..sort()),
        verify: _verify && isAsrSupported,
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _regenerate(TtsRenderJob job) async {
    if (_regenSelected.isEmpty) return;
    await _queue.enqueue(
      bookKey: job.bookKey,
      title: job.title,
      presetId: job.presetId,
      sections: job.sections,
      verify: job.verify,
      regenerate: _regenSelected.toList()..sort(),
    );
  }

  Future<void> _releasePreview() async {
    _previewUnpin?.call();
    _previewUnpin = null;
    await _previewSub?.cancel();
    _previewSub = null;
    final AudioPlayer? player = _previewPlayer;
    _previewPlayer = null;
    await player?.dispose();
  }

  /// 试听被标出的一句：用任务当时的声音，命中缓存直接播（缺了现合成补上）。
  Future<void> _preview(TtsRenderJob job, int sentence) async {
    final TtsBookPlan? plan = _plan;
    if (plan == null || sentence < 0 || sentence >= plan.length) return;
    final TtsVoicePreset? preset = _presets
        .where((TtsVoicePreset p) => p.id == job.presetId)
        .firstOrNull;
    final TtsProviderDescriptor? descriptor = preset == null
        ? null
        : _tts.registry[preset.providerId];
    if (preset == null || descriptor == null) {
      FushiToast.show(msg: t.audiobook_studio_failure_voice_missing);
      return;
    }
    _previewCancel?.cancel();
    await _releasePreview();
    if (!mounted) return;
    setState(() => _previewing = sentence);
    final String text = plan.sentences[sentence].spokenText;
    final TtsCancelToken cancel = TtsCancelToken();
    _previewCancel = cancel;
    final TtsProvider provider = descriptor.create(preset, _tts.host);
    try {
      final TtsAudioCache cache = await _tts.cache();
      final String key = TtsAudioCache.keyFor(
        descriptor.audioIdentity(preset),
        text,
      );
      final TtsCachedAudio audio = await cache.obtain(
        key,
        (String out) =>
            provider.synthesize(text, outputPath: out, cancel: cancel),
      );
      if (!mounted || cancel.isCancelled) return;
      // 播完才释放（桌面 media_kit 下 play() 发出命令即返回）。
      final AudioPlayer player = AudioPlayer();
      _previewPlayer = player;
      cache.pin(key);
      _previewUnpin = () => cache.unpin(key);
      _previewSub = player.playerStateStream.listen((PlayerState state) {
        if (state.processingState == ProcessingState.completed) {
          unawaited(_releasePreview());
        }
      });
      await player.setFilePath(audio.path);
      unawaited(player.play());
    } on TtsFailure catch (failure) {
      if (failure.code != TtsFailureCode.cancelled) {
        FushiToast.show(msg: ttsFailureText(failure));
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsStudio.preview', e, stack);
      FushiToast.show(msg: t.audiobook_studio_failure_internal);
    } finally {
      await provider.dispose();
      if (identical(_previewCancel, cancel)) _previewCancel = null;
      if (mounted && _previewing == sentence) {
        setState(() => _previewing = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    return SettingsKitScaffold(
      title: t.audiobook_studio_title,
      leadingIcon: FushiIcons.audiobook,
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => ListView(
            key: const ValueKey<String>('tts-studio'),
            controller: controller,
            padding: EdgeInsets.fromLTRB(
              inset,
              tokens.spacing.gap + MediaQuery.paddingOf(context).top,
              inset,
              tokens.spacing.page + bottomSafeInsetOf(context),
            ),
            children: <Widget>[
              if (_bookMissing)
                _notice(
                  'tts-studio-book-missing',
                  t.audiobook_studio_failure_book_missing,
                  FushiNoticeSeverity.error,
                ),
              ListenableBuilder(
                listenable: EngineListenable(_queue),
                builder: (BuildContext context, Widget? _) => _jobSection(),
              ),
              ..._voiceSection(),
              _chaptersSection(),
              AdaptiveSettingsSection(
                children: <Widget>[
                  AdaptiveSettingsSwitchRow(
                    key: const ValueKey<String>('tts-studio-verify'),
                    title: t.audiobook_studio_verify,
                    subtitle: isAsrSupported
                        ? t.audiobook_studio_verify_hint
                        : t.audiobook_studio_verify_unavailable,
                    value: _verify && isAsrSupported,
                    onChanged: isAsrSupported
                        ? (bool v) => setState(() => _verify = v)
                        : null,
                  ),
                ],
              ),
              _pronunciationSection(),
              if (_hasAudiobook)
                _notice(
                  'tts-studio-replace-warning',
                  t.audiobook_studio_replace_warning,
                  FushiNoticeSeverity.warning,
                ),
              ListenableBuilder(
                listenable: EngineListenable(_queue),
                builder: (BuildContext context, Widget? _) => _startButton(),
              ),
            ],
          ),
    );
  }

  Widget _notice(String key, String message, FushiNoticeSeverity severity) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FushiInlineNotice(
          key: ValueKey<String>(key),
          severity: severity,
          message: message,
        ),
      );

  List<Widget> _voiceSection() {
    final TtsVoicePreset? preset = _preset;
    final TtsProviderDescriptor? descriptor = _descriptor;
    return <Widget>[
      AdaptiveSettingsSection(
        key: const ValueKey<String>('tts-studio-voice'),
        title: t.audiobook_studio_voice,
        children: <Widget>[
          if (preset == null)
            AdaptiveSettingsRow(
              key: const ValueKey<String>('tts-studio-no-voice'),
              icon: FushiIcons.voice,
              showIcon: true,
              title: t.audiobook_studio_no_voice,
              onTap: () => unawaited(_openVoiceSettings()),
            )
          else
            AdaptiveSettingsRow(
              key: const ValueKey<String>('tts-studio-voice-pick'),
              icon: (descriptor?.capabilities.online ?? false)
                  ? FushiIcons.cloud
                  : FushiIcons.devices,
              showIcon: true,
              title: _presetName(preset),
              subtitle: _voiceUsable
                  ? ttsProviderLabel(preset.providerId)
                  : t.audiobook_tts_voice_incomplete,
              onTap: _presets.length > 1
                  ? () => unawaited(_pickPreset())
                  : null,
            ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('tts-studio-voice-settings'),
            icon: FushiIcons.settings,
            showIcon: true,
            title: t.audiobook_tts_voice_settings,
            onTap: () => unawaited(_openVoiceSettings()),
            trailing: isGlassDesign(context)
                ? const FushiAppleChevron()
                : FushiIcon(
                    FushiIcons.chevronRight,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
          ),
        ],
      ),
      if (descriptor != null &&
          descriptor.category == TtsProviderCategory.online)
        _notice(
          'tts-studio-online-warning',
          t.audiobook_studio_online_warning,
          FushiNoticeSeverity.warning,
        ),
    ];
  }

  Widget _chaptersSection() {
    if (_planFailed) {
      return _notice(
        'tts-studio-plan-failed',
        t.audiobook_studio_failure_internal,
        FushiNoticeSeverity.error,
      );
    }
    if (_planning || (_plan == null && !_bookMissing && _preset != null)) {
      return const Padding(
        key: ValueKey<String>('tts-studio-planning'),
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: FushiCircularProgressIndicator()),
      );
    }
    final TtsBookPlan? plan = _plan;
    if (plan == null) return const SizedBox.shrink();
    if (plan.isEmpty) {
      return _notice(
        'tts-studio-empty',
        t.audiobook_tts_empty_book,
        FushiNoticeSeverity.warning,
      );
    }
    int sentences = 0, chars = 0;
    for (final _StudioChapter c in _chapters) {
      if (!_selected.contains(c.section)) continue;
      sentences += c.sentences;
      chars += c.chars;
    }
    final Color secondary = fushiNeutralSecondaryForeground(context);
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('tts-studio-chapters'),
      title: t.audiobook_studio_chapters,
      titlePlacement: SettingsSectionTitlePlacement.inside,
      collapsible: true,
      summary: t.audiobook_studio_summary(sentences: sentences, chars: chars),
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
            vertical: 4,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.audiobook_studio_summary(
                    sentences: sentences,
                    chars: chars,
                  ),
                  key: const ValueKey<String>('tts-studio-summary'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: secondary),
                ),
              ),
              FushiTextButton(
                key: const ValueKey<String>('tts-studio-select-all'),
                onPressed: () => _selectAll(true),
                child: Text(t.audiobook_studio_select_all),
              ),
              FushiTextButton(
                key: const ValueKey<String>('tts-studio-select-none'),
                onPressed: () => _selectAll(false),
                child: Text(t.audiobook_studio_select_none),
              ),
            ],
          ),
        ),
        for (final _StudioChapter c in _chapters)
          AdaptiveSettingsRow(
            key: ValueKey<String>('tts-studio-chapter-${c.section}'),
            title: c.label,
            titleMaxLines: 3,
            subtitle: t.audiobook_studio_chapter_count(
              n: c.sentences,
              chars: c.chars,
            ),
            onTap: () => _toggleSection(c.section),
            // 整行可聚焦并以 Enter 切换；复选框只作展示，不另占一个焦点位。
            trailing: ExcludeFocus(
              child: FushiCheckbox(
                value: _selected.contains(c.section),
                onChanged: (_) => _toggleSection(c.section),
              ),
            ),
          ),
      ],
    );
  }

  Widget _pronunciationSection() => AdaptiveSettingsSection(
    key: const ValueKey<String>('tts-studio-pronunciation'),
    title: t.audiobook_studio_pronunciation,
    titlePlacement: SettingsSectionTitlePlacement.inside,
    collapsible: true,
    initiallyExpanded: false,
    summary: t.audiobook_studio_pronunciation_hint,
    children: <Widget>[
      for (int i = 0; i < _rules.length; i++)
        AdaptiveSettingsRow(
          key: ValueKey<String>('tts-studio-rule-$i'),
          title: '${_rules[i].written} → ${_rules[i].spoken}',
          onTap: () => unawaited(_editRule(i)),
          trailing: FushiIconButtonControl(
            key: ValueKey<String>('tts-studio-rule-$i-delete'),
            tooltip: t.dialog_delete,
            icon: const FushiIcon(FushiIcons.delete),
            onPressed: () => unawaited(_deleteRule(i)),
          ),
        ),
      AdaptiveSettingsRow(
        key: const ValueKey<String>('tts-studio-rule-add'),
        icon: FushiIcons.add,
        showIcon: true,
        title: t.audiobook_studio_pronunciation_add,
        subtitle: _rules.isEmpty ? t.audiobook_studio_pronunciation_hint : null,
        onTap: () => unawaited(_editRule()),
      ),
    ],
  );

  Widget _startButton() {
    final TtsRenderJob? job = _queue.latestFor(widget.bookKey);
    final bool busy = job != null && !job.isTerminal;
    final bool ready =
        !busy &&
        !_starting &&
        !_planning &&
        _voiceUsable &&
        _plan != null &&
        !_plan!.isEmpty &&
        _selected.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Center(
        child: FushiFilledButton.icon(
          key: const ValueKey<String>('tts-studio-start'),
          onPressed: ready ? () => unawaited(_start()) : null,
          icon: const FushiIcon(FushiIcons.play),
          label: Text(t.audiobook_studio_start),
        ),
      ),
    );
  }

  Widget _jobSection() {
    final TtsRenderJob? job = _queue.latestFor(widget.bookKey);
    if (job == null) return const SizedBox.shrink();
    if (_regenJobId != job.id) {
      _regenJobId = job.id;
      _regenSelected.clear();
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool retryable =
        job.status == TtsRenderJobStatus.failed ||
        job.status == TtsRenderJobStatus.cancelled;
    final Color statusColor = switch (job.status) {
      TtsRenderJobStatus.failed => fushiStatusColor(
        context,
        FushiStatusTone.error,
      ),
      TtsRenderJobStatus.done => fushiStatusColor(
        context,
        FushiStatusTone.success,
      ),
      _ => fushiNeutralSecondaryForeground(context),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsSection(
          key: const ValueKey<String>('tts-studio-job'),
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.rowHorizontal,
                12,
                tokens.spacing.rowHorizontal,
                12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    ttsRenderJobStatusText(job),
                    key: const ValueKey<String>('tts-studio-job-status'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(color: statusColor),
                  ),
                  if (!job.isTerminal) ...<Widget>[
                    const SizedBox(height: 10),
                    FushiLinearProgressIndicator(
                      value: ttsRenderJobProgress(job),
                    ),
                  ],
                ],
              ),
            ),
            if (!job.isTerminal)
              AdaptiveSettingsRow(
                key: const ValueKey<String>('tts-studio-job-cancel'),
                icon: FushiIcons.stop,
                showIcon: true,
                title: t.audiobook_studio_cancel,
                onTap: () => unawaited(_queue.cancel(job.id)),
              ),
            if (retryable)
              AdaptiveSettingsRow(
                key: const ValueKey<String>('tts-studio-job-retry'),
                icon: FushiIcons.refresh,
                showIcon: true,
                title: t.audiobook_studio_retry,
                onTap: () => unawaited(_queue.retry(job.id)),
              ),
          ],
        ),
        if (job.status == TtsRenderJobStatus.done) ..._flagsSection(job),
      ],
    );
  }

  List<Widget> _flagsSection(TtsRenderJob job) {
    if (!job.verified) {
      return <Widget>[
        _notice(
          'tts-studio-flags-unverified',
          t.audiobook_studio_flags_unverified,
          FushiNoticeSeverity.info,
        ),
      ];
    }
    if (job.flags.isEmpty) {
      return <Widget>[
        _notice(
          'tts-studio-flags-none',
          t.audiobook_studio_flags_none,
          FushiNoticeSeverity.success,
        ),
      ];
    }
    final TtsBookPlan? plan = _plan;
    return <Widget>[
      AdaptiveSettingsSection(
        key: const ValueKey<String>('tts-studio-flags'),
        title: t.audiobook_studio_flags_title(n: job.flags.length),
        children: <Widget>[
          for (final TtsRenderFlag flag in job.flags)
            AdaptiveSettingsRow(
              key: ValueKey<String>('tts-studio-flag-${flag.sentence}'),
              title: plan != null && flag.sentence < plan.length
                  ? plan.sentences[flag.sentence].text
                  : '#${flag.sentence + 1}',
              titleMaxLines: 4,
              subtitle:
                  '${t.audiobook_studio_heard(text: flag.heard)}'
                  ' · ${(flag.similarity * 100).round()}%',
              onTap: () => setState(() {
                if (!_regenSelected.remove(flag.sentence)) {
                  _regenSelected.add(flag.sentence);
                }
              }),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FushiIconButtonControl(
                    key: ValueKey<String>(
                      'tts-studio-flag-${flag.sentence}-play',
                    ),
                    tooltip: t.audiobook_studio_play,
                    icon: _previewing == flag.sentence
                        ? const SizedBox.square(
                            dimension: 18,
                            child: FushiCircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const FushiIcon(FushiIcons.play),
                    onPressed: plan == null || _previewing != null
                        ? null
                        : () => unawaited(_preview(job, flag.sentence)),
                  ),
                  ExcludeFocus(
                    child: FushiCheckbox(
                      value: _regenSelected.contains(flag.sentence),
                      onChanged: (_) => setState(() {
                        if (!_regenSelected.remove(flag.sentence)) {
                          _regenSelected.add(flag.sentence);
                        }
                      }),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Center(
          child: FushiFilledButton.icon(
            key: const ValueKey<String>('tts-studio-regenerate'),
            onPressed: _regenSelected.isEmpty
                ? null
                : () => unawaited(_regenerate(job)),
            icon: const FushiIcon(FushiIcons.refresh),
            label: Text(
              t.audiobook_studio_regenerate_selected(n: _regenSelected.length),
            ),
          ),
        ),
      ),
    ];
  }
}

class _PronunciationRuleDialog extends StatefulWidget {
  const _PronunciationRuleDialog({required this.initial});

  final TtsPronunciationRule? initial;

  @override
  State<_PronunciationRuleDialog> createState() =>
      _PronunciationRuleDialogState();
}

class _PronunciationRuleDialogState extends State<_PronunciationRuleDialog> {
  late final TextEditingController _written = TextEditingController(
    text: widget.initial?.written ?? '',
  );
  late final TextEditingController _spoken = TextEditingController(
    text: widget.initial?.spoken ?? '',
  );

  @override
  void dispose() {
    _written.dispose();
    _spoken.dispose();
    super.dispose();
  }

  bool get _valid =>
      _written.text.trim().isNotEmpty && _spoken.text.trim().isNotEmpty;

  void _submit() {
    if (!_valid) return;
    Navigator.of(context).pop(
      TtsPronunciationRule(
        written: _written.text.trim(),
        spoken: _spoken.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FushiAlertDialog(
    icon: const FushiDialogHeroIcon(icon: FushiIcons.dictionary),
    title: Text(
      widget.initial == null
          ? t.audiobook_studio_pronunciation_add
          : t.audiobook_studio_pronunciation,
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiTextFormFieldControl(
          key: const ValueKey<String>('tts-studio-rule-written'),
          controller: _written,
          autofocus: true,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: t.audiobook_studio_pronunciation_written,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        FushiTextFormFieldControl(
          key: const ValueKey<String>('tts-studio-rule-spoken'),
          controller: _spoken,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: t.audiobook_studio_pronunciation_spoken,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
          onFieldSubmitted: (_) => _submit(),
        ),
      ],
    ),
    actions: <Widget>[
      FushiDialogAction(
        label: t.dialog_cancel,
        onPressed: () => Navigator.of(context).pop(),
      ),
      FushiDialogAction(
        label: t.dialog_ok,
        kind: FushiDialogActionKind.primary,
        onPressed: _valid ? _submit : null,
      ),
    ],
  );
}
