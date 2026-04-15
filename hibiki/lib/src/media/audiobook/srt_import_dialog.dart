import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';
import 'package:hibiki/utils.dart';

/// SRT 独立有声书导入对话框。
///
/// 用户选择 SRT 文件 + 音频目录，填写书名（可选作者），
/// 点击导入后创建 [SrtBook] 并解析 [AudioCue] 存入 Isar。
class SrtImportDialog extends StatefulWidget {
  const SrtImportDialog({required this.repo, super.key});

  final SrtBookRepository repo;

  @override
  State<SrtImportDialog> createState() => _SrtImportDialogState();
}

class _SrtImportDialogState extends State<SrtImportDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _authorCtrl = TextEditingController();

  String? _srtPath;
  String? _audioDir;
  bool _importing = false;

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
        _pickRow(
          label: t.srt_import_pick_srt,
          value: _srtPath != null ? _basename(_srtPath!) : null,
          onTap: _pickSrt,
        ),
        const SizedBox(height: 8),
        _pickRow(
          label: t.srt_import_pick_audio_dir,
          value: _audioDir != null ? _basename(_audioDir!) : null,
          onTap: _pickAudioDir,
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
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey),
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

  Future<void> _pickSrt() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['srt'],
    );
    final String? path = result?.files.single.path;
    if (path != null && mounted) {
      setState(() {
        _srtPath = path;
        // 以文件名（去扩展）作为默认书名，仅在用户尚未手动填写时填入
        if (_titleCtrl.text.isEmpty) {
          _titleCtrl.text = _basename(path)
              .replaceAll(RegExp(r'\.srt$', caseSensitive: false), '');
        }
      });
    }
  }

  Future<void> _pickAudioDir() async {
    final String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null && mounted) {
      setState(() => _audioDir = dir);
    }
  }

  Future<void> _doImport() async {
    final String title = _titleCtrl.text.trim();
    if (_srtPath == null || _audioDir == null || title.isEmpty) {
      Fluttertoast.showToast(msg: t.srt_import_error);
      return;
    }

    setState(() => _importing = true);

    try {
      final String uid =
          'srtbook_${DateTime.now().millisecondsSinceEpoch}';

      final SrtBook book = SrtBook()
        ..uid = uid
        ..title = title
        ..audioRoot = _audioDir!
        ..srtPath = _srtPath!
        ..importedAt = DateTime.now().millisecondsSinceEpoch;

      final String authorText = _authorCtrl.text.trim();
      if (authorText.isNotEmpty) {
        book.author = authorText;
      }

      await widget.repo.save(book);

      final List<AudioCue> cues = SrtParser.parse(
        srtFile: File(_srtPath!),
        bookUid: uid,
      );
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

  String _basename(String path) {
    return path.split(Platform.pathSeparator).last;
  }
}
