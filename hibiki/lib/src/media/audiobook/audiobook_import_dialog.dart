import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/audiobook/audiobook_alignment_service.dart'
    show epubSectionsFromExtractDir, parseCuesForFormat;
import 'package:fushi/src/media/import/audiobook_health_summary.dart';
import 'package:fushi/src/media/import/epub_backed_srt_book.dart';
import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:fushi/src/media/drag_drop/import_dialog_drop.dart';
import 'package:fushi/src/media/import/import_flow_mixin.dart';
import 'package:fushi/src/media/audiobook/subtitle_rematch.dart';
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/sync/deletion_prompt.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi/utils.dart';

/// 有声书导入/移除对话框。
///
/// UI 沿用 `BookImportDialog` 的图标按钮模式：音频来源行提供「选文件」按钮，
/// 用户明确多选音频文件（TODO-1031 删掉了旧的「选目录」整目录吞并入口）。
class AudiobookImportDialog extends StatefulWidget {
  const AudiobookImportDialog({
    required this.bookKey,
    required this.repo,
    this.extractDir,
    this.audioOnly = false,
    this.initialAudioPaths,
    this.initialAlignmentPath,
    super.key,
  });

  /// 书的唯一标识 = EpubBooks.bookKey（也用作有声书 / cue 的 key）。
  final String bookKey;
  final AudiobookRepository repo;

  /// 已导入 EPUB 的提取目录（`EpubBooks.extractDir`）。非空时走 Sasayaki
  /// 路径：从提取目录读章节文本 → EpubSrtMatcher 匹配 → 把命中 cue 的偏移
  /// 编码写回 textFragmentId。standalone（无 EPUB）时为 null。
  final String? extractDir;

  /// When true, only audio files can be imported (alignment row and matcher
  /// settings are hidden). Used for SRT books that already have their own cues.
  final bool audioOnly;

  /// 拖拽导入预填：要附加到该书的音频文件路径（覆盖既有记录的推断音频源）。
  final List<String>? initialAudioPaths;

  /// 拖拽导入预填：对齐用的字幕/对齐文件路径（覆盖既有 alignmentPath）。
  final String? initialAlignmentPath;

  @override
  State<AudiobookImportDialog> createState() => _AudiobookImportDialogState();
}

