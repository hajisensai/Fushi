/// 漫画有声制作台：声音指派（作品默认 / 叙述 / 角色 / 角色 × 类型，默认记到系列，可选
/// 只用于这一卷）、重试候选声音、生成本卷 / 按系列跑、未配音的台词（换配置重试 /
/// 指定声音 / 手动填写）、逐句试听与换种子重生成（保留 / 撤回）。
///
/// 生成与补回都排进制作队列（与小说有声书共用一个串行队列，GPU / 在线配额不打架）；
/// 单句换种子要立刻试听，不经队列，这一卷有任务在跑时不给点。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate.dart'
    show mergedMangaRoster;
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:just_audio/just_audio.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_manga_audio_assistant.dart'
    show findMangaNameReadings;
import 'package:fushi/src/media/audiobook/tts/irodori_voice_packs.dart';
import 'package:fushi/src/media/audiobook/tts/cast/cast_substitutions_page.dart';
import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_series_run.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_series_cast.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_line_editor.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/engine_listenable.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

Future<void> openMangaAudioStudioPage(
  BuildContext context, {
  required AppModel appModel,
  required String bookKey,
}) async {
  final NavigatorState navigator = Navigator.of(context);
  await TtsServices.of(appModel.prefsRepo).seedBuiltinVoiceIfUnset();
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) =>
          MangaAudioStudioPage(appModel: appModel, bookKey: bookKey),
    ),
  );
}

/// 角色 × 类型细分里可选的类型（叙述单独一行，不读没有声音）。
const List<CastLineKind> kMangaCharacterKinds = <CastLineKind>[
  CastLineKind.spoken,
  CastLineKind.monologue,
  CastLineKind.thought,
  CastLineKind.shout,
  CastLineKind.mutter,
];

String mangaCastKindLabel(CastLineKind kind) => switch (kind) {
  CastLineKind.narration => t.manga_audio_voice_narration,
  CastLineKind.monologue => t.manga_audio_kind_monologue,
  CastLineKind.thought => t.manga_audio_kind_thought,
  CastLineKind.spoken => t.manga_audio_kind_spoken,
  CastLineKind.shout => t.manga_audio_kind_shout,
  CastLineKind.mutter => t.manga_audio_kind_mutter,
  CastLineKind.skip => kind.wire,
};

/// 指派表里出现的角色：演出稿角色表 + 系列角色表 + 台词里出现过的说话人（按出现先后）。
List<String> mangaAssignableSpeakers(MangaAudioVolume volume) {
  final List<String> out = <String>[];
  void add(String name) {
    if (name.isNotEmpty && !out.contains(name)) out.add(name);
  }

  volume.series?.roster.keys.forEach(add);
  volume.script.roster.keys.forEach(add);
  for (final MangaScriptLine l in volume.script.lines) {
    if (l.kind.isAudible && l.kind != CastLineKind.narration) add(l.speaker);
  }
  return out;
}

class MangaAudioStudioPage extends StatefulWidget {
  const MangaAudioStudioPage({
    required this.appModel,
    required this.bookKey,
    super.key,
  });

  final AppModel appModel;
  final String bookKey;

  @override
  State<MangaAudioStudioPage> createState() => _MangaAudioStudioPageState();
}

class _MangaAudioStudioPageState extends State<MangaAudioStudioPage> {
  late final TtsServices _tts = TtsServices.of(widget.appModel.prefsRepo);
  late final TtsRenderQueue _queue = ttsRenderQueueFor(widget.appModel);

  MangaAudioVolume? _volume;
  bool _loading = true;
  MangaRenderManifest? _manifest;

  /// [_manifest] 的清单文件（登记的是外部导入的清单时在用户目录里，句文件与它同目录）。
  File? _manifestFile;

  /// 已出音频、但按当前替换表 / 人名读法该念的文字已变的句子（载入与改表后重算）。
  List<MangaSpokenTextChange> _readingChanges = const <MangaSpokenTextChange>[];
  CastVoicingLedger _ledger = CastVoicingLedger();
  List<TtsVoicePreset> _presets = const <TtsVoicePreset>[];
  String? _basePresetId;

  /// 改声音指派时只写这一卷（关 = 写系列，下一卷自动沿用）。
  bool _volumeOnly = false;

  /// 按系列跑（与小说共用，一次只跑一个）：进来时接上正在跑的那个。
  TtsSeriesRun? _seriesRun = activeTtsSeriesRun;

  String? _regenerating;
  AudioPlayer? _player;
  TtsRenderJobStatus? _lastStatus;

