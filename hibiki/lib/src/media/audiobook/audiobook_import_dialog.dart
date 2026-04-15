import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/json_alignment_parser.dart';
import 'package:hibiki/src/media/audiobook/smil_parser.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';
import 'package:hibiki/utils.dart';

/// 有声书导入/移除对话框。
///
/// 允许用户为当前书籍挂载音频目录 + 对齐文件，或移除已有有声书。
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
  String? _audioDir;
  String? _alignmentPath;
  bool _importing = false;

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
            : _buildImportForm(),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow(Icons.folder_open, ab.audioRoot),
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
      children: [
        _pickRow(
          label: t.audiobook_pick_audio_dir,
          value: _audioDir,
          onTap: _pickAudioDir,
        ),
        const SizedBox(height: 12),
        _pickRow(
          label: t.audiobook_pick_alignment,
          value: _alignmentPath,
          onTap: _pickAlignment,
        ),
        if (_importing) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }

  Widget _pickRow({
    required String label,
    required String? value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 13)),
                  if (value != null)
                    Text(
                      value,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAudioDir() async {
    final String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null && mounted) {
      setState(() => _audioDir = dir);
    }
  }

  Future<void> _pickAlignment() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['smil', 'json', 'srt'],
    );
    final String? path = result?.files.single.path;
    if (path != null && mounted) {
      setState(() => _alignmentPath = path);
    }
  }

  Future<void> _doImport() async {
    if (_audioDir == null || _alignmentPath == null) {
      Fluttertoast.showToast(msg: t.audiobook_import_error);
      return;
    }

    setState(() => _importing = true);

    try {
      final String ext =
          _alignmentPath!.split('.').last.toLowerCase();
      final String format =
          (ext == 'smil') ? 'smil' : (ext == 'srt') ? 'srt' : 'json';

      final Audiobook audiobook = Audiobook()
        ..bookUid = widget.bookUid
        ..audioRoot = _audioDir!
        ..alignmentFormat = format
        ..alignmentPath = _alignmentPath!;

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

    if (format == 'srt') {
      // SRT 作为 EPUB 对齐文件：全书单章节，chapterHref 固定为 srt://default
      final List<AudioCue> cues = SrtParser.parse(
        srtFile: alignFile,
        bookUid: widget.bookUid,
      );
      await widget.repo.saveCues(
        bookUid: widget.bookUid,
        chapterHref: SrtParser.defaultChapter,
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
}
