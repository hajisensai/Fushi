import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/video/video_shader_downloader.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/utils.dart';

/// 设置 →「存储」目的地正文（经 [SettingsDestination.body] 逃生口渲染）。
///
/// 三块：
/// 1. 磁盘占用总览——[StorageUsageService.scanCategories] 逐类目渐进出结果，
///    书籍/词典类目可展开明细并单条删除；
/// 2. 可选模块——漫画 OCR 模型（删除/下载，接 [MangaOcrService] 既有原语）与
///    Anime4K 着色器（只删清单内文件，恢复走视频设置既有下载入口）；
/// 3. 随包组件——安装目录内随包携带的大件，**只展示**：更新 = 安装器整体重写
///    安装目录，删掉的必然回来，做删除按钮是假动作。
///
/// 删除一律复用各域既有路径（见 [StorageUsageService] 头注释），本文件零裸
/// `Directory.delete`。所有依赖经构造参数注入（服务/取数/删除回调），
/// widget 测试注 fake 即可；真实接线在 `settings_schema_storage.dart`。
class StorageUsageView extends ConsumerStatefulWidget {
  const StorageUsageView({
    required this.service,
    required this.ocrService,
    required this.booksProvider,
    required this.dictionaryNamesProvider,
    required this.deleteBook,
    required this.deleteDictionary,
    this.anime4kBytesProvider = anime4kInstalledBytes,
    this.anime4kDelete = deleteAnime4kShaderFiles,
    super.key,
  });

  final StorageUsageService service;

  /// 漫画 OCR 服务（与漫画 OCR 设置区同一单例；测试注 fake）。
  final MangaOcrService ocrService;

  /// 书籍清单取数（真实现读 `epub_books` 表）。
  final Future<List<StorageBookRef>> Function() booksProvider;

  /// 词典名清单取数（真实现读 `AppModel.dictionaries`）。
  final Future<List<String>> Function() dictionaryNamesProvider;

  /// 删除一本书（真实现 `ReaderFushiSource.instance.deleteBook`）。
  /// 返回 null = 成功，非 null = 失败原因。
  final Future<String?> Function(String bookKey) deleteBook;

  /// 删除一部词典（真实现 `AppModel.deleteDictionary`）。
  final Future<void> Function(String name) deleteDictionary;

  /// Anime4K 已下载字节数 / 删除（默认真实现；测试注临时目录版）。
  final Future<int> Function() anime4kBytesProvider;
  final Future<List<String>> Function() anime4kDelete;

  @override
  ConsumerState<StorageUsageView> createState() => _StorageUsageViewState();
}

class _StorageUsageViewState extends ConsumerState<StorageUsageView> {
  /// 明细默认最多展示条数（书可能几百本，全展开把设置页拖成长卷轴）。
  static const int kMaxVisibleEntries = 20;

  final Map<StorageCategoryId, StorageCategoryUsage> _usage =
      <StorageCategoryId, StorageCategoryUsage>{};
  final Set<StorageCategoryId> _expanded = <StorageCategoryId>{};
  bool _scanning = false;
  StreamSubscription<StorageCategoryUsage>? _scanSub;

  List<BundledComponentUsage> _bundled = const <BundledComponentUsage>[];

  MangaOcrModelStatus? _ocrStatus;
  bool _ocrBusy = false;
  double? _ocrDownloadProgress;
  StreamSubscription<MangaOcrDownloadEvent>? _ocrSub;

  int _anime4kBytes = 0;
  bool _anime4kBusy = false;

  @override
  void initState() {
    super.initState();
    _rescan();
  }

  @override
  void dispose() {
    unawaited(_scanSub?.cancel());
    unawaited(_ocrSub?.cancel());
    super.dispose();
  }

