import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:hibiki/src/media/audiobook/audiobook_health.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/cues_to_epub.dart';
import 'package:hibiki/src/media/audiobook/epub_cue_matcher.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_match_codec.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_rematch.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/src/media/audiobook/ass_parser.dart';
import 'package:hibiki/src/media/audiobook/lrc_parser.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';
import 'package:hibiki/src/media/audiobook/text_to_epub.dart';
import 'package:hibiki/src/media/audiobook/ttu_epub_importer.dart';
import 'package:hibiki/src/media/audiobook/ttu_idb_schema.dart';
import 'package:hibiki/src/media/audiobook/ttu_idb_reader.dart';
import 'package:hibiki/src/media/audiobook/vtt_parser.dart';
import 'package:hibiki/utils.dart';

/// 统一"导入书"对话框。EPUB、字幕、音频可按需组合，一次导入。
///
/// 路由规则（以"选中了什么"为准）：
///
/// - **仅 EPUB**：[TtuEpubImporter] 驱动 ttu 的 `<input type=file>` 管线导入，
///   不落 [SrtBook] / [Audiobook]，书自然出现在书架的 EPUB 区。
/// - **仅字幕（可带音频）**：解析 cues → [CuesToEpub.buildIdbPayload] 拼 ttu
///   原生 IDB 载荷并 `put()` 写入（带 `data-cue-id` span，供 AudiobookBridge
///   做高亮同步）；同时把 cues + audio 路径落到 Isar 的 [SrtBook] / [AudioCue]。
/// - **EPUB + 字幕（可带音频）**：先用 ttu 导入 EPUB 拿 `ttuBookId`；再从 IDB
///   读回章节文本，跑 [EpubSrtMatcher] + [SasayakiMatchCodec]，把 cue 对齐到
///   真实 EPUB；cues + 可选音频落到 [AudiobookRepository]（bookUid 复用
///   `MediaItem.uniqueKey` 约定：`$sourceId/b.html?id=X&?title=Y`）。
/// - **音频但无字幕**：非法组合，音频必须配合字幕使用。
class BookImportDialog extends StatefulWidget {
  const BookImportDialog({
    required this.repo,
    required this.audiobookRepo,
    required this.serverPort,
    required this.ttuMediaSourceIdentifier,
    super.key,
  });

  final SrtBookRepository repo;

  /// 存 EPUB+字幕 组合路径的 Audiobook / AudioCue。
  final AudiobookRepository audiobookRepo;

  /// ッツ Ebook Reader local server port.
  final int serverPort;

  /// `MediaItem.mediaSourceIdentifier` 值（同 `ReaderTtuSource.instance.uniqueKey`）。
  /// 用于构造 EPUB+字幕 组合的 bookUid。
  final String ttuMediaSourceIdentifier;

  @override
  State<BookImportDialog> createState() => _BookImportDialogState();
}

