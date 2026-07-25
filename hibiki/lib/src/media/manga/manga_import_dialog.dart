import 'dart:async' show unawaited;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';
import 'package:hibiki/src/media/manga/external_mokuro_runner.dart';
import 'package:hibiki/src/media/manga/manga_importer.dart';
import 'package:hibiki/src/media/manga/manga_ocr_provider.dart';
import 'package:hibiki/src/media/manga/manga_ocr_wizard_dialog.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/ocr/manga_ocr_service.dart';
import 'package:hibiki/src/sync/interconnect_manga_ocr_client.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/utils.dart';

/// 漫画导入对话框：选一个 `.mokuro` 文件（其同级目录须有图片），校验通过后离主线程解析/
/// 复制/入库，成功后 `Navigator.pop` 返回新建 `EpubBooks.bookKey`（`format='manga'`）。
///
/// 导入脚手架参照 [BookImportDialog] 的 AlertDialog 骨架。落库端是 `EpubBooks`（第三种书），
/// 复用整套书架 / 进度 / 删除管线。
class MangaImportDialog extends StatefulWidget {
  /// [db] 必填：导入器写入此 DB，调用方读取须为同一实例。
  const MangaImportDialog({
    required this.db,
    this.mangaOcrRemoteRunner,
    this.ocrEntryDesktopOverride,
    super.key,
  });

  /// 目标数据库（漫画行写入此处）。
  final HibikiDatabase db;

  /// 测试缝：注入远程 OCR runner（探测已配对 host 能力 + 代跑）。
  /// null = 生产路径，按 [db] 惰性构造 [InterconnectMangaOcrClient]。
  final MangaOcrRemoteRunner? mangaOcrRemoteRunner;

  /// 测试缝：覆盖「是否桌面平台」判定（widget 测试模拟移动端入口 gating）。
  /// null = 用真实 [isDesktopPlatform]。
  final bool? ocrEntryDesktopOverride;

  @override
  State<MangaImportDialog> createState() => _MangaImportDialogState();
}

class _MangaImportDialogState extends State<MangaImportDialog> {
  String? _mokuroPath;
  bool _busy = false;
  int _done = 0;
  int _total = 0;
  String? _error;

  /// 移动端 OCR 入口 gating——探测到具备漫画 OCR 能力的已配对 host 时才显示入口
  /// （桌面恒显示，不必等探测）。initState 异步探测后置位。
  bool _remoteOcrAvailable = false;

  /// 远程 OCR runner（生产 = [InterconnectMangaOcrClient]；测试注 fake）。
  late final MangaOcrRemoteRunner _mangaOcrRemoteRunner =
      widget.mangaOcrRemoteRunner ??
          InterconnectMangaOcrClient(repo: SyncRepository(widget.db));

  bool get _ocrEntryDesktop =>
      widget.ocrEntryDesktopOverride ?? isDesktopPlatform;

  /// OCR 导入漫画入口显隐：桌面恒显示；移动端仅当探测到可代跑的已配对 host。
  bool get _showOcrEntry => _ocrEntryDesktop || _remoteOcrAvailable;

  @override
  void initState() {
    super.initState();
    // 非桌面平台异步探测已配对 host 的漫画 OCR 能力，命中后亮出「OCR 导入漫画」
    // 入口（桌面恒显示，无需探测）。
    if (!_ocrEntryDesktop) {
      unawaited(_probeRemoteOcrEntry());
    }
  }

  /// 探测已配对 host 的漫画 OCR 能力（capabilities 的 `mangaOcr` 字段；
  /// 老 host 无字段 → null → 入口保持隐藏，版本 skew 零破坏）。
  Future<void> _probeRemoteOcrEntry() async {
    bool available = false;
    try {
      available = (await _mangaOcrRemoteRunner.probe()) != null;
    } catch (_) {
      available = false;
    }
    if (!mounted || !available) return;
    setState(() => _remoteOcrAvailable = true);
  }

  /// 打开 OCR 导入漫画向导：从 provider 取内置 OCR 服务、按当前偏好构造外部
  /// mokuro runner（均桌面工具），再挂上远程「已配对主机」runner（移动端唯一
  /// 引擎，桌面亦可作后备）；向导内选裸图片文件夹跑整卷 OCR 后无缝落库；成功
  /// （返回 bookKey）则连同关闭本导入框并回传 bookKey，让调用方定位新书。
  Future<void> _openOcrWizard() async {
    final ProviderContainer container =
        ProviderScope.containerOf(context, listen: false);
    final AppModel appModel = container.read(appProvider);
    final MangaOcrService service = container.read(mangaOcrServiceProvider);
    final String configured = appModel.mangaExternalMokuroPath.trim();
    final ExternalMokuroRunner? runner = _ocrEntryDesktop
        ? ExternalMokuroRunner(
            configuredPath: configured.isEmpty ? null : configured,
          )
        : null;
    final String? bookKey = await showAppDialog<String>(
      context: context,
      builder: (_) => MangaOcrWizardDialog(
        service: service,
        db: widget.db,
        externalRunner: runner,
        remoteRunner: _mangaOcrRemoteRunner,
      ),
    );
    if (bookKey != null && mounted) {
      Navigator.pop(context, bookKey);
    }
  }

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
        // 「OCR 导入漫画」：桌面恒显示（内置 OCR / 外部 mokuro CLI 均桌面工具）；
        // 移动端在探测到可代跑 OCR 的已配对 host 时也显示（远程引擎）。
        if (_showOcrEntry)
          TextButton(
            onPressed: _busy ? null : _openOcrWizard,
            child: Text(t.manga_ocr_wizard_title),
          ),
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
