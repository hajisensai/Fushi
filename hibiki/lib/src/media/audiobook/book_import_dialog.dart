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

  bool _importing = false;

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
          const LinearProgressIndicator(),
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
                  _basename(_epubPath!),
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
                  _basename(_subtitlePath!),
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
            onPressed: () => setState(() => _subtitlePath = null),
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
                  _basename(_audioPath!),
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
            onPressed: () => setState(() => _audioPath = null),
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
    final String? path = result?.files.single.path;
    if (path != null && mounted) {
      setState(() {
        _epubPath = path;
        if (_titleCtrl.text.isEmpty) {
          _titleCtrl.text = _basename(path).replaceAll(
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
    final String? path = result?.files.single.path;
    if (path == null || !mounted) return;

    setState(() {
      _subtitlePath = path;
      if (_titleCtrl.text.isEmpty) {
        _titleCtrl.text = p.basenameWithoutExtension(path);
      }
    });
  }

  Future<void> _pickAudio() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
    );
    final String? path = result?.files.single.path;
    if (path == null || !mounted) return;

    setState(() => _audioPath = path);
  }

  // ── 导入 ────────────────────────────────────────────────────────────────

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
    Fluttertoast.showToast(msg: t.dialog_importing);

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
    debugPrint('[hibiki-import] subtitleBook: parsing cues...');

    final List<AudioCue> cues = await _parseCuesWithIndex(
      File(_subtitlePath!),
      uid,
      0,
    );
    debugPrint('[hibiki-import] subtitleBook: parsed ${cues.length} cues');

    int ttuBookId = 0;
    if (cues.isNotEmpty) {
      try {
        debugPrint('[hibiki-import] subtitleBook: building IDB payload...');
        final TtuIdbPayload payload = CuesToEpub.buildIdbPayload(
          title: title,
          cues: cues,
        );
        debugPrint('[hibiki-import] subtitleBook: injecting into ttu IDB...');
        ttuBookId = await _injectPayloadIntoTtuIdb(payload);
        debugPrint('[hibiki-import] subtitleBook: IDB inject done, id=$ttuBookId');
      } catch (e) {
        debugPrint('[hibiki-import] ttu IDB inject failed: $e');
      }
    }

    debugPrint('[hibiki-import] subtitleBook: persisting files...');
    final Directory persistDir = await _ensurePersistDir(uid);
    final String persistedSrt =
        await _persistFile(File(_subtitlePath!), persistDir);

    String? persistedAudioPath;
    if (_audioPath != null) {
      persistedAudioPath = await _persistFile(File(_audioPath!), persistDir);
    }

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
    debugPrint('[hibiki-import] subtitleBook: repo.save done');
    await widget.repo.saveCues(uid: uid, cues: cues);
    debugPrint('[hibiki-import] subtitleBook: saveCues done, COMPLETE');
  }

  /// EPUB-only flow: read the file bytes and drive ttu's own file-input
  /// importer. For non-EPUB text formats, converts to EPUB first.
  /// We don't build a [SrtBook] — the book just shows up in the
  /// regular EPUB section of the bookshelf.
  Future<void> _importEpubOnly({required String title}) async {
    debugPrint('[hibiki-import] epubOnly: start');
    final File file = File(_epubPath!);
    final Uint8List bytes;
    final String filename;

    if (TextToEpub.isSupported(_epubPath!)) {
      debugPrint('[hibiki-import] epubOnly: converting to EPUB...');
      bytes = await TextToEpub.convert(file: file, title: title);
      filename = '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub';
    } else {
      bytes = await file.readAsBytes();
      filename = _basename(_epubPath!);
    }

    debugPrint('[hibiki-import] epubOnly: TtuEpubImporter.import (${bytes.length} bytes)...');
    final int ttuBookId = await TtuEpubImporter.import(
      bytes: bytes,
      filename: filename,
      serverPort: widget.serverPort,
    );
    debugPrint('[hibiki-import] epubOnly: COMPLETE ttuBookId=$ttuBookId');
  }

  /// EPUB + subtitle (+optional audio) flow: import the real EPUB via ttu,
  /// then attach a Sasayaki-matched [Audiobook] record pointing to the
  /// same `bookUid` the bookshelf will compute for this book.
  Future<String?> _importEpubWithAlignment({required String title}) async {
    debugPrint('[hibiki-import] epubAlign: start');
    final File epubFile = File(_epubPath!);
    final Uint8List importBytes;
    final String importFilename;
    if (TextToEpub.isSupported(_epubPath!)) {
      debugPrint('[hibiki-import] epubAlign: converting to EPUB...');
      importBytes = await TextToEpub.convert(file: epubFile, title: title);
      importFilename = '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub';
    } else {
      importBytes = await epubFile.readAsBytes();
      importFilename = _basename(_epubPath!);
    }
    debugPrint('[hibiki-import] epubAlign: TtuEpubImporter.import...');
    final int ttuBookId = await TtuEpubImporter.import(
      bytes: importBytes,
      filename: importFilename,
      serverPort: widget.serverPort,
    );
    debugPrint('[hibiki-import] epubAlign: ttuBookId=$ttuBookId');
    if (ttuBookId <= 0) {
      throw StateError('ttu returned invalid book id');
    }

    String idbTitle = '';
    List<EpubSection> sections = const <EpubSection>[];
    try {
      debugPrint('[hibiki-import] epubAlign: readBookRecord...');
      final TtuBookRecord rec = await TtuIdbReader.readBookRecord(
        ttuBookId: ttuBookId,
        serverPort: widget.serverPort,
      );
      idbTitle = rec.title;
      sections = rec.sections;
      debugPrint('[hibiki-import] epubAlign: got ${sections.length} sections');
    } catch (e) {
      debugPrint('[hibiki-import] readBookRecord failed: $e');
    }
    final String safeTitle = idbTitle.isNotEmpty ? idbTitle : ' ';
    final String mediaIdentifier =
        'http://localhost:${widget.serverPort}/b.html?id=$ttuBookId&?title=$safeTitle';
    final String bookUid =
        '${widget.ttuMediaSourceIdentifier}/$mediaIdentifier';

    final String ext = _subtitlePath!.split('.').last.toLowerCase();
    debugPrint('[hibiki-import] epubAlign: parsing cues (ext=$ext)...');
    final List<AudioCue> cues = await _parseCuesWithIndex(
      File(_subtitlePath!),
      bookUid,
      0,
    );
    debugPrint('[hibiki-import] epubAlign: parsed ${cues.length} cues');
    final String chapterHref = _defaultChapterFor(ext);

    AudiobookHealth health;
    final bool runMatcher = SasayakiRematch.supportedFormats.contains(ext);
    debugPrint('[hibiki-import] epubAlign: runMatcher=$runMatcher sections=${sections.length} cues=${cues.length}');
    if (runMatcher && sections.isNotEmpty && cues.isNotEmpty) {
      int chosenWindow = _searchWindow;
      if (_autoWindow) {
        final int? best = await SasayakiRematch.runAutoProbe(
          sections: sections,
          cues: cues,
        );
        if (best != null) {
          chosenWindow = best;
        }
      }
      debugPrint('[hibiki-import] epubAlign: running Sasayaki match (window=$chosenWindow)...');
      health = await _runSasayakiMatch(
        sections: sections,
        cues: cues,
        searchWindow: chosenWindow,
        similarityThreshold: _similarityThreshold,
      );
      debugPrint('[hibiki-import] epubAlign: Sasayaki match done');
    } else if (runMatcher) {
      health = sections.isEmpty
          ? AudiobookHealth.failed(reason: 'ttu IDB record had 0 sections')
          : AudiobookHealth.failed(reason: 'parser returned 0 cues');
    } else {
      health = AudiobookHealth.notApplicable(
        reason: '$ext format uses file anchors, no matcher needed',
      );
    }

    debugPrint('[hibiki-import] epubAlign: persisting files...');
    final Directory persistDir = await _ensurePersistDir(bookUid);
    final String persistedSrt =
        await _persistFile(File(_subtitlePath!), persistDir);

    String? persistedAudioPath;
    if (_audioPath != null) {
      persistedAudioPath = await _persistFile(File(_audioPath!), persistDir);
    }

    final Audiobook audiobook = Audiobook()
      ..bookUid = bookUid
      ..alignmentFormat = ext
      ..alignmentPath = persistedSrt;
    if (persistedAudioPath != null) {
      audiobook.audioPaths = [persistedAudioPath];
    }
    health.packInto(audiobook);

    debugPrint('[hibiki-import] EPUB+align save: bookUid="$bookUid" '
        'ttuBookId=$ttuBookId cues=${cues.length}');

    await widget.audiobookRepo.saveAudiobook(audiobook);
    debugPrint('[hibiki-import] epubAlign: saveAudiobook done');
    await widget.audiobookRepo.saveCues(
      bookUid: bookUid,
      chapterHref: chapterHref,
      cues: cues,
    );
    debugPrint('[hibiki-import] epubAlign: saveCues done');
    await widget.audiobookRepo.updateHealthOverlay(
      bookUid: bookUid,
      health: health,
    );
    debugPrint('[hibiki-import] epubAlign: COMPLETE');

    return _summarizeHealth(health);
  }

  Future<AudiobookHealth> _runSasayakiMatch({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    required int searchWindow,
    double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
  }) async {
    try {
      final MatchResult result = await EpubCueMatcher.matchInIsolate(
        sections: sections,
        cues: cues,
        searchWindow: searchWindow,
        similarityThreshold: similarityThreshold,
      );
      SasayakiMatchCodec.applyToCues(cues: cues, result: result);
      debugPrint('[hibiki-import] Sasayaki match: '
          '${result.matchedCues}/${result.totalCues} window=$searchWindow '
          'threshold=$similarityThreshold');
      final int pct = (result.matchRate * 100).round();
      return AudiobookHealth.fromRatePct(
        ratePct: pct,
        reason: '${result.matchedCues}/${result.totalCues} cues matched '
            '(window=$searchWindow threshold=$similarityThreshold)',
      );
    } catch (e) {
      debugPrint('[hibiki-import] Sasayaki match failed: $e');
      return AudiobookHealth.failed(reason: 'matcher threw: $e');
    }
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
