/// 有声漫画工作台（2026-11-20 反馈 #4 定稿）：把「识别台词 → 演出稿 → 角色与配音 →
/// 试听与导出」这条流程收进一页，和「制作有声书」用同一个步骤外壳
/// （[AudioProductionStepLayout]：左边步骤栏 / 窄屏步骤选择片 + 常驻主按钮）。
///
/// 工作台本身不持有任何制作逻辑，只读状态、分发到已有的功能：
/// - 识别台词 = 整卷 OCR（[enqueuePendingMangaOcrForBooks]，与书卡「识别文字」同一条路）；
/// - 演出稿 = [openMangaAudioScriptPage]（AI 标注说话人 / 类型 / 阅读顺序 + 逐页复核）；
/// - 角色与配音、试听与导出 = [openMangaAudioStudioPage]（声音指派、生成、试听、
///   单句重生成），另有导入成品清单（[pickAndImportMangaAudio]）、有声书音源、
///   广播剧 / 动画音轨三种成品来源。
///
/// 每步副行是按磁盘 / 库里的真值现算的进度（[loadMangaAudioWorkbenchSnapshot]）；
/// 从子页面回来、生成任务结束、OCR 任务集合变化时重读。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_layout.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_import_flow.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_script_page.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_studio_page.dart';
import 'package:fushi/src/media/manga/audio/manga_audiobook_source_page.dart';
import 'package:fushi/src/media/manga/audio/manga_drama_track_page.dart';
import 'package:fushi/src/media/manga/library/manga_book_ocr.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/engine_listenable.dart';

/// 打开 [bookKey] 这一卷漫画的有声漫画工作台（书卡菜单、侧栏速览「加声音」共用）。
Future<void> openMangaAudioWorkbench(
  BuildContext context, {
  required AppModel appModel,
  required String bookKey,
}) => Navigator.of(context).push<void>(
  adaptivePageRoute<void>(
    context: context,
    builder: (BuildContext context) =>
        MangaAudioWorkbenchPage(appModel: appModel, bookKey: bookKey),
  ),
);

/// 这一卷有没有登记好的漫画有声成品（生成 / 导入 / 广播剧匹配登记的都算）。与
/// [loadMangaAudio] 同一判据（`Audiobooks.alignmentFormat` = [kMangaAlignmentFormat]），
/// 只查一行库，不读清单。
Future<bool> mangaHasAudio(AppModel appModel, String bookKey) async {
  final AudiobookRow? row = await appModel.database.getAudiobookByBookKey(
    bookKey,
  );
  return row != null && row.alignmentFormat == kMangaAlignmentFormat;
}

/// 书卡菜单「有声漫画工作台」的副行：本地化的一行进度；还没开始（没标注、没生成、
/// 没成品、没有任务）或这本不能做有声（在线章节 / 读不出）返回 null，由菜单显示
/// [Translations.manga_audio_workbench_not_started]。
Future<String?> mangaAudioWorkbenchStatusLine(
  AppModel appModel,
  String bookKey,
) async {
  final MangaAudioWorkbenchSnapshot snapshot =
      await loadMangaAudioWorkbenchSnapshot(appModel, bookKey);
  return mangaAudioWorkbenchStatusText(
    snapshot,
    job: ttsRenderQueueFor(appModel).latestFor(bookKey),
  );
}

/// 工作台的四步（顺序即展示顺序）。
enum MangaAudioWorkbenchStep { recognize, script, voices, render }

/// 演出稿预览里的一句（说话人 + 念的文字）。
typedef MangaAudioWorkbenchLine = ({String speaker, String text});

/// 工作台一次读到的状态（纯数据，单测可直接构造）。
@immutable
class MangaAudioWorkbenchSnapshot {
  const MangaAudioWorkbenchSnapshot({
    this.unsupportedReason,
    this.pageCount = 0,
    this.ocrPages = 0,
    this.blockCount = 0,
    this.annotatedPages = 0,
    this.lineCount = 0,
    this.scriptStale = false,
    this.speakerCount = 0,
    this.assignedSpeakers = 0,
    this.renderedLines = 0,
    this.hasAudio = false,
    this.preview = const <MangaAudioWorkbenchLine>[],
  });

