import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/import/import_flow_mixin.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/utils.dart';

/// 漫画导入对话框。
///
/// 与 [BookImportDialog] 分家的理由不是「代码重复」——两者共用 [ImportFlowMixin]
/// 骨架、[ImportDialogFrame] 外框、同名书冲突解决和 `EpubBooks` 表，共用的部分一
/// 点没少。分家是因为**载体不同、可填字段就不同**：漫画没有字幕、没有音频、没有
/// 有声书对齐窗口，而书籍没有 OCR。此前两者挤在同一个对话框里，从漫画库点「导入
/// 漫画」弹出的框有三行对漫画毫无意义的字幕/音频/对齐控件，且「这是漫画」这个在
/// 入口就已知的事实被丢掉，一路走到导入执行阶段再靠扩展名 + 真读包嗅回来。
///
/// 本对话框只暴露漫画 importer 真正消费的两个参数：路径 + 标题。载体的三种细分
/// （页图目录 / `.mokuro` / 图片压缩包）由 [classifyImportCarrier] 在**选中那一刻**
/// 定死，[_doImport] 只是照着分派，不再二次嗅探。
class MangaImportDialog extends StatefulWidget {
  const MangaImportDialog({
    required this.db,
    this.initialPath,
    this.mangaOcrRemoteRunner,
    this.ocrEntryDesktopOverride,
    super.key,
  });

  final FushiDatabase db;

  /// 拖放/书籍框转交时预填的漫画路径（目录 / `.cbz` / `.zip` 页图包 / `.mokuro`）。
  final String? initialPath;

  /// 测试缝：注入远程 OCR runner（探测已配对 host 能力 + 代跑）。null = 生产路径，
  /// 由 [MangaOcrWizardEngines.resolve] 按 [db] 构造 [InterconnectMangaOcrClient]。
  final MangaOcrRemoteRunner? mangaOcrRemoteRunner;

  /// 测试缝：覆盖「是否桌面平台」判定。null = 用真实 [isDesktopPlatform]。
  final bool? ocrEntryDesktopOverride;

  @override
  State<MangaImportDialog> createState() => _MangaImportDialogState();
}

