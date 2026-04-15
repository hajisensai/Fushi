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
import 'package:hibiki/src/media/audiobook/vtt_parser.dart';
import 'package:hibiki/utils.dart';

/// SRT 独立有声书导入对话框。
///
/// 用户选择 SRT 文件 + 音频来源（目录或文件列表），填写书名（可选作者），
/// 点击导入后创建 [SrtBook] 并解析 [AudioCue] 存入 Isar。
///
/// **音频来源两种模式：**
/// - Folder：选择目录，运行时递归扫描其中的音频文件（支持嵌套子目录）。
/// - Files：直接选择一个或多个音频文件，路径写死在 [SrtBook.audioPaths] 中。
class SrtImportDialog extends StatefulWidget {
  const SrtImportDialog({
    required this.repo,
    required this.serverPort,
    super.key,
  });

  final SrtBookRepository repo;

  /// ッツ Ebook Reader local server port.
  /// Used to inject the generated book into the reader's IndexedDB.
  final int serverPort;

  @override
  State<SrtImportDialog> createState() => _SrtImportDialogState();
}

class _SrtImportDialogState extends State<SrtImportDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _authorCtrl = TextEditingController();

  String? _srtPath;

  // ── 音频来源 ── 两者互斥，最后选的那个生效 ─────────────────────────────────
  String? _audioDir;          // folder 模式
  List<String>? _audioPaths;  // files 模式

  bool _importing = false;

  // ── 辅助 getter ─────────────────────────────────────────────────────────────

  bool get _hasAudioSource =>
      (_audioDir != null) || (_audioPaths != null && _audioPaths!.isNotEmpty);

  String get _audioSourceLabel {
    if (_audioPaths != null && _audioPaths!.isNotEmpty) {
      return t.srt_import_files_selected(n: _audioPaths!.length);
    }
    if (_audioDir != null) return _basename(_audioDir!);
    return '';
  }

  // ── 生命周期 ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _titleCtrl.dispose();
    _authorCtrl.dispose();
    super.dispose();
  }

  // ── 构建 ────────────────────────────────────────────────────────────────────

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

  /// 字幕文件行：标签 + [选目录扫描] [选文件] 两个按钮。
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
        // 扫描目录按钮
        IconButton(
          icon: const Icon(Icons.folder_open, size: 20),
          tooltip: t.srt_import_pick_srt_dir,
          onPressed: _pickSrtFromFolder,
        ),
        // 直接选文件按钮
        IconButton(
          icon: const Icon(Icons.subtitles, size: 20),
          tooltip: t.srt_import_pick_srt,
          onPressed: _pickSrt,
        ),
      ],
    );
  }

  /// 音频来源行：标签 + [选目录] [选文件] 两个按钮。
  Widget _audioSourceRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // 根据当前模式显示不同标题
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
            // 选目录按钮
            IconButton(
              icon: const Icon(Icons.folder_open, size: 20),
              tooltip: t.srt_import_pick_audio_dir,
              onPressed: _pickAudioDir,
            ),
            // 选文件按钮
            IconButton(
              icon: const Icon(Icons.audio_file, size: 20),
              tooltip: t.srt_import_pick_audio_files,
              onPressed: _pickAudioFiles,
            ),
          ],
        ),
      ],
    );
  }

  // ── 文件/目录选择 ────────────────────────────────────────────────────────────

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
          _titleCtrl.text = _basename(path)
              .replaceAll(
                  RegExp(r'\.(srt|lrc|vtt|ass|ssa)$',
                      caseSensitive: false),
                  '');
        }
      });
    }
  }

  /// 字幕目录扫描：递归扫描选中目录内的字幕文件，单文件自动选，多文件弹窗让用户挑选。
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
      // 多个字幕文件时弹窗让用户选择
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
          _titleCtrl.text = _basename(_srtPath!)
              .replaceAll(
                  RegExp(r'\.(srt|lrc|vtt|ass|ssa)$', caseSensitive: false),
                  '');
        }
      });
    }
  }

  /// 选目录模式：清空 audioPaths，设置 audioDir。
  Future<void> _pickAudioDir() async {
    final String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null && mounted) {
      setState(() {
        _audioDir = dir;
        _audioPaths = null; // 互斥：清空文件模式
      });
    }
  }

  /// 选文件模式：清空 audioDir，设置 audioPaths。
  /// 支持多选，按文件路径排序（与目录扫描排序一致）。
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
        _audioDir = null; // 互斥：清空目录模式
      });
    }
  }

  // ── 导入 ─────────────────────────────────────────────────────────────────────

  Future<void> _doImport() async {
    final String title = _titleCtrl.text.trim();
    if (_srtPath == null) {
      Fluttertoast.showToast(msg: t.srt_import_missing_srt);
      return;
    }
    if (!_hasAudioSource) {
      Fluttertoast.showToast(msg: t.srt_import_missing_audio_dir);
      return;
    }
    if (title.isEmpty) {
      Fluttertoast.showToast(msg: t.srt_import_missing_title);
      return;
    }

    setState(() => _importing = true);

    try {
      final String uid = 'srtbook_${DateTime.now().millisecondsSinceEpoch}';
      final String authorText = _authorCtrl.text.trim();

      // 1. 解析字幕 cues
      final List<AudioCue> cues = _parseCues(File(_srtPath!), uid);

      // 2. 生成 ttu IndexedDB payload 并注入
      int ttuBookId = 0;
      try {
        final TtuIdbPayload payload = CuesToEpub.buildIdbPayload(
          title: title,
          cues: cues,
        );
        ttuBookId = await _injectIntoTtuIdb(payload);
      } catch (e) {
        debugPrint('SrtImportDialog: ttu IDB inject failed: $e');
        // 非致命错误，继续保存书籍（ttuBookId 保持 0）
      }

      // 3. 构建并保存 SrtBook
      final SrtBook book = SrtBook()
        ..uid = uid
        ..title = title
        ..srtPath = _srtPath!
        ..importedAt = DateTime.now().millisecondsSinceEpoch
        ..ttuBookId = ttuBookId;

      if (_audioPaths != null && _audioPaths!.isNotEmpty) {
        book.audioPaths = _audioPaths;
      } else {
        book.audioRoot = _audioDir;
      }
      if (authorText.isNotEmpty) {
        book.author = authorText;
      }

      await widget.repo.save(book);
      await widget.repo.saveCues(uid: uid, cues: cues);

      if (mounted) {
        Fluttertoast.showToast(msg: t.srt_import_success);
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('SrtImportDialog error: $e');
      if (mounted) {
        Fluttertoast.showToast(msg: t.srt_import_error);
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  /// Injects [payload] into the ッツ Ebook Reader's "books" IndexedDB via a
  /// headless WebView loaded at the ttu server origin.
  ///
  /// Returns the auto-incremented IndexedDB key assigned to the new entry,
  /// or throws if the injection fails or times out.
  Future<int> _injectIntoTtuIdb(TtuIdbPayload payload) async {
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
