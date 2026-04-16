import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/src/media/audiobook/ass_parser.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/json_alignment_parser.dart';
import 'package:hibiki/src/media/audiobook/lrc_parser.dart';
import 'package:hibiki/src/media/audiobook/smil_parser.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';
import 'package:hibiki/src/media/audiobook/vtt_parser.dart';
import 'package:hibiki/utils.dart';

/// 有声书导入/移除对话框。
///
/// UI 沿用 [SrtImportDialog] 的双图标按钮模式：每一项右侧提供
/// "选目录"和"选文件"两个按钮，可在两种音频来源模式间切换。
class AudiobookImportDialog extends StatefulWidget {
  const AudiobookImportDialog({
    required this.bookUid,
    required this.repo,
    super.key,
  });

  final String bookUid;
  final AudiobookRepository repo;

  @override
  State<AudiobookImportDialog> createState() => _AudiobookImportDialogState();
}

class _AudiobookImportDialogState extends State<AudiobookImportDialog> {
  // ── 音频来源 ── 两者互斥，最后选的那个生效 ─────────────────────────────────
  String? _audioDir;          // folder 模式
  List<String>? _audioPaths;  // files 模式

  String? _alignmentPath;
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

  // ── 构建 ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final Audiobook? existing = widget.repo.findByBookUid(widget.bookUid);

