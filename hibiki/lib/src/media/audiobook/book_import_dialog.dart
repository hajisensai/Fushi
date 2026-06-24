import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:path/path.dart' as p;
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/drag_drop/import_dialog_drop.dart';
import 'package:hibiki/src/media/audiobook/import_dialog_progress_mixin.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_rematch.dart';
import 'package:hibiki/src/media/audiobook/text_to_epub.dart';
import 'package:hibiki/src/media/import/sidecar_finder.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/utils.dart';

/// 统一"导入书"对话框。EPUB、字幕、音频可按需组合，一次导入。
///
/// 路由规则（以"选中了什么"为准）：
///
/// - **仅 EPUB**：[EpubImporter] 解压 + 入 Drift，书自然出现在书架。
/// - **仅字幕（可带音频）**：解析 cues → [CuesToEpub] 生成真 EPUB 并
///   [EpubImporter] 导入；同时把 cues + audio 路径落到 Isar [SrtBook] / [AudioCue]。
/// - **EPUB + 字幕（可带音频）**：先 [EpubImporter] 导入 EPUB 拿 `bookId`；再用
///   [EpubParser] 读回章节文本，跑 [EpubSrtMatcher] + [SasayakiMatchCodec]，
///   把 cue 对齐到真实 EPUB；cues + 可选音频落到 [AudiobookRepository]。
/// - **音频但无字幕**：非法组合，音频必须配合字幕使用。
class BookImportDialog extends StatefulWidget {
  const BookImportDialog({
    required this.repo,
    required this.audiobookRepo,
    required this.db,
    this.initialEpubPath,
    this.initialSubtitlePath,
    this.initialAudioPaths,
    super.key,
  });

  final SrtBookRepository repo;
  final AudiobookRepository audiobookRepo;
  final HibikiDatabase db;
  final String? initialEpubPath;
  final String? initialSubtitlePath;

  /// 拖拽导入预填：随新书一起拖入的音频文件路径。EPUB+音频拖到书架空白处时透传，
  /// 否则丢失（书架 `importNewBook` 此前未携带 `files.audios`）。音频必配字幕，
  /// 故仅预填展示——`_doImport` 的「音频必须配字幕」校验照旧（拖 EPUB+音频无字幕
  /// 时仍要求补字幕）。
  final List<String>? initialAudioPaths;

  @override
  State<BookImportDialog> createState() => _BookImportDialogState();
}