  @override
  void initState() {
    super.initState();
    // 声音预设 + 声音包（Irodori v4-Large，桌面端）。
    _presets = ttsProductionPresets(_tts, widget.appModel);
    final String? jobPreset = _queue.latestFor(widget.bookKey)?.presetId;
    final String? active = _tts.store.activePreset()?.id;
    _basePresetId = <String?>[jobPreset, active, _presets.firstOrNull?.id]
        .firstWhere(
          (String? id) =>
              id != null && _presets.any((TtsVoicePreset p) => p.id == id),
          orElse: () => null,
        );
    _lastStatus = _queue.latestFor(widget.bookKey)?.status;
    _queue.addListener(_onQueue);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _queue.removeListener(_onQueue);
    unawaited(_player?.dispose());
    super.dispose();
  }

  /// 本卷任务结束（完成 / 失败 / 取消）时重新读清单、账本与演出稿（补回会改它们）。
  void _onQueue() {
    final TtsRenderJobStatus? status = _queue.latestFor(widget.bookKey)?.status;
    final bool finished =
        _lastStatus != status &&
        status != null &&
        status != TtsRenderJobStatus.queued &&
        status != TtsRenderJobStatus.running;
    _lastStatus = status;
    if (finished && mounted) unawaited(_reload());
  }

  Future<void> _reload() async {
    final MangaAudioVolume? volume = await loadMangaAudioVolume(
      widget.appModel,
      widget.bookKey,
    );
    final File manifestFile = (await mangaAudioEditTarget(
      widget.appModel,
      widget.bookKey,
    )).manifestFile;
    final MangaRenderManifest? manifest = await MangaRenderManifest.load(
      manifestFile,
    );
    final CastVoicingLedger ledger = await ttsVoicingStoreFor(
      widget.appModel,
    ).load(widget.bookKey);
    if (!mounted) return;
    setState(() {
      _volume = volume;
      _manifest = manifest;
      _manifestFile = manifestFile;
      _ledger = ledger;
      _loading = false;
      if (volume?.series == null) _volumeOnly = true;
      _readingChanges = _computeReadingChanges();
    });
  }

  List<MangaSpokenTextChange> _computeReadingChanges() {
    final MangaAudioVolume? volume = _volume;
    final MangaRenderManifest? manifest = _manifest;
    if (volume == null || manifest == null) {
      return const <MangaSpokenTextChange>[];
    }
    return mangaSpokenTextChanges(
      script: volume.script,
      pageBlocks: volume.pageBlocks,
      manifest: manifest,
    );
  }

  TtsRenderJob? get _job => _queue.latestFor(widget.bookKey);

  bool get _busy {
    final TtsRenderJob? job = _job;
    return job != null && !job.isTerminal;
  }

  String _presetLabel(String? id) {
    if (id == null) return t.manga_audio_voice_inherit;
    return _presets.where((TtsVoicePreset p) => p.id == id).firstOrNull?.name ??
        id;
  }

  /// 指派写到哪张表：只这一卷 / 没有系列 → 演出稿；否则 → 系列档案。
  CastVoiceAssignment _target(MangaAudioVolume volume) =>
      _volumeOnly || volume.series == null
      ? volume.script.voices
      : volume.series!.voices;

  /// [edit] 已经改过本地这张表（界面即时反映）；写系列时在最新的系列档案上再做一次
  /// （串行的读-改-写，不拿本页的旧拷贝覆盖别处刚写的改动）。
  Future<void> _saveAssignment(
    MangaAudioVolume volume,
    void Function(CastVoiceAssignment target) edit,
  ) async {
    await saveMangaVoiceAssignment(
      widget.appModel,
      volume,
      seriesLevel: !_volumeOnly && volume.series != null,
      edit: edit,
    );
    if (mounted) setState(() {});
  }

  /// 选一个声音；`''` = 沿用上一级（清掉这一级），null = 取消。
  Future<String?> _pickVoice({
    required String title,
    String? message,
    String? selected,
    bool allowInherit = true,
  }) => showFushiChoiceDialog<String>(
    context: context,
    title: title,
    message: message,
    icon: FushiIcons.voice,
    selected: selected ?? (allowInherit ? '' : null),
    options: <FushiChoiceOption<String>>[
      if (allowInherit)
        FushiChoiceOption<String>(
          value: '',
          label: t.manga_audio_voice_inherit,
        ),
      for (final TtsVoicePreset preset in _presets)
        FushiChoiceOption<String>(value: preset.id, label: preset.name),
    ],
  );

  Future<void> _editBase() async {
    final String? picked = await _pickVoice(
      title: t.manga_audio_voice_base,
      selected: _basePresetId,
      allowInherit: false,
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() => _basePresetId = picked);
  }

  Future<void> _editLevel(
    String title,
    String? current,
    void Function(CastVoiceAssignment target, String? voice) apply,
  ) async {
    final MangaAudioVolume? volume = _volume;
    if (volume == null) return;
    final String? picked = await _pickVoice(title: title, selected: current);
    if (picked == null || !mounted) return;
    final String? voice = picked.isEmpty ? null : picked;
    void edit(CastVoiceAssignment target) => apply(target, voice);
    edit(_target(volume));
    await _saveAssignment(volume, edit);
  }