  Future<void> _rescan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _usage.clear();
    });
    unawaited(_loadModules());
    List<StorageBookRef> books = const <StorageBookRef>[];
    List<String> dictNames = const <String>[];
    try {
      books = await widget.booksProvider();
      dictNames = await widget.dictionaryNamesProvider();
    } catch (e) {
      debugPrint('[storage] listing failed: $e');
    }
    if (!mounted) return;
    await _scanSub?.cancel();
    _scanSub = widget.service
        .scanCategories(books: books, dictionaryNames: dictNames)
        .listen(
      (StorageCategoryUsage usage) {
        if (!mounted) return;
        setState(() => _usage[usage.id] = usage);
      },
      onError: (Object e) {
        debugPrint('[storage] scan failed: $e');
        if (mounted) setState(() => _scanning = false);
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  Future<void> _loadModules() async {
    try {
      final MangaOcrModelStatus ocr = await widget.ocrService.modelStatus();
      if (mounted) setState(() => _ocrStatus = ocr);
    } catch (e) {
      debugPrint('[storage] ocr status failed: $e');
    }
    try {
      final int bytes = await widget.anime4kBytesProvider();
      if (mounted) setState(() => _anime4kBytes = bytes);
    } catch (e) {
      debugPrint('[storage] anime4k size failed: $e');
    }
    try {
      final List<BundledComponentUsage> bundled =
          await widget.service.scanBundledComponents();
      if (mounted) setState(() => _bundled = bundled);
    } catch (e) {
      debugPrint('[storage] bundled scan failed: $e');
    }
  }

  // ── 删除动作 ────────────────────────────────────────────────────────

  Future<bool> _confirmDelete(String name, String body) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.storage_entry_delete_confirm_title(name: name)),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.dialog_delete),
          ),
        ],
      ),
    );
    return ok == true && mounted;
  }

  Future<void> _deleteEntry(
    StorageCategoryId category,
    StorageEntryUsage entry,
  ) async {
    final String body = category == StorageCategoryId.books
        ? t.storage_entry_delete_book_confirm_body
        : t.storage_entry_delete_dictionary_confirm_body;
    if (!await _confirmDelete(entry.label, body)) return;
    String? failure;
    try {
      if (category == StorageCategoryId.books) {
        failure = await widget.deleteBook(entry.id);
      } else {
        await widget.deleteDictionary(entry.id);
      }
    } catch (e) {
      failure = '$e';
    }
    if (!mounted) return;
    if (failure == null) {
      FushiToast.show(
        msg: t.storage_entry_delete_done,
        severity: ToastSeverity.success,
      );
      await _rescan();
    } else {
      FushiToast.show(
        msg: t.storage_entry_delete_failed(reason: failure),
        severity: ToastSeverity.error,
      );
    }
  }

  // ── OCR 模型模块 ────────────────────────────────────────────────────

  Future<void> _ocrDownload() async {
    if (_ocrBusy) return;
    setState(() {
      _ocrBusy = true;
      _ocrDownloadProgress = null;
    });
    await _ocrSub?.cancel();
    _ocrSub = widget.ocrService.downloadModels().listen(
      (MangaOcrDownloadEvent e) {
        if (!mounted) return;
        setState(() {
          _ocrDownloadProgress =
              e.totalBytes > 0 ? e.receivedBytes / e.totalBytes : null;
        });
      },
      onError: (Object e) async {
        debugPrint('[storage] ocr download failed: $e');
        if (!mounted) return;
        setState(() => _ocrBusy = false);
        await _loadModules();
      },
      onDone: () async {
        if (!mounted) return;
        setState(() => _ocrBusy = false);
        await _loadModules();
      },
    );
  }

  Future<void> _ocrDelete() async {
    if (_ocrBusy) return;
    if (!await _confirmDelete(
      t.storage_category_ocr_models,
      t.manga_ocr_delete_confirm_message,
    )) {
      return;
    }
    setState(() => _ocrBusy = true);
    try {
      await widget.ocrService.deleteModels();
    } finally {
      if (mounted) setState(() => _ocrBusy = false);
    }
    if (!mounted) return;
    FushiToast.show(
      msg: t.manga_ocr_delete_done,
      severity: ToastSeverity.success,
    );
    await _loadModules();
    // OCR 类目行也要跟着归零。
    await _rescan();
  }

  Future<void> _anime4kDeleteAction() async {
    if (_anime4kBusy) return;
    if (!await _confirmDelete(
      t.storage_modules_anime4k_title,
      t.storage_modules_anime4k_hint,
    )) {
      return;
    }
    setState(() => _anime4kBusy = true);
    List<String> deleted = const <String>[];
    try {
      deleted = await widget.anime4kDelete();
    } finally {
      if (mounted) setState(() => _anime4kBusy = false);
    }
    if (!mounted) return;
    FushiToast.show(
      msg: t.storage_modules_anime4k_delete_done(n: deleted.length),
      severity: ToastSeverity.success,
    );
    await _loadModules();
    await _rescan();
  }

  // ── 渲染 ────────────────────────────────────────────────────────────

  static const Map<StorageCategoryId, IconData> _categoryIcons =
      <StorageCategoryId, IconData>{
    StorageCategoryId.books: Icons.menu_book_outlined,
    StorageCategoryId.dictionaries: Icons.translate_outlined,
    StorageCategoryId.videoDownloads: Icons.movie_outlined,
    StorageCategoryId.covers: Icons.image_outlined,
    StorageCategoryId.subtitles: Icons.subtitles_outlined,
    StorageCategoryId.shaders: Icons.auto_awesome_outlined,
    StorageCategoryId.customFonts: Icons.font_download_outlined,
    StorageCategoryId.web: Icons.public_outlined,
    StorageCategoryId.exports: Icons.output_outlined,
    StorageCategoryId.database: Icons.storage_outlined,
    StorageCategoryId.ocrModels: Icons.document_scanner_outlined,
  };

  String _categoryTitle(StorageCategoryId id) {
    switch (id) {
      case StorageCategoryId.books:
        return t.storage_category_books;
      case StorageCategoryId.dictionaries:
        return t.storage_category_dictionaries;
      case StorageCategoryId.videoDownloads:
        return t.storage_category_video_downloads;
      case StorageCategoryId.covers:
        return t.storage_category_covers;
      case StorageCategoryId.subtitles:
        return t.storage_category_subtitles;
      case StorageCategoryId.shaders:
        return t.storage_category_shaders;
      case StorageCategoryId.customFonts:
        return t.storage_category_custom_fonts;
      case StorageCategoryId.web:
        return t.storage_category_web;
      case StorageCategoryId.exports:
        return t.storage_category_exports;
      case StorageCategoryId.database:
        return t.storage_category_database;
      case StorageCategoryId.ocrModels:
        return t.storage_category_ocr_models;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildOverviewSection(),
        const SizedBox(height: 12),
        _buildModulesSection(),
        if (_bundled.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          _buildBundledSection(),
        ],
      ],
    );
  }

  Widget _buildOverviewSection() {
    final int total = _usage.values
        .fold<int>(0, (int sum, StorageCategoryUsage u) => sum + u.bytes);
    return AdaptiveSettingsSection(
      title: t.storage_overview_section,
      children: <Widget>[
        AdaptiveSettingsRow(
          title: t.storage_overview_total,
          subtitle: _scanning ? t.storage_overview_scanning : null,
          icon: Icons.pie_chart_outline,
          showIcon: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_scanning)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Text(formatStorageBytes(total)),
              const SizedBox(width: 4),
              IconButton(
                tooltip: t.storage_overview_refresh,
                icon: const Icon(Icons.refresh_outlined),
                onPressed: _scanning ? null : _rescan,
              ),
            ],
          ),
        ),
        for (final StorageCategoryId id in StorageCategoryId.values)
          ..._buildCategoryRows(id),
      ],
    );
  }

  List<Widget> _buildCategoryRows(StorageCategoryId id) {
    final StorageCategoryUsage? usage = _usage[id];
    // 未扫到且已结束 = 0 字节：仍显示行（0 也是信息）；扫描中未出结果的类目
    // 显示占位。
    final bool expandable = usage != null && usage.entries.isNotEmpty;
    final bool expanded = _expanded.contains(id);
    return <Widget>[
      FushiListItem(
        title: Text(_categoryTitle(id)),
        leading: Icon(_categoryIcons[id]),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(usage == null ? '…' : formatStorageBytes(usage.bytes)),
            if (expandable) ...<Widget>[
              const SizedBox(width: 4),
              Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18),
            ],
          ],
        ),
        onTap: expandable
            ? () => setState(() {
                  if (!_expanded.add(id)) _expanded.remove(id);
                })
            : null,
      ),
      if (expandable && expanded) ..._buildEntryRows(id, usage),
    ];
  }

  List<Widget> _buildEntryRows(
    StorageCategoryId id,
    StorageCategoryUsage usage,
  ) {
    final List<StorageEntryUsage> visible =
        usage.entries.take(kMaxVisibleEntries).toList(growable: false);
    final List<StorageEntryUsage> rest =
        usage.entries.skip(kMaxVisibleEntries).toList(growable: false);
    final int restBytes =
        rest.fold<int>(0, (int sum, StorageEntryUsage e) => sum + e.bytes);
    return <Widget>[
      for (final StorageEntryUsage entry in visible)
        FushiListItem(
          title: Text(entry.label),
          subtitle: Text(formatStorageBytes(entry.bytes)),
          padding: const EdgeInsetsDirectional.only(start: 32, end: 8),
          density: FushiListDensity.compact,
          trailing: IconButton(
            tooltip: t.dialog_delete,
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => _deleteEntry(id, entry),
          ),
        ),
      if (rest.isNotEmpty)
        FushiListItem(
          title: Text(t.storage_entry_more_rest(
            n: rest.length,
            size: formatStorageBytes(restBytes),
          )),
          padding: const EdgeInsetsDirectional.only(start: 32, end: 8),
          density: FushiListDensity.compact,
        ),
    ];
  }

  Widget _buildModulesSection() {
    final MangaOcrModelStatus? ocr = _ocrStatus;
    final bool ocrReady = ocr?.allReady ?? false;
    final bool ocrPartial = !ocrReady && (ocr?.downloadedBytes ?? 0) > 0;
    return AdaptiveSettingsSection(
      title: t.storage_modules_section,
      children: <Widget>[
        // 漫画 OCR 模型：删除/下载接既有原语（与漫画 OCR 设置区同一 service）。
        AdaptiveSettingsRow(
          title: t.storage_category_ocr_models,
          subtitle: ocr == null
              ? null
              : (ocrReady || ocrPartial
                  ? formatStorageBytes(ocr.downloadedBytes)
                  : t.storage_modules_not_installed),
          icon: Icons.document_scanner_outlined,
          showIcon: true,
          trailing: _ocrBusy && _ocrDownloadProgress != null
              ? SizedBox(
                  width: 80,
                  child: LinearProgressIndicator(value: _ocrDownloadProgress),
                )
              : (_ocrBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : (ocrReady || ocrPartial
                      ? IconButton(
                          tooltip: t.manga_ocr_delete,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: _ocrDelete,
                        )
                      : IconButton(
                          tooltip: t.manga_ocr_download,
                          icon: const Icon(Icons.download_outlined),
                          onPressed: _ocrDownload,
                        ))),
        ),
        // Anime4K 着色器：只删清单内文件（用户自导入的同目录着色器不碰）；
        // 恢复走视频设置 → 画质增强的既有预设下载入口。
        AdaptiveSettingsRow(
          title: t.storage_modules_anime4k_title,
          subtitle: _anime4kBytes > 0
              ? '${formatStorageBytes(_anime4kBytes)} · '
                  '${t.storage_modules_anime4k_hint}'
              : t.storage_modules_not_installed,
          icon: Icons.auto_awesome_outlined,
          showIcon: true,
          trailing: _anime4kBusy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : (_anime4kBytes > 0
                  ? IconButton(
                      tooltip: t.dialog_delete,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _anime4kDeleteAction,
                    )
                  : null),
        ),
      ],
    );
  }

  Widget _buildBundledSection() {
    return AdaptiveSettingsSection(
      title: t.storage_bundled_section,
      children: <Widget>[
        for (final BundledComponentUsage c in _bundled)
          AdaptiveSettingsRow(
            title: c.name,
            subtitle: c.path,
            icon: Icons.inventory_2_outlined,
            showIcon: true,
            trailing: Text(formatStorageBytes(c.bytes)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            t.storage_bundled_hint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
