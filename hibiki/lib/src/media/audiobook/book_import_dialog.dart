import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:path/path.dart' as p;
import 'package:hibiki/src/media/audiobook/sasayaki_rematch.dart';
import 'package:hibiki/src/media/audiobook/text_to_epub.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
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
    super.key,
  });

  final SrtBookRepository repo;
  final AudiobookRepository audiobookRepo;
  final HibikiDatabase db;

  @override
  State<BookImportDialog> createState() => _BookImportDialogState();
}

class _BookImportDialogState extends State<BookImportDialog> {
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

  bool _importing = false;
  bool _pickerActive = false;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  final ValueNotifier<String> _progressMsg = ValueNotifier<String>('');

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
  void dispose() {
    _titleCtrl.dispose();
    _authorCtrl.dispose();
    _progress.dispose();
    _progressMsg.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BookImportDialogFrame(
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
          onPressed: _importing ? null : _doImport,
          child: _importing
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: adaptiveIndicator(
                        context: context,
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(t.dialog_importing),
                  ],
                )
              : Text(t.dialog_import),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t.srt_import_hint_epub_or_srt,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 8),
        AdaptiveSettingsSection(
          children: [
            _epubRow(),
            _subtitleRow(),
            _audioRow(),
            _coverRow(),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _titleCtrl,
          decoration: InputDecoration(
            labelText: t.srt_import_title_hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _authorCtrl,
          decoration: InputDecoration(
            labelText: t.srt_import_author_hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_willRunMatcher) ...[
          const SizedBox(height: 12),
          AdaptiveSettingsSection(
            children: [
              AdaptiveSettingsSwitchRow(
                title: t.auto_select_search_window,
                subtitle: t.auto_select_search_window_hint,
                value: _autoWindow,
                onChanged: _importing
                    ? null
                    : (bool value) => setState(() => _autoWindow = value),
              ),
            ],
          ),
          if (!_autoWindow) ...[
            const SizedBox(height: 8),
            SasayakiWindowSlider(
              value: _searchWindow,
              onChanged: (v) => setState(() => _searchWindow = v),
            ),
            const SizedBox(height: 8),
            SasayakiThresholdSlider(
              value: _similarityThreshold,
              onChanged: (v) => setState(() => _similarityThreshold = v),
            ),
          ],
        ],
        if (_importing) ...[
          const SizedBox(height: 16),
          ValueListenableBuilder<double>(
            valueListenable: _progress,
            builder: (_, value, __) => LinearProgressIndicator(value: value),
          ),
          const SizedBox(height: 4),
          ValueListenableBuilder<String>(
            valueListenable: _progressMsg,
            builder: (_, msg, __) => Text(
              msg,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _epubRow() {
    return HibikiFilePickerRow(
      title: t.srt_import_pick_epub,
      subtitle: _epubPath == null ? null : _epubName ?? p.basename(_epubPath!),
      icon: Icons.menu_book_outlined,
      actions: [
        IconButton(
          icon: const Icon(Icons.menu_book_outlined, size: 20),
          tooltip: t.srt_import_pick_epub,
          onPressed: _pickEpub,
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
      actions: [
        if (_subtitlePath != null)
          IconButton(
            icon: Icon(Icons.close,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            onPressed: () => setState(() {
              _subtitlePath = null;
              _subtitleName = null;
            }),
          ),
        IconButton(
          icon: const Icon(Icons.subtitles_outlined, size: 20),
          tooltip: t.srt_import_pick_subtitle_files,
          onPressed: _pickSubtitle,
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
      actions: [
        if (_audioPaths.isNotEmpty)
          IconButton(
            icon: Icon(Icons.close,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            onPressed: () => setState(() {
              _audioPaths = [];
              _audioCoverPath = null;
            }),
          ),
        IconButton(
          icon: const Icon(Icons.audio_file_outlined, size: 20),
          tooltip: t.srt_import_pick_audio_files,
          onPressed: _pickAudio,
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
      }
    } finally {
      _pickerActive = false;
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
      actions: [
        if (effectiveCover != null)
          IconButton(
            icon: Icon(Icons.close,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            onPressed: () => setState(() {
              _coverPath = null;
              _audioCoverPath = null;
            }),
          ),
        IconButton(
          icon: const Icon(Icons.image_outlined, size: 20),
          tooltip: t.srt_import_pick_cover,
          onPressed: _pickCover,
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

  Future<void> _applyCoverToEpub(int bookId, {String? sourcePath}) async {
    final String source = sourcePath ?? _coverPath!;
    final String extractDir = await EpubStorage.bookDirectory(bookId);
    final String ext = p.extension(source);
    final String dest = p.join(extractDir, 'cover$ext');
    await File(source).copy(dest);
    await (widget.db.update(widget.db.epubBooks)
          ..where((tbl) => tbl.id.equals(bookId)))
        .write(EpubBooksCompanion(coverPath: Value('cover$ext')));
  }

  Future<bool> _epubHasCover(int bookId) async {
    final row = await (widget.db.select(widget.db.epubBooks)
          ..where((tbl) => tbl.id.equals(bookId)))
        .getSingleOrNull();
    return row?.coverPath != null;
  }

  // ── 导入 ────────────────────────────────────────────────────────────────

  void _reportProgress(double value, String msg) {
    _progress.value = value;
    _progressMsg.value = msg;
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

    setState(() => _importing = true);
    _reportProgress(0, '');

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
    } catch (e, stack) {
      ErrorLogService.instance.log('BookImportDialog.import', e, stack);
      debugPrint('BookImportDialog error: $e');
      if (mounted) {
        HibikiToast.show(msg: '${t.srt_import_error}: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  Future<void> _importSubtitleBook({
    required String title,
    required String? author,
  }) async {
    final String uid = 'srtbook_${DateTime.now().millisecondsSinceEpoch}';
    _reportProgress(0.1, t.import_step_parsing);

    final List<AudioCue> cues = await _parseCuesWithIndex(
      File(_subtitlePath!),
      uid,
      0,
    );
    debugPrint('[hibiki-import] subtitleBook: parsed ${cues.length} cues');

    int bookId = 0;
    if (cues.isNotEmpty) {
      try {
        _reportProgress(0.3, t.import_step_building_epub);
        final Directory tmpDir = await getTemporaryDirectory();
        final String epubPath = p.join(tmpDir.path, 'cues_to_epub_$uid.epub');
        await CuesToEpub.convert(
          title: title,
          cues: cues,
          outputPath: epubPath,
          author: author,
        );
        _reportProgress(0.5, t.import_step_importing_epub);
        bookId = await EpubImporter.importFromPath(
          db: widget.db,
          filePath: epubPath,
          fileName: '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub',
        );
        debugPrint(
            '[hibiki-import] subtitleBook: EPUB import done, id=$bookId');
      } catch (e, stack) {
        ErrorLogService.instance.log('BookImportDialog.epubImport', e, stack);
        debugPrint('[hibiki-import] EPUB generation/import failed: $e');
      }
    }

    _reportProgress(0.7, t.import_step_persisting);
    final Directory persistDir = await _ensurePersistDir(uid);
    final String persistedSrt = await AudiobookStorage.persistFileWithProgress(
      File(_subtitlePath!),
      persistDir,
      onProgress: (int copied, int total) {
        _reportProgress(
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
            _reportProgress(
                0.8, t.import_step_copying_file(name: p.basename(src)));
          },
        ),
      );
    }

    _reportProgress(0.9, t.import_step_saving);
    final SrtBook book = SrtBook()
      ..uid = uid
      ..title = title
      ..srtPath = persistedSrt
      ..importedAt = DateTime.now().millisecondsSinceEpoch
      ..ttuBookId = bookId;
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
        'bookId=$bookId cues=${cues.length}');

    await widget.repo.save(book);
    await widget.repo.saveCues(uid: uid, cues: cues);
    _reportProgress(1, t.import_step_done);
  }

  Future<void> _importEpubOnly({required String title}) async {
    final File file = File(_epubPath!);

    _reportProgress(0.2, t.import_step_reading);
    final String ext = p.extension(_epubPath!).toLowerCase();
    final int bookId;
    if (TextToEpub.isSupported(_epubPath!) ||
        (ext != '.epub' && ext != '.zip')) {
      _reportProgress(0.3, t.import_step_converting_epub);
      final Uint8List bytes =
          await TextToEpub.convert(file: file, title: title);
      final String filename =
          '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub';
      _reportProgress(0.5, t.import_step_importing_epub);
      bookId = await EpubImporter.import(
        db: widget.db,
        bytes: bytes,
        fileName: filename,
      );
    } else {
      _reportProgress(0.5, t.import_step_importing_epub);
      bookId = await EpubImporter.importFromPath(
        db: widget.db,
        filePath: _epubPath!,
        fileName: _epubName ?? p.basename(_epubPath!),
      );
    }

    await _applyBestCoverToEpub(bookId);
    _reportProgress(1, t.import_step_done);
  }

  Future<void> _applyBestCoverToEpub(int bookId) async {
    if (_coverPath != null) {
      await _applyCoverToEpub(bookId);
    } else if (_audioCoverPath != null && !(await _epubHasCover(bookId))) {
      await _applyCoverToEpub(bookId, sourcePath: _audioCoverPath);
    }
  }

  Future<String?> _importEpubWithAlignment({required String title}) async {
    final File epubFile = File(_epubPath!);

    _reportProgress(0.05, t.import_step_reading);
    final int bookId;
    if (TextToEpub.isSupported(_epubPath!)) {
      _reportProgress(0.1, t.import_step_converting_epub);
      final Uint8List importBytes =
          await TextToEpub.convert(file: epubFile, title: title);
      final String importFilename =
          '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub';
      _reportProgress(0.2, t.import_step_importing_epub);
      bookId = await EpubImporter.import(
        db: widget.db,
        bytes: importBytes,
        fileName: importFilename,
      );
    } else {
      _reportProgress(0.2, t.import_step_importing_epub);
      bookId = await EpubImporter.importFromPath(
        db: widget.db,
        filePath: _epubPath!,
        fileName: _epubName ?? p.basename(_epubPath!),
      );
    }

    await _applyBestCoverToEpub(bookId);

    _reportProgress(0.35, t.import_step_reading_idb);
    List<EpubSection> sections = const <EpubSection>[];
    try {
      final String extractDir = await EpubStorage.bookDirectory(bookId);
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
    final String bookUid = ReaderHibikiSource.bookUidFor(bookId);

    _reportProgress(0.45, t.import_step_parsing);
    final String ext = _subtitlePath!.split('.').last.toLowerCase();
    final List<AudioCue> cues = await _parseCuesWithIndex(
      File(_subtitlePath!),
      bookUid,
      0,
    );
    AudiobookHealth health;
    final bool runMatcher = SasayakiRematch.supportedFormats.contains(ext);
    if (runMatcher && sections.isNotEmpty && cues.isNotEmpty) {
      _reportProgress(0.55, t.import_step_matching);
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

    _reportProgress(0.8, t.import_step_persisting);
    final Directory persistDir = await _ensurePersistDir(bookUid);
    final String persistedSrt = await AudiobookStorage.persistFileWithProgress(
      File(_subtitlePath!),
      persistDir,
      onProgress: (int copied, int total) {
        _reportProgress(
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
            _reportProgress(
                0.85, t.import_step_copying_file(name: p.basename(src)));
          },
        ),
      );
    }

    _reportProgress(0.9, t.import_step_saving);
    final Audiobook audiobook = Audiobook()
      ..bookUid = bookUid
      ..alignmentFormat = ext
      ..alignmentPath = persistedSrt;
    if (persistedAudioPaths.isNotEmpty) {
      audiobook.audioPaths = persistedAudioPaths;
    }
    health.packInto(audiobook);

    await widget.audiobookRepo.saveAudiobook(audiobook);
    await widget.audiobookRepo.saveCues(
      bookUid: bookUid,
      cues: cues,
    );
    await widget.audiobookRepo.updateHealthOverlay(
      bookUid: bookUid,
      health: health,
    );
    _reportProgress(1, t.import_step_done);

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
    String bookUid,
    int audioFileIndex,
  ) {
    final String ext = file.path.split('.').last.toLowerCase();
    switch (ext) {
      case 'lrc':
        return LrcParser.parse(
            lrcFile: file, bookUid: bookUid, audioFileIndex: audioFileIndex);
      case 'vtt':
        return VttParser.parse(
            vttFile: file, bookUid: bookUid, audioFileIndex: audioFileIndex);
      case 'ass':
      case 'ssa':
        return AssParser.parse(
            assFile: file, bookUid: bookUid, audioFileIndex: audioFileIndex);
      default:
        return SrtParser.parse(
            srtFile: file, bookUid: bookUid, audioFileIndex: audioFileIndex);
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
    return adaptiveAlertDialog(
      context: context,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      buttonPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: DefaultTextStyle.merge(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: title,
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: double.maxFinite,
          maxHeight: MediaQuery.of(context).size.height * 0.56,
        ),
        child: SingleChildScrollView(child: content),
      ),
      actions: actions,
    );
  }
}