  Future<void> _editCharacterKind(String speaker) async {
    final CastLineKind? kind = await showFushiChoiceDialog<CastLineKind>(
      context: context,
      title: t.manga_audio_character_kind(
        name: ttsCastSpeakerLabel(speaker),
        kind: t.manga_audio_character_kinds,
      ),
      options: <FushiChoiceOption<CastLineKind>>[
        for (final CastLineKind k in kMangaCharacterKinds)
          FushiChoiceOption<CastLineKind>(
            value: k,
            label: mangaCastKindLabel(k),
          ),
      ],
    );
    if (kind == null || !mounted) return;
    final MangaAudioVolume? volume = _volume;
    if (volume == null) return;
    await _editLevel(
      t.manga_audio_character_kind(
        name: ttsCastSpeakerLabel(speaker),
        kind: mangaCastKindLabel(kind),
      ),
      _target(volume).byCharacterKind[speaker]?[kind],
      (CastVoiceAssignment target, String? voice) {
        final Map<CastLineKind, String> kinds = target.byCharacterKind
            .putIfAbsent(speaker, () => <CastLineKind, String>{});
        if (voice == null) {
          kinds.remove(kind);
        } else {
          kinds[kind] = voice;
        }
        if (kinds.isEmpty) target.byCharacterKind.remove(speaker);
      },
    );
  }

  Future<void> _toggleRetry(String presetId, bool on) async {
    final MangaAudioVolume? volume = _volume;
    if (volume == null) return;
    void edit(CastVoiceAssignment target) {
      target.retryVoices.remove(presetId);
      if (on) target.retryVoices.add(presetId);
    }

    edit(_target(volume));
    await _saveAssignment(volume, edit);
  }

  String _title(MangaAudioVolume volume) =>
      volume.row.title.isEmpty ? volume.bookKey : volume.row.title;