  /// 这一卷做不了有声的原因（已本地化，在线章节 / 读不出）；null = 能做。
  final String? unsupportedReason;

  final int pageCount;

  /// 有识别结果（至少一个气泡）的页数。
  final int ocrPages;

  /// 气泡总数。
  final int blockCount;

  /// 演出稿里已标注的页数。
  final int annotatedPages;

  /// 要念的台词句数（[MangaAudioScript.audibleLines]）。
  final int lineCount;

  /// 标注之后 OCR 重跑过，演出稿要重新标注。
  final bool scriptStale;

  /// 可指派声音的角色数 / 其中显式指派过声音的。
  final int speakerCount;
  final int assignedSpeakers;

  /// 成品清单里已配上音的句数（不含静音占位）。
  final int renderedLines;

  /// 已登记漫画有声成品（[mangaHasAudio]）。
  final bool hasAudio;

  /// 演出稿开头几句（预览用）。
  final List<MangaAudioWorkbenchLine> preview;

  bool get supported => unsupportedReason == null;

  /// 一进来停在哪一步：第一个还没做完的。
  MangaAudioWorkbenchStep get suggestedStep {
    if (ocrPages == 0) return MangaAudioWorkbenchStep.recognize;
    if (lineCount == 0 || scriptStale) return MangaAudioWorkbenchStep.script;
    if (!hasAudio && renderedLines == 0) return MangaAudioWorkbenchStep.voices;
    return MangaAudioWorkbenchStep.render;
  }
}

/// 读 [bookKey] 的工作台状态：本卷 `manga.json`（后台 isolate 解析）+ 演出稿 + 系列
/// 声音指派 + 成品清单 + 库里的成品登记。
Future<MangaAudioWorkbenchSnapshot> loadMangaAudioWorkbenchSnapshot(
  AppModel appModel,
  String bookKey,
) async {
  final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
  if (row == null) {
    return MangaAudioWorkbenchSnapshot(
      unsupportedReason: t.manga_audio_error_unreadable,
    );
  }
  if (!isLocalMangaVolume(row)) {
    return MangaAudioWorkbenchSnapshot(
      unsupportedReason: t.manga_audio_error_online,
    );
  }
  final MangaAudioVolume? volume = await loadMangaAudioVolume(
    appModel,
    bookKey,
  );
  if (volume == null) {
    return MangaAudioWorkbenchSnapshot(
      unsupportedReason: t.manga_audio_error_unreadable,
    );
  }
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    mangaRenderManifestFile(appModel, bookKey),
  );
  final bool hasAudio = await mangaHasAudio(appModel, bookKey);
  return mangaAudioWorkbenchSnapshotOf(
    volume.payload,
    volume.script,
    speakers: mangaAssignableSpeakers(volume),
    seriesVoices: volume.series?.voices,
    stale: volume.freshness == MangaScriptFreshness.needsReannotation,
    manifest: manifest,
    hasAudio: hasAudio,
  );
}

