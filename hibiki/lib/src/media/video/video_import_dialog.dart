import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// 按字幕扩展名路由到对应解析器，返回按 [AudioCue.startMs] 升序排序的 cue。
///
/// 纯函数，无 IO / context 依赖，是 [VideoImportDialog] 的可测核心：
/// - `srt` → [SrtParser]
/// - `vtt` → [VttParser]
/// - `ass` / `ssa` → [AssParser]
/// - 其他 → 抛 [ArgumentError]
List<AudioCue> parseSubtitleCues({
  required String content,
  required String format,
  required String bookUid,
}) {
  final String normalized = format.toLowerCase();
  final List<AudioCue> cues;
  switch (normalized) {
    case 'srt':
      cues = SrtParser.parseString(content: content, bookUid: bookUid);
      break;
    case 'vtt':
      cues = VttParser.parseString(content: content, bookUid: bookUid);
      break;
    case 'ass':
    case 'ssa':
      cues = AssParser.parseString(content: content, bookUid: bookUid);
      break;
    default:
      throw ArgumentError.value(
        format,
        'format',
        'Unsupported subtitle format',
      );
  }
  cues.sort((AudioCue a, AudioCue b) => a.startMs.compareTo(b.startMs));
  return cues;
}

/// 视频导入对话框：选一个视频文件 + 一个外挂字幕文件（srt/vtt/ass/ssa），
/// 解析字幕为 cue 后写入 VideoBooks 与 audioCues 表。
///
/// Phase 0 不处理跨设备同步身份：bookUid 直接用视频文件名（basename）。
class VideoImportDialog extends StatefulWidget {
  const VideoImportDialog({required this.repo, super.key});

  final VideoBookRepository repo;

  @override
  State<VideoImportDialog> createState() => _VideoImportDialogState();
}

class _VideoImportDialogState extends State<VideoImportDialog> {
  String? _videoPath;
  String? _subtitlePath;
  bool _busy = false;

  bool get _canImport =>
      !_busy && _videoPath != null && _subtitlePath != null;

  Future<void> _pickVideo() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );
    final String? path = result?.files.single.path;
    if (path == null) return;
    setState(() => _videoPath = path);
  }

  Future<void> _pickSubtitle() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa'],
      allowMultiple: false,
    );
    final String? path = result?.files.single.path;
    if (path == null) return;
    setState(() => _subtitlePath = path);
  }

  Future<void> _doImport() async {
    if (!_canImport) return;
    final String videoPath = _videoPath!;
    final String subtitlePath = _subtitlePath!;
    setState(() => _busy = true);
    try {
      final String bookUid = 'video/${p.basename(videoPath)}';
      final String format = p
          .extension(subtitlePath)
          .replaceFirst('.', '')
          .toLowerCase();
      final String content = await readTextWithEncoding(File(subtitlePath));
      final List<AudioCue> cues = parseSubtitleCues(
        content: content,
        format: format,
        bookUid: bookUid,
      );

      await widget.repo.saveVideoBook(VideoBooksCompanion(
        bookUid: Value(bookUid),
        title: Value(p.basenameWithoutExtension(videoPath)),
        videoPath: Value(videoPath),
        subtitleSource: Value(subtitlePath),
        subtitleFormat: Value(format),
        importedAt: Value(DateTime.now()),
      ));
      await widget.repo.saveCues(bookUid: bookUid, cues: cues);

      if (!mounted) return;
      Navigator.pop(context, bookUid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.video_import_title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickVideo,
            icon: const Icon(Icons.movie_outlined),
            label: Text(
              _videoPath == null
                  ? t.video_import_pick_video
                  : p.basename(_videoPath!),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickSubtitle,
            icon: const Icon(Icons.subtitles_outlined),
            label: Text(
              _subtitlePath == null
                  ? t.video_import_pick_subtitle
                  : p.basename(_subtitlePath!),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          onPressed: _canImport ? _doImport : null,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(t.video_import_confirm),
        ),
      ],
    );
  }
}
