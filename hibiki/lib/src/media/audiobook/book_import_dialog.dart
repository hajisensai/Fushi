import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/cues_to_epub.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/src/media/audiobook/ass_parser.dart';
import 'package:hibiki/src/media/audiobook/lrc_parser.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';
import 'package:hibiki/src/media/audiobook/ttu_epub_importer.dart';
import 'package:hibiki/src/media/audiobook/vtt_parser.dart';
import 'package:hibiki/utils.dart';

/// 统一"导入书"对话框：EPUB 或字幕任选其一，字幕可再附加音频。
///
/// - **仅 EPUB**：读取用户选的 EPUB 文件 → [TtuEpubImporter] 驱动 ttu reader
///   自己的 `<input type=file>` 导入管线，拿到 `ttuBookId`。
/// - **仅字幕（可带音频）**：解析 cues → [CuesToEpub.buildIdbPayload] 拼 ttu
///   原生 IDB 载荷并 `put()` 写入（带 `data-cue-id` span，供 AudiobookBridge
///   做高亮同步）；同时把 cues + audio 路径落到 Isar 的 [SrtBook] / [AudioCue]。
/// - **EPUB + 字幕**：不支持（要给 EPUB 挂字幕走书架长按里的 AudiobookImportDialog）。
class BookImportDialog extends StatefulWidget {
  const BookImportDialog({
    required this.repo,
    required this.serverPort,
    super.key,
  });

  final SrtBookRepository repo;

  /// ッツ Ebook Reader local server port.
  final int serverPort;

  @override
  State<BookImportDialog> createState() => _BookImportDialogState();
}