class _BookImportDialogState extends State<BookImportDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _authorCtrl = TextEditingController();

  String? _epubPath;
  String? _subtitlePath;
  String? _audioPath;

  // 原始文件名（file_picker 在 Android 上返回的 cache 路径文件名可能与原始不同）
  String? _epubName;
  String? _subtitleName;
  String? _audioName;

  bool _importing = false;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0.0);
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
    return AlertDialog(
      title: Text(t.srt_import),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(child: _buildForm()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          onPressed: _importing ? null : _doImport,
          child: _importing
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
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
        _epubRow(),
        const SizedBox(height: 8),
        _subtitleRow(),
        const SizedBox(height: 8),
        _audioRow(),
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
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(t.auto_select_search_window),
            subtitle: Text(
              t.auto_select_search_window_hint,
              style: TextStyle(fontSize: 11),
            ),
            value: _autoWindow,
            onChanged:
                _importing ? null : (bool v) => setState(() => _autoWindow = v),
          ),
          if (!_autoWindow)
            SasayakiWindowSlider(
              value: _searchWindow,
              onChanged: (int v) => setState(() => _searchWindow = v),
            ),
          if (!_autoWindow)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SasayakiThresholdSlider(
                value: _similarityThreshold,
                onChanged: (double v) =>
                    setState(() => _similarityThreshold = v),
              ),
            ),
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
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ],
      ],
    );
  }

  Widget _epubRow() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.srt_import_pick_epub,
                  style: const TextStyle(fontSize: 13)),
              if (_epubPath != null)
                Text(
                  _epubName ?? _basename(_epubPath!),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.menu_book, size: 20),
          tooltip: t.srt_import_pick_epub,
          onPressed: _pickEpub,
        ),
      ],
    );
  }

  Widget _subtitleRow() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.srt_import_pick_subtitle_files,
                  style: const TextStyle(fontSize: 13)),
              if (_subtitlePath != null)
                Text(
                  _subtitleName ?? _basename(_subtitlePath!),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
            ],
          ),
        ),
        if (_subtitlePath != null)
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Colors.grey),
            onPressed: () => setState(() {
              _subtitlePath = null;
              _subtitleName = null;
            }),
          ),
        IconButton(
          icon: const Icon(Icons.subtitles, size: 20),
          tooltip: t.srt_import_pick_subtitle_files,
          onPressed: _pickSubtitle,
        ),
      ],
    );
  }

  Widget _audioRow() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.srt_import_pick_audio_files,
                  style: const TextStyle(fontSize: 13)),
              if (_audioPath != null)
                Text(
                  _audioName ?? _basename(_audioPath!),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
            ],
          ),
        ),
        if (_audioPath != null)
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Colors.grey),
            onPressed: () => setState(() {
              _audioPath = null;
              _audioName = null;
            }),
          ),
        IconButton(
          icon: const Icon(Icons.audio_file, size: 20),
          tooltip: t.srt_import_pick_audio_files,
          onPressed: _pickAudio,
        ),
      ],
    );
  }

  // ── 文件/目录选择 ────────────────────────────────────────────────────────

  static const List<String> _bookExtensions = [
    'epub',
    'txt',
    'html',
    'htm',
    'xhtml',
    'md',
    'markdown',
    'rst',
    'org',
    'csv',
    'tsv',
    'log',
    'json',
    'xml',
  ];

  Future<void> _pickEpub() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _bookExtensions,
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
  }

  Future<void> _pickSubtitle() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['srt', 'lrc', 'vtt', 'ass', 'ssa'],
    );
    final PlatformFile? file = result?.files.single;
    final String? path = file?.path;
    if (path == null || file == null || !mounted) return;

    setState(() {
      _subtitlePath = path;
      _subtitleName = file.name;
      if (_titleCtrl.text.isEmpty) {
        final String name = file.name;
        final int dot = name.lastIndexOf('.');
        _titleCtrl.text = dot > 0 ? name.substring(0, dot) : name;
      }
    });
  }

  Future<void> _pickAudio() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
    );
    final PlatformFile? file = result?.files.single;
    final String? path = file?.path;
    if (path == null || file == null || !mounted) return;

    setState(() {
      _audioPath = path;
      _audioName = file.name;
    });
  }

  // ── 导入 ────────────────────────────────────────────────────────────────

  void _reportProgress(double value, String msg) {
    _progress.value = value;
    _progressMsg.value = msg;
  }

  Future<void> _doImport() async {
    if (_epubPath == null && !_hasSubtitles) {
      Fluttertoast.showToast(msg: t.srt_import_missing_input);
      return;
    }
    if (_epubPath != null && !_hasSubtitles && _audioPath != null) {
      Fluttertoast.showToast(msg: t.srt_import_audio_needs_subtitle);
      return;
    }
    final String title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      Fluttertoast.showToast(msg: t.srt_import_missing_title);
      return;
    }

    setState(() => _importing = true);
    _reportProgress(0.0, '');

    try {
      final String? authorText =
          _authorCtrl.text.trim().isEmpty ? null : _authorCtrl.text.trim();

      debugPrint('[hibiki-import] route: epub=$_epubPath sub=$_subtitlePath audio=$_audioPath');
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
        Fluttertoast.showToast(msg: msg);
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('BookImportDialog error: $e');
      if (mounted) {
        Fluttertoast.showToast(msg: '${t.srt_import_error}: $e');
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

    int ttuBookId = 0;
    if (cues.isNotEmpty) {
      try {
        _reportProgress(0.3, t.import_step_building_epub);
        final TtuIdbPayload payload = CuesToEpub.buildIdbPayload(
          title: title,
          cues: cues,
        );
        _reportProgress(0.5, t.import_step_injecting_idb);
        ttuBookId = await _injectPayloadIntoTtuIdb(payload);
        debugPrint('[hibiki-import] subtitleBook: IDB inject done, id=$ttuBookId');
      } catch (e) {
        debugPrint('[hibiki-import] ttu IDB inject failed: $e');
      }
    }

    _reportProgress(0.7, t.import_step_persisting);
    final Directory persistDir = await _ensurePersistDir(uid);
    final String persistedSrt =
        await _persistFile(File(_subtitlePath!), persistDir);

    String? persistedAudioPath;
    if (_audioPath != null) {
      persistedAudioPath = await _persistFile(File(_audioPath!), persistDir);
    }

    _reportProgress(0.9, t.import_step_saving);
    final SrtBook book = SrtBook()
      ..uid = uid
      ..title = title
      ..srtPath = persistedSrt
      ..importedAt = DateTime.now().millisecondsSinceEpoch
      ..ttuBookId = ttuBookId;
    if (persistedAudioPath != null) {
      book.audioPaths = [persistedAudioPath];
    }
    if (author != null) {
      book.author = author;
    }

    debugPrint('[hibiki-import] SrtBook save: uid=$uid title="$title" '
        'ttuBookId=$ttuBookId cues=${cues.length}');

    await widget.repo.save(book);
    await widget.repo.saveCues(uid: uid, cues: cues);
    _reportProgress(1.0, t.import_step_done);
  }

  Future<void> _importEpubOnly({required String title}) async {
    final File file = File(_epubPath!);
    final Uint8List bytes;
    final String filename;

    _reportProgress(0.2, t.import_step_reading);
    if (TextToEpub.isSupported(_epubPath!)) {
      _reportProgress(0.3, t.import_step_converting_epub);
      bytes = await TextToEpub.convert(file: file, title: title);
      filename = '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub';
    } else {
      bytes = await file.readAsBytes();
      filename = _epubName ?? _basename(_epubPath!);
    }

    _reportProgress(0.5, t.import_step_importing_epub);
    await TtuEpubImporter.import(
      bytes: bytes,
      filename: filename,
      serverPort: widget.serverPort,
    );
    _reportProgress(1.0, t.import_step_done);
  }

  Future<String?> _importEpubWithAlignment({required String title}) async {
    final File epubFile = File(_epubPath!);
    final Uint8List importBytes;
    final String importFilename;

    _reportProgress(0.05, t.import_step_reading);
    if (TextToEpub.isSupported(_epubPath!)) {
      _reportProgress(0.1, t.import_step_converting_epub);
      importBytes = await TextToEpub.convert(file: epubFile, title: title);
      importFilename = '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub';
    } else {
      importBytes = await epubFile.readAsBytes();
      importFilename = _epubName ?? _basename(_epubPath!);
    }

    _reportProgress(0.2, t.import_step_importing_epub);
    final int ttuBookId = await TtuEpubImporter.import(
      bytes: importBytes,
      filename: importFilename,
      serverPort: widget.serverPort,
    );
    if (ttuBookId <= 0) {
      throw StateError('ttu returned invalid book id');
    }

    _reportProgress(0.35, t.import_step_reading_idb);
    String idbTitle = '';
    List<EpubSection> sections = const <EpubSection>[];
    try {
      final TtuBookRecord rec = await TtuIdbReader.readBookRecord(
        ttuBookId: ttuBookId,
        serverPort: widget.serverPort,
      );
      idbTitle = rec.title;
      sections = rec.sections;
    } catch (e) {
      debugPrint('[hibiki-import] readBookRecord failed: $e');
    }
    final String safeTitle = idbTitle.isNotEmpty ? idbTitle : ' ';
    final String mediaIdentifier =
        'http://localhost:${widget.serverPort}/b.html?id=$ttuBookId&?title=$safeTitle';
    final String bookUid =
        '${widget.ttuMediaSourceIdentifier}/$mediaIdentifier';

    _reportProgress(0.45, t.import_step_parsing);
    final String ext = _subtitlePath!.split('.').last.toLowerCase();
    final List<AudioCue> cues = await _parseCuesWithIndex(
      File(_subtitlePath!),
      bookUid,
      0,
    );
    final String chapterHref = _defaultChapterFor(ext);

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
      if (matchResult == null) {
        matchResult = await EpubCueMatcher.matchInIsolate(
          sections: sections,
          cues: cues,
          searchWindow: chosenWindow,
          similarityThreshold: _similarityThreshold,
        );
      }
      SasayakiMatchCodec.applyToCues(cues: cues, result: matchResult);
      final int pct = (matchResult.matchRate * 100).round();
      health = AudiobookHealth.fromRatePct(
        ratePct: pct,
        reason: '${matchResult.matchedCues}/${matchResult.totalCues} cues matched '
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
    final String persistedSrt =
        await _persistFile(File(_subtitlePath!), persistDir);

    String? persistedAudioPath;
    if (_audioPath != null) {
      persistedAudioPath = await _persistFile(File(_audioPath!), persistDir);
    }

    _reportProgress(0.9, t.import_step_saving);
    final Audiobook audiobook = Audiobook()
      ..bookUid = bookUid
      ..alignmentFormat = ext
      ..alignmentPath = persistedSrt;
    if (persistedAudioPath != null) {
      audiobook.audioPaths = [persistedAudioPath];
    }
    health.packInto(audiobook);

    await widget.audiobookRepo.saveAudiobook(audiobook);
    await widget.audiobookRepo.saveCues(
      bookUid: bookUid,
      chapterHref: chapterHref,
      cues: cues,
    );
    await widget.audiobookRepo.updateHealthOverlay(
      bookUid: bookUid,
      health: health,
    );
    _reportProgress(1.0, t.import_step_done);

    return _summarizeHealth(health);
  }


  String? _summarizeHealth(AudiobookHealth h) {
    switch (h.kind) {
      case HealthKind.ok:
      case HealthKind.partial:
      case HealthKind.failed:
        final int p = h.ratePct ?? 0;
        return 'match $p%';
      case HealthKind.notApplicable:
      case HealthKind.unrun:
      case HealthKind.running:
        return null;
    }
  }

  String _defaultChapterFor(String ext) {
    switch (ext) {
      case 'lrc':
        return LrcParser.defaultChapter;
      case 'vtt':
        return VttParser.defaultChapter;
      case 'ass':
      case 'ssa':
        return AssParser.defaultChapter;
      default:
        return SrtParser.defaultChapter;
    }
  }

  /// Injects [payload] into the ッツ reader's "books" IDB via a
  /// headless WebView and resolves with the auto-incremented row key.
  Future<int> _injectPayloadIntoTtuIdb(TtuIdbPayload payload) async {
    final String jsonStr = jsonEncode(payload.toJson());
    final String js = '''
(async function() {
  ${TtuIdbSchema.openBooksDbJs}
  const payload = $jsonStr;
  const db = await hibikiOpenBooksDb();
  const id = await new Promise((resolve, reject) => {
    if (!db.objectStoreNames.contains('data')) {
      db.close();
      reject('data_store_missing'); return;
    }
    const tx = db.transaction(['data'], 'readwrite');
    const store = tx.objectStore('data');
    const put = store.put(payload);
    put.onsuccess = (e) => resolve(e.target.result);
    put.onerror = (e) => reject(String(e.target.error));
    tx.oncomplete = () => db.close();
    tx.onabort = () => db.close();
  });
  console.log(JSON.stringify({messageType: 'srt_idb_ok', id: id}));
})().catch(err => {
  console.log(JSON.stringify({messageType: 'srt_idb_err', error: String(err)}));
});
''';

    final Completer<int> completer = Completer<int>();
    HeadlessInAppWebView? webView;
    // ttu 是 SPA，启动期间可能多次触发 onLoadStop；不去重会让 store.put
    // 执行多次、产生自增 id 不同的孤儿 IDB 条目，在书架 EPUB 区多出一本。
    bool jsDispatched = false;
    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:${widget.serverPort}/_hibiki_idb.html'),
      ),
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        databaseEnabled: true,
        domStorageEnabled: true,
      ),
      onLoadStop: (controller, url) async {
        if (jsDispatched) return;
        jsDispatched = true;
        await controller.evaluateJavascript(source: js);
      },
      onConsoleMessage: (controller, message) {
        try {
          final Map<String, dynamic> msg =
              jsonDecode(message.message) as Map<String, dynamic>;
          if (completer.isCompleted) return;
          if (msg['messageType'] == 'srt_idb_ok') {
            completer.complete((msg['id'] as num).toInt());
          } else if (msg['messageType'] == 'srt_idb_err') {
            completer.completeError(msg['error'] ?? 'idb_error');
          }
        } catch (_) {}
      },
    );

    try {
      await webView.run();
      return await completer.future.timeout(const Duration(seconds: 15));
    } finally {
      await webView.dispose();
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

  String _basename(String path) => path.split(Platform.pathSeparator).last;

  Future<Directory> _ensurePersistDir(String key) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final String hash = key.hashCode.toRadixString(16);
    final Directory dir = Directory(p.join(docs.path, 'audiobooks', hash));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<String> _persistFile(File src, Directory persistDir) async {
    if (src.path.startsWith(persistDir.path)) return src.path;
    final String dest = p.join(persistDir.path, p.basename(src.path));
    await src.copy(dest);
    debugPrint('[hibiki-import] persisted ${src.path} → $dest');
    return dest;
  }
}
