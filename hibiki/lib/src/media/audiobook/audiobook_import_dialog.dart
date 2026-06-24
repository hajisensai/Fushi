import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart'
    show BookImportDialog;
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/drag_drop/import_dialog_drop.dart';
import 'package:hibiki/src/media/audiobook/import_dialog_progress_mixin.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_rematch.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/utils.dart';

/// 有声书导入/移除对话框。
///
/// UI 沿用 [BookImportDialog] 的双图标按钮模式：每一项右侧提供
/// "选目录"和"选文件"两个按钮，可在两种音频来源模式间切换。
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
    with ImportDialogProgressMixin<AudiobookImportDialog> {
  // ── 音频来源 ── 两者互斥，最后选的那个生效 ─────────────────────────────────
  String? _audioDir; // folder 模式
  List<String>? _audioPaths; // files 模式

  String? _alignmentPath;
  String? _alignmentName;
  bool _pickerActive = false;

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
    return SasayakiRematch.supportedFormats.contains(ext);
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

  // 进度 ValueNotifier 由 ImportDialogProgressMixin.dispose() 释放（无本地 dispose
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
              adaptiveDialogAction(
                context: context,
                isDefaultAction: true,
                onPressed: importing ? null : _doImport,
                child: importing
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: tokens.spacing.gap * 2,
                            height: tokens.spacing.gap * 2,
                            child: adaptiveIndicator(
                              context: context,
                              strokeWidth: 2,
                              color: tokens.surfaces.primary,
                            ),
                          ),
                          SizedBox(width: tokens.spacing.gap),
                          Text(t.dialog_importing),
                        ],
                      )
                    : Text(t.dialog_import),
              ),
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
                child: Text(t.audiobook_remove),
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
    if (!SasayakiRematch.isEligible(ab)) return false;
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
        label = t.sasayaki_health_label(pct: '$pctStr%', detail: tail);
      case HealthKind.partial:
        icon = Icons.warning_amber;
        color = cs.secondary;
        label = t.sasayaki_health_label(pct: '$pctStr%', detail: tail);
      case HealthKind.failed:
        icon = Icons.error_outline;
        color = cs.error;
        label = t.sasayaki_health_label(pct: '$pctStr%', detail: tail);
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
        if (!widget.audioOnly && _willRunMatcher) ...[
          SizedBox(height: tokens.spacing.rowVertical),
          SasayakiWindowSlider(
            value: _searchWindow,
            onChanged: (v) => setState(() => _searchWindow = v),
            onAutoTap: _canAutoProbe ? _handleAutoProbe : null,
            autoBusy: _autoProbing,
          ),
          SizedBox(height: tokens.spacing.gap),
          SasayakiThresholdSlider(
            value: _similarityThreshold,
            onChanged: (v) => setState(() => _similarityThreshold = v),
          ),
        ],
        if (importing) ...buildProgressSection(context, tokens),
      ],
    );
  }

  /// 音频来源行：标签 + [选目录] [选文件] 两个按钮。
  Widget _audioSourceRow() {
    return HibikiFilePickerRow(
      title: _audioPaths != null
          ? t.srt_import_pick_audio_files
          : t.srt_import_pick_audio_dir,
      subtitle: _hasAudioSource ? _audioSourceLabel : null,
      icon: _audioPaths != null
          ? Icons.audio_file_outlined
          : Icons.folder_open_outlined,
      actions: [
        HibikiIconButton(
          icon: Icons.folder_open_outlined,
          tooltip: t.srt_import_pick_audio_dir,
          isWideTapArea: true,
          onTap: _pickAudioDir,
        ),
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

  Future<void> _pickAudioDir() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final String? dir = await FilePicker.platform.getDirectoryPath();
      if (dir != null && mounted) {
        setState(() {
          _audioDir = dir;
          _audioPaths = null;
        });
      }
    } finally {
      _pickerActive = false;
    }
  }

  Future<void> _pickAudioFiles() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );
      if (result == null || !mounted) return;

      final List<String> paths = result.files
          .map((f) => f.path)
          .whereType<String>()
          .toList()
        ..sort(compareAudioFilePath);

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

  static const List<String> _alignmentExtensions = [
    'smil',
    'srt',
    'lrc',
    'vtt',
    'ass',
    'ssa',
    'json',
  ];

  Future<void> _pickAlignment() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _alignmentExtensions,
      );
      final PlatformFile? file = result?.files.single;
      final String? path = file?.path;
      if (path == null || file == null || !mounted) return;
      const Set<String> allowed = {
        'smil',
        'srt',
        'lrc',
        'vtt',
        'ass',
        'ssa',
        'json'
      };
      final String ext = p.extension(path).toLowerCase().replaceFirst('.', '');
      if (!allowed.contains(ext)) {
        HibikiToast.show(msg: t.import_unsupported_file_format(ext: '.$ext'));
        return;
      }
      setState(() {
        _alignmentPath = path;
        _alignmentName = file.name;
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
      final int? best = await SasayakiRematch.runAutoProbe(
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
      final String extractDir = widget.extractDir!;
      final EpubBook book = EpubParser.parseFromExtracted(extractDir);
      return List<EpubSection>.generate(
        book.chapters.length,
        (i) => EpubSection(
          index: i,
          href: book.chapters[i].href,
          text: book.chapterPlainText(i),
        ),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('AudiobookImport.loadSections', e, stack);
      debugPrint('[hibiki-audiobook] probe loadSections failed: $e');
      return const <EpubSection>[];
    }
  }

  /// 只 parse 不落库 —— 导入尚未 commit，不能污染 Isar。正式导入走 _parseCues。
  Future<List<AudioCue>> _parseCuesForProbe() async {
    final String? p = _alignmentPath;
    if (p == null) return const <AudioCue>[];
    final File f = File(p);
    final String ext = p.split('.').last.toLowerCase();
    try {
      switch (ext) {
        case 'srt':
          return await SrtParser.parse(srtFile: f, bookKey: widget.bookKey);
        case 'lrc':
          return await LrcParser.parse(lrcFile: f, bookKey: widget.bookKey);
        case 'vtt':
          return await VttParser.parse(vttFile: f, bookKey: widget.bookKey);
        case 'ass':
          return await AssParser.parse(assFile: f, bookKey: widget.bookKey);
        default:
          return const <AudioCue>[];
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('AudiobookImport.parseCues', e, stack);
      debugPrint('[hibiki-audiobook] probe parseCues failed: $e');
      return const <AudioCue>[];
    }
  }

  // ── 导入 ─────────────────────────────────────────────────────────────────────

  Future<void> _doImport() async {
    if (!_hasAudioSource || (!widget.audioOnly && _alignmentPath == null)) {
      HibikiToast.show(msg: t.audiobook_import_error);
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

      // 收集需要复制的音频文件。
      // file mode: 用户选的文件列表。
      // directory mode: 列出目录下所有音频文件。
      // 两种模式都复制到持久化目录——Android 11+ scoped storage 下，
      // SAF 临时授权的路径后续可能无法访问。
      final List<File> audioCopyFiles = <File>[];
      if (_audioPaths != null && _audioPaths!.isNotEmpty) {
        audioCopyFiles.addAll(_audioPaths!.map(File.new));
      } else if (_audioDir != null) {
        final Directory srcDir = Directory(_audioDir!);
        if (await srcDir.exists()) {
          final List<FileSystemEntity> entries = await srcDir.list().toList();
          audioCopyFiles.addAll(
            entries
                .whereType<File>()
                .where((f) => AudiobookStorage.isAudioFile(f.path)),
          );
          audioCopyFiles.sort(
            (a, b) => compareAudioFilePath(a.path, b.path),
          );
        }
      }

      for (final File f in audioCopyFiles) {
        if (!p.isWithin(
            p.canonicalize(persistDir.path), p.canonicalize(f.path))) {
          grandTotal += await f.length();
        }
      }
      int grandCopied = 0;

      await AudiobookStorage.cleanAudioFiles(persistDir);
      final List<String> persistedPaths = <String>[];
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
      if (parsed != null) {
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
            parsed != null ? _summarizeHealth(parsed.health) : null;
        final String msg = tail == null
            ? t.audiobook_import_success
            : '${t.audiobook_import_success} · $tail';
        HibikiToast.show(msg: msg);
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
          );
        } else {
          HibikiToast.show(
            msg: t.audiobook_import_error_copy_failed(
              name: e.path ?? '',
            ),
          );
        }
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('AudiobookImport.doImport', e, stack);
      debugPrint('AudiobookImportDialog import error: $e');
      if (mounted) {
        HibikiToast.show(msg: t.audiobook_import_error);
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
      HibikiToast.show(msg: t.ttu_not_bound_cannot_rematch);
      return;
    }
    await SasayakiRematch.promptAndRun(
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
      final String extractDir = widget.extractDir!;
      final EpubBook epubBook = EpubParser.parseFromExtracted(extractDir);
      final List<EpubSection> sections = List<EpubSection>.generate(
        epubBook.chapters.length,
        (i) => EpubSection(
          index: i,
          href: epubBook.chapters[i].href,
          text: epubBook.chapterPlainText(i),
        ),
      );
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
      SasayakiMatchCodec.applyToCues(cues: cues, result: result);
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

    if (format == 'srt') {
      cues = await SrtParser.parse(srtFile: alignFile, bookKey: widget.bookKey);
    } else if (format == 'lrc') {
      cues = await LrcParser.parse(lrcFile: alignFile, bookKey: widget.bookKey);
    } else if (format == 'vtt') {
      cues = await VttParser.parse(vttFile: alignFile, bookKey: widget.bookKey);
    } else if (format == 'ass' || format == 'ssa') {
      cues = await AssParser.parse(assFile: alignFile, bookKey: widget.bookKey);
    } else if (format == 'json') {
      cues = await JsonAlignmentParser.parse(
          jsonFile: alignFile, bookKey: widget.bookKey);
      useFragmentHealth = true;
    } else {
      final String fileName =
          alignmentFilePath.split(Platform.pathSeparator).last;
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

  /// 把 [AudiobookHealth] 压成一段 toast 尾巴；notApplicable/unrun 返回 null
  /// 省掉冗余提示。
  String? _summarizeHealth(AudiobookHealth h) {
    switch (h.kind) {
      case HealthKind.ok:
      case HealthKind.partial:
      case HealthKind.failed:
        final int p = h.ratePct ?? 0;
        return t.health_match_summary(pct: p);
      case HealthKind.notApplicable:
      case HealthKind.unrun:
      case HealthKind.running:
        return null;
    }
  }

  void _enterReplaceSubtitleMode(Audiobook ab) {
    setState(() {
      _patchingAudio = true;
      _alignmentPath = ab.alignmentPath;
      _alignmentName = ab.alignmentPath.split(Platform.pathSeparator).last;
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

    final bool? confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AudiobookRemoveConfirmationDialog(
        onConfirm: () => Navigator.of(ctx).pop(true),
      ),
    );
    debugPrint('AudiobookImportDialog: confirm=$confirm');
    if (confirm != true) return;

    try {
      await widget.repo.deleteAudiobook(widget.bookKey);
      debugPrint('AudiobookImportDialog: deleteAudiobook done');
    } catch (e, st) {
      ErrorLogService.instance.log('AudiobookImport.deleteAudiobook', e, st);
      debugPrint('AudiobookImportDialog: deleteAudiobook failed: $e\n$st');
      if (mounted) {
        HibikiToast.show(msg: t.audiobook_import_error);
      }
      return;
    }

    if (mounted) {
      outerNavigator.pop(false); // false = no audiobook
    }
  }

  Future<Directory> _ensurePersistDir() =>
      AudiobookStorage.ensurePersistDir(widget.bookKey);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 560,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: title,
        leadingIcon: Icons.headphones_outlined,
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
        scrollable: true,
        body: content,
        footer: actions.isEmpty
            ? null
            : Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: actions,
              ),
      ),
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
          t.audiobook_remove_confirm,
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
              child: Text(t.audiobook_remove),
            ),
          ],
        ),
      ),
    );
  }
}