/// [loadMangaAudioWorkbenchSnapshot] 的纯计算部分。
MangaAudioWorkbenchSnapshot mangaAudioWorkbenchSnapshotOf(
  MokuroPayload payload,
  MangaAudioScript script, {
  required List<String> speakers,
  required bool stale,
  required bool hasAudio,
  CastVoiceAssignment? seriesVoices,
  MangaRenderManifest? manifest,
  int previewCount = 6,
}) {
  int ocrPages = 0, blocks = 0;
  for (final MokuroImage image in payload.images) {
    if (image.blocks.isNotEmpty) ocrPages++;
    blocks += image.blocks.length;
  }
  bool assigned(CastVoiceAssignment? v, String speaker) =>
      v != null &&
      (v.byCharacter.containsKey(speaker) ||
          v.byCharacterKind.containsKey(speaker));
  final List<MangaScriptLine> audible = script.audibleLines;
  String textOf(MangaScriptLine line) {
    final String? say = line.say;
    if (say != null && say.isNotEmpty) return say;
    if (line.page < 0 || line.page >= payload.images.length) return '';
    final List<MokuroBlock> pageBlocks = payload.images[line.page].blocks;
    return <String>[
      for (final int b in line.blocks)
        line.textFixes[b] ??
            (b >= 0 && b < pageBlocks.length ? pageBlocks[b].lines.join() : ''),
    ].join();
  }

  final int rendered = manifest == null
      ? 0
      : manifest.lines.length - manifest.placeholderCount;
  return MangaAudioWorkbenchSnapshot(
    pageCount: payload.images.length,
    ocrPages: ocrPages,
    blockCount: blocks,
    annotatedPages: script.annotatedPages.length,
    lineCount: audible.length,
    scriptStale: stale,
    speakerCount: speakers.length,
    assignedSpeakers: speakers
        .where(
          (String s) => assigned(script.voices, s) || assigned(seriesVoices, s),
        )
        .length,
    renderedLines: rendered.clamp(0, audible.length),
    hasAudio: hasAudio,
    preview: <MangaAudioWorkbenchLine>[
      for (final MangaScriptLine line in audible.take(previewCount))
        (speaker: ttsCastSpeakerLabel(line.speaker), text: textOf(line)),
    ],
  );
}

/// 菜单副行文案（见 [mangaAudioWorkbenchStatusLine]）。
String? mangaAudioWorkbenchStatusText(
  MangaAudioWorkbenchSnapshot s, {
  TtsRenderJob? job,
}) {
  if (!s.supported) return null;
  if (job != null && !job.isTerminal) return ttsRenderJobStatusText(job);
  final String lines = t.audiobook_studio_cast_lines(n: s.lineCount);
  if (s.hasAudio) {
    return <String>[
      t.manga_audio_workbench_ready,
      if (s.lineCount > 0) lines,
    ].join(' · ');
  }
  if (s.renderedLines > 0) {
    return <String>[
      lines,
      t.manga_audio_workbench_render_progress(
        done: s.renderedLines,
        total: s.lineCount,
      ),
    ].join(' · ');
  }
  if (s.annotatedPages > 0) return _scriptProgress(s);
  return null;
}

String _scriptProgress(MangaAudioWorkbenchSnapshot s) =>
    t.manga_audio_workbench_script_progress(
      pages: t.manga_audio_status(
        done: s.annotatedPages,
        total: s.ocrPages > 0 ? s.ocrPages : s.pageCount,
      ),
      lines: s.lineCount,
    );

/// 工作台页：读状态、接任务变化、把动作分发到已有功能；版面在
/// [MangaAudioWorkbenchView]。
class MangaAudioWorkbenchPage extends StatefulWidget {
  const MangaAudioWorkbenchPage({
    required this.appModel,
    required this.bookKey,
    super.key,
  });

  final AppModel appModel;
  final String bookKey;

  @override
  State<MangaAudioWorkbenchPage> createState() =>
      _MangaAudioWorkbenchPageState();
}

class _MangaAudioWorkbenchPageState extends State<MangaAudioWorkbenchPage> {
  late final TtsRenderQueue _queue = ttsRenderQueueFor(widget.appModel);
  MangaOcrJobRegistry? _ocr;
  StreamSubscription<void>? _ocrChanges;