class _BookImportDialogState extends State<BookImportDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _authorCtrl = TextEditingController();

  String? _epubPath;
  String? _srtPath;

  // 音频来源两者互斥，最后选的那个生效。
  String? _audioDir;
  List<String>? _audioPaths;

  bool _importing = false;

  bool get _hasAudioSource =>
      (_audioDir != null) || (_audioPaths != null && _audioPaths!.isNotEmpty);

  String get _audioSourceLabel {
    if (_audioPaths != null && _audioPaths!.isNotEmpty) {
      return t.srt_import_files_selected(n: _audioPaths!.length);
    }
    if (_audioDir != null) return _basename(_audioDir!);
    return '';
  }

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
          onPressed: _importing ? null : _doImport,
          child: Text(t.dialog_import),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
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
        _audioSourceRow(),
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
              Text(t.srt_import_pick_srt, style: const TextStyle(fontSize: 13)),
              if (_srtPath != null)
                Text(
                  _basename(_srtPath!),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.folder_open, size: 20),
          tooltip: t.srt_import_pick_srt_dir,
          onPressed: _pickSrtFromFolder,
        ),
        IconButton(
          icon: const Icon(Icons.subtitles, size: 20),
          tooltip: t.srt_import_pick_srt,
          onPressed: _pickSrt,
        ),
      ],
    );
  }

  Widget _audioSourceRow() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _audioPaths != null
                    ? t.srt_import_pick_audio_files
                    : t.srt_import_pick_audio_dir,
                style: const TextStyle(fontSize: 13),
              ),
              if (_hasAudioSource)
                Text(
                  _audioSourceLabel,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.folder_open, size: 20),
          tooltip: t.srt_import_pick_audio_dir,
          onPressed: _pickAudioDir,
        ),
        IconButton(
          icon: const Icon(Icons.audio_file, size: 20),
          tooltip: t.srt_import_pick_audio_files,
          onPressed: _pickAudioFiles,
        ),
      ],
    );
  }

  // ── 文件/目录选择 ────────────────────────────────────────────────────────

  Future<void> _pickEpub() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );
    final String? path = result?.files.single.path;
    if (path != null && mounted) {
      setState(() {
        _epubPath = path;
        if (_titleCtrl.text.isEmpty) {
          _titleCtrl.text = _basename(path)
              .replaceAll(RegExp(r'\.epub$', caseSensitive: false), '');
        }
      });
    }
  }

  Future<void> _pickSrt() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['srt', 'lrc', 'vtt', 'ass', 'ssa'],
    );
    final String? path = result?.files.single.path;
    if (path != null && mounted) {
      setState(() {
        _srtPath = path;
        if (_titleCtrl.text.isEmpty) {
          _titleCtrl.text = _basename(path).replaceAll(
              RegExp(r'\.(srt|lrc|vtt|ass|ssa)$', caseSensitive: false), '');
        }
      });
    }
  }

  Future<void> _pickSrtFromFolder() async {
    final String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || !mounted) return;

    final directory = Directory(dir);
    if (!directory.existsSync()) {
      Fluttertoast.showToast(msg: t.srt_no_subtitle_files);
      return;
    }

    const subtitleExts = ['.srt', '.lrc', '.vtt', '.ass', '.ssa'];
    final files = directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) {
          final lower = f.path.toLowerCase();
          return subtitleExts.any(lower.endsWith);
        })
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    if (files.isEmpty) {
      Fluttertoast.showToast(msg: t.srt_no_subtitle_files);
      return;
    }

    String? chosen;
    if (files.length == 1) {
      chosen = files.first.path;
    } else {
      chosen = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(t.srt_pick_subtitle_file),
          children: [
            for (final f in files)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, f.path),
                child: Text(
                  _basename(f.path),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
        ),
      );
    }

    if (chosen != null && mounted) {
      setState(() {
        _srtPath = chosen;
        if (_titleCtrl.text.isEmpty) {
          _titleCtrl.text = _basename(_srtPath!).replaceAll(
              RegExp(r'\.(srt|lrc|vtt|ass|ssa)$', caseSensitive: false), '');
        }
      });
    }
  }

  Future<void> _pickAudioDir() async {
    final String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null && mounted) {
      setState(() {
        _audioDir = dir;
        _audioPaths = null;
      });
    }
  }

  Future<void> _pickAudioFiles() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (result == null || !mounted) return;

    final List<String> paths = result.files
        .map((f) => f.path)
        .whereType<String>()
        .toList()
      ..sort();

    if (paths.isNotEmpty) {
      setState(() {
        _audioPaths = paths;
        _audioDir = null;
      });
    }
  }

  // ── 导入 ────────────────────────────────────────────────────────────────

  Future<void> _doImport() async {
    if (_epubPath != null && _srtPath != null) {
      Fluttertoast.showToast(msg: t.srt_import_conflict);
      return;
    }
    if (_epubPath == null && _srtPath == null) {
      Fluttertoast.showToast(msg: t.srt_import_missing_input);
      return;
    }
    final String title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      Fluttertoast.showToast(msg: t.srt_import_missing_title);
      return;
    }

    setState(() => _importing = true);

    try {
      final bool isSubtitleFlow = _srtPath != null;
      final String? authorText = _authorCtrl.text.trim().isEmpty
          ? null
          : _authorCtrl.text.trim();

      if (isSubtitleFlow) {
        await _importSubtitleBook(title: title, author: authorText);
      } else {
        await _importEpubOnly(title: title);
      }

      if (mounted) {
        Fluttertoast.showToast(msg: t.srt_import_success);
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

  /// Subtitle flow: parse cues → build ttu IDB payload with `data-cue-id`
  /// spans → inject directly, then persist the [SrtBook] + cues for sync.
  Future<void> _importSubtitleBook({
    required String title,
    required String? author,
  }) async {
    final String uid = 'srtbook_${DateTime.now().millisecondsSinceEpoch}';
    final List<AudioCue> cues = _parseCues(File(_srtPath!), uid);

    int ttuBookId = 0;
    try {
      final TtuIdbPayload payload = CuesToEpub.buildIdbPayload(
        title: title,
        cues: cues,
      );
      ttuBookId = await _injectPayloadIntoTtuIdb(payload);
    } catch (e) {
      debugPrint('[hibiki-import] ttu IDB inject failed: $e');
    }

    final SrtBook book = SrtBook()
      ..uid = uid
      ..title = title
      ..srtPath = _srtPath!
      ..importedAt = DateTime.now().millisecondsSinceEpoch
      ..ttuBookId = ttuBookId;
    if (_audioPaths != null && _audioPaths!.isNotEmpty) {
      book.audioPaths = _audioPaths;
    } else if (_audioDir != null) {
      book.audioRoot = _audioDir;
    }
    if (author != null) {
      book.author = author;
    }

    debugPrint('[hibiki-import] SrtBook save: uid=$uid title="$title" '
        'ttuBookId=$ttuBookId cues=${cues.length}');

    await widget.repo.save(book);
    await widget.repo.saveCues(uid: uid, cues: cues);
  }

  /// EPUB-only flow: read the file bytes and drive ttu's own file-input
  /// importer. We don't build a [SrtBook] — the book just shows up in the
  /// regular EPUB section of the bookshelf.
  Future<void> _importEpubOnly({required String title}) async {
    final File file = File(_epubPath!);
    final int ttuBookId = await TtuEpubImporter.import(
      bytes: await file.readAsBytes(),
      filename: _basename(_epubPath!),
      serverPort: widget.serverPort,
    );
    debugPrint('[hibiki-import] EPUB save: title="$title" '
        'ttuBookId=$ttuBookId path=$_epubPath');
  }

  /// Injects [payload] into the ッツ reader's "books" IDB via a
  /// headless WebView and resolves with the auto-incremented row key.
  Future<int> _injectPayloadIntoTtuIdb(TtuIdbPayload payload) async {
    final String jsonStr = jsonEncode(payload.toJson());
    final String js = '''
(async function() {
  const payload = $jsonStr;
  const id = await new Promise((resolve, reject) => {
    const req = indexedDB.open('books');
    req.onupgradeneeded = (event) => {
      const db = event.target.result;
      if (!db.objectStoreNames.contains('data'))
        db.createObjectStore('data', {autoIncrement: true});
      if (!db.objectStoreNames.contains('bookmark'))
        db.createObjectStore('bookmark', {autoIncrement: true});
      if (!db.objectStoreNames.contains('lastItem'))
        db.createObjectStore('lastItem');
    };
    req.onsuccess = (event) => {
      const db = event.target.result;
      if (!db.objectStoreNames.contains('data')) {
        reject('data_store_missing'); return;
      }
      const tx = db.transaction(['data'], 'readwrite');
      const store = tx.objectStore('data');
      const put = store.put(payload);
      put.onsuccess = (e) => resolve(e.target.result);
      put.onerror = (e) => reject(String(e.target.error));
    };
    req.onerror = (e) => reject(String(e.target.error));
  });
  console.log(JSON.stringify({messageType: 'srt_idb_ok', id: id}));
})().catch(err => {
  console.log(JSON.stringify({messageType: 'srt_idb_err', error: String(err)}));
});
''';

    final Completer<int> completer = Completer<int>();
    HeadlessInAppWebView? webView;
    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:${widget.serverPort}/'),
      ),
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
      ),
      onLoadStop: (controller, url) async {
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

  List<AudioCue> _parseCues(File file, String bookUid) {
    final String ext = file.path.split('.').last.toLowerCase();
    switch (ext) {
      case 'lrc':
        return LrcParser.parse(lrcFile: file, bookUid: bookUid);
      case 'vtt':
        return VttParser.parse(vttFile: file, bookUid: bookUid);
      case 'ass':
      case 'ssa':
        return AssParser.parse(assFile: file, bookUid: bookUid);
      default:
        return SrtParser.parse(srtFile: file, bookUid: bookUid);
    }
  }

  String _basename(String path) =>
      path.split(Platform.pathSeparator).last;
}