  Future<void> _generate() async {
    final MangaAudioVolume? volume = _volume;
    final String? base = _basePresetId;
    if (volume == null || base == null || _busy) return;
    try {
      await _queue.enqueue(
        bookKey: volume.bookKey,
        title: _title(volume),
        presetId: base,
        kind: TtsRenderJobKind.manga,
      );
    } on TtsRenderRejected {
      FushiToast.show(
        msg: t.manga_audio_package_error_importing,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (mounted) setState(() {});
  }

  /// 按系列跑（与小说同一个 [TtsSeriesRun]）：逐卷看图标注没标过的页，再排整卷
  /// 生成任务；某卷标注没做完就不排它。
  Future<void> _startSeriesRun() async {
    final MangaAudioVolume? volume = _volume;
    final String? base = _basePresetId;
    final String? seriesKey = volume?.seriesKey;
    if (volume == null || seriesKey == null) return;
    final TtsSeriesRunMode? mode =
        await showFushiChoiceDialog<TtsSeriesRunMode>(
          context: context,
          title: t.audiobook_studio_series_run,
          message: t.audiobook_studio_series_run_hint,
          icon: FushiIcons.playlist,
          options: <FushiChoiceOption<TtsSeriesRunMode>>[
            FushiChoiceOption<TtsSeriesRunMode>(
              value: TtsSeriesRunMode.both,
              label: t.audiobook_studio_series_run_both,
            ),
            FushiChoiceOption<TtsSeriesRunMode>(
              value: TtsSeriesRunMode.annotate,
              label: t.audiobook_studio_series_run_annotate,
            ),
            FushiChoiceOption<TtsSeriesRunMode>(
              value: TtsSeriesRunMode.render,
              label: t.audiobook_studio_series_run_render,
            ),
          ],
        );
    if (mode == null || !mounted) return;
    if (mode.renders && base == null) {
      FushiToast.show(msg: t.audiobook_studio_no_voice);
      return;
    }
    final List<String> volumes = await mangaSeriesVolumeKeys(
      widget.appModel,
      seriesKey,
    );
    if (!mounted) return;
    final TtsSeriesRun run = TtsSeriesRun.start(
      appModel: widget.appModel,
      seriesKey: seriesKey,
      books: volumes,
      mode: mode,
      kind: TtsRenderJobKind.manga,
      render: (
        presetId: base ?? '',
        verify: false,
        pausePreset: 'standard',
        normalizeLoudness: false,
      ),
    );
    setState(() => _seriesRun = run);
    unawaited(
      run.done.then((_) async {
        // 按系列跑离开制作台照跑；结果是全局提示，页面不在也要弹。
        FushiToast.show(
          msg:
              run.failures.any(
                (TtsSeriesRunFailure f) =>
                    f.code == kTtsSeriesRunMangaIncomplete,
              )
              ? '${t.manga_audio_series_run_failed(queued: run.queued.length, failed: run.failures.length)}\n'
                    '${t.manga_audio_series_run_annotate_incomplete}'
              : t.manga_audio_series_run_failed(
                  queued: run.queued.length,
                  failed: run.failures.length,
                ),
        );
        if (mounted) await _reload();
      }),
    );
  }

  /// 系列用词替换表（用于 AI 标注文字、朗读与字幕；源文件与手填念法不变）。
  Future<void> _editSubstitutions(MangaAudioVolume volume) async {
    final SeriesCastProfile? series = volume.series;
    final String? seriesKey = volume.seriesKey;
    if (series == null || seriesKey == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CastSubstitutionsPage(
          seriesTitle: series.title.isEmpty ? seriesKey : series.title,
          initial: series.substitutions,
          roster: mergedMangaRoster(
            series: series.roster,
            volume: volume.script.roster,
          ).values,
          findReadings: (List<CastTextSubstitution> names) =>
              findMangaNameReadings(
                widget.appModel,
                bookKey: volume.bookKey,
                seriesKey: seriesKey,
                workTitle: series.title.isNotEmpty
                    ? series.title
                    : volume.row.title,
                names: names,
                substitutions:
                    volume.series?.substitutions ?? series.substitutions,
              ),
          save: (List<CastTextSubstitution> next) async {
            final SeriesCastProfile fresh =
                await seriesCastStoreFor(widget.appModel).update(
                  seriesKey,
                  (SeriesCastProfile p) => p.substitutions
                    ..clear()
                    ..addAll(next),
                );
            if (fresh.title.isEmpty) fresh.title = series.title;
            volume.series = fresh;
            volume.script.series = fresh.voices;
            volume.script.substitutions = fresh.substitutions;
            return fresh.substitutions;
          },
        ),
      ),
    );
    if (mounted) setState(() => _readingChanges = _computeReadingChanges());
  }

  Widget _seriesSection(BuildContext context, MangaAudioVolume volume) {
    final TtsSeriesRun? run = _seriesRun;
    if (run == null) return _seriesSectionContent(context, volume);
    return ListenableBuilder(
      listenable: run,
      builder: (BuildContext context, Widget? _) =>
          _seriesSectionContent(context, volume),
    );
  }

  Widget _seriesSectionContent(BuildContext context, MangaAudioVolume volume) {
    final SeriesCastProfile? series = volume.series;
    final TtsSeriesRun? run = _seriesRun;
    final bool running = run != null && run.running;
    final double inset = FushiDesignTokens.of(context).spacing.rowHorizontal;
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('manga-audio-series'),
      title: t.audiobook_studio_series_title,
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('manga-audio-substitutions'),
          icon: FushiIcons.swap,
          showIcon: true,
          title: t.tts_substitutions_title,
          subtitle: castSubstitutionsSummary(
            series?.substitutions ?? const <CastTextSubstitution>[],
          ),
          onTap: series == null
              ? null
              : () => unawaited(_editSubstitutions(volume)),
        ),
        AdaptiveSettingsRow(
          key: const ValueKey<String>('manga-audio-series-run'),
          icon: FushiIcons.playlist,
          showIcon: true,
          title: t.audiobook_studio_series_run,
          subtitle: running
              ? t.audiobook_studio_series_run_progress(
                  done: run.index + 1,
                  total: run.books.length,
                  title: run.title,
                )
              : t.audiobook_studio_series_run_hint,
          onTap: running ? null : () => unawaited(_startSeriesRun()),
        ),
        if (running) ...<Widget>[
          Padding(
            key: const ValueKey<String>('manga-audio-series-run-progress'),
            padding: EdgeInsets.fromLTRB(inset, 0, inset, 12),
            child: FushiLinearProgressIndicator(
              value: run.books.isEmpty
                  ? null
                  : ((run.index +
                                (run.annotateTotal <= 0
                                    ? 0
                                    : run.annotateDone / run.annotateTotal)) /
                            run.books.length)
                        .clamp(0.0, 1.0),
            ),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('manga-audio-series-run-cancel'),
            icon: FushiIcons.stop,
            showIcon: true,
            title: t.audiobook_studio_cancel,
            onTap: run.cancelled ? null : run.cancel,
          ),
        ],
      ],
    );
  }

  /// 排一个补回任务；这一卷已有任务在跑时不排（队列会把请求并进那个任务而丢掉）。
  Future<void> _backfill(List<TtsRenderLineRequest> requests) async {
    final MangaAudioVolume? volume = _volume;
    final String? base = _basePresetId;
    if (volume == null || base == null || requests.isEmpty) return;
    if (_busy) {
      FushiToast.show(msg: t.manga_audio_job_busy);
      return;
    }
    try {
      await _queue.enqueue(
        bookKey: volume.bookKey,
        title: _title(volume),
        presetId: base,
        kind: TtsRenderJobKind.manga,
        lineRequests: requests,
      );
    } on TtsRenderRejected {
      FushiToast.show(
        msg: t.manga_audio_package_error_importing,
        severity: ToastSeverity.error,
      );
      return;
    }
    FushiToast.show(msg: t.manga_audio_backfill_queued);
    if (mounted) setState(() {});
  }

  /// 「切配置重试」能不能换到新声音（候选都失败过就不能）。
  bool _hasRetryVoice(MangaAudioVolume volume, String lineId) {
    final MangaScriptLine? line = volume.script.lineById(lineId);
    final String? base = _basePresetId;
    if (line == null || base == null) return false;
    final CastVoicingEntry entry =
        _ledger.entries[lineId] ??
        CastVoicingEntry(lineId: lineId, placeholderMs: 0);
    return entry.nextRetryVoice(
          mangaResolvedVoice(volume.script, line, base),
          volume.script.retryVoices,
        ) !=
        null;
  }

  Future<void> _retryAll() async {
    final MangaAudioVolume? volume = _volume;
    if (volume == null) return;
    final List<TtsRenderLineRequest> requests = <TtsRenderLineRequest>[
      for (final String id in _ledger.entries.keys)
        if (_hasRetryVoice(volume, id))
          TtsRenderLineRequest(lineId: id, nextRetryVoice: true),
    ];
    if (requests.isEmpty) {
      FushiToast.show(msg: t.manga_audio_no_retry_voice);
      return;
    }
    await _backfill(requests);
  }

  Future<void> _unvoicedActions(MangaRenderedLine line) async {
    final MangaAudioVolume? volume = _volume;
    if (volume == null) return;
    final String? action = await showFushiChoiceDialog<String>(
      context: context,
      title: t.manga_audio_section_unvoiced,
      message: line.text,
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(
          value: 'next',
          label: t.manga_audio_retry_next,
          icon: FushiIcons.refresh,
        ),
        FushiChoiceOption<String>(
          value: 'voice',
          label: t.manga_audio_pick_voice,
          icon: FushiIcons.voice,
        ),
        FushiChoiceOption<String>(
          value: 'say',
          label: t.manga_audio_type_text,
          icon: FushiIcons.edit,
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'next':
        if (!_hasRetryVoice(volume, line.lineId)) {
          FushiToast.show(msg: t.manga_audio_no_retry_voice);
          return;
        }
        await _backfill(<TtsRenderLineRequest>[
          TtsRenderLineRequest(lineId: line.lineId, nextRetryVoice: true),
        ]);
      case 'voice':
        final String? voice = await _pickVoice(
          title: t.manga_audio_pick_voice,
          message: line.text,
          allowInherit: false,
        );
        if (voice == null || voice.isEmpty || !mounted) return;
        await _backfill(<TtsRenderLineRequest>[
          TtsRenderLineRequest(lineId: line.lineId, voice: voice),
        ]);
      case 'say':
        final String? typed = await showFushiTextInputDialog(
          context: context,
          title: t.manga_audio_type_text,
          initialValue: line.text,
          labelText: t.manga_audio_type_text_label,
          icon: FushiIcons.edit,
        );
        if (typed == null || typed.trim().isEmpty || !mounted) return;
        await _backfill(<TtsRenderLineRequest>[
          TtsRenderLineRequest(lineId: line.lineId, say: typed.trim()),
        ]);
    }
  }

  Future<void> _play(String path) async {
    final AudioPlayer player = _player ??= AudioPlayer();
    try {
      await player.stop();
      await player.setFilePath(path);
      await player.play();
    } on Exception catch (e, stack) {
      ErrorLogService.instance.log('MangaAudioStudio.preview', e, stack);
    }
  }

  String _linePath(MangaRenderedLine line) => p.join(
    (_manifestFile ?? mangaRenderManifestFile(widget.appModel, widget.bookKey))
        .parent
        .path,
    line.file,
  );

  Future<void> _lineActions(MangaRenderedLine line) async {
    final String? action = await showFushiChoiceDialog<String>(
      context: context,
      title: t.manga_audio_line_page(
        page: line.page + 1,
        speaker: ttsCastSpeakerLabel(line.speaker),
      ),
      message: line.text,
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(
          value: 'play',
          label: t.manga_audio_preview,
          icon: FushiIcons.play,
        ),
        FushiChoiceOption<String>(
          value: 'regen',
          label: t.manga_audio_regenerate,
          icon: FushiIcons.shuffle,
          enabled: !_busy && _regenerating == null,
        ),
      ],
    );
    if (action == null || !mounted) return;
    if (action == 'play') {
      await _play(_linePath(line));
    } else {
      await _regenerate(line);
    }
  }

  /// 换种子重生成这一句并试听、保留或撤回（与阅读页「编辑这句配音」同一份流程）。
  Future<void> _regenerate(MangaRenderedLine line) async {
    final MangaAudioVolume? volume = _volume;
    final String? base = _basePresetId;
    if (volume == null || base == null || _busy) return;
    setState(() => _regenerating = line.lineId);
    try {
      await _player?.stop();
      if (!mounted) return;
      await regenerateMangaLineWithReview(
        context,
        host: widget.appModel,
        volume: volume,
        lineId: line.lineId,
        voice: base,
      );
    } finally {
      if (mounted) setState(() => _regenerating = null);
    }
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    return SettingsKitScaffold(
      title: t.manga_audio_studio_title,
      leadingIcon: FushiIcons.voice,
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => ListenableBuilder(
            listenable: EngineListenable(_queue),
            builder: (BuildContext context, Widget? _) {
              final List<Widget> head = _headSections(context);
              final List<MangaRenderedLine> lines =
                  _manifest?.lines ?? const <MangaRenderedLine>[];
              return FushiEntranceScope(
                replayKey: _loading,
                child: ListView.builder(
                  key: const ValueKey<String>('manga-audio-studio-list'),
                  controller: controller,
                  padding: EdgeInsets.fromLTRB(
                    inset,
                    tokens.spacing.gap + MediaQuery.paddingOf(context).top,
                    inset,
                    tokens.spacing.page + bottomSafeInsetOf(context),
                  ),
                  itemCount: head.length + lines.length,
                  itemBuilder: fushiStaggeredItemBuilder((
                    BuildContext context,
                    int index,
                  ) {
                    if (index < head.length) return head[index];
                    return _lineRow(lines[index - head.length]);
                  }),
                ),
              );
            },
          ),
    );
  }

  List<Widget> _headSections(BuildContext context) {
    if (_loading) {
      return <Widget>[const FushiLinearProgressIndicator(value: null)];
    }
    final MangaAudioVolume? volume = _volume;
    if (volume == null) {
      return <Widget>[
        AdaptiveSettingsSection(
          children: <Widget>[
            AdaptiveSettingsRow(
              key: const ValueKey<String>('manga-audio-unavailable'),
              icon: FushiIcons.warning,
              showIcon: true,
              title: t.manga_audio_volume_unavailable,
              titleMaxLines: 4,
            ),
          ],
        ),
      ];
    }
    return <Widget>[
      _summarySection(volume),
      _jobSection(context, volume),
      if (volume.seriesKey != null) _seriesSection(context, volume),
      _voiceSection(volume),
      _retrySection(volume),
      _unvoicedSection(volume),
      if (_readingChanges.isNotEmpty) _readingChangesSection(),
      AdaptiveSettingsSection(
        key: const ValueKey<String>('manga-audio-lines-header'),
        title: t.manga_audio_section_lines,
        children: <Widget>[
          if (_manifest == null)
            AdaptiveSettingsRow(title: t.manga_audio_lines_empty),
        ],
      ),
    ];
  }

  Widget _summarySection(MangaAudioVolume volume) {
    final String? blocker = mangaRenderBlocker(volume);
    final String? seriesKey = volume.seriesKey;
    final String seriesTitle = volume.series?.title ?? '';
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('manga-audio-summary'),
      children: <Widget>[
        AdaptiveSettingsRow(
          icon: FushiIcons.audiobook,
          showIcon: true,
          title: _title(volume),
          subtitle: t.manga_audio_summary(
            lines: volume.script.audibleLines.length,
            pages: volume.payload.images.length,
          ),
        ),
        AdaptiveSettingsRow(
          icon: FushiIcons.person,
          showIcon: true,
          title: seriesKey == null
              ? t.manga_audio_series_none
              : t.manga_audio_series_label(
                  name: seriesTitle.isEmpty ? seriesKey : seriesTitle,
                ),
          titleMaxLines: 3,
        ),
        if (blocker != null)
          AdaptiveSettingsRow(
            key: const ValueKey<String>('manga-audio-blocker'),
            icon: FushiIcons.warning,
            showIcon: true,
            title: ttsRenderFailureText(blocker),
            titleMaxLines: 4,
          ),
      ],
    );
  }

  Widget _jobSection(BuildContext context, MangaAudioVolume volume) {
    final TtsRenderJob? job = _job;
    final bool ready =
        mangaRenderBlocker(volume) == null && _basePresetId != null && !_busy;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('manga-audio-job'),
      children: <Widget>[
        if (job != null)
          AdaptiveSettingsRow(
            key: const ValueKey<String>('manga-audio-job-status'),
            title: ttsRenderJobStatusText(job),
            subtitle: _manifest == null
                ? null
                : t.audiobook_studio_cast_lines(n: _manifest!.lines.length),
            trailing: job.isTerminal
                ? null
                : FushiTextButton(
                    onPressed: () => unawaited(_queue.cancel(job.id)),
                    child: Text(t.dialog_cancel),
                  ),
          ),
        if (job != null && !job.isTerminal)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
            child: FushiLinearProgressIndicator(
              value: ttsRenderJobProgress(job),
            ),
          ),
        Padding(
          padding: EdgeInsets.all(tokens.spacing.gap),
          child: Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap / 2,
            children: <Widget>[
              FushiPressScale(
                enabled: ready,
                child: FushiFilledButton.icon(
                  key: const ValueKey<String>('manga-audio-generate'),
                  onPressed: ready ? () => unawaited(_generate()) : null,
                  icon: const FushiIcon(FushiIcons.play),
                  label: Text(t.manga_audio_generate),
                ),
              ),
              if (volume.seriesKey != null)
                FushiPressScale(
                  enabled: !(_seriesRun?.running ?? false),
                  child: FushiOutlinedButton.icon(
                    key: const ValueKey<String>('manga-audio-generate-series'),
                    onPressed: (_seriesRun?.running ?? false)
                        ? null
                        : () => unawaited(_startSeriesRun()),
                    icon: const FushiIcon(FushiIcons.audiobook),
                    label: Text(t.manga_audio_generate_series),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _voiceSection(MangaAudioVolume volume) {
    final CastVoiceAssignment target = _target(volume);
    final List<String> speakers = mangaAssignableSpeakers(volume);
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('manga-audio-voices'),
      title: t.manga_audio_section_voices,
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('manga-audio-voice-base'),
          icon: FushiIcons.voice,
          showIcon: true,
          title: t.manga_audio_voice_base,
          subtitle:
              '${_basePresetId == null ? '—' : _presetLabel(_basePresetId)}'
              ' · ${t.manga_audio_voice_base_hint}',
          onTap: () => unawaited(_editBase()),
        ),
        if (volume.series != null)
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('manga-audio-scope'),
            title: t.manga_audio_scope_volume,
            subtitle: t.manga_audio_scope_volume_hint,
            value: _volumeOnly,
            onChanged: (bool v) => setState(() => _volumeOnly = v),
          ),
        AdaptiveSettingsRow(
          key: const ValueKey<String>('manga-audio-voice-default'),
          title: t.manga_audio_voice_default,
          subtitle: _presetLabel(target.defaultVoice),
          onTap: () => unawaited(
            _editLevel(
              t.manga_audio_voice_default,
              target.defaultVoice,
              (CastVoiceAssignment a, String? v) => a.defaultVoice = v,
            ),
          ),
        ),
        AdaptiveSettingsRow(
          key: const ValueKey<String>('manga-audio-voice-narration'),
          title: t.manga_audio_voice_narration,
          subtitle: _presetLabel(target.narrationVoice),
          onTap: () => unawaited(
            _editLevel(
              t.manga_audio_voice_narration,
              target.narrationVoice,
              (CastVoiceAssignment a, String? v) => a.narrationVoice = v,
            ),
          ),
        ),
        for (final String speaker in speakers) ...<Widget>[
          AdaptiveSettingsRow(
            key: ValueKey<String>('manga-audio-voice-char-$speaker'),
            icon: FushiIcons.person,
            showIcon: true,
            title: ttsCastSpeakerLabel(speaker),
            subtitle: _presetLabel(target.byCharacter[speaker]),
            onTap: () => unawaited(
              _editLevel(
                ttsCastSpeakerLabel(speaker),
                target.byCharacter[speaker],
                (CastVoiceAssignment a, String? v) {
                  if (v == null) {
                    a.byCharacter.remove(speaker);
                  } else {
                    a.byCharacter[speaker] = v;
                  }
                },
              ),
            ),
            trailing: FushiTextButton(
              onPressed: () => unawaited(_editCharacterKind(speaker)),
              child: Text(t.manga_audio_character_kinds),
            ),
          ),
          for (final MapEntry<CastLineKind, String> e
              in (target.byCharacterKind[speaker] ??
                      const <CastLineKind, String>{})
                  .entries)
            AdaptiveSettingsRow(
              key: ValueKey<String>(
                'manga-audio-voice-char-$speaker-${e.key.wire}',
              ),
              title: t.manga_audio_character_kind(
                name: ttsCastSpeakerLabel(speaker),
                kind: mangaCastKindLabel(e.key),
              ),
              subtitle: _presetLabel(e.value),
              onTap: () => unawaited(_editCharacterKind(speaker)),
            ),
        ],
      ],
    );
  }

  Widget _retrySection(MangaAudioVolume volume) {
    final CastVoiceAssignment target = _target(volume);
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('manga-audio-retry'),
      title: t.manga_audio_retry_voices,
      summary: target.retryVoices.isEmpty
          ? t.manga_audio_retry_voices_none
          : target.retryVoices.map(_presetLabel).join(' → '),
      collapsible: true,
      initiallyExpanded: false,
      children: <Widget>[
        AdaptiveSettingsRow(
          title: t.manga_audio_retry_voices_hint,
          titleMaxLines: 3,
        ),
        for (final TtsVoicePreset preset in _presets)
          AdaptiveSettingsSwitchRow(
            key: ValueKey<String>('manga-audio-retry-${preset.id}'),
            title: preset.name,
            subtitle: target.retryVoices.contains(preset.id)
                ? '#${target.retryVoices.indexOf(preset.id) + 1}'
                : null,
            value: target.retryVoices.contains(preset.id),
            onChanged: (bool v) => unawaited(_toggleRetry(preset.id, v)),
          ),
      ],
    );
  }

  Widget _unvoicedSection(MangaAudioVolume volume) {
    final List<MangaRenderedLine> unvoiced = <MangaRenderedLine>[
      for (final MangaRenderedLine l
          in _manifest?.lines ?? const <MangaRenderedLine>[])
        if (l.placeholder) l,
    ];
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('manga-audio-unvoiced'),
      title: '${t.manga_audio_section_unvoiced} (${unvoiced.length})',
      children: <Widget>[
        if (unvoiced.isEmpty)
          AdaptiveSettingsRow(title: t.manga_audio_unvoiced_empty)
        else
          AdaptiveSettingsRow(
            key: const ValueKey<String>('manga-audio-retry-all'),
            icon: FushiIcons.refresh,
            showIcon: true,
            title: t.manga_audio_retry_all,
            onTap: _busy ? null : () => unawaited(_retryAll()),
          ),
        for (final MangaRenderedLine line in unvoiced)
          AdaptiveSettingsRow(
            key: ValueKey<String>('manga-audio-unvoiced-${line.lineId}'),
            icon: FushiIcons.warning,
            showIcon: true,
            title: line.text.isEmpty ? line.lineId : line.text,
            titleMaxLines: 4,
            subtitle: _attemptText(line.lineId),
            onTap: _busy ? null : () => unawaited(_unvoicedActions(line)),
          ),
      ],
    );
  }

  /// 读法变了的台词（拍板 TW9ete_FHX）：系列人名读法 / 用词替换改过后，已出音频还按
  /// 旧文字念的句子。一键排补回（按当前表重新合成，声音与种子不变）。
  Widget _readingChangesSection() {
    final List<MangaSpokenTextChange> changes = _readingChanges;
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('manga-audio-reading-changes'),
      title: '${t.manga_audio_section_reading_changes} (${changes.length})',
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('manga-audio-reading-changes-regenerate'),
          icon: FushiIcons.refresh,
          showIcon: true,
          title: t.manga_audio_reading_changes_regenerate,
          onTap: _busy
              ? null
              : () => unawaited(
                  _backfill(<TtsRenderLineRequest>[
                    for (final MangaSpokenTextChange c in changes)
                      TtsRenderLineRequest(lineId: c.rendered.lineId),
                  ]),
                ),
        ),
        for (final MangaSpokenTextChange c in changes)
          AdaptiveSettingsRow(
            key: ValueKey<String>(
              'manga-audio-reading-change-${c.rendered.lineId}',
            ),
            icon: FushiIcons.voice,
            showIcon: true,
            title: c.rendered.text.isEmpty
                ? c.rendered.lineId
                : c.rendered.text,
            titleMaxLines: 4,
            subtitle: t.manga_audio_reading_changes_now(spoken: c.spoken),
            subtitleMaxLines: 4,
            onTap: () => unawaited(_lineActions(c.rendered)),
          ),
      ],
    );
  }

  String? _attemptText(String lineId) {
    final CastVoicingAttempt? last = _ledger.entries[lineId]?.lastAttempt;
    if (last == null) return null;
    final String voice = last.voice == null
        ? '—'
        : last.voice!.startsWith(kMangaClipVoicePrefix)
        ? t.manga_audio_failure_clip_missing
        : _presetLabel(last.voice);
    return t.manga_audio_unvoiced_attempt(
      reason: ttsRenderFailureText(last.code),
      voice: voice,
    );
  }

  Widget _lineRow(MangaRenderedLine line) {
    final bool regenerating = _regenerating == line.lineId;
    return AdaptiveSettingsRow(
      key: ValueKey<String>('manga-audio-line-${line.lineId}'),
      title: line.text.isEmpty ? line.lineId : line.text,
      titleMaxLines: 4,
      subtitle: t.manga_audio_line_page(
        page: line.page + 1,
        speaker: ttsCastSpeakerLabel(line.speaker),
      ),
      trailing: regenerating
          ? const SizedBox.square(
              dimension: 20,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            )
          : line.placeholder
          ? const FushiIcon(FushiIcons.warning)
          : null,
      onTap: () => unawaited(_lineActions(line)),
    );
  }
}