  MangaAudioWorkbenchSnapshot? _snapshot;
  MangaAudioWorkbenchStep? _step;
  TtsRenderJobStatus? _lastStatus;
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _lastStatus = _queue.latestFor(widget.bookKey)?.status;
    _queue.addListener(_onQueue);
    unawaited(_reload());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ocr != null) return;
    final MangaOcrJobRegistry registry = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(mangaOcrJobRegistryProvider);
    _ocr = registry;
    // 任务集合变了（排上 / 跑完）：识别结果写回 manga.json 后重读。
    _ocrChanges = registry.changes.listen((_) {
      if (mounted) unawaited(_reload());
    });
  }

  @override
  void dispose() {
    _queue.removeListener(_onQueue);
    unawaited(_ocrChanges?.cancel());
    super.dispose();
  }

  /// 本卷生成任务结束（完成 / 失败 / 取消）时重读成品状态。
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
    final int seq = ++_loadSeq;
    final MangaAudioWorkbenchSnapshot snapshot =
        await loadMangaAudioWorkbenchSnapshot(widget.appModel, widget.bookKey);
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _snapshot = snapshot;
      _step ??= snapshot.suggestedStep;
    });
  }

  bool get _ocrRunning {
    final MangaOcrJobRegistry? registry = _ocr;
    if (registry == null) return false;
    return registry.entries().any(
      (MangaOcrJobEntry e) => e.bookKey == widget.bookKey,
    );
  }

  Future<void> _after(Future<void> action) async {
    await action;
    if (mounted) await _reload();
  }

  Future<void> _recognize() async {
    final MangaOcrJobRegistry? registry = _ocr;
    if (registry == null) return;
    await enqueuePendingMangaOcrForBooks(
      context: context,
      appModel: widget.appModel,
      registry: registry,
      bookKeys: <String>[widget.bookKey],
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SettingsKitScaffold(
      title: t.manga_audio_workbench_title,
      leadingIcon: FushiIcons.audio,
      leadingTone: SettingsIconTone.purple,
      // 让位由步骤外壳在固定的步骤导航之上一次性吃掉（与「制作有声书」同一约定）。
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => SettingsSectionAnchor(
            title: t.manga_audio_workbench_title,
            child: ListenableBuilder(
              listenable: EngineListenable(_queue),
              builder: (BuildContext context, Widget? _) {
                final MangaAudioWorkbenchSnapshot? snapshot = _snapshot;
                if (snapshot == null) {
                  return const Center(child: FushiCircularProgressIndicator());
                }
                return MangaAudioWorkbenchView(
                  snapshot: snapshot,
                  job: _queue.latestFor(widget.bookKey),
                  ocrRunning: _ocrRunning,
                  includeAudioSteps: widget.appModel.moduleVisibility.isEnabled(
                    ModuleId.listening,
                  ),
                  selected: _step ?? snapshot.suggestedStep,
                  onSelect: (MangaAudioWorkbenchStep step) =>
                      setState(() => _step = step),
                  onRecognize: () => unawaited(_recognize()),
                  onOpenScript: () => unawaited(
                    _after(
                      openMangaAudioScriptPage(
                        context,
                        appModel: widget.appModel,
                        bookKey: widget.bookKey,
                      ),
                    ),
                  ),
                  onOpenStudio: () => unawaited(
                    _after(
                      openMangaAudioStudioPage(
                        context,
                        appModel: widget.appModel,
                        bookKey: widget.bookKey,
                      ),
                    ),
                  ),
                  onImport: () => unawaited(
                    _after(
                      pickAndImportMangaAudio(
                        widget.appModel.database,
                        widget.bookKey,
                      ),
                    ),
                  ),
                  onOpenAudiobookSource: () => unawaited(
                    _after(
                      MangaAudiobookSourcePage.push(
                        context,
                        appModel: widget.appModel,
                        bookKey: widget.bookKey,
                      ),
                    ),
                  ),
                  onOpenDramaTrack: () => unawaited(
                    _after(
                      MangaDramaTrackPage.push(
                        context,
                        appModel: widget.appModel,
                        bookKey: widget.bookKey,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
    );
  }
}

/// 工作台版面（纯 widget：不读 AppModel / Riverpod，状态与回调由页面交进来）。
class MangaAudioWorkbenchView extends StatelessWidget {
  const MangaAudioWorkbenchView({
    required this.snapshot,
    required this.selected,
    required this.onSelect,
    required this.onRecognize,
    required this.onOpenScript,
    required this.onOpenStudio,
    required this.onImport,
    required this.onOpenAudiobookSource,
    required this.onOpenDramaTrack,
    this.job,
    this.ocrRunning = false,
    this.includeAudioSteps = true,
    super.key,
  });

  final MangaAudioWorkbenchSnapshot snapshot;
  final MangaAudioWorkbenchStep selected;
  final ValueChanged<MangaAudioWorkbenchStep> onSelect;

  /// 本卷最近一次生成任务；null = 没有。
  final TtsRenderJob? job;

  /// 本卷有 OCR 任务在跑 / 排队。
  final bool ocrRunning;

  /// 听书模块开着：显示「角色与配音」「试听与导出」两步（生成 / 导入受它门控）。
  final bool includeAudioSteps;

  final VoidCallback onRecognize;
  final VoidCallback onOpenScript;
  final VoidCallback onOpenStudio;
  final VoidCallback onImport;
  final VoidCallback onOpenAudiobookSource;
  final VoidCallback onOpenDramaTrack;

  static const String keyPrefix = 'manga-audio-workbench';

  bool get _jobActive => job != null && !job!.isTerminal;

  MangaAudioWorkbenchStep get _effectiveStep =>
      !includeAudioSteps &&
          (selected == MangaAudioWorkbenchStep.voices ||
              selected == MangaAudioWorkbenchStep.render)
      ? MangaAudioWorkbenchStep.script
      : selected;

  static String stepTitle(MangaAudioWorkbenchStep step) => switch (step) {
    MangaAudioWorkbenchStep.recognize => t.manga_audio_workbench_step_recognize,
    MangaAudioWorkbenchStep.script => t.manga_audio_workbench_step_script,
    MangaAudioWorkbenchStep.voices => t.manga_audio_workbench_step_voices,
    MangaAudioWorkbenchStep.render => t.manga_audio_workbench_step_render,
  };

  static IconData stepIcon(MangaAudioWorkbenchStep step) => switch (step) {
    MangaAudioWorkbenchStep.recognize => FushiIcons.ocr,
    MangaAudioWorkbenchStep.script => FushiIcons.subtitles,
    MangaAudioWorkbenchStep.voices => FushiIcons.voice,
    MangaAudioWorkbenchStep.render => FushiIcons.audio,
  };

  String? _summary(MangaAudioWorkbenchStep step) {
    final MangaAudioWorkbenchSnapshot s = snapshot;
    if (!s.supported) return null;
    return switch (step) {
      MangaAudioWorkbenchStep.recognize =>
        ocrRunning
            ? t.manga_series_ocr_queued
            : s.ocrPages == 0
            ? t.manga_audio_workbench_ocr_none
            : t.manga_audio_workbench_ocr_progress(
                done: s.ocrPages,
                total: s.pageCount,
                blocks: s.blockCount,
              ),
      MangaAudioWorkbenchStep.script =>
        s.scriptStale
            ? t.manga_audio_stale
            : s.annotatedPages == 0
            ? t.manga_audio_page_not_annotated
            : _scriptProgress(s),
      MangaAudioWorkbenchStep.voices =>
        s.speakerCount == 0
            ? null
            : t.manga_audio_workbench_voices_summary(
                n: s.speakerCount,
                assigned: s.assignedSpeakers,
              ),
      MangaAudioWorkbenchStep.render =>
        _jobActive
            ? ttsRenderJobStatusText(job!)
            : s.hasAudio
            ? t.manga_audio_workbench_ready
            : s.renderedLines > 0
            ? t.manga_audio_workbench_render_progress(
                done: s.renderedLines,
                total: s.lineCount,
              )
            : t.manga_audio_lines_empty,
    };
  }

  bool _attention(MangaAudioWorkbenchStep step) => switch (step) {
    MangaAudioWorkbenchStep.script => snapshot.scriptStale,
    MangaAudioWorkbenchStep.render => job?.status == TtsRenderJobStatus.failed,
    _ => false,
  };

  List<AudioProductionStepEntry<MangaAudioWorkbenchStep>> get _entries =>
      <AudioProductionStepEntry<MangaAudioWorkbenchStep>>[
        for (final MangaAudioWorkbenchStep step
            in MangaAudioWorkbenchStep.values)
          if (includeAudioSteps ||
              step == MangaAudioWorkbenchStep.recognize ||
              step == MangaAudioWorkbenchStep.script)
            AudioProductionStepEntry<MangaAudioWorkbenchStep>(
              step: step,
              icon: stepIcon(step),
              title: stepTitle(step),
              summary: _summary(step),
              attention: _attention(step),
            ),
      ];

  /// 步骤的主动作：(文案, 图标, 回调；null = 现在不能做)。
  (String, IconData, VoidCallback?) _primary(MangaAudioWorkbenchStep step) {
    final MangaAudioWorkbenchSnapshot s = snapshot;
    final bool ok = s.supported;
    return switch (step) {
      MangaAudioWorkbenchStep.recognize => (
        t.manga_library_ocr_action,
        FushiIcons.ocr,
        ok && !ocrRunning ? onRecognize : null,
      ),
      MangaAudioWorkbenchStep.script => (
        t.manga_audio_workbench_script_open,
        FushiIcons.subtitles,
        ok && s.ocrPages > 0 ? onOpenScript : null,
      ),
      MangaAudioWorkbenchStep.voices => (
        t.manga_audio_workbench_voices_open,
        FushiIcons.voice,
        ok && s.lineCount > 0 ? onOpenStudio : null,
      ),
      MangaAudioWorkbenchStep.render => (
        t.manga_audio_workbench_render_open,
        FushiIcons.play,
        ok && s.lineCount > 0 ? onOpenStudio : null,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final MangaAudioWorkbenchStep step = _effectiveStep;
    return AudioProductionStepLayout<MangaAudioWorkbenchStep>(
      keyPrefix: keyPrefix,
      steps: _entries,
      selected: step,
      onSelect: onSelect,
      header: snapshot.supported
          ? null
          : Padding(
              padding: EdgeInsets.symmetric(
                horizontal: FushiDesignTokens.of(context).spacing.page,
              ),
              child: FushiInlineNotice(
                key: const ValueKey<String>('$keyPrefix-unsupported'),
                severity: FushiNoticeSeverity.error,
                message: snapshot.unsupportedReason!,
              ),
            ),
      body: _body(context, step),
      footerBuilder: (BuildContext context, bool wide) =>
          _footer(context, step, wide: wide),
    );
  }

  Widget _footer(
    BuildContext context,
    MangaAudioWorkbenchStep step, {
    required bool wide,
  }) {
    final (String label, IconData icon, VoidCallback? onPressed) = _primary(
      step,
    );
    final String? summary = _summary(step);
    final Widget status = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (summary != null)
          Text(
            summary,
            key: const ValueKey<String>('$keyPrefix-footer-status'),
            maxLines: wide ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: fushiNeutralSecondaryForeground(context),
            ),
          ),
        if (_jobActive) ...<Widget>[
          const SizedBox(height: 6),
          FushiLinearProgressIndicator(value: ttsRenderJobProgress(job!)),
        ],
      ],
    );
    final Widget primary = FushiPressScale(
      enabled: onPressed != null,
      child: FushiFilledButton.icon(
        key: const ValueKey<String>('$keyPrefix-primary'),
        onPressed: onPressed,
        icon: FushiIcon(icon),
        label: Text(label),
      ),
    );
    if (wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[status, const SizedBox(height: 12), primary],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(child: status),
        const SizedBox(width: 12),
        primary,
      ],
    );
  }

  String _hint(MangaAudioWorkbenchStep step) => switch (step) {
    MangaAudioWorkbenchStep.recognize => t.manga_audio_workbench_ocr_hint,
    MangaAudioWorkbenchStep.script => t.manga_audio_workbench_script_hint,
    MangaAudioWorkbenchStep.voices => t.manga_audio_workbench_voices_hint,
    MangaAudioWorkbenchStep.render => t.manga_audio_workbench_render_hint,
  };

  /// 步骤正文：说明卡、前置条件提示、本步的次要入口；各块错峰进场。
  Widget _body(BuildContext context, MangaAudioWorkbenchStep step) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MangaAudioWorkbenchSnapshot s = snapshot;
    final List<Widget> sections = <Widget>[
      AdaptiveSettingsSection(
        key: ValueKey<String>('$keyPrefix-intro-${step.name}'),
        children: <Widget>[
          AdaptiveSettingsRow(
            icon: stepIcon(step),
            showIcon: true,
            title: _summary(step) ?? stepTitle(step),
            subtitle: _hint(step),
          ),
        ],
      ),
      if (s.supported) ..._notices(step),
      if (step == MangaAudioWorkbenchStep.script && s.preview.isNotEmpty)
        AdaptiveSettingsSection(
          key: const ValueKey<String>('$keyPrefix-script-preview'),
          title: t.manga_audio_section_lines,
          children: <Widget>[
            for (final MangaAudioWorkbenchLine line in s.preview)
              AdaptiveSettingsRow(
                title: line.text.isEmpty ? '…' : line.text,
                subtitle: line.speaker,
                titleMaxLines: 2,
              ),
          ],
        ),
      if (step == MangaAudioWorkbenchStep.render && s.supported)
        AdaptiveSettingsSection(
          key: const ValueKey<String>('$keyPrefix-sources'),
          children: <Widget>[
            AdaptiveSettingsRow(
              key: const ValueKey<String>('$keyPrefix-import'),
              icon: FushiIcons.importFile,
              showIcon: true,
              title: t.manga_audio_import,
              onTap: onImport,
            ),
            AdaptiveSettingsRow(
              key: const ValueKey<String>('$keyPrefix-audiobook-source'),
              icon: FushiIcons.audiobook,
              showIcon: true,
              title: t.manga_audio_source_title,
              onTap: onOpenAudiobookSource,
            ),
            AdaptiveSettingsRow(
              key: const ValueKey<String>('$keyPrefix-drama-track'),
              icon: FushiIcons.mic,
              showIcon: true,
              title: t.manga_audio_drama_title,
              onTap: onOpenDramaTrack,
            ),
          ],
        ),
    ];
    return FushiEntranceScope(
      replayKey: step,
      child: ListView.separated(
        key: ValueKey<String>('$keyPrefix-step-body-${step.name}'),
        primary: false,
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap,
          tokens.spacing.page,
          tokens.spacing.page,
        ),
        itemCount: sections.length,
        separatorBuilder: (BuildContext context, int index) =>
            SizedBox(height: tokens.spacing.gap),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => sections[index],
        ),
      ),
    );
  }

  List<Widget> _notices(MangaAudioWorkbenchStep step) {
    final MangaAudioWorkbenchSnapshot s = snapshot;
    final String? message = switch (step) {
      MangaAudioWorkbenchStep.recognize => null,
      MangaAudioWorkbenchStep.script =>
        s.ocrPages == 0
            ? t.manga_audio_error_no_ocr
            : s.scriptStale
            ? t.manga_audio_stale
            : null,
      MangaAudioWorkbenchStep.voices || MangaAudioWorkbenchStep.render =>
        s.lineCount == 0
            ? t.manga_audio_failure_script_empty
            : s.scriptStale
            ? t.manga_audio_failure_script_stale
            : null,
    };
    if (message == null) return const <Widget>[];
    return <Widget>[
      FushiInlineNotice(
        key: ValueKey<String>('$keyPrefix-notice-${step.name}'),
        severity: FushiNoticeSeverity.warning,
        message: message,
      ),
    ];
  }
}