class _MangaImportDialogState extends State<MangaImportDialog>
    with ImportFlowMixin<MangaImportDialog> {
  final TextEditingController _titleCtrl = TextEditingController();

  String? _path;
  String? _pathName;
  ImportCarrier? _carrier;

  /// 用户是否手打过标题。打过就永不被自动派生覆盖。
  ///
  /// 书籍框那套五值 [ImportTitleSource] 是为「EPUB / 字幕 / 音频标签」三个来源
  /// 抢同一个标题框而生的；漫画框只有一个来源（漫画路径），退化成一个 bool 即可，
  /// 不搬那套跨来源优先级机器。
  bool _titleFromUser = false;

  bool _pickerActive = false;

  @override
  void initState() {
    super.initState();
    final String? initial = widget.initialPath;
    if (initial != null) {
      // 预填路径来自已判定为漫画的上游（拖放决策层 / 书籍框转交），这里仍重跑一次
      // 分类以拿到细分载体；万一上游给了非漫画路径，宁可留空也不静默导错东西。
      final ImportCarrier carrier = _classify(initial);
      if (carrier.isManga) {
        _path = initial;
        _pathName = p.basename(initial);
        _carrier = carrier;
        _titleCtrl.text = _deriveTitle(initial);
      }
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  ImportCarrier _classify(String path) => classifyImportCarrier(
        path,
        isDirectory: (String pth) => Directory(pth).existsSync(),
        isImageArchive: MangaModule.isImageArchive,
      );

  /// 目录取目录名，文件取去扩展名的文件名。
  String _deriveTitle(String path) {
    if (Directory(path).existsSync()) return p.basename(path);
    return p.basenameWithoutExtension(path);
  }

  @override
  Widget build(BuildContext context) {
    return FushiFileDropTarget(
      enabled: !importing,
      debugLabel: 'manga-import-dialog',
      onDrop: _handleDialogDrop,
      child: ImportDialogFrame(
        leadingIcon: Icons.auto_stories_outlined,
        title: t.manga_import_action,
        body: _buildForm(),
        actions: <Widget>[
          adaptiveDialogAction(
            context: context,
            onPressed: importing ? null : _openOcrWizard,
            child: Text(t.manga_ocr_wizard_title),
          ),
          adaptiveDialogAction(
            context: context,
            onPressed: () => Navigator.pop(context),
            child: Text(t.dialog_cancel),
          ),
          buildImportAction(context, onImport: _doImport),
        ],
      ),
    );
  }

  Widget _buildForm() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(t.manga_import_hint, style: tokens.type.metadata),
        SizedBox(height: tokens.spacing.gap),
        AdaptiveSettingsSection(children: <Widget>[_mangaRow()]),
        SizedBox(height: tokens.spacing.rowVertical),
        FushiTextField(
          controller: _titleCtrl,
          labelText: t.srt_import_title_hint,
          onChanged: (String _) => _titleFromUser = true,
        ),
        if (importing) ...buildProgressSection(context, tokens),
      ],
    );
  }

  Widget _mangaRow() {
    return FushiFilePickerRow(
      title: t.manga_import_pick_file,
      subtitle: _pathName,
      icon: Icons.auto_stories_outlined,
      onTap: _pickFile,
      actions: <Widget>[
        // 漫画载体可以是**文件**（.cbz/.zip/.mokuro）也可以是**目录**（一卷页图），
        // 两种选择器在系统层是两个不同的对话框，故并列两个入口而非合成一个。
        FushiIconButton(
          icon: Icons.folder_open_outlined,
          tooltip: t.manga_import_pick_folder,
          isWideTapArea: true,
          onTap: _pickFolder,
        ),
        FushiIconButton(
          icon: Icons.insert_drive_file_outlined,
          tooltip: t.manga_import_pick_file,
          isWideTapArea: true,
          onTap: _pickFile,
        ),
      ],
    );
  }

  // ── 选择 ────────────────────────────────────────────────────────────────

  /// 漫画**文件**扩展名（不带点，小写）。`.zip` / `.epub` 在此列是因为图片型压缩包
  /// 与词典包/普通电子书同形，选中后由 [classifyImportCarrier] 真读包定性；不是
  /// 漫画的会被 [_adoptPath] 挡回。
  static const Set<String> _mangaFileExtensions = <String>{
    'mokuro',
    'cbz',
    'zip',
    'epub',
  };

  Future<void> _pickFile() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final AppModel appModel =
          ProviderScope.containerOf(context, listen: false).read(appProvider);
      final String? path = await pickRealFilePath(
        context: context,
        appModel: appModel,
        allowedExtensions: _mangaFileExtensions,
      );
      if (path == null || !mounted) return;
      _adoptPath(path);
    } finally {
      _pickerActive = false;
    }
  }

  Future<void> _pickFolder() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final AppModel appModel =
          ProviderScope.containerOf(context, listen: false).read(appProvider);
      final String? path = await pickRealDirectoryPath(
        context: context,
        appModel: appModel,
      );
      if (path == null || !mounted) return;
      _adoptPath(path);
    } finally {
      _pickerActive = false;
    }
  }

  /// 收下一个候选路径：先定性，非漫画直接挡回并说明，绝不静默吞掉。
  void _adoptPath(String path) {
    final ImportCarrier carrier = _classify(path);
    if (!carrier.isManga) {
      final String ext = p.extension(path).toLowerCase();
      FushiToast.show(
        msg: t.import_unsupported_file_format(ext: ext.isEmpty ? path : ext),
        severity: ToastSeverity.error,
      );
      return;
    }
    setState(() {
      _path = path;
      _pathName = p.basename(path);
      _carrier = carrier;
      if (!_titleFromUser) {
        _titleCtrl.text = _deriveTitle(path);
      }
    });
  }

  void _handleDialogDrop(List<String> paths, Offset _) {
    if (importing) return;
    // 拖进本框的东西只有一种可能有意义：漫画。取第一个能定性成漫画的路径。
    for (final String path in paths) {
      if (_classify(path).isManga) {
        _adoptPath(path);
        return;
      }
    }
    if (paths.isNotEmpty) {
      final String ext = p.extension(paths.first).toLowerCase();
      FushiToast.show(
        msg: t.import_unsupported_file_format(
          ext: ext.isEmpty ? paths.first : ext,
        ),
        severity: ToastSeverity.error,
      );
    }
  }

  // ── OCR ─────────────────────────────────────────────────────────────────

  /// 打开 OCR 导入漫画向导：向导内选裸图片文件夹跑整卷 OCR 后无缝落库；成功
  /// （返回 bookKey）则连同关闭本导入框并回传 true，让书架刷新。
  Future<void> _openOcrWizard() async {
    final String? bookKey = await MangaModule.openOcrImportWizard(
      context: context,
      db: widget.db,
      remoteRunnerOverride: widget.mangaOcrRemoteRunner,
      desktopOverride: widget.ocrEntryDesktopOverride,
    );
    if (bookKey != null && mounted) {
      Navigator.pop(context, true);
    }
  }

  // ── 导入 ────────────────────────────────────────────────────────────────

  /// 同名书弹窗回调。是→加后缀，否/关闭→取消这本书。与书籍框逐字同语义。
  Future<DuplicateChoice> _askOnDuplicate(
    String proposedTitle,
  ) async {
    if (!mounted) return DuplicateChoice.cancel;
    final bool? keep = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.book_import_duplicate_title),
        content: Text(t.book_import_duplicate_message(name: proposedTitle)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.book_import_duplicate_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.book_import_duplicate_keep),
          ),
        ],
      ),
    );
    return keep == true ? DuplicateChoice.suffix : DuplicateChoice.cancel;
  }

  void _reportCopyProgress(int done, int total) {
    if (total <= 0) return;
    reportProgress(
      (done / total).clamp(0.0, 1.0),
      t.import_step_copying_file(name: _pathName ?? ''),
    );
  }

  Future<void> _doImport() async {
    final String? path = _path;
    final ImportCarrier? carrier = _carrier;
    if (path == null || carrier == null) {
      FushiToast.show(
        msg: t.manga_import_missing_input,
        severity: ToastSeverity.error,
      );
      return;
    }
    final String title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      FushiToast.show(
        msg: t.srt_import_missing_title,
        severity: ToastSeverity.error,
      );
      return;
    }

    await runImport(
      logTag: 'MangaImportDialog.import',
      debugMessage: (Object e) => 'MangaImportDialog error: $e',
      isCancelled: (Object e) => e is DuplicateImportCancelledException,
      onCancelled: () {
        if (mounted) {
          FushiToast.show(
            msg: t.book_import_duplicate_cancelled,
            severity: ToastSeverity.info,
          );
          Navigator.pop(context, false);
        }
      },
      action: () async {
        reportProgress(0, '');
        debugPrint('[fushi-import] manga route: carrier=$carrier path=$path');
        reportProgress(0.5, t.import_step_importing_epub);

        // 载体在选中那一刻已定死，这里只照着分派——不再二次嗅探扩展名或读包。
        switch (carrier) {
          case ImportCarrier.mangaFolder:
            await MangaModule.importImageFolder(
              db: widget.db,
              path: path,
              title: title,
              policy: DuplicatePolicy.ask(_askOnDuplicate),
              onProgress: _reportCopyProgress,
            );
          case ImportCarrier.mangaMokuro:
            await MangaModule.importMokuro(
              db: widget.db,
              path: path,
              title: title,
              policy: DuplicatePolicy.ask(_askOnDuplicate),
              onProgress: _reportCopyProgress,
            );
          case ImportCarrier.mangaArchive:
            await MangaModule.importArchive(
              db: widget.db,
              path: path,
              title: title,
              policy: DuplicatePolicy.ask(_askOnDuplicate),
              onProgress: _reportCopyProgress,
            );
          case ImportCarrier.pdf:
          case ImportCarrier.epub:
          case ImportCarrier.text:
            // 不可达：[_adoptPath] / [initState] 只收下 isManga 的载体。
            throw StateError(
                'non-manga carrier in MangaImportDialog: $carrier');
        }

        reportProgress(1, t.import_step_done);
        if (mounted) {
          FushiToast.show(
            msg: t.srt_import_success,
            severity: ToastSeverity.success,
          );
          Navigator.pop(context, true);
        }
      },
    );
  }
}