    return AlertDialog(
      title: Text(
        existing != null ? t.audiobook_attached : t.audiobook_import,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: existing != null
            ? _buildAttachedView(existing)
            : SingleChildScrollView(child: _buildImportForm()),
      ),
      actions: existing != null
          ? [
              TextButton(
                onPressed: () => _removeAudiobook(existing),
                child: Text(t.audiobook_remove),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t.dialog_close),
              ),
            ]
          : [
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

  Widget _buildAttachedView(Audiobook ab) {
    final String audioLabel = (ab.audioPaths != null && ab.audioPaths!.isNotEmpty)
        ? t.srt_import_files_selected(n: ab.audioPaths!.length)
        : (ab.audioRoot ?? '');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow(
          (ab.audioPaths != null && ab.audioPaths!.isNotEmpty)
              ? Icons.audio_file
              : Icons.folder_open,
          audioLabel,
        ),
        const SizedBox(height: 8),
        _infoRow(Icons.align_horizontal_left, ab.alignmentPath),
      ],
    );
  }

  Widget _infoRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ],
    );
  }

  Widget _buildImportForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _audioSourceRow(),
        const SizedBox(height: 12),
        _alignmentRow(),
        if (_importing) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }

  /// 音频来源行：标签 + [选目录] [选文件] 两个按钮。
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

  /// 对齐文件行：标签 + [选文件] 按钮。
  Widget _alignmentRow() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.audiobook_pick_alignment,
                style: const TextStyle(fontSize: 13),
              ),
              if (_alignmentPath != null)
                Text(
                  _basename(_alignmentPath!),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.align_horizontal_left, size: 20),
          tooltip: t.audiobook_pick_alignment,
          onPressed: _pickAlignment,
        ),
      ],
    );
  }

  // ── 文件/目录选择 ────────────────────────────────────────────────────────────

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

  Future<void> _pickAlignment() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['smil', 'json', 'srt', 'lrc', 'vtt', 'ass'],
    );
    final String? path = result?.files.single.path;
    if (path != null && mounted) {
      setState(() => _alignmentPath = path);
    }
  }

  // ── 导入 ─────────────────────────────────────────────────────────────────────

  Future<void> _doImport() async {
    if (!_hasAudioSource || _alignmentPath == null) {
      Fluttertoast.showToast(msg: t.audiobook_import_error);
      return;
    }

    setState(() => _importing = true);

    try {
      final String ext =
          _alignmentPath!.split('.').last.toLowerCase();
      const Set<String> cueFormats = {'smil', 'srt', 'lrc', 'vtt', 'ass'};
      final String format = cueFormats.contains(ext) ? ext : 'json';

      final Audiobook audiobook = Audiobook()
        ..bookUid = widget.bookUid
        ..alignmentFormat = format
        ..alignmentPath = _alignmentPath!;

      if (_audioPaths != null && _audioPaths!.isNotEmpty) {
        audiobook.audioPaths = _audioPaths;
      } else {
        audiobook.audioRoot = _audioDir;
      }

      await widget.repo.saveAudiobook(audiobook);
      await _parseCues(format);

      if (mounted) {
        Fluttertoast.showToast(msg: t.audiobook_import_success);
        Navigator.pop(context, true); // true = reload player
      }
    } catch (e) {
      debugPrint('AudiobookImportDialog import error: $e');
      if (mounted) {
        Fluttertoast.showToast(msg: t.audiobook_import_error);
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  Future<void> _parseCues(String format) async {
    final File alignFile = File(_alignmentPath!);

    // SRT / LRC / VTT / ASS 四种都走"单章节 defaultChapter"路径
    if (format == 'srt') {
      final List<AudioCue> cues = SrtParser.parse(
        srtFile: alignFile,
        bookUid: widget.bookUid,
      );
      await widget.repo.saveCues(
        bookUid: widget.bookUid,
        chapterHref: SrtParser.defaultChapter,
        cues: cues,
      );
    } else if (format == 'lrc') {
      final List<AudioCue> cues = LrcParser.parse(
        lrcFile: alignFile,
        bookUid: widget.bookUid,
      );
      await widget.repo.saveCues(
        bookUid: widget.bookUid,
        chapterHref: LrcParser.defaultChapter,
        cues: cues,
      );
    } else if (format == 'vtt') {
      final List<AudioCue> cues = VttParser.parse(
        vttFile: alignFile,
        bookUid: widget.bookUid,
      );
      await widget.repo.saveCues(
        bookUid: widget.bookUid,
        chapterHref: VttParser.defaultChapter,
        cues: cues,
      );
    } else if (format == 'ass') {
      final List<AudioCue> cues = AssParser.parse(
        assFile: alignFile,
        bookUid: widget.bookUid,
      );
      await widget.repo.saveCues(
        bookUid: widget.bookUid,
        chapterHref: AssParser.defaultChapter,
        cues: cues,
      );
    } else if (format == 'json') {
      final List<AudioCue> allCues = JsonAlignmentParser.parse(
        jsonFile: alignFile,
        bookUid: widget.bookUid,
      );
      // 按章节批量存入 Isar
      final Map<String, List<AudioCue>> byChapter = {};
      for (final AudioCue c in allCues) {
        byChapter.putIfAbsent(c.chapterHref, () => []).add(c);
      }
      for (final MapEntry<String, List<AudioCue>> entry
          in byChapter.entries) {
        await widget.repo.saveCues(
          bookUid: widget.bookUid,
          chapterHref: entry.key,
          cues: entry.value,
        );
      }
    } else {
      // SMIL：单文件对应单章节，文件名（去扩展）推断 chapterHref
      final String fileName = _alignmentPath!
          .split(Platform.pathSeparator)
          .last;
      final String chapterHref =
          fileName.replaceAll(RegExp(r'\.smil$', caseSensitive: false), '.xhtml');

      final List<AudioCue> cues = SmilParser.parse(
        smilFile: alignFile,
        bookUid: widget.bookUid,
        chapterHref: chapterHref,
      );
      await widget.repo.saveCues(
        bookUid: widget.bookUid,
        chapterHref: chapterHref,
        cues: cues,
      );
    }
  }

  Future<void> _removeAudiobook(Audiobook ab) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(t.audiobook_remove_confirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.audiobook_remove),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.dialog_cancel),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await widget.repo.deleteAudiobook(widget.bookUid);
      if (mounted) {
        Navigator.pop(context, false); // false = no audiobook
      }
    }
  }

  String _basename(String path) =>
      path.split(Platform.pathSeparator).last;
}
