/// 「制作有声书」工作台：选声音 / 章节 / 校对 / 发音词典 → 排进制作队列；
/// 看本书最近一个任务的进度与校对结果，勾选被标出的句子重新生成。
///
/// 句序必须与制作流程同一口径，计划一律经 [buildStudioPlan] 构建。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_pause.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart' show XFile;

import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/media/audiobook/tts/studio/tts_audiobook_export.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_annotator.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_lines_page.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_layout.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/ai_settings_route.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart'
    show SettingsSectionFooter;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/engine_listenable.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/utils.dart';

export 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';

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

  /// 选角表（多声优）。标注进行中不许手改（标注结果整份换回来会盖掉手改）。
  TtsCast _cast = TtsCast();
  bool _annotating = false;
  bool _annotateCancelled = false;
  int _annotateDone = 0;
  int _annotateTotal = 0;
  String? _annotateFailureCode;
  String? _annotateFailureText;

  /// 标注阶段（`roster` / `lines`）；标注器不报阶段时为 null。
  String? _annotatePhase;

  /// 成品选项：沿用本书上一次任务的选择。
  TtsPausePreset _pause = TtsPausePreset.standard;
  bool _loudness = true;

  bool _exporting = false;
  double? _exportProgress;

  /// 当前显示的步骤：本书已有任务时直接落到「结果」，否则从「内容」开始。
  late TtsStudioStep _step = _queue.latestFor(widget.bookKey) == null
      ? TtsStudioStep.content
      : TtsStudioStep.result;

  @override
  void initState() {
    super.initState();
    final TtsRenderJob? last = _queue.latestFor(widget.bookKey);
    if (last != null) {
      _pause = TtsPausePreset.parse(last.pausePreset);
      _loudness = last.normalizeLoudness;
    }
    _reloadPresets(preferJobPreset: true);
    _rules = _tts.pronunciation.load();
    unawaited(_loadBook());
  }

  @override
  void dispose() {
    _annotateCancelled = true;
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
    final TtsCast cast = await _loadCast();
    if (!mounted) return;
    setState(() {
      _cast = cast;
      _loaded = loaded;
      _bookMissing = loaded == null;
      _hasAudiobook = existing != null;
    });
    await _rebuildPlan();
  }

  Future<void> _rebuildPlan() async {
    final ({EpubBookRow row, EpubBook book})? loaded = _loaded;
    if (loaded == null) return;
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
    setState(() => _presetId = picked);
  }

  Future<void> _openVoiceSettings() async {
    await openTtsVoiceSettingsPage(context, _tts);
    if (!mounted) return;
    setState(_reloadPresets);
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
        pausePreset: _pause.name,
        normalizeLoudness: _loudness,
      );
      // 排进队列后切到「结果」看进度。
      if (mounted) setState(() => _step = TtsStudioStep.result);
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
      pausePreset: job.pausePreset,
      normalizeLoudness: job.normalizeLoudness,
    );
  }

  /// 读不出的选角表按空表处理（记日志），不挡制作台其它功能。
  Future<TtsCast> _loadCast() async {
    try {
      return await ttsCastStoreFor(widget.appModel).load(widget.bookKey);
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsStudio.loadCast', e, stack);
      return TtsCast();
    }
  }

  Future<void> _saveCast() async {
    try {
      await ttsCastStoreFor(widget.appModel).save(widget.bookKey, _cast);
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsStudio.saveCast', e, stack);
      FushiToast.show(msg: t.audiobook_studio_failure_internal);
    }
  }

  /// 默认声音或任一角色的声音走在线服务。
  bool get _usesOnlineVoice {
    final Set<String> ids = <String>{
      if (_presetId case final String id) id,
      ..._cast.voices.values,
    };
    for (final TtsVoicePreset p in _presets) {
      if (!ids.contains(p.id)) continue;
      if (_tts.registry[p.providerId]?.category == TtsProviderCategory.online) {
        return true;
      }
    }
    return false;
  }

  Future<void> _annotate({required bool again}) async {
    final TtsBookPlan? plan = _plan;
    if (plan == null || _selected.isEmpty || _annotating) return;
    if (again) {
      final bool confirmed = await showFushiConfirmDialog(
        context: context,
        title: t.audiobook_studio_cast_reannotate,
        message: t.audiobook_studio_cast_reannotate_confirm,
        confirmLabel: t.audiobook_studio_cast_reannotate,
        icon: FushiIcons.refresh,
      );
      if (!confirmed || !mounted) return;
    }
    setState(() {
      _annotating = true;
      _annotateCancelled = false;
      _annotateDone = 0;
      _annotateTotal = 0;
      _annotateFailureCode = null;
      _annotateFailureText = null;
      _annotatePhase = null;
    });
    TtsCast? result;
    try {
      result = await annotateTtsCast(
        appModel: widget.appModel,
        bookKey: widget.bookKey,
        plan: plan,
        sections: Set<int>.of(_selected),
        skipAnnotated: !again,
        // 报了阶段就按阶段内进度显示；总进度只在没有阶段信息时兜底。
        onProgress: (int done, int total) {
          if (!mounted || _annotatePhase != null) return;
          setState(() {
            _annotateDone = done;
            _annotateTotal = total;
          });
        },
        onPhase: (String phase, int done, int total) {
          if (!mounted) return;
          setState(() {
            _annotatePhase = phase;
            _annotateDone = done;
            _annotateTotal = total;
          });
        },
        isCancelled: () => _annotateCancelled,
      );
    } on TtsCastAnnotateFailure catch (failure) {
      _annotateFailureCode = failure.code;
      _annotateFailureText = ttsCastAnnotateFailureText(failure);
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsStudio.annotate', e, stack);
      _annotateFailureCode = 'internal';
      _annotateFailureText = t.audiobook_studio_cast_failed(
        reason: t.audiobook_studio_failure_internal,
      );
    }
    // 失败 / 取消时已标完的章已经落盘：从盘上取回，不丢进度。
    final TtsCast cast = result ?? await _loadCast();
    if (!mounted) return;
    setState(() {
      _cast = cast;
      _annotating = false;
    });
  }

  String _voiceLabel(String? presetId) {
    if (presetId == null) return t.audiobook_studio_cast_default_voice;
    final TtsVoicePreset? preset = _presets
        .where((TtsVoicePreset p) => p.id == presetId)
        .firstOrNull;
    return preset == null
        ? t.audiobook_studio_failure_voice_missing
        : _presetName(preset);
  }

  Future<void> _pickCastVoice(String speaker) async {
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: ttsCastSpeakerLabel(speaker),
      icon: FushiIcons.voice,
      selected: _cast.voices[speaker] ?? '',
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(
          value: '',
          label: t.audiobook_studio_cast_default_voice,
          subtitle: _preset == null ? null : _presetName(_preset!),
        ),
        for (final TtsVoicePreset p in _presets)
          FushiChoiceOption<String>(
            value: p.id,
            label: _presetName(p),
            subtitle: ttsProviderLabel(p.providerId),
          ),
      ],
    );
    if (picked == null || !mounted || _annotating) return;
    setState(() {
      if (picked.isEmpty) {
        _cast.voices.remove(speaker);
      } else {
        _cast.voices[speaker] = picked;
      }
    });
    await _saveCast();
  }

  Future<void> _renameSpeaker(String from) async {
    final String? to = await showFushiTextInputDialog(
      context: context,
      title: t.audiobook_studio_cast_rename_title,
      initialValue: from,
      labelText: t.audiobook_studio_cast_line_speaker,
      icon: FushiIcons.edit,
    );
    if (to == null || to.isEmpty || to == from || !mounted || _annotating) {
      return;
    }
    setState(() => _cast.renameSpeaker(from, to));
    await _saveCast();
  }

  String get _bookTitle {
    final ({EpubBookRow row, EpubBook book})? loaded = _loaded;
    if (loaded == null) return '';
    return loaded.row.title.isEmpty ? loaded.book.title : loaded.row.title;
  }

  /// 移动端分享导出的输出路径：清掉上一次导出留下的暂存，再落在空的暂存目录里。
  Future<String> _shareStagingPath(String fileName) async {
    final Directory staging = await prepareTtsAudiobookShareStagingDir(
      Directory(
        p.join(Directory.systemTemp.path, kTtsAudiobookShareStagingDirName),
      ),
    );
    return p.join(staging.path, fileName);
  }

  /// 导出为 M4B：桌面选保存位置直接写；移动端写进 app 自管的暂存目录再走系统
  /// 分享（暂存目录每次导出前清空，见 [prepareTtsAudiobookShareStagingDir]）。
  Future<void> _export() async {
    if (_exporting) return;
    final String fileName = ttsAudiobookExportFileName(_bookTitle);
    final bool desktop = isDesktopPlatform;
    String? pickedPath;
    if (desktop) {
      // 只在桌面弹保存框（移动端走分享），默认文件名已带 .m4b；不传
      // FileType.custom 扩展名过滤（BUG-2099 的选择器纪律，同 collection_exporter）。
      final String? picked = await FilePicker.platform.saveFile(
        dialogTitle: t.audiobook_studio_export,
        fileName: fileName,
      );
      if (picked == null || picked.trim().isEmpty || !mounted) return;
      pickedPath = picked;
    }
    setState(() {
      _exporting = true;
      _exportProgress = null;
    });
    try {
      final String outputPath =
          pickedPath ?? await _shareStagingPath(fileName);
      final String written = await exportTtsAudiobookM4b(
        appModel: widget.appModel,
        bookKey: widget.bookKey,
        outputPath: outputPath,
        onProgress: (double progress) {
          if (mounted) setState(() => _exportProgress = progress);
        },
      );
      if (desktop) {
        FushiToast.show(msg: t.audiobook_studio_export_done(path: written));
      } else {
        final String srt = p.setExtension(written, '.srt');
        await FushiShare.shareFiles(<XFile>[
          XFile(written, mimeType: 'audio/mp4', name: p.basename(written)),
          if (File(srt).existsSync())
            XFile(srt, mimeType: 'application/x-subrip', name: p.basename(srt)),
        ], subject: p.basename(written));
      }
    } on AudiobookExportFailure catch (failure) {
      FushiToast.show(
        msg: ttsAudiobookExportFailureText(failure.code, failure.message),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsStudio.export', e, stack);
      FushiToast.show(
        msg: ttsAudiobookExportFailureText(
          'export_failed',
          t.audiobook_studio_failure_internal,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _exportProgress = null;
        });
      }
    }
  }

  Future<void> _pickPause() async {
    final TtsPausePreset? picked = await showFushiChoiceDialog<TtsPausePreset>(
      context: context,
      title: t.audiobook_studio_pause,
      message: t.audiobook_studio_pause_hint,
      selected: _pause,
      options: <FushiChoiceOption<TtsPausePreset>>[
        for (final TtsPausePreset p in TtsPausePreset.values)
          FushiChoiceOption<TtsPausePreset>(
            value: p,
            label: ttsPausePresetLabel(p),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() => _pause = picked);
  }

  /// 「不明」的台词一次性全指给某个角色（或新名字）。
  Future<void> _assignUnknown() async {
    const String newSpeaker = '\u0000new';
    final List<String> names = <String>[
      for (final ({String speaker, int count}) s in _cast.speakers())
        if (s.speaker != kTtsUnknown) s.speaker,
    ];
    for (final String name in _cast.roster.keys) {
      if (!names.contains(name)) names.add(name);
    }
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: t.audiobook_studio_cast_assign_all,
      icon: FushiIcons.voice,
      options: <FushiChoiceOption<String>>[
        for (final String name in names)
          FushiChoiceOption<String>(
            value: name,
            label: name,
            subtitle: ttsCastCharacterTraits(_cast.roster[name]),
          ),
        FushiChoiceOption<String>(
          value: newSpeaker,
          label: t.audiobook_studio_cast_new_speaker,
          icon: FushiIcons.add,
        ),
      ],
    );
    if (picked == null || !mounted) return;
    String target = picked;
    if (picked == newSpeaker) {
      final String? typed = await showFushiTextInputDialog(
        context: context,
        title: t.audiobook_studio_cast_new_speaker,
        labelText: t.audiobook_studio_cast_line_speaker,
        icon: FushiIcons.edit,
      );
      if (typed == null || typed.isEmpty || !mounted) return;
      target = typed;
    }
    if (_annotating) return;
    setState(() => _cast.renameSpeaker(kTtsUnknown, target));
    await _saveCast();
  }

  Future<void> _openCastLines({bool reviewOnly = false}) async {
    final TtsBookPlan? plan = _plan;
    if (plan == null || _chapters.isEmpty) return;
    int initial = _chapters
        .map((_StudioChapter c) => c.section)
        .firstWhere(_selected.contains, orElse: () => _chapters.first.section);
    if (reviewOnly) {
      // 直接落到第一处有待复核行的章。
      for (final TtsPlanSentence s in plan.sentences) {
        if (ttsCastIsReviewLine(_cast, s, reviewOnly: true)) {
          initial = s.section;
          break;
        }
      }
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TtsCastLinesPage(
          plan: plan,
          chapters: <({int section, String label})>[
            for (final _StudioChapter c in _chapters)
              (section: c.section, label: c.label),
          ],
          initialSection: initial,
          reviewOnly: reviewOnly,
          cast: _cast,
          onChanged: () async {
            if (mounted) setState(() {});
            await _saveCast();
          },
        ),
      ),
    );
    if (mounted) setState(() {});
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

  // ---------------------------------------------------------------------------
  // 版面：四步（内容 / 角色与配音 / 生成 / 结果），骨架见 [TtsStudioLayout]。
  // ---------------------------------------------------------------------------

  /// 选中章节的句数 / 字数合计。
  ({int sentences, int chars}) get _selectedTotals {
    int sentences = 0, chars = 0;
    for (final _StudioChapter c in _chapters) {
      if (!_selected.contains(c.section)) continue;
      sentences += c.sentences;
      chars += c.chars;
    }
    return (sentences: sentences, chars: chars);
  }

  String get _chapterRatio => '${_selected.length}/${_chapters.length}';

  /// 角色步骤的一行摘要（标注中 = 进度；否则 已标章数 · 待复核）。
  String? get _castSummary {
    if (_plan == null || _plan!.isEmpty) return null;
    if (_annotating) {
      return ttsCastAnnotateProgressText(
        _annotatePhase,
        _annotateDone,
        _annotateTotal,
      );
    }
    final int annotated = ttsCastAnnotatedCount(_cast, <int>[
      for (final _StudioChapter c in _chapters) c.section,
    ]);
    final int review = _cast.reviewCount;
    return <String>[
      t.audiobook_studio_cast_annotated(
        done: annotated,
        total: _chapters.length,
      ),
      if (review > 0) t.audiobook_studio_cast_review(n: review),
    ].join(' · ');
  }

  String get _generateSummary => <String>[
    ttsPausePresetLabel(_pause),
    if (_verify && isAsrSupported) t.audiobook_studio_verify,
    if (_loudness) t.audiobook_studio_loudness,
  ].join(' · ');

  List<TtsStudioStepEntry> _stepEntries(TtsRenderJob? job) {
    final TtsVoicePreset? preset = _preset;
    final bool hasPlan = _plan != null && !_plan!.isEmpty;
    final bool flagged =
        job != null &&
        job.status == TtsRenderJobStatus.done &&
        job.verified &&
        job.flags.isNotEmpty;
    return <TtsStudioStepEntry>[
      TtsStudioStepEntry(
        step: TtsStudioStep.content,
        icon: FushiIcons.checklist,
        title: t.audiobook_studio_chapters,
        summary: <String>[
          if (hasPlan) _chapterRatio,
          if (preset != null) _presetName(preset),
        ].join(' · '),
        attention: preset == null || _bookMissing || _planFailed,
      ),
      TtsStudioStepEntry(
        step: TtsStudioStep.cast,
        icon: FushiIcons.voice,
        title: t.audiobook_studio_cast,
        summary: _castSummary,
        attention: _cast.reviewCount > 0 || _annotateFailureText != null,
      ),
      TtsStudioStepEntry(
        step: TtsStudioStep.generate,
        icon: FushiIcons.settings,
        title: t.audiobook_studio_start,
        summary: _generateSummary,
      ),
      TtsStudioStepEntry(
        step: TtsStudioStep.result,
        icon: FushiIcons.audiobook,
        title: t.audiobook_studio_export,
        summary: job == null
            ? null
            : flagged
            ? t.audiobook_studio_flags_title(n: job.flags.length)
            : ttsRenderJobStatusText(job),
        attention: flagged || job?.status == TtsRenderJobStatus.failed,
      ),
    ];
  }

  void _selectStep(TtsStudioStep step) {
    if (step == _step) return;
    setState(() => _step = step);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsKitScaffold(
      title: t.audiobook_studio_title,
      leadingIcon: FushiIcons.audiobook,
      leadingTone: SettingsIconTone.purple,
      // 让位由 [TtsStudioLayout] 在固定的步骤导航之上一次性吃掉。
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) =>
              // 单一锚点：步骤内带标题的分组不再各自登记，壳不画跳转条（导航由
              // 步骤侧栏 / 步骤选择片承担）。
              SettingsSectionAnchor(
                title: t.audiobook_studio_title,
                child: ListenableBuilder(
                  key: const ValueKey<String>('tts-studio'),
                  listenable: EngineListenable(_queue),
                  builder: (BuildContext context, Widget? _) {
                    final TtsRenderJob? job = _queue.latestFor(widget.bookKey);
                    return TtsStudioLayout(
                      steps: _stepEntries(job),
                      selected: _step,
                      onSelect: _selectStep,
                      header: _bookMissing
                          ? Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: FushiDesignTokens.of(
                                  context,
                                ).spacing.page,
                              ),
                              child: _notice(
                                'tts-studio-book-missing',
                                t.audiobook_studio_failure_book_missing,
                                FushiNoticeSeverity.error,
                              ),
                            )
                          : null,
                      body: _stepBody(context, job),
                      footerBuilder: (BuildContext context, bool wide) =>
                          _footer(context, job, wide: wide),
                    );
                  },
                ),
              ),
    );
  }

  /// 选中步骤的内容：一个独立滚动的 [CustomScrollView]，长列表（章节 / 角色 /
  /// 问题句）都是懒构建的 sliver。
  Widget _stepBody(BuildContext context, TtsRenderJob? job) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final double inset = isGlassDesign(context)
            ? GlassSettingsRenderer.detailHorizontalInset(context)
            : tokens.spacing.page;
        final bool roomy = constraints.maxWidth >= 600;
        final List<Widget> slivers = switch (_step) {
          TtsStudioStep.content => _contentSlivers(context),
          TtsStudioStep.cast => _castSlivers(context, table: roomy),
          TtsStudioStep.generate => _generateSlivers(context),
          TtsStudioStep.result => _resultSlivers(context, job),
        };
        return FushiEntranceScope(
          replayKey: _step,
          child: CustomScrollView(
            key: ValueKey<String>('tts-studio-step-body-${_step.name}'),
            primary: false,
            slivers: <Widget>[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  inset,
                  tokens.spacing.gap,
                  inset,
                  tokens.spacing.page,
                ),
                sliver: SliverMainAxisGroup(slivers: slivers),
              ),
            ],
          ),
        );
      },
    );
  }

  static Widget _box(Widget child) => SliverToBoxAdapter(child: child);

  /// 吸顶的分组头（底色取页面底，内容滚到它下面时不透字）。
  Widget _pinnedHeader(
    BuildContext context, {
    required Widget child,
    Key? key,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return PinnedHeaderSliver(
      key: key,
      child: ColoredBox(
        color: tokens.surfaces.page,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
          child: child,
        ),
      ),
    );
  }

  // ① 内容：声音 + 发音词典 + 章节网格。

  List<Widget> _contentSlivers(BuildContext context) => <Widget>[
    for (final Widget w in _voiceSection()) _box(w),
    _box(_pronunciationSection()),
    ..._chaptersSlivers(context),
  ];

  List<Widget> _chaptersSlivers(BuildContext context) {
    if (_planFailed) {
      return <Widget>[
        _box(
          _notice(
            'tts-studio-plan-failed',
            t.audiobook_studio_failure_internal,
            FushiNoticeSeverity.error,
          ),
        ),
      ];
    }
    if (_planning || (_plan == null && !_bookMissing)) {
      return const <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            key: ValueKey<String>('tts-studio-planning'),
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: FushiCircularProgressIndicator()),
          ),
        ),
      ];
    }
    final TtsBookPlan? plan = _plan;
    if (plan == null) return const <Widget>[];
    if (plan.isEmpty) {
      return <Widget>[
        _box(
          _notice(
            'tts-studio-empty',
            t.audiobook_tts_empty_book,
            FushiNoticeSeverity.warning,
          ),
        ),
      ];
    }
    final ({int sentences, int chars}) totals = _selectedTotals;
    final ThemeData theme = Theme.of(context);
    final Color secondary = fushiNeutralSecondaryForeground(context);
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    return <Widget>[
      _pinnedHeader(
        context,
        key: const ValueKey<String>('tts-studio-chapters'),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '${t.audiobook_studio_chapters} · $_chapterRatio',
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    t.audiobook_studio_summary(
                      sentences: totals.sentences,
                      chars: totals.chars,
                    ),
                    key: const ValueKey<String>('tts-studio-summary'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: secondary,
                    ),
                  ),
                ],
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
      SliverGrid.builder(
        key: const ValueKey<String>('tts-studio-chapter-grid'),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 320,
          mainAxisExtent: MediaQuery.textScalerOf(context).scale(76),
          mainAxisSpacing: gap / 2,
          crossAxisSpacing: gap / 2,
        ),
        itemCount: _chapters.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) =>
              _chapterTile(context, _chapters[index]),
        ),
      ),
    ];
  }

  /// 章节格：整格可聚焦、Enter 切换；复选框只作展示，不另占焦点位。
  Widget _chapterTile(BuildContext context, _StudioChapter c) {
    final bool checked = _selected.contains(c.section);
    final ThemeData theme = Theme.of(context);
    return FushiCard(
      key: ValueKey<String>('tts-studio-chapter-${c.section}'),
      selected: checked,
      onTap: () => _toggleSection(c.section),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: <Widget>[
          ExcludeFocus(
            child: FushiCheckbox(
              value: checked,
              onChanged: (_) => _toggleSection(c.section),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  c.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  t.audiobook_studio_chapter_count(
                    n: c.sentences,
                    chars: c.chars,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: fushiNeutralSecondaryForeground(context),
                  ),
                ),
              ],
            ),
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
            trailing: _chevron(context),
          ),
        ],
      ),
      if (_usesOnlineVoice)
        _notice(
          'tts-studio-online-warning',
          t.audiobook_studio_online_warning,
          FushiNoticeSeverity.warning,
        ),
    ];
  }

  Widget _chevron(BuildContext context) => isGlassDesign(context)
      ? const FushiAppleChevron()
      : FushiIcon(
          FushiIcons.chevronRight,
          size: 20,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );

  // ② 角色与配音：标注控制 + 旁白 / 不明 / 待复核入口 + 角色表。

  List<Widget> _castSlivers(BuildContext context, {required bool table}) {
    final TtsBookPlan? plan = _plan;
    // 计划还没好 / 失败 / 空书：与章节步骤同一套占位。
    if (plan == null || plan.isEmpty) return _chaptersSlivers(context);
    final List<int> sections = <int>[
      for (final _StudioChapter c in _chapters) c.section,
    ];
    final int annotatedAll = ttsCastAnnotatedCount(_cast, sections);
    final int annotatedSelected = ttsCastAnnotatedCount(_cast, _selected);
    final bool canAnnotate = !_annotating && _selected.isNotEmpty;
    final List<({String speaker, int count})> speakers = _cast.speakers();
    final int unknownCount = ttsCastUnknownCount(speakers);
    final List<({String speaker, int count})> characters = ttsCastCharacterRows(
      _cast,
      speakers,
    );
    final int reviewCount = _cast.reviewCount;
    final Widget chevron = _chevron(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return <Widget>[
      _box(
        AdaptiveSettingsSection(
          key: const ValueKey<String>('tts-studio-cast'),
          title: t.audiobook_studio_cast,
          children: <Widget>[
            if (_annotating)
              Padding(
                key: const ValueKey<String>('tts-studio-cast-progress'),
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
                      ttsCastAnnotateProgressText(
                        _annotatePhase,
                        _annotateDone,
                        _annotateTotal,
                      ),
                    ),
                    const SizedBox(height: 10),
                    FushiLinearProgressIndicator(
                      value: _annotateTotal <= 0
                          ? null
                          : (_annotateDone / _annotateTotal).clamp(0.0, 1.0),
                    ),
                  ],
                ),
              ),
            if (_annotating)
              AdaptiveSettingsRow(
                key: const ValueKey<String>('tts-studio-cast-cancel'),
                icon: FushiIcons.stop,
                showIcon: true,
                title: t.audiobook_studio_cancel,
                onTap: _annotateCancelled
                    ? null
                    : () => setState(() => _annotateCancelled = true),
              )
            else ...<Widget>[
              // 选中的章还有没标的：补标（跳过已标的章）。
              if (annotatedSelected < _selected.length || _selected.isEmpty)
                AdaptiveSettingsRow(
                  key: const ValueKey<String>('tts-studio-cast-annotate'),
                  icon: FushiIcons.voice,
                  showIcon: true,
                  title: t.audiobook_studio_cast_annotate,
                  subtitle: t.audiobook_studio_cast_annotated(
                    done: annotatedAll,
                    total: sections.length,
                  ),
                  onTap: canAnnotate
                      ? () => unawaited(_annotate(again: false))
                      : null,
                ),
              if (annotatedSelected > 0)
                AdaptiveSettingsRow(
                  key: const ValueKey<String>('tts-studio-cast-reannotate'),
                  icon: FushiIcons.refresh,
                  showIcon: true,
                  title: t.audiobook_studio_cast_reannotate,
                  subtitle: annotatedSelected < _selected.length
                      ? null
                      : t.audiobook_studio_cast_annotated(
                          done: annotatedAll,
                          total: sections.length,
                        ),
                  onTap: canAnnotate
                      ? () => unawaited(_annotate(again: true))
                      : null,
                ),
            ],
            if (reviewCount > 0)
              AdaptiveSettingsRow(
                key: const ValueKey<String>('tts-studio-cast-review'),
                icon: FushiIcons.warning,
                showIcon: true,
                title: t.audiobook_studio_cast_review(n: reviewCount),
                subtitle: t.audiobook_studio_cast_review_hint,
                onTap: _annotating
                    ? null
                    : () => unawaited(_openCastLines(reviewOnly: true)),
                trailing: chevron,
              ),
            AdaptiveSettingsRow(
              key: const ValueKey<String>('tts-studio-cast-lines'),
              icon: FushiIcons.checklist,
              showIcon: true,
              title: t.audiobook_studio_cast_lines_title,
              onTap: _annotating ? null : () => unawaited(_openCastLines()),
              trailing: chevron,
            ),
          ],
        ),
      ),
      _box(
        SettingsSectionFooter(
          characters.isEmpty && unknownCount == 0
              ? '${t.audiobook_studio_cast_hint}\n${t.audiobook_studio_cast_empty}'
              : t.audiobook_studio_cast_hint,
          key: const ValueKey<String>('tts-studio-cast-footer'),
        ),
      ),
      if (_annotateFailureText case final String message)
        _box(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: FushiInlineNotice(
              key: const ValueKey<String>('tts-studio-cast-failure'),
              severity: _annotateFailureCode == 'no_ai_provider'
                  ? FushiNoticeSeverity.warning
                  : FushiNoticeSeverity.error,
              message: message,
              actions: <Widget>[
                if (_annotateFailureCode == 'no_ai_provider')
                  FushiTextButton(
                    key: const ValueKey<String>('tts-studio-cast-ai-settings'),
                    onPressed: () => unawaited(pushAiSettingsPage(context)),
                    child: Text(t.ai_settings_title),
                  ),
              ],
            ),
          ),
        ),
      // 角色表：旁白 / 不明说话人置顶，角色按台词数懒构建。
      if (table)
        _pinnedHeader(
          context,
          key: const ValueKey<String>('tts-studio-cast-table-header'),
          child: _castTableRow(
            context,
            name: t.audiobook_studio_cast_line_speaker,
            lines: t.audiobook_studio_cast_lines_title,
            voice: t.audiobook_studio_voice,
            traits: '',
            header: true,
          ),
        ),
      SliverList.builder(
        key: const ValueKey<String>('tts-studio-cast-roster'),
        itemCount: characters.length + 1 + (unknownCount > 0 ? 1 : 0),
        itemBuilder: fushiStaggeredItemBuilder((
          BuildContext context,
          int index,
        ) {
          if (index == 0) return _narratorRow(context, table: table);
          if (unknownCount > 0 && index == 1) {
            return _unknownRow(context, unknownCount, table: table);
          }
          final int offset = unknownCount > 0 ? 2 : 1;
          return _characterRow(
            context,
            characters[index - offset],
            table: table,
          );
        }),
      ),
    ];
  }

  /// 角色表一行的四列排版（名字 | 台词数 | 声音 | 特征）。表头与数据行共用，
  /// 列宽天然对齐。
  Widget _castTableRow(
    BuildContext context, {
    required String name,
    required String lines,
    required String voice,
    required String traits,
    bool header = false,
    Widget? trailing,
    VoidCallback? onTap,
    Key? key,
  }) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = fushiNeutralSecondaryForeground(context);
    final TextStyle? headerStyle = theme.textTheme.labelMedium?.copyWith(
      color: secondary,
    );
    final TextStyle? cellStyle = header ? headerStyle : null;
    final TextStyle? mutedStyle = header
        ? headerStyle
        : theme.textTheme.bodyMedium?.copyWith(color: secondary);
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    return FushiListItem(
      key: key,
      density: FushiListDensity.compact,
      onTap: onTap,
      leading: header
          ? const SizedBox(width: 24)
          : const FushiIcon(FushiIcons.voice),
      title: Row(
        children: <Widget>[
          Expanded(flex: 3, child: Text(name, style: cellStyle)),
          SizedBox(width: gap),
          SizedBox(
            width: 88,
            child: Text(lines, style: mutedStyle, textAlign: TextAlign.end),
          ),
          SizedBox(width: gap * 2),
          Expanded(flex: 3, child: Text(voice, style: cellStyle)),
          SizedBox(width: gap),
          Expanded(flex: 4, child: Text(traits, style: mutedStyle)),
        ],
      ),
      trailing: trailing ?? const SizedBox(width: 40),
    );
  }

  Widget _narratorRow(BuildContext context, {required bool table}) {
    final VoidCallback? onTap = _annotating
        ? null
        : () => unawaited(_pickCastVoice(kTtsNarrator));
    if (table) {
      return _castTableRow(
        context,
        key: const ValueKey<String>('tts-studio-cast-narrator'),
        name: t.audiobook_studio_cast_narrator,
        lines: '',
        voice: _voiceLabel(_cast.voices[kTtsNarrator]),
        traits: '',
        onTap: onTap,
      );
    }
    return FushiListItem(
      key: const ValueKey<String>('tts-studio-cast-narrator'),
      leading: const FushiIcon(FushiIcons.audiobook),
      title: Text(t.audiobook_studio_cast_narrator),
      subtitle: Text(_voiceLabel(_cast.voices[kTtsNarrator])),
      onTap: onTap,
    );
  }

  Widget _unknownRow(BuildContext context, int count, {required bool table}) {
    final Widget assign = FushiTextButton(
      key: const ValueKey<String>('tts-studio-cast-assign-all'),
      onPressed: _annotating ? null : () => unawaited(_assignUnknown()),
      child: Text(t.audiobook_studio_cast_assign_all),
    );
    final VoidCallback? onTap = _annotating
        ? null
        : () => unawaited(_pickCastVoice(kTtsUnknown));
    if (table) {
      return _castTableRow(
        context,
        key: const ValueKey<String>('tts-studio-cast-unknown'),
        name: t.audiobook_studio_cast_unknown,
        lines: t.audiobook_studio_cast_lines(n: count),
        voice: _voiceLabel(_cast.voices[kTtsUnknown]),
        traits: '',
        onTap: onTap,
        trailing: assign,
      );
    }
    return FushiListItem(
      key: const ValueKey<String>('tts-studio-cast-unknown'),
      leading: const FushiIcon(FushiIcons.voice),
      title: Text(t.audiobook_studio_cast_unknown),
      subtitle: Text(
        '${t.audiobook_studio_cast_lines(n: count)}'
        ' · ${_voiceLabel(_cast.voices[kTtsUnknown])}',
      ),
      onTap: onTap,
      trailing: assign,
    );
  }

  Widget _characterRow(
    BuildContext context,
    ({String speaker, int count}) s, {
    required bool table,
  }) {
    final Widget rename = FushiIconButtonControl(
      key: ValueKey<String>('tts-studio-cast-speaker-${s.speaker}-rename'),
      tooltip: t.audiobook_studio_cast_rename,
      icon: const FushiIcon(FushiIcons.edit),
      onPressed: _annotating
          ? null
          : () => unawaited(_renameSpeaker(s.speaker)),
    );
    final VoidCallback? onTap = _annotating
        ? null
        : () => unawaited(_pickCastVoice(s.speaker));
    final String? traits = ttsCastCharacterTraits(_cast.roster[s.speaker]);
    final Key key = ValueKey<String>('tts-studio-cast-speaker-${s.speaker}');
    if (table) {
      return _castTableRow(
        context,
        key: key,
        name: s.speaker,
        lines: t.audiobook_studio_cast_lines(n: s.count),
        voice: _voiceLabel(_cast.voices[s.speaker]),
        traits: traits ?? '',
        onTap: onTap,
        trailing: rename,
      );
    }
    return FushiListItem(
      key: key,
      leading: const FushiIcon(FushiIcons.voice),
      title: Text(s.speaker),
      subtitle: Text(
        <String>[
          '${t.audiobook_studio_cast_lines(n: s.count)}'
              ' · ${_voiceLabel(_cast.voices[s.speaker])}',
          ?traits,
        ].join('\n'),
      ),
      isThreeLine: traits != null,
      onTap: onTap,
      trailing: rename,
    );
  }

  // ③ 生成：前两步回顾 + 校对 / 停顿 / 响度；开始按钮常驻在侧栏 / 底栏。

  List<Widget> _generateSlivers(BuildContext context) {
    final TtsVoicePreset? preset = _preset;
    final ({int sentences, int chars}) totals = _selectedTotals;
    final Widget chevron = _chevron(context);
    return <Widget>[
      _box(
        AdaptiveSettingsSection(
          key: const ValueKey<String>('tts-studio-recap'),
          children: <Widget>[
            AdaptiveSettingsRow(
              key: const ValueKey<String>('tts-studio-recap-voice'),
              icon: FushiIcons.voice,
              showIcon: true,
              title: t.audiobook_studio_voice,
              subtitle: preset == null
                  ? t.audiobook_studio_no_voice
                  : _presetName(preset),
              onTap: () => _selectStep(TtsStudioStep.content),
              trailing: chevron,
            ),
            AdaptiveSettingsRow(
              key: const ValueKey<String>('tts-studio-recap-chapters'),
              icon: FushiIcons.checklist,
              showIcon: true,
              title: t.audiobook_studio_chapters,
              subtitle:
                  '$_chapterRatio · ${t.audiobook_studio_summary(sentences: totals.sentences, chars: totals.chars)}',
              onTap: () => _selectStep(TtsStudioStep.content),
              trailing: chevron,
            ),
            if (_castSummary case final String cast)
              AdaptiveSettingsRow(
                key: const ValueKey<String>('tts-studio-recap-cast'),
                icon: FushiIcons.audiobook,
                showIcon: true,
                title: t.audiobook_studio_cast,
                subtitle: cast,
                onTap: () => _selectStep(TtsStudioStep.cast),
                trailing: chevron,
              ),
          ],
        ),
      ),
      _box(
        AdaptiveSettingsSection(
          key: const ValueKey<String>('tts-studio-options'),
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
            AdaptiveSettingsRow(
              key: const ValueKey<String>('tts-studio-pause'),
              title: t.audiobook_studio_pause,
              subtitle: t.audiobook_studio_pause_hint,
              onTap: () => unawaited(_pickPause()),
              trailing: Text(
                ttsPausePresetLabel(_pause),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: fushiNeutralSecondaryForeground(context),
                ),
              ),
            ),
            AdaptiveSettingsSwitchRow(
              key: const ValueKey<String>('tts-studio-loudness'),
              title: t.audiobook_studio_loudness,
              subtitle: t.audiobook_studio_loudness_hint,
              value: _loudness,
              onChanged: (bool v) => setState(() => _loudness = v),
            ),
          ],
        ),
      ),
      if (_hasAudiobook)
        _box(
          _notice(
            'tts-studio-replace-warning',
            t.audiobook_studio_replace_warning,
            FushiNoticeSeverity.warning,
          ),
        ),
    ];
  }

  // ④ 结果：任务卡 + 校对标出的句子 + 重新生成 + 导出。

  List<Widget> _resultSlivers(BuildContext context, TtsRenderJob? job) {
    final Widget export = _exportSection(job);
    if (job == null) {
      return <Widget>[
        _box(
          _notice(
            'tts-studio-no-job',
            t.audiobook_studio_hint,
            FushiNoticeSeverity.info,
          ),
        ),
        _box(export),
      ];
    }
    if (_regenJobId != job.id) {
      _regenJobId = job.id;
      _regenSelected.clear();
    }
    return <Widget>[
      _box(_jobCard(context, job)),
      if (job.loudnessSkipped)
        _box(
          _notice(
            'tts-studio-loudness-skipped',
            t.audiobook_studio_loudness_skipped,
            FushiNoticeSeverity.info,
          ),
        ),
      if (job.status == TtsRenderJobStatus.done) ..._flagsSlivers(context, job),
      _box(export),
    ];
  }

  Widget _exportSection(TtsRenderJob? job) {
    final bool available =
        _hasAudiobook || job?.status == TtsRenderJobStatus.done;
    if (!available || _loaded == null) return const SizedBox.shrink();
    final double inset = FushiDesignTokens.of(context).spacing.rowHorizontal;
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('tts-studio-export'),
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('tts-studio-export-run'),
          icon: FushiIcons.download,
          showIcon: true,
          title: t.audiobook_studio_export,
          subtitle: _exporting
              ? t.audiobook_studio_export_running
              : t.audiobook_studio_export_hint,
          onTap: _exporting ? null : () => unawaited(_export()),
        ),
        if (_exporting)
          Padding(
            key: const ValueKey<String>('tts-studio-export-progress'),
            padding: EdgeInsets.fromLTRB(inset, 0, inset, 12),
            child: FushiLinearProgressIndicator(value: _exportProgress),
          ),
      ],
    );
  }

  /// 常驻主操作：任务进行中显示状态 + 进度，否则显示所选章节摘要；外加「开始制作」。
  Widget _footer(
    BuildContext context,
    TtsRenderJob? job, {
    required bool wide,
  }) {
    final bool busy = job != null && !job.isTerminal;
    final ({int sentences, int chars}) totals = _selectedTotals;
    final ThemeData theme = Theme.of(context);
    final Widget status = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          busy
              ? ttsRenderJobStatusText(job)
              : t.audiobook_studio_summary(
                  sentences: totals.sentences,
                  chars: totals.chars,
                ),
          key: const ValueKey<String>('tts-studio-footer-status'),
          maxLines: wide ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: fushiNeutralSecondaryForeground(context),
          ),
        ),
        if (busy) ...<Widget>[
          const SizedBox(height: 6),
          FushiLinearProgressIndicator(
            key: const ValueKey<String>('tts-studio-footer-progress'),
            value: ttsRenderJobProgress(job),
          ),
        ],
      ],
    );
    final Widget start = _startButton(job);
    if (wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[status, const SizedBox(height: 12), start],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(child: status),
        const SizedBox(width: 12),
        start,
      ],
    );
  }

  Widget _startButton(TtsRenderJob? job) {
    final bool busy = job != null && !job.isTerminal;
    final bool ready =
        !busy &&
        !_starting &&
        !_planning &&
        _voiceUsable &&
        _plan != null &&
        !_plan!.isEmpty &&
        _selected.isNotEmpty;
    return FushiFilledButton.icon(
      key: const ValueKey<String>('tts-studio-start'),
      onPressed: ready ? () => unawaited(_start()) : null,
      icon: const FushiIcon(FushiIcons.play),
      label: Text(t.audiobook_studio_start),
    );
  }

  Widget _jobCard(BuildContext context, TtsRenderJob job) {
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
    return AdaptiveSettingsSection(
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
                FushiLinearProgressIndicator(value: ttsRenderJobProgress(job)),
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
    );
  }

  void _toggleRegen(int sentence) {
    setState(() {
      if (!_regenSelected.remove(sentence)) _regenSelected.add(sentence);
    });
  }

  List<Widget> _flagsSlivers(BuildContext context, TtsRenderJob job) {
    if (!job.verified) {
      return <Widget>[
        _box(
          _notice(
            'tts-studio-flags-unverified',
            t.audiobook_studio_flags_unverified,
            FushiNoticeSeverity.info,
          ),
        ),
      ];
    }
    if (job.flags.isEmpty) {
      return <Widget>[
        _box(
          _notice(
            'tts-studio-flags-none',
            t.audiobook_studio_flags_none,
            FushiNoticeSeverity.success,
          ),
        ),
      ];
    }
    final TtsBookPlan? plan = _plan;
    return <Widget>[
      _pinnedHeader(
        context,
        key: const ValueKey<String>('tts-studio-flags'),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.audiobook_studio_flags_title(n: job.flags.length),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            FushiFilledButton.icon(
              key: const ValueKey<String>('tts-studio-regenerate'),
              onPressed: _regenSelected.isEmpty
                  ? null
                  : () => unawaited(_regenerate(job)),
              icon: const FushiIcon(FushiIcons.refresh),
              label: Text(
                t.audiobook_studio_regenerate_selected(
                  n: _regenSelected.length,
                ),
              ),
            ),
          ],
        ),
      ),
      SliverList.builder(
        key: const ValueKey<String>('tts-studio-flag-list'),
        itemCount: job.flags.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) =>
              _flagRow(context, job, job.flags[index], plan),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
    ];
  }

  Widget _flagRow(
    BuildContext context,
    TtsRenderJob job,
    TtsRenderFlag flag,
    TtsBookPlan? plan,
  ) {
    final bool checked = _regenSelected.contains(flag.sentence);
    return FushiListItem(
      key: ValueKey<String>('tts-studio-flag-${flag.sentence}'),
      selected: checked,
      titleMaxLines: 4,
      title: Text(
        plan != null && flag.sentence < plan.length
            ? plan.sentences[flag.sentence].text
            : '#${flag.sentence + 1}',
      ),
      subtitle: Text(
        '${t.audiobook_studio_heard(text: flag.heard)}'
        ' · ${(flag.similarity * 100).round()}%',
      ),
      onTap: () => _toggleRegen(flag.sentence),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIconButtonControl(
            key: ValueKey<String>('tts-studio-flag-${flag.sentence}-play'),
            tooltip: t.audiobook_studio_play,
            icon: _previewing == flag.sentence
                ? const SizedBox.square(
                    dimension: 18,
                    child: FushiCircularProgressIndicator(strokeWidth: 2),
                  )
                : const FushiIcon(FushiIcons.play),
            onPressed: plan == null || _previewing != null
                ? null
                : () => unawaited(_preview(job, flag.sentence)),
          ),
          ExcludeFocus(
            child: FushiCheckbox(
              value: checked,
              onChanged: (_) => _toggleRegen(flag.sentence),
            ),
          ),
        ],
      ),
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
