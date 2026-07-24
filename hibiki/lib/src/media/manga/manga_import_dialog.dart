import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';
import 'package:hibiki/src/media/manga/manga_importer.dart';
import 'package:hibiki/utils.dart';

/// 漫画导入对话框：选一个 `.mokuro` 文件（其同级目录须有图片），校验通过后离主线程解析/
/// 复制/入库，成功后 `Navigator.pop` 返回新建 `EpubBooks.bookKey`（`format='manga'`）。
///
/// 导入脚手架参照 [BookImportDialog] 的 AlertDialog 骨架。落库端是 `EpubBooks`（第三种书），
/// 复用整套书架 / 进度 / 删除管线。
class MangaImportDialog extends StatefulWidget {
  /// [db] 必填：导入器写入此 DB，调用方读取须为同一实例。
  const MangaImportDialog({required this.db, super.key});

  /// 目标数据库（漫画行写入此处）。
  final HibikiDatabase db;

  @override
  State<MangaImportDialog> createState() => _MangaImportDialogState();
}

class _MangaImportDialogState extends State<MangaImportDialog> {
  String? _mokuroPath;
  bool _busy = false;
  int _done = 0;
  int _total = 0;
  String? _error;

  bool get _canImport =>
      !_busy &&
      _mokuroPath != null &&
      mangaImportCanImport(<String>[_mokuroPath!]);

  Future<void> _pickMokuro() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['mokuro'],
      allowMultiple: false,
    );
    final String? path = result?.files.single.path;
    if (path == null || !mounted) return;
    final bool ok = mangaImportCanImport(<String>[path]);
    setState(() {
      _mokuroPath = path;
      _error = ok ? null : t.manga_invalid_import;
    });
  }

  Future<void> _doImport() async {
    if (!_canImport) return;
    final String mokuroPath = _mokuroPath!;
    setState(() {
      _busy = true;
      _error = null;
      _done = 0;
      _total = 0;
    });
    try {
      final String bookKey = await MangaImporter.importFromMokuroPath(
        db: widget.db,
        mokuroPath: mokuroPath,
        onProgress: (int done, int total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      Navigator.pop(context, bookKey);
    } on DuplicateImportCancelledException {
      // 用户在同名弹窗选了「否」——取消，不是错误。
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.manga_invalid_import;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final double? progress =
        _busy && _total > 0 ? (_done / _total).clamp(0.0, 1.0) : null;
    return AlertDialog(
      title: Text(t.manga_import_title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickMokuro,
            icon: const Icon(Icons.menu_book_outlined),
            label: Text(
              _mokuroPath == null
                  ? t.manga_import_pick
                  : p.basename(_mokuroPath!),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_busy) ...<Widget>[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
          ],
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
              : Text(t.manga_import_confirm),
        ),
      ],
    );
  }
}