class _AudiobookImportDialogState extends State<AudiobookImportDialog>
    with ImportFlowMixin<AudiobookImportDialog> {
  // ── 音频来源 ── 两者互斥，最后选的那个生效 ─────────────────────────────────
  String? _audioDir; // folder 模式
  List<String>? _audioPaths; // files 模式

  String? _alignmentPath;
  String? _alignmentName;
  bool _pickerActive = false;

  /// TODO-935 ①A：导入时「引用原文件（不复制）」开关。仅桌面可见/可选；
  /// 移动端 file_picker 返回的是缓存临时副本，引用即指向会被系统清掉的文件，
  /// 故移动端恒 false（隐藏开关、保持复制行为，零回归）。
  bool _referenceOriginal = false;

  /// 已有记录但缺音频源 → 进入"补音频"模式，显示导入表单而非只读视图。
  bool _patchingAudio = false;

  Audiobook? _existing;
  bool _existingLoaded = false;
  Future<AudiobookHealth>? _healthFuture;

  int _searchWindow = EpubSrtMatcher.defaultSearchWindow;
  double _similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold;

  // ── 自动匹配 probe 缓存 ─────────────────────────────────────────────────────
  // 反复点"自动匹配"时只读一次 ttu IDB / 只 parse 一次 cues。dialog dispose 即释放。
  bool _autoProbing = false;
  List<EpubSection>? _probedSections;
  List<AudioCue>? _probedCues;
  String? _probedCuesSourcePath;

  /// 只有 srt/lrc/vtt/ass 才跑 matcher（SMIL/JSON 有硬时间码锚点，与
  /// window 无关），且必须绑定了 ttu 才有 sections 可查，否则 slider 隐藏。
  /// 是否绑定了一本已导入的 EPUB（有提取目录可供 matcher 读章节文本）。
  bool get _hasEpub =>
      widget.extractDir != null && widget.extractDir!.isNotEmpty;

  bool get _willRunMatcher {
    if (_alignmentPath == null) return false;
    if (!_hasEpub) return false;
    final String ext = _alignmentPath!.split('.').last.toLowerCase();
    return SubtitleRematch.supportedFormats.contains(ext);
  }

  bool get _canAutoProbe => _willRunMatcher;

  // ── 辅助 getter ─────────────────────────────────────────────────────────────

  bool get _hasAudioSource =>
      (_audioDir != null) || (_audioPaths != null && _audioPaths!.isNotEmpty);

  String get _audioSourceLabel {
    if (_audioPaths != null && _audioPaths!.isNotEmpty) {
      return t.srt_import_files_selected(n: _audioPaths!.length);
    }
    if (_audioDir != null) return p.basename(_audioDir!);
    return '';
  }

  @override
  void initState() {
    super.initState();
    _initExisting();
  }

  // 进度 ValueNotifier 由 ImportFlowMixin.dispose() 释放（无本地 dispose
  // override 时 mixin 的 dispose() 即生效）。

  Future<void> _initExisting() async {
    final Audiobook? existing = await widget.repo.findByBookKey(widget.bookKey);
    if (!mounted) return;
    setState(() {
      _existing = existing;
      _existingLoaded = true;
      if (existing != null) {
        _healthFuture = widget.repo.resolveHealth(existing);
        if (!_existingHasAudio(existing)) {
          _patchingAudio = true;
          _alignmentPath = existing.alignmentPath;
        }
      }
      // 拖拽导入预填：拖入值覆盖 existing 推断的音频源 / 对齐文件。
      final List<String>? dropAudio = widget.initialAudioPaths;
      if (dropAudio != null && dropAudio.isNotEmpty) {
        _audioPaths = dropAudio;
        _audioDir = null;
      }
      final String? dropAlign = widget.initialAlignmentPath;
      if (dropAlign != null) {
        _alignmentPath = dropAlign;
        _alignmentName = p.basename(dropAlign);
      }
      // 有预填时强制走导入表单：书已有完整有声书时 showImportForm 默认为 false
      // （existing != null && !_patchingAudio）→ 只读视图会静默忽略预填值。
      // 复用"补音频"语义，让拖入的音频/对齐文件进入可保存的导入表单。
      final bool hasDropPrefill =
          (dropAudio != null && dropAudio.isNotEmpty) || dropAlign != null;
      if (hasDropPrefill) {
        _patchingAudio = true;
      }
    });
  }

  static bool _existingHasAudio(Audiobook ab) =>
      (ab.audioPaths != null && ab.audioPaths!.isNotEmpty) ||
      (ab.audioRoot != null && ab.audioRoot!.isNotEmpty);

  // ── 构建 ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return HibikiFileDropTarget(
      enabled: !importing,
      debugLabel: 'audiobook-import-dialog',
      onDrop: _handleDialogDrop,
      child: _buildContent(context),
    );
  }

  /// 拖文件进本对话框 → 全部音频写 `_audioPaths`（清 `_audioDir`，两者互斥）、
  /// 第一个字幕写 `_alignmentPath`，并复用「强制进可保存导入表单」语义
  /// （`_patchingAudio = true`）——否则已有完整有声书时只读视图会静默丢弃拖入值。
  /// 纯解析交给 [resolveAudiobookDialogDrop]。
  void _handleDialogDrop(List<String> paths, Offset _) {
    if (importing) return;
    final DroppedFiles files = classifyDroppedFiles(paths);
    final AudiobookDialogDropResult r = resolveAudiobookDialogDrop(files);
    if (r.isEmpty) return;
    setState(() {
      if (r.audioPaths.isNotEmpty) {
        _audioPaths = r.audioPaths;
        _audioDir = null;
      }
      if (r.alignmentPath != null) {
        _alignmentPath = r.alignmentPath;
        _alignmentName = p.basename(r.alignmentPath!);
        _probedCues = null;
        _probedCuesSourcePath = null;
      }
      // 让拖入值进入可保存的导入表单（见 _initExisting 的同款闸门注释）。
      _patchingAudio = true;
    });
  }

  Widget _buildContent(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    if (!_existingLoaded) {
      return AudiobookImportDialogFrame(
        title: widget.audioOnly ? t.audio_import : t.audiobook_import,
        content: SizedBox(
          height: tokens.spacing.card * 4,
          child: Center(child: adaptiveIndicator(context: context)),
        ),
        actions: const <Widget>[],
      );
    }

    final Audiobook? existing = _existing;
    final bool showImportForm = existing == null || _patchingAudio;

    return AudiobookImportDialogFrame(
      title: showImportForm
          ? (widget.audioOnly ? t.audio_import : t.audiobook_import)
          : t.audiobook_attached,
      content:
          showImportForm ? _buildImportForm() : _buildAttachedView(existing),
      actions: showImportForm
          ? [
              adaptiveDialogAction(
                context: context,
                onPressed: () => Navigator.pop(context),
                child: Text(t.dialog_cancel),
              ),
              buildImportAction(context, onImport: _doImport),
            ]
          : [
              adaptiveDialogAction(
                context: context,
                onPressed: () => Navigator.pop(context),
                child: Text(t.dialog_close),
              ),
              adaptiveDialogAction(
                context: context,
                onPressed: () => _enterReplaceSubtitleMode(existing),
                child: Text(t.audio_panel_pick_new_subtitle),
              ),
              adaptiveDialogAction(
                context: context,
                isDestructiveAction: true,
                onPressed: () => _removeAudiobook(existing),
                child: Text(t.audiobook_delete),
              ),
            ],
    );
  }

  Widget _buildAttachedView(Audiobook ab) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String audioLabel =
        (ab.audioPaths != null && ab.audioPaths!.isNotEmpty)
            ? t.srt_import_files_selected(n: ab.audioPaths!.length)
            : (ab.audioRoot ?? '');
    return FutureBuilder<AudiobookHealth>(
      future: _healthFuture,
      builder: (context, snapshot) {
        final AudiobookHealth health =
            snapshot.data ?? AudiobookHealth.fromAudiobook(ab);
        final Widget? healthRow = _buildHealthRow(health);
        final bool canReMatch = _canReMatch(ab, health);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AdaptiveSettingsSection(
              children: [
                HibikiFilePickerRow(
                  title: (ab.audioPaths != null && ab.audioPaths!.isNotEmpty)
                      ? t.srt_import_pick_audio_files
                      : t.srt_import_pick_audio_dir,
                  subtitle: audioLabel,
                  icon: (ab.audioPaths != null && ab.audioPaths!.isNotEmpty)
                      ? Icons.audio_file_outlined
                      : Icons.folder_open_outlined,
                ),
                HibikiFilePickerRow(
                  title: t.audiobook_pick_alignment,
                  subtitle: ab.alignmentPath,
                  icon: Icons.align_horizontal_left,
                ),
              ],
            ),
            if (healthRow != null) ...[
              SizedBox(height: tokens.spacing.gap),
              healthRow,
            ],
            if (canReMatch) ...[
              SizedBox(height: tokens.spacing.rowVertical),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: importing ? null : () => _openReMatchSheet(ab),
                  icon: const Icon(Icons.tune_outlined, size: 18),
                  label: Text(t.rematch_adjust_window),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// 只有挂了 ttu book 且 alignmentFormat 属于 matcher 管线（srt/lrc/vtt/ass）
  /// 才显示重跑入口。SMIL/JSON 走信任文件锚点，与 searchWindow 无关。
  /// unrun 状态也允许重跑 — 历史脏记录的书借此给它跑一次。
  bool _canReMatch(Audiobook ab, AudiobookHealth health) {
    if (!_hasEpub) return false;
    if (!SubtitleRematch.isEligible(ab)) return false;
    switch (health.kind) {
      case HealthKind.partial:
      case HealthKind.failed:
      case HealthKind.unrun:
      case HealthKind.ok: // 让用户也能收紧窗口搏一个更高的匹配率
        return true;
      case HealthKind.running:
      case HealthKind.notApplicable:
        return false;
    }
  }

  /// 已附加有声书时展示匹配状态。notApplicable / unrun → 不渲染（无信息可看）。
  /// reason 来自 matcher（如 "123/140 cues matched"），直接展示给用户。
  Widget? _buildHealthRow(AudiobookHealth health) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    IconData icon;
    Color color;
    String label;
    // pct 为 null 时多半是历史脏记录（见 AudiobookHealth.fromAudiobook 的 clamp
    // 注释）——显示 "?" 而非 0%，避免用绿色对勾配一个假的 0%。
    final String pctStr = health.ratePct?.toString() ?? '?';
    final String? reason = health.reason;
    final String tail = (reason == null || reason.isEmpty) ? '' : ' · $reason';
    final cs = Theme.of(context).colorScheme;
    switch (health.kind) {
      case HealthKind.ok:
        icon = Icons.check_circle;
        color = cs.tertiary;
        label = t.audiobook_rematch_health_label(pct: '$pctStr%', detail: tail);
      case HealthKind.partial:
        icon = Icons.warning_amber;
        color = cs.secondary;
        label = t.audiobook_rematch_health_label(pct: '$pctStr%', detail: tail);
      case HealthKind.failed:
        icon = Icons.error_outline;
        color = cs.error;
        label = t.audiobook_rematch_health_label(pct: '$pctStr%', detail: tail);
      case HealthKind.running:
      case HealthKind.unrun:
      case HealthKind.notApplicable:
        return null;
    }
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        SizedBox(width: tokens.spacing.gap),
        Expanded(
          child: Text(
            label,
            style: tokens.type.metadata.copyWith(color: color),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildImportForm() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveSettingsSection(
          children: [
            _audioSourceRow(),
            if (!widget.audioOnly) _alignmentRow(),
          ],
        ),
        if (isDesktopPlatform) ...[
          SizedBox(height: tokens.spacing.gap),
          AdaptiveSettingsSection(
            children: [
              AdaptiveSettingsSwitchRow(
                title: t.audiobook_reference_original,
                subtitle: t.audiobook_reference_original_desc,
                icon: Icons.link_outlined,
                value: _referenceOriginal,
                onChanged: importing
                    ? null
                    : (bool v) => setState(() => _referenceOriginal = v),
              ),
            ],
          ),
        ],
        if (!widget.audioOnly && _willRunMatcher) ...[
          SizedBox(height: tokens.spacing.rowVertical),
          SubtitleRematchWindowSlider(
            value: _searchWindow,
            onChanged: (v) => setState(() => _searchWindow = v),
            onAutoTap: _canAutoProbe ? _handleAutoProbe : null,
            autoBusy: _autoProbing,
          ),
          SizedBox(height: tokens.spacing.gap),
          SubtitleRematchThresholdSlider(
            value: _similarityThreshold,
            onChanged: (v) => setState(() => _similarityThreshold = v),
          ),
        ],
        if (importing) ...buildProgressSection(context, tokens),
      ],
    );
  }

  /// 音频来源行：标签 + [选文件] 按钮。
  ///
  /// TODO-1031：只保留「选文件」入口，删掉旧的「选目录」按钮。旧目录模式
  /// 会把用户指向的整个文件夹里所有音频一股脑塞进同一本书，
  /// 用户抱怨「导入文件夹书籍把一系列音频全弄进一本」即此。
  /// 真正的多段章节有声书（一本书 N 个章节音频）仍可通过「选文件」多选精确选中，
  /// 由用户明确挑文件而非盲目吞整个目录 —— 多段有声书语义完好保留。
  Widget _audioSourceRow() {
    return HibikiFilePickerRow(
      title: t.srt_import_pick_audio_files,
      subtitle: _hasAudioSource ? _audioSourceLabel : null,
      icon: Icons.audio_file_outlined,
      onTap: _pickAudioFiles,
      actions: [
        HibikiIconButton(
          icon: Icons.audio_file_outlined,
          tooltip: t.srt_import_pick_audio_files,
          isWideTapArea: true,
          onTap: _pickAudioFiles,
        ),
      ],
    );
  }

  /// 对齐文件行：标签 + [选文件] 按钮。
  Widget _alignmentRow() {
    return HibikiFilePickerRow(
      title: t.audiobook_pick_alignment,
      subtitle: _alignmentPath == null
          ? null
          : _alignmentName ?? p.basename(_alignmentPath!),
      icon: Icons.align_horizontal_left,
      onTap: _pickAlignment,
      actions: [
        HibikiIconButton(
          icon: Icons.align_horizontal_left,
          tooltip: t.audiobook_pick_alignment,
          isWideTapArea: true,
          onTap: _pickAlignment,
        ),
      ],
    );
  }

  // ── 文件/目录选择 ────────────────────────────────────────────────────────────

  Future<void> _pickAudioFiles() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final AppModel appModel =
          ProviderScope.containerOf(context, listen: false).read(appProvider);
      final List<String> paths = await pickRealFilePaths(
        context: context,
        appModel: appModel,
        allowedExtensions: AudiobookStorage.audioExtensionsNoDot,
      );
      if (!mounted) return;
      paths.sort(compareAudioFilePath);

      if (paths.isNotEmpty) {
        setState(() {
          _audioPaths = paths;
          _audioDir = null;
        });
      }
    } finally {
      _pickerActive = false;
    }
  }

  static const Set<String> _alignmentExtensions = {
    'smil',
    'srt',
    'lrc',
    'vtt',
    'ass',
    'ssa',
    'json',
  };

  Future<void> _pickAlignment() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      // 对齐字幕 / SMIL / JSON 导入时即被解析跑 matcher 当场消费，不以绝对路径长期引用，
      // 故维持系统文件选择器（board 1360）：用户熟悉，且能触达 Downloads / 云盘 / 最近文件。
      final String? path = await pickSystemFilePath(
        context: context,
        allowedExtensions: _alignmentExtensions,
      );
      if (path == null || !mounted) return;
      final String ext = p.extension(path).toLowerCase().replaceFirst('.', '');
      if (!_alignmentExtensions.contains(ext)) {
        HibikiToast.show(
          msg: t.import_unsupported_file_format(ext: '.$ext'),
          severity: ToastSeverity.error,
        );
        return;
      }
      setState(() {
        _alignmentPath = path;
        _alignmentName = p.basename(path);
        _probedCues = null;
        _probedCuesSourcePath = null;
      });
    } finally {
      _pickerActive = false;
    }
  }

  /// 「自动匹配」按钮：probe 当前 alignment 对本书 ttu sections 在多档 window
  /// 下的命中率，挑最高的一档回写到 slider。cues / sections 缓存避免同一次
  /// 对话反复点击时重复 IO。
  Future<void> _handleAutoProbe() async {
    if (!_canAutoProbe || _alignmentPath == null) return;
    setState(() => _autoProbing = true);
    try {
      _probedSections ??= await _loadSectionsForProbe();
      if (_probedCues == null || _probedCuesSourcePath != _alignmentPath) {
        _probedCues = await _parseCuesForProbe();
        _probedCuesSourcePath = _alignmentPath;
      }
      final int? best = await SubtitleRematch.runAutoProbe(
        sections: _probedSections ?? const <EpubSection>[],
        cues: _probedCues ?? const <AudioCue>[],
      );
      if (best != null && mounted) {
        setState(() => _searchWindow = best);
      }
    } finally {
      if (mounted) setState(() => _autoProbing = false);
    }
  }

  Future<List<EpubSection>> _loadSectionsForProbe() async {
    if (!_hasEpub) {
      return const <EpubSection>[];
    }
    try {
      return epubSectionsFromExtractDir(widget.extractDir!);
    } catch (e, stack) {
      ErrorLogService.instance.log('AudiobookImport.loadSections', e, stack);
      debugPrint('[hibiki-audiobook] probe loadSections failed: $e');
      return const <EpubSection>[];
    }
  }

  /// 只 parse 不落库 —— 导入尚未 commit，不能污染 Isar。正式导入走 _parseCues。
  Future<List<AudioCue>> _parseCuesForProbe() async {
    final String? path = _alignmentPath;
    if (path == null) return const <AudioCue>[];
    final String ext = path.split('.').last.toLowerCase();
    // probe 口径与 matcher 管线一致：仅 srt/lrc/vtt/ass；其余（含 ssa/smil/json/
    // 未知扩展名）返回空——与收敛前的显式四分支 + default 空返回逐位等价
    // （公共函数 default 落 SRT，故必须先用 supportedFormats 门控）。
    if (!SubtitleRematch.supportedFormats.contains(ext)) {
      return const <AudioCue>[];
    }
    try {
      return await parseCuesForFormat(File(path), widget.bookKey, 0);
    } catch (e, stack) {
      ErrorLogService.instance.log('AudiobookImport.parseCues', e, stack);
      debugPrint('[hibiki-audiobook] probe parseCues failed: $e');
      return const <AudioCue>[];
    }
  }

  // ── 导入 ─────────────────────────────────────────────────────────────────────

  Future<void> _doImport() async {
    if (!_hasAudioSource || (!widget.audioOnly && _alignmentPath == null)) {
      HibikiToast.show(
        msg: t.audiobook_import_error,
        severity: ToastSeverity.error,
      );
      return;
    }

    debugPrint(
        '[hibiki-audiobook] doImport bookKey.len=${widget.bookKey.length} '
        'hash=${widget.bookKey.hashCode} key=${widget.bookKey}');
    setState(() => importing = true);
    reportProgress(0, '');

    int grandTotal = 0;
    try {
      String? persistedAlignment;
      ({AudiobookHealth health, List<AudioCue> cues})? parsed;

      final Directory persistDir = await _ensurePersistDir();

      if (!widget.audioOnly && _alignmentPath != null) {
        final String ext = _alignmentPath!.split('.').last.toLowerCase();
        // HBK-AUDIT-068: re-validate the extension against the supported set
        // at import time. A path reaching here via a non-picker route (e.g.
        // an existing book's persisted alignment) might carry an extension
        // that never went through the picker's allow-list, and force-routing
        // it through the json parser would only surface as a generic decode
        // error. Bail early with a format-specific message instead.
        if (!_alignmentExtensions.contains(ext)) {
          if (mounted) {
            HibikiToast.show(
              msg: t.import_unsupported_file_format(ext: '.$ext'),
              severity: ToastSeverity.error,
            );
          }
          return;
        }
        // After validation every ext is a supported format that _parseCues
        // routes 1:1 to its parser (smil/json via the else/json branches).
        final String format = ext;

        reportProgress(0.05, t.import_step_persisting);
        // HBK-AUDIT-068: keep the persisted path in a local instead of
        // mutating the stateful _alignmentPath, so a retry after a failure
        // re-reads the user-picked source rather than a stale persisted copy.
        persistedAlignment = await AudiobookStorage.persistFileWithProgress(
          File(_alignmentPath!),
          persistDir,
        );

        reportProgress(0.1, t.import_step_parsing);
        parsed = await _parseCues(
          format: format,
          alignmentFilePath: persistedAlignment,
        );
      }

      reportProgress(0.5, t.import_step_persisting);

      // 收集需要复制的音频文件（file mode：用户经「选文件」明确挑选的列表）。
      // 复制到持久化目录——Android 11+ scoped storage 下，SAF 临时授权的路径
      // 后续可能无法访问。
      //
      // TODO-1031：旧的目录模式（指向一个文件夹后扫描其下全部音频）已删除——它是
      // 用户抱怨「导入文件夹书籍把一系列音频全弄进一本」的根因。新导入只走用户
      // 明确多选的音频文件列表；多段章节有声书由用户显式多选章节文件表达，语义
      // 完好。legacy audioRoot 记录仍可在只读视图 / 换字幕模式回显，但不再作为
      // 新导入的输入源。
      final List<File> audioCopyFiles = <File>[];
      if (_audioPaths != null && _audioPaths!.isNotEmpty) {
        audioCopyFiles.addAll(_audioPaths!.map(File.new));
      }

      // TODO-935 ①A：引用模式（仅桌面）下不复制音频，直接存原始绝对路径
      // （仿 VideoBooks 的 `videoPath: Value(only.path)`）。读取/删除按路径是否在
      // 持久根之外派生「引用 vs 已复制」，无需额外标记列。
      final bool referenceAudio = _referenceOriginal && isDesktopPlatform;
      final List<String> persistedPaths = <String>[];
      if (referenceAudio) {
        await AudiobookStorage.cleanAudioFiles(persistDir);
        persistedPaths.addAll(audioCopyFiles.map((File f) => f.path));
      } else {
        for (final File f in audioCopyFiles) {
          if (!p.isWithin(
              p.canonicalize(persistDir.path), p.canonicalize(f.path))) {
            grandTotal += await f.length();
          }
        }
        int grandCopied = 0;

        await AudiobookStorage.cleanAudioFiles(persistDir);
        for (final File srcFile in audioCopyFiles) {
          final int fileLen = await srcFile.length();
          final int capturedGrandCopied = grandCopied;
          persistedPaths.add(
            await AudiobookStorage.persistFileWithProgress(
              srcFile,
              persistDir,
              onProgress: (int copied, int total) {
                final double ratio = grandTotal > 0
                    ? (capturedGrandCopied + copied) / grandTotal
                    : 0.0;
                reportProgress(0.5 + ratio * 0.3,
                    t.import_step_copying_file(name: p.basename(srcFile.path)));
              },
            ),
          );
          grandCopied += fileLen;
        }
      }

      reportProgress(0.8, t.import_step_saving);
      final Audiobook audiobook = Audiobook()..bookKey = widget.bookKey;

      if (persistedAlignment != null) {
        final String ext = persistedAlignment.split('.').last.toLowerCase();
        const Set<String> cueFormats = {'smil', 'srt', 'lrc', 'vtt', 'ass'};
        audiobook
          ..alignmentFormat = cueFormats.contains(ext) ? ext : 'json'
          ..alignmentPath = persistedAlignment;
      }

      if (persistedPaths.isNotEmpty) {
        audiobook.audioPaths = persistedPaths;
      }

      if (parsed != null) {
        parsed.health.packInto(audiobook);
      }
      await widget.repo.saveAudiobook(audiobook);
      // TODO-1288：EPUB-backed 有声书导入必须补写一条配对 srt_books 行，否则互联
      // host 的 hasAudiobook 判据（app_model_library_host_service
      // ._srtBackedAudiobookKeys 要求 audiobooks + srt_books 两表齐备）认不出这本
      // 书 → 对端下载后显示成普通书、且 exportAudiobook 抛 StateError → 音频永不
      // 同步。book_import_dialog / audiobook_alignment_service / v29 backfill 三处
      // 均已补写，唯本对话框（给已有 EPUB 书加/换音频）遗漏，v29 之后的新导入不再
      // 被一次性 backfill 覆盖。与它们共用同一稳定派生 uid（srtbook_epub_<bookKey>）
      // 保持幂等。判据 = epub_books 存在（等价 v29 backfill 的 audiobooks JOIN
      // epub_books）；standalone（无 EPUB backing）与 audioOnly（SrtBook 已存在）
      // 天然豁免。非 audioOnly 路径在 line 637 已门控 alignment 非空，故
      // persistedAlignment 此处必非 null。
      if (!widget.audioOnly && persistedAlignment != null) {
        final EpubBookRow? epubRow =
            await widget.repo.database.getEpubBook(widget.bookKey);
        if (epubRow != null) {
          await writeEpubBackedSrtBook(
            repo: SrtBookRepository(widget.repo.database),
            bookKey: widget.bookKey,
            title: epubRow.title,
            author: epubRow.author,
            srtPath: persistedAlignment,
            audioPaths: persistedPaths,
          );
        }
      }
      if (parsed != null) {
        // TODO-811: single-timeline subtitle formats (srt/lrc/vtt/ass) carry one
        // continuous timeline, so the parser sets every cue's audioFileIndex to 0.
        // With multiple audio files that cuts sentence audio from the wrong file.
        // SMIL/JSON already map files/fragments themselves, so skip them. Probe
        // per-file durations and rebind each cue to its real file + local time.
        const Set<String> singleTimelineFormats = {'srt', 'lrc', 'vtt', 'ass'};
        if (persistedPaths.length > 1 &&
            persistedAlignment != null &&
            singleTimelineFormats.contains(audiobook.alignmentFormat)) {
          final List<int> durationsMs =
              await AudiobookStorage.probeAudioDurationsMs(persistedPaths);
          if (durationsMs.length == persistedPaths.length &&
              durationsMs.every((int d) => d > 0)) {
            reindexCuesByFileBoundaries(
              cues: parsed.cues,
              fileDurationsMs: durationsMs,
            );
          } else {
            debugPrint('[AudiobookImport] TODO-811 skip cue reindex: '
                'duration probe incomplete ($durationsMs).');
          }
        }
        await widget.repo.saveCues(
          bookKey: widget.bookKey,
          cues: parsed.cues,
        );
        await widget.repo.updateHealthOverlay(
          bookKey: widget.bookKey,
          health: parsed.health,
        );
      }
      reportProgress(1, t.import_step_done);

      if (mounted) {
        final String? tail =
            parsed != null ? summarizeAudiobookHealth(parsed.health) : null;
        final String msg = tail == null
            ? t.audiobook_import_success
            : '${t.audiobook_import_success} · $tail';
        HibikiToast.show(msg: msg, severity: ToastSeverity.success);
        Navigator.pop(context, true); // true = reload player
      }
    } on FileSystemException catch (e, stack) {
      ErrorLogService.instance.log('AudiobookImport.doImport', e, stack);
      debugPrint('AudiobookImportDialog import error (FS): $e');
      if (mounted) {
        final bool diskFull = e.osError?.errorCode == 28 ||
            e.message.toLowerCase().contains('no space');
        if (diskFull) {
          HibikiToast.show(
            msg: t.audiobook_import_error_disk_full(
              size: _formatBytes(grandTotal),
            ),
            toastLength: Toast.LENGTH_LONG,
            severity: ToastSeverity.error,
          );
        } else {
          HibikiToast.show(
            msg: t.audiobook_import_error_copy_failed(
              name: e.path ?? '',
            ),
            severity: ToastSeverity.error,
          );
        }
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('AudiobookImport.doImport', e, stack);
      debugPrint('AudiobookImportDialog import error: $e');
      if (mounted) {
        HibikiToast.show(
          msg: t.audiobook_import_error,
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => importing = false);
      }
    }
  }

  /// 已附加书的重跑匹配入口：委托给 [SasayakiRematch.promptAndRun]，跑完
  /// health 走 Hive overlay（不 put Audiobook，避免二次 put 把 matchRatePct
  /// 字节写坏）。
  Future<void> _openReMatchSheet(Audiobook ab) async {
    if (!_hasEpub) {
      HibikiToast.show(
        msg: t.reader_not_bound_cannot_rematch,
        severity: ToastSeverity.error,
      );
      return;
    }
    await SubtitleRematch.promptAndRun(
      context: context,
      ab: ab,
      repo: widget.repo,
      extractDir: widget.extractDir!,
      onRunningChanged: (running) {
        if (mounted) setState(() => importing = running);
      },
    );
    // 跑完无论成败都刷一次，让 healthRow 重新读 overlay。
    if (mounted) setState(() {});
  }

  /// 对 SRT/LRC/VTT/ASS 四格式：若本书已挂 ttu，跑 [EpubCueMatcher] 把命中
  /// cue 的 section/charStart/charEnd 编码写回 [AudioCue.textFragmentId]。
  /// 失败不中断导入（cues 仍按原样落库，少的只是跨章定位能力）。
  ///
  /// 返回值是本次匹配的健康度：matcher 跑起来 → fromRatePct；没 ttu 绑定 →
  /// notApplicable；reader 失败 / cues 为空 → failed。调用方据此写回
  /// [Audiobook.healthKindRaw] 等字段。
  Future<AudiobookHealth> _matchCuesToTtu(List<AudioCue> cues) async {
    if (!_hasEpub) {
      return AudiobookHealth.notApplicable(
        reason: 'no book bound — subtitle playback works, but no '
            'cross-chapter highlight',
      );
    }
    if (cues.isEmpty) {
      return AudiobookHealth.failed(reason: 'parser returned 0 cues');
    }
    try {
      reportProgress(0.2, t.import_step_reading_idb);
      final List<EpubSection> sections =
          epubSectionsFromExtractDir(widget.extractDir!);
      if (sections.isEmpty) {
        return AudiobookHealth.failed(
          reason: 'EPUB has 0 chapters',
        );
      }
      reportProgress(0.3, t.import_step_matching);
      // 匹配器放 isolate 跑，主线程不能被大书的 bigram 扫描挤出 ANR。
      final MatchResult result = await EpubCueMatcher.matchInIsolate(
        sections: sections,
        cues: cues,
        searchWindow: _searchWindow,
        similarityThreshold: _similarityThreshold,
      );
      SubtitleRematchCodec.applyToCues(cues: cues, result: result);
      final int pct = (result.matchRate * 100).round();
      return AudiobookHealth.fromRatePct(
        ratePct: pct,
        reason: '${result.matchedCues}/${result.totalCues} cues matched '
            '(window=$_searchWindow threshold=$_similarityThreshold)',
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('AudiobookImport.epubCueMatcher', e, stack);
      debugPrint('EpubCueMatcher failed: $e');
      return AudiobookHealth.failed(reason: 'matcher threw: $e');
    }
  }

  static const int _maxCuesPerFile = 50000;

  /// 解析字幕文件并运行 matcher（如适用）。返回 cues 和 health，
  /// 但 **不写入数据库**——调用方在 saveAudiobook 之后再 saveCues，
  /// 避免中途失败留下孤立 cue。
  // HBK-AUDIT-068: parse from an explicit file path passed by the caller
  // instead of reading the mutable _alignmentPath field, so the persisted
  // copy is threaded as data rather than via shared state.
  Future<({AudiobookHealth health, List<AudioCue> cues})> _parseCues({
    required String format,
    required String alignmentFilePath,
  }) async {
    final File alignFile = File(alignmentFilePath);

    List<AudioCue> cues;
    bool useFragmentHealth = false;
    String formatLabel = format;

    const Set<String> subtitleFormats = <String>{
      'srt',
      'lrc',
      'vtt',
      'ass',
      'ssa',
    };
    if (subtitleFormats.contains(format)) {
      // 四个字幕分支收敛到公共 parseCuesForFormat：按文件扩展名分派，与原
      // 显式分支逐字节等价（持久化副本保留原 basename/扩展名，见
      // AudiobookStorage.persistFileWithProgress 的碰撞改名逻辑）。
      cues = await parseCuesForFormat(alignFile, widget.bookKey, 0);
    } else if (format == 'json') {
      cues = await JsonAlignmentParser.parse(
          jsonFile: alignFile, bookKey: widget.bookKey);
      useFragmentHealth = true;
    } else {
      final String fileName = p.basename(alignmentFilePath);
      final String chapterHref = fileName.replaceAll(
          RegExp(r'\.smil$', caseSensitive: false), '.xhtml');
      cues = await SmilParser.parse(
          smilFile: alignFile,
          bookKey: widget.bookKey,
          chapterHref: chapterHref);
      useFragmentHealth = true;
      formatLabel = 'smil';
    }

    if (cues.length > _maxCuesPerFile) {
      debugPrint('[AudiobookImport] cue count ${cues.length} exceeds limit '
          '$_maxCuesPerFile, truncating');
      cues = cues.sublist(0, _maxCuesPerFile);
    }

    final AudiobookHealth health = useFragmentHealth
        ? _healthFromFragmentIntegrity(cues, formatLabel: formatLabel)
        : await _matchCuesToTtu(cues);
    return (health: health, cues: cues);
  }

  /// SMIL/JSON 的静态健康度：基于 cue 自带的 textFragmentId 完整度。
  ///
  /// SMIL fragment 形如 `#sN`，JSON 是 CSS selector。非空即视为"有定位能力"。
  /// PR8 落地后 JSON 还会追加一次 DOM 命中率复核，此处先给兜底值。
  AudiobookHealth _healthFromFragmentIntegrity(
    List<AudioCue> cues, {
    required String formatLabel,
  }) {
    if (cues.isEmpty) {
      return AudiobookHealth.failed(
        reason: '$formatLabel parser returned 0 cues',
      );
    }
    int intact = 0;
    for (final AudioCue c in cues) {
      if (c.textFragmentId.isNotEmpty) {
        intact++;
      }
    }
    final int pct = (intact * 100 / cues.length).round();
    return AudiobookHealth.fromRatePct(
      ratePct: pct,
      reason: '$intact/${cues.length} cues have fragment id',
    );
  }

  void _enterReplaceSubtitleMode(Audiobook ab) {
    setState(() {
      _patchingAudio = true;
      _alignmentPath = ab.alignmentPath;
      _alignmentName = p.basename(ab.alignmentPath);
      if (ab.audioPaths != null && ab.audioPaths!.isNotEmpty) {
        _audioPaths = List<String>.from(ab.audioPaths!);
      } else if (ab.audioRoot != null && ab.audioRoot!.isNotEmpty) {
        _audioDir = ab.audioRoot;
      }
    });
  }

  Future<void> _removeAudiobook(Audiobook ab) async {
    debugPrint('AudiobookImportDialog: remove tapped for ${widget.bookKey}');
    final NavigatorState outerNavigator =
        Navigator.of(context, rootNavigator: true);

    final DeleteScope? scope = await showDeleteScopeConfirm(
      context,
      title: t.dialog_delete,
      message: t.audiobook_delete_confirm,
      disclosure: buildDeletionDisclosure(
        target: DeletionDisclosureTarget.attachedAudiobook,
      ),
      db: widget.repo.database,
    );
    debugPrint('AudiobookImportDialog: scope=$scope');
    if (scope == null) return;

    try {
      await widget.repo.deleteAudiobook(
        widget.bookKey,
        propagateDeletion: scope == DeleteScope.syncEverywhere,
      );
      debugPrint('AudiobookImportDialog: deleteAudiobook done');
    } catch (e, st) {
      ErrorLogService.instance.log('AudiobookImport.deleteAudiobook', e, st);
      debugPrint('AudiobookImportDialog: deleteAudiobook failed: $e\n$st');
      if (mounted) {
        HibikiToast.show(
          msg: t.audiobook_import_error,
          severity: ToastSeverity.error,
        );
      }
      return;
    }

    if (mounted) {
      outerNavigator.pop(false); // false = no audiobook
    }
  }

  Future<Directory> _ensurePersistDir() =>
      AudiobookStorage.ensurePersistDir(widget.bookKey);

  static String _formatBytes(int bytes) => HibikiByteFormat.bytes(bytes);
}

@visibleForTesting
class AudiobookImportDialogFrame extends StatelessWidget {
  const AudiobookImportDialogFrame({
    required this.title,
    required this.content,
    required this.actions,
    super.key,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return ImportDialogFrame(
      title: title,
      leadingIcon: Icons.headphones_outlined,
      body: content,
      actions: actions,
    );
  }
}

@visibleForTesting
class AudiobookRemoveConfirmationDialog extends StatelessWidget {
  const AudiobookRemoveConfirmationDialog({
    required this.onConfirm,
    super.key,
  });

  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      child: HibikiModalSheetFrame(
        title: t.dialog_delete,
        leadingIcon: Icons.delete_outline,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          t.audiobook_delete_confirm,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: onConfirm,
              child: Text(t.audiobook_delete),
            ),
          ],
        ),
      ),
    );
  }
}