class _BookImportDialogState extends State<BookImportDialog>
    with ImportDialogProgressMixin<BookImportDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _authorCtrl = TextEditingController();

  String? _epubPath;
  String? _subtitlePath;
  List<String> _audioPaths = [];
  String? _coverPath;
  String? _audioCoverPath;

  // 原始文件名（file_picker 在 Android 上返回的 cache 路径文件名可能与原始不同）
  String? _epubName;
  String? _subtitleName;

  bool _pickerActive = false;

  bool _autoWindow = true;
  int _searchWindow = EpubSrtMatcher.defaultSearchWindow;
  double _similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold;

  bool get _willRunMatcher {
    if (_epubPath == null || _subtitlePath == null) return false;
    final String ext = _subtitlePath!.split('.').last.toLowerCase();
    return SasayakiRematch.supportedFormats.contains(ext);
  }

  bool get _hasSubtitles => _subtitlePath != null;

  @override
  void initState() {
    super.initState();
    final String? epub = widget.initialEpubPath;
    if (epub != null) {
      _epubPath = epub;
      _epubName = p.basename(epub);
      if (_titleCtrl.text.isEmpty) {
        _titleCtrl.text = p.basenameWithoutExtension(epub);
      }
    }
    final String? sub = widget.initialSubtitlePath;
    if (sub != null) {
      _subtitlePath = sub;
      _subtitleName = p.basename(sub);
    }
    final List<String>? audios = widget.initialAudioPaths;
    if (audios != null && audios.isNotEmpty) {
      _audioPaths = List<String>.of(audios);
      // 预填音频时尝试抽内嵌封面（与 _pickAudio 路径一致）。首帧后跑，避免在
      // initState 内同步触发 setState / 平台通道调用。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _coverPath == null) {
          _tryExtractAudioCover();
        }
      });
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _authorCtrl.dispose();
    // 进度 ValueNotifier 由 ImportDialogProgressMixin.dispose() 经 super 链释放。
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiFileDropTarget(
      enabled: !importing,
      debugLabel: 'book-import-dialog',
      onDrop: _handleDialogDrop,
      child: BookImportDialogFrame(
        title: Text(t.srt_import),
        content: _buildForm(),
        actions: [
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
        ],
      ),
    );
  }

  /// 拖文件进本对话框 → 分类 → 按字段覆盖（仅填命中类，不清用户已选）。
  /// 纯解析交给 [resolveBookDialogDrop]；此处只 setState + sidecar/封面副作用。
  void _handleDialogDrop(List<String> paths, Offset _) {
    if (importing) return;
    final DroppedFiles files = classifyDroppedFiles(paths);
    final BookDialogDropResult r = resolveBookDialogDrop(files);
    if (r.isEmpty) return;
    final String? droppedEpub = r.epubPath;
    final bool gotAudio = r.audioPaths.isNotEmpty;
    setState(() {
      if (droppedEpub != null) {
        _epubPath = droppedEpub;
        _epubName = p.basename(droppedEpub);
        if (_titleCtrl.text.isEmpty) {
          _titleCtrl.text = p.basenameWithoutExtension(droppedEpub);
        }
      }
      if (r.subtitlePath != null) {
        _subtitlePath = r.subtitlePath;
        _subtitleName = p.basename(r.subtitlePath!);
      }
      if (gotAudio) {
        _audioPaths = r.audioPaths;
        _audioCoverPath = null;
      }
    });
    // 拖入主书文件时顺带扫同目录 sidecar（仅填空、不覆盖）；拖入音频时抽内嵌封面。
    if (droppedEpub != null) {
      _autoAttachSidecars(droppedEpub);
    }
    if (gotAudio && _coverPath == null) {
      _tryExtractAudioCover();
    }
  }

  Widget _buildForm() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t.srt_import_hint_epub_or_srt,
          style: tokens.type.metadata,
        ),
        SizedBox(height: tokens.spacing.gap),
        AdaptiveSettingsSection(
          children: [
            _epubRow(),
            _subtitleRow(),
            _audioRow(),
            _coverRow(),
          ],
        ),
        SizedBox(height: tokens.spacing.rowVertical),
        HibikiTextField(
          controller: _titleCtrl,
          labelText: t.srt_import_title_hint,
        ),
        SizedBox(height: tokens.spacing.gap),
        HibikiTextField(
          controller: _authorCtrl,
          labelText: t.srt_import_author_hint,
        ),
        if (_willRunMatcher) ...[
          SizedBox(height: tokens.spacing.rowVertical),
          AdaptiveSettingsSection(
            children: [
              AdaptiveSettingsSwitchRow(
                title: t.auto_select_search_window,
                subtitle: t.auto_select_search_window_hint,
                value: _autoWindow,
                onChanged: importing
                    ? null
                    : (bool value) => setState(() => _autoWindow = value),
              ),
            ],
          ),
          if (!_autoWindow) ...[
            SizedBox(height: tokens.spacing.gap),
            SasayakiWindowSlider(
              value: _searchWindow,
              onChanged: (v) => setState(() => _searchWindow = v),
            ),
            SizedBox(height: tokens.spacing.gap),
            SasayakiThresholdSlider(
              value: _similarityThreshold,
              onChanged: (v) => setState(() => _similarityThreshold = v),
            ),
          ],
        ],
        if (importing) ...buildProgressSection(context, tokens),
      ],
    );
  }

  Widget _epubRow() {
    return HibikiFilePickerRow(
      title: t.srt_import_pick_epub,
      subtitle: _epubPath == null ? null : _epubName ?? p.basename(_epubPath!),
      icon: Icons.menu_book_outlined,
      onTap: () => _pickEpub(),
      actions: [
        HibikiIconButton(
          icon: Icons.menu_book_outlined,
          tooltip: t.srt_import_pick_epub,
          isWideTapArea: true,
          onTap: _pickEpub,
        ),
      ],
    );
  }

  Widget _subtitleRow() {
    return HibikiFilePickerRow(
      title: t.srt_import_pick_subtitle_files,
      subtitle: _subtitlePath == null
          ? null
          : _subtitleName ?? p.basename(_subtitlePath!),
      icon: Icons.subtitles_outlined,
      onTap: _pickSubtitle,
      actions: [
        if (_subtitlePath != null)
          HibikiIconButton(
            icon: Icons.close,
            tooltip: t.dialog_clear,
            isWideTapArea: true,
            onTap: () async => setState(() {
              _subtitlePath = null;
              _subtitleName = null;
            }),
          ),
        HibikiIconButton(
          icon: Icons.subtitles_outlined,
          tooltip: t.srt_import_pick_subtitle_files,
          isWideTapArea: true,
          onTap: _pickSubtitle,
        ),
      ],
    );
  }

  Widget _audioRow() {
    return HibikiFilePickerRow(
      title: t.srt_import_pick_audio_files,
      subtitle: _audioPaths.isEmpty
          ? null
          : _audioPaths.length == 1
              ? p.basename(_audioPaths.first)
              : t.file_count(count: _audioPaths.length),
      icon: Icons.audio_file_outlined,
      onTap: _pickAudio,
      actions: [
        if (_audioPaths.isNotEmpty)
          HibikiIconButton(
            icon: Icons.close,
            tooltip: t.dialog_clear,
            isWideTapArea: true,
            onTap: () async => setState(() {
              _audioPaths = [];
              _audioCoverPath = null;
            }),
          ),
        HibikiIconButton(
          icon: Icons.audio_file_outlined,
          tooltip: t.srt_import_pick_audio_files,
          isWideTapArea: true,
          onTap: _pickAudio,
        ),
      ],
    );
  }

  // ── 文件/目录选择 ────────────────────────────────────────────────────────

  static final List<String> _bookExtensions = [
    'epub',
    ...TextToEpub.supportedExtensions,
  ];

  Future<void> _pickEpub({bool anyFile = false}) async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: anyFile ? FileType.any : FileType.custom,
        allowedExtensions: anyFile ? null : _bookExtensions,
      );
      final PlatformFile? file = result?.files.single;
      final String? path = file?.path;
      if (path != null && file != null && mounted) {
        setState(() {
          _epubPath = path;
          _epubName = file.name;
          if (_titleCtrl.text.isEmpty) {
            _titleCtrl.text = file.name.replaceAll(
                RegExp(
                    r'\.(epub|txt|html?|xhtml|md|markdown|rst|org|csv|tsv|log|json|xml)$',
                    caseSensitive: false),
                '');
          }
        });
        await _autoAttachSidecars(path);
      }
    } finally {
      _pickerActive = false;
    }
  }

  /// 选中主书文件后，扫同目录同名字幕/音频自动填进对应行（仅填空、不覆盖
  /// 用户手选）。音频必须配字幕，故仅在字幕已就位时才填音频。桌面端有效；
  /// 移动端是缓存副本目录、扫不到兄弟文件，[findSidecars] 静默返回空。
  Future<void> _autoAttachSidecars(String mainPath) async {
    final SidecarMatch m = await findSidecars(mainPath);
    if (!mounted || m.isEmpty) return;
    bool attachedSub = false;
    bool attachedAudio = false;
    setState(() {
      if (_subtitlePath == null && m.subtitlePath != null) {
        _subtitlePath = m.subtitlePath;
        _subtitleName = p.basename(m.subtitlePath!);
        attachedSub = true;
      }
      final bool hasSub = _subtitlePath != null;
      if (_audioPaths.isEmpty && hasSub && m.audioPaths.isNotEmpty) {
        _audioPaths = m.audioPaths;
        attachedAudio = true;
      }
    });
    if (attachedAudio && _coverPath == null) {
      await _tryExtractAudioCover();
    }
    final List<String> parts = <String>[
      if (attachedSub)
        t.import_sidecar_subtitle(name: p.basename(_subtitlePath!)),
      if (attachedAudio) t.import_sidecar_audio(count: _audioPaths.length),
    ];
    if (parts.isNotEmpty && mounted) {
      HibikiToast.show(msg: parts.join(' · '));
    }
  }

  static const List<String> _subtitleExtensions = [
    'srt',
    'lrc',
    'vtt',
    'ass',
    'ssa',
  ];

  Future<void> _pickSubtitle() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _subtitleExtensions,
      );
      final PlatformFile? file = result?.files.single;
      final String? path = file?.path;
      if (path == null || file == null || !mounted) return;
      const Set<String> allowed = {'srt', 'lrc', 'vtt', 'ass', 'ssa'};
      final String ext = p.extension(path).toLowerCase().replaceFirst('.', '');
      if (!allowed.contains(ext)) {
        HibikiToast.show(msg: t.import_unsupported_file_format(ext: '.$ext'));
        return;
      }

      setState(() {
        _subtitlePath = path;
        _subtitleName = file.name;
        if (_titleCtrl.text.isEmpty) {
          final String name = file.name;
          final int dot = name.lastIndexOf('.');
          _titleCtrl.text = dot > 0 ? name.substring(0, dot) : name;
        }
      });
    } finally {
      _pickerActive = false;
    }
  }

  Future<void> _pickAudio() async {
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
          _audioCoverPath = null;
        });
        if (_coverPath == null) {
          await _tryExtractAudioCover();
        }
      }
    } finally {
      _pickerActive = false;
    }
  }

  Future<void> _tryExtractAudioCover() async {
    if (_audioPaths.isEmpty) return;
    final Directory tmpDir = await getTemporaryDirectory();
    final String outputPath = p.join(
      tmpDir.path,
      'audio_cover_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    for (final String audioPath in _audioPaths) {
      final String? result = await TtsChannel.instance.extractEmbeddedCover(
        audioPath: audioPath,
        outputPath: outputPath,
      );
      if (result != null && mounted) {
        setState(() => _audioCoverPath = result);
        return;
      }
    }
  }

  Widget _coverRow() {
    final String? effectiveCover = _coverPath ?? _audioCoverPath;
    return HibikiFilePickerRow(
      title: t.srt_import_pick_cover,
      subtitle: effectiveCover == null ? null : p.basename(effectiveCover),
      icon: Icons.image_outlined,
      onTap: _pickCover,
      actions: [
        if (effectiveCover != null)
          HibikiIconButton(
            icon: Icons.close,
            tooltip: t.dialog_clear,
            isWideTapArea: true,
            onTap: () async => setState(() {
              _coverPath = null;
              _audioCoverPath = null;
            }),
          ),
        HibikiIconButton(
          icon: Icons.image_outlined,
          tooltip: t.srt_import_pick_cover,
          isWideTapArea: true,
          onTap: _pickCover,
        ),
      ],
    );
  }

  Future<void> _pickCover() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
      );
      if (result == null || !mounted) return;
      final String? path = result.files.first.path;
      if (path != null) {
        setState(() => _coverPath = path);
      }
    } finally {
      _pickerActive = false;
    }
  }

  Future<void> _applyCoverToEpub(String bookKey, {String? sourcePath}) async {
    final String source = sourcePath ?? _coverPath!;
    // Locate the extracted dir via the stored extract_dir column (the on-disk
    // folder name may still be a legacy int id; the column is the truth).
    final EpubBookRow? row = await widget.db.getEpubBook(bookKey);
    if (row == null) return;
    final String extractDir = row.extractDir;
    final String ext = p.extension(source);
    final String dest = p.join(extractDir, 'cover$ext');
    await File(source).copy(dest);
    await (widget.db.update(widget.db.epubBooks)
          ..where((tbl) => tbl.bookKey.equals(bookKey)))
        .write(EpubBooksCompanion(coverPath: Value('cover$ext')));
  }

  Future<bool> _epubHasCover(String bookKey) async {
    final row = await (widget.db.select(widget.db.epubBooks)
          ..where((tbl) => tbl.bookKey.equals(bookKey)))
        .getSingleOrNull();
    return row?.coverPath != null;
  }

  // ── 导入 ────────────────────────────────────────────────────────────────

  /// 同名书弹窗回调，喂给 [EpubImporter]。是→加后缀，否/关闭→取消这本书。
  Future<DuplicateTitleResolution> _onDuplicateTitle(
    String proposedTitle,
  ) async {
    if (!mounted) return DuplicateTitleResolution.cancel;
    final bool? keep = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.book_import_duplicate_title),
        content: Text(t.book_import_duplicate_message(name: proposedTitle)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.book_import_duplicate_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.book_import_duplicate_keep),
          ),
        ],
      ),
    );
    return keep == true
        ? DuplicateTitleResolution.addSuffix
        : DuplicateTitleResolution.cancel;
  }

  Future<void> _doImport() async {
    if (_epubPath == null && !_hasSubtitles) {
      HibikiToast.show(msg: t.srt_import_missing_input);
      return;
    }
    if (_epubPath != null && !_hasSubtitles && _audioPaths.isNotEmpty) {
      HibikiToast.show(msg: t.srt_import_audio_needs_subtitle);
      return;
    }
    final String title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      HibikiToast.show(msg: t.srt_import_missing_title);
      return;
    }

    setState(() => importing = true);
    reportProgress(0, '');

    try {
      final String? authorText =
          _authorCtrl.text.trim().isEmpty ? null : _authorCtrl.text.trim();

      debugPrint(
          '[hibiki-import] route: epub=$_epubPath sub=$_subtitlePath audio=${_audioPaths.length} files');
      String? tail;
      if (_epubPath != null && _hasSubtitles) {
        debugPrint('[hibiki-import] → _importEpubWithAlignment');
        tail = await _importEpubWithAlignment(title: title);
      } else if (_hasSubtitles) {
        debugPrint('[hibiki-import] → _importSubtitleBook');
        await _importSubtitleBook(title: title, author: authorText);
      } else {
        debugPrint('[hibiki-import] → _importEpubOnly');
        await _importEpubOnly(title: title);
      }

      if (mounted) {
        final String msg = tail == null
            ? t.srt_import_success
            : '${t.srt_import_success} · $tail';
        HibikiToast.show(msg: msg);
        Navigator.pop(context, true);
      }
    } on DuplicateImportCancelledException {
      // 用户在同名弹窗选了"否"——取消这本书，不是错误。
      if (mounted) {
        HibikiToast.show(msg: t.book_import_duplicate_cancelled);
        Navigator.pop(context, false);
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('BookImportDialog.import', e, stack);
      debugPrint('BookImportDialog error: $e');
      if (mounted) {
        HibikiToast.show(msg: '${t.srt_import_error}: $e');
      }
    } finally {
      if (mounted) {
        setState(() => importing = false);
      }
    }
  }

  Future<void> _importSubtitleBook({
    required String title,
    required String? author,
  }) async {
    final String uid = 'srtbook_${DateTime.now().millisecondsSinceEpoch}';
    reportProgress(0.1, t.import_step_parsing);

    final List<AudioCue> cues = await _parseCuesWithIndex(
      File(_subtitlePath!),
      uid,
      0,
    );
    debugPrint('[hibiki-import] subtitleBook: parsed ${cues.length} cues');

    String bookKey = '';
    if (cues.isNotEmpty) {
      try {
        reportProgress(0.3, t.import_step_building_epub);
        final Directory tmpDir = await getTemporaryDirectory();
        final String epubPath = p.join(tmpDir.path, 'cues_to_epub_$uid.epub');
        await CuesToEpub.convert(
          title: title,
          cues: cues,
          outputPath: epubPath,
          author: author,
        );
        reportProgress(0.5, t.import_step_importing_epub);
        bookKey = await EpubImporter.importFromPath(
          db: widget.db,
          filePath: epubPath,
          fileName: '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub',
          onDuplicateTitle: _onDuplicateTitle,
        );
        debugPrint(
            '[hibiki-import] subtitleBook: EPUB import done, key=$bookKey');
      } on DuplicateImportCancelledException {
        // 取消必须冒泡到顶层中止整次导入，不能被吞成 bookId=0 继续。
        rethrow;
      } catch (e, stack) {
        ErrorLogService.instance.log('BookImportDialog.epubImport', e, stack);
        debugPrint('[hibiki-import] EPUB generation/import failed: $e');
      }
    }

    reportProgress(0.7, t.import_step_persisting);
    final Directory persistDir = await _ensurePersistDir(uid);
    final String persistedSrt = await AudiobookStorage.persistFileWithProgress(
      File(_subtitlePath!),
      persistDir,
      onProgress: (int copied, int total) {
        reportProgress(
            0.7, t.import_step_copying_file(name: p.basename(_subtitlePath!)));
      },
    );

    await AudiobookStorage.cleanAudioFiles(persistDir);
    final List<String> persistedAudioPaths = [];
    for (final String src in _audioPaths) {
      persistedAudioPaths.add(
        await AudiobookStorage.persistFileWithProgress(
          File(src),
          persistDir,
          onProgress: (int copied, int total) {
            reportProgress(
                0.8, t.import_step_copying_file(name: p.basename(src)));
          },
        ),
      );
    }

    reportProgress(0.9, t.import_step_saving);
    final SrtBook book = SrtBook()
      ..uid = uid
      ..title = title
      ..srtPath = persistedSrt
      ..importedAt = DateTime.now().millisecondsSinceEpoch
      ..bookKey = bookKey;
    if (persistedAudioPaths.isNotEmpty) {
      book.audioPaths = persistedAudioPaths;
    }
    if (author != null) {
      book.author = author;
    }
    final String? coverSource = _coverPath ?? _audioCoverPath;
    if (coverSource != null) {
      final String ext = p.extension(coverSource);
      final String dest = p.join(persistDir.path, 'cover$ext');
      await File(coverSource).copy(dest);
      book.coverPath = dest;
    }

    debugPrint('[hibiki-import] SrtBook save: uid=$uid title="$title" '
        'bookKey=$bookKey cues=${cues.length}');

    await widget.repo.save(book);
    await widget.repo.saveCues(uid: uid, cues: cues);
    reportProgress(1, t.import_step_done);
  }

  Future<void> _importEpubOnly({required String title}) async {
    final File file = File(_epubPath!);

    reportProgress(0.2, t.import_step_reading);
    final String ext = p.extension(_epubPath!).toLowerCase();
    final String bookKey;
    if (TextToEpub.isSupported(_epubPath!) ||
        (ext != '.epub' && ext != '.zip')) {
      reportProgress(0.3, t.import_step_converting_epub);
      final Uint8List bytes =
          await TextToEpub.convert(file: file, title: title);
      final String filename =
          '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub';
      reportProgress(0.5, t.import_step_importing_epub);
      bookKey = await EpubImporter.import(
        db: widget.db,
        bytes: bytes,
        fileName: filename,
        onDuplicateTitle: _onDuplicateTitle,
      );
    } else {
      reportProgress(0.5, t.import_step_importing_epub);
      bookKey = await EpubImporter.importFromPath(
        db: widget.db,
        filePath: _epubPath!,
        fileName: _epubName ?? p.basename(_epubPath!),
        onDuplicateTitle: _onDuplicateTitle,
      );
    }

    await _applyBestCoverToEpub(bookKey);
    reportProgress(1, t.import_step_done);
  }

  Future<void> _applyBestCoverToEpub(String bookKey) async {
    if (_coverPath != null) {
      await _applyCoverToEpub(bookKey);
    } else if (_audioCoverPath != null && !(await _epubHasCover(bookKey))) {
      await _applyCoverToEpub(bookKey, sourcePath: _audioCoverPath);
    }
  }

  Future<String?> _importEpubWithAlignment({required String title}) async {
    final File epubFile = File(_epubPath!);

    reportProgress(0.05, t.import_step_reading);
    final String bookKey;
    if (TextToEpub.isSupported(_epubPath!)) {
      reportProgress(0.1, t.import_step_converting_epub);
      final Uint8List importBytes =
          await TextToEpub.convert(file: epubFile, title: title);
      final String importFilename =
          '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub';
      reportProgress(0.2, t.import_step_importing_epub);
      bookKey = await EpubImporter.import(
        db: widget.db,
        bytes: importBytes,
        fileName: importFilename,
        onDuplicateTitle: _onDuplicateTitle,
      );
    } else {
      reportProgress(0.2, t.import_step_importing_epub);
      bookKey = await EpubImporter.importFromPath(
        db: widget.db,
        filePath: _epubPath!,
        fileName: _epubName ?? p.basename(_epubPath!),
        onDuplicateTitle: _onDuplicateTitle,
      );
    }

    await _applyBestCoverToEpub(bookKey);

    reportProgress(0.35, t.import_step_reading_idb);
    List<EpubSection> sections = const <EpubSection>[];
    try {
      final EpubBookRow? bookRow = await widget.db.getEpubBook(bookKey);
      final String extractDir = bookRow?.extractDir ?? '';
      final EpubBook epubBook = EpubParser.parseFromExtracted(extractDir);
      sections = List<EpubSection>.generate(
        epubBook.chapters.length,
        (i) => EpubSection(
          index: i,
          href: epubBook.chapters[i].href,
          text: epubBook.chapterPlainText(i),
        ),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('BookImportDialog.parseEpub', e, stack);
      debugPrint('[hibiki-import] parseFromExtracted failed: $e');
    }
    reportProgress(0.45, t.import_step_parsing);
    final String ext = _subtitlePath!.split('.').last.toLowerCase();
    final List<AudioCue> cues = await _parseCuesWithIndex(
      File(_subtitlePath!),
      bookKey,
      0,
    );
    AudiobookHealth health;
    final bool runMatcher = SasayakiRematch.supportedFormats.contains(ext);
    if (runMatcher && sections.isNotEmpty && cues.isNotEmpty) {
      reportProgress(0.55, t.import_step_matching);
      MatchResult? matchResult;
      int chosenWindow = _searchWindow;
      if (_autoWindow) {
        final ProbeResult probe = await EpubCueMatcher.probeInIsolate(
          sections: sections,
          cues: cues,
        );
        final MapEntry<int, double>? best = probe.best;
        if (best != null && best.value > 0) {
          chosenWindow = best.key;
          matchResult = probe.bestResult;
        }
      }
      matchResult ??= await EpubCueMatcher.matchInIsolate(
        sections: sections,
        cues: cues,
        searchWindow: chosenWindow,
        similarityThreshold: _similarityThreshold,
      );
      SasayakiMatchCodec.applyToCues(cues: cues, result: matchResult);
      final int pct = (matchResult.matchRate * 100).round();
      health = AudiobookHealth.fromRatePct(
        ratePct: pct,
        reason:
            '${matchResult.matchedCues}/${matchResult.totalCues} cues matched '
            '(window=$chosenWindow)',
      );
    } else if (runMatcher) {
      health = sections.isEmpty
          ? AudiobookHealth.failed(reason: 'ttu IDB record had 0 sections')
          : AudiobookHealth.failed(reason: 'parser returned 0 cues');
    } else {
      health = AudiobookHealth.notApplicable(
        reason: '$ext format uses file anchors, no matcher needed',
      );
    }

    reportProgress(0.8, t.import_step_persisting);
    final Directory persistDir = await _ensurePersistDir(bookKey);
    final String persistedSrt = await AudiobookStorage.persistFileWithProgress(
      File(_subtitlePath!),
      persistDir,
      onProgress: (int copied, int total) {
        reportProgress(
            0.8, t.import_step_copying_file(name: p.basename(_subtitlePath!)));
      },
    );

    await AudiobookStorage.cleanAudioFiles(persistDir);
    final List<String> persistedAudioPaths = [];
    for (final String src in _audioPaths) {
      persistedAudioPaths.add(
        await AudiobookStorage.persistFileWithProgress(
          File(src),
          persistDir,
          onProgress: (int copied, int total) {
            reportProgress(
                0.85, t.import_step_copying_file(name: p.basename(src)));
          },
        ),
      );
    }

    reportProgress(0.9, t.import_step_saving);
    final Audiobook audiobook = Audiobook()
      ..bookKey = bookKey
      ..alignmentFormat = ext
      ..alignmentPath = persistedSrt;
    if (persistedAudioPaths.isNotEmpty) {
      audiobook.audioPaths = persistedAudioPaths;
    }
    health.packInto(audiobook);

    await widget.audiobookRepo.saveAudiobook(audiobook);
    await widget.audiobookRepo.saveCues(
      bookKey: bookKey,
      cues: cues,
    );
    await widget.audiobookRepo.updateHealthOverlay(
      bookKey: bookKey,
      health: health,
    );
    reportProgress(1, t.import_step_done);

    return _summarizeHealth(health);
  }

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

  Future<List<AudioCue>> _parseCuesWithIndex(
    File file,
    String bookKey,
    int audioFileIndex,
  ) {
    final String ext = file.path.split('.').last.toLowerCase();
    switch (ext) {
      case 'lrc':
        return LrcParser.parse(
            lrcFile: file, bookKey: bookKey, audioFileIndex: audioFileIndex);
      case 'vtt':
        return VttParser.parse(
            vttFile: file, bookKey: bookKey, audioFileIndex: audioFileIndex);
      case 'ass':
      case 'ssa':
        return AssParser.parse(
            assFile: file, bookKey: bookKey, audioFileIndex: audioFileIndex);
      default:
        return SrtParser.parse(
            srtFile: file, bookKey: bookKey, audioFileIndex: audioFileIndex);
    }
  }

  Future<Directory> _ensurePersistDir(String key) =>
      AudiobookStorage.ensurePersistDir(key);
}

@visibleForTesting
class BookImportDialogFrame extends StatelessWidget {
  const BookImportDialogFrame({
    required this.title,
    required this.content,
    required this.actions,
    super.key,
  });

  final Widget title;
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
        leadingIcon: Icons.library_add_outlined,
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
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DefaultTextStyle.merge(
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listTitle.copyWith(
                fontWeight: FontWeight.w600,
              ),
              child: title,
            ),
            SizedBox(height: tokens.spacing.gap),
            content,
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ),
    );
  }
}
