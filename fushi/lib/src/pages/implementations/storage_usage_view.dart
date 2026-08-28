import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show DatabaseSnapshotDeletionResult;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/video_shader_downloader.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/utils.dart';

/// 设置 →「存储」目的地正文（经 [SettingsDestination.body] 逃生口渲染）。
///
/// 两块：
/// 1. 磁盘占用总览——[StorageUsageService.scanCategories] 逐类目渐进出结果，
///    **每个类目都可展开明细**：书籍/词典是 DB 已知条目（可单条删除），其余
///    类目是类目根下的直接子项（只读，看清是哪个文件在吃盘）；着色器类目行
///    额外挂 Anime4K 预设删除（只删清单内文件，恢复走视频设置既有下载入口）；
/// 2. 随包组件——安装目录内随包携带的大件，**只展示**：更新 = 安装器整体重写
///    安装目录，删掉的必然回来，做删除按钮是假动作。
///
/// 漫画 OCR 模型的下载/删除**不在这里**：入口在漫画 OCR 设置区
/// （`manga_ocr_settings_section.dart`），存储页只如实显示它占多少。
///
/// 删除一律复用各域既有路径（见 [StorageUsageService] 头注释），本文件零裸
/// `Directory.delete`。所有依赖经构造参数注入（服务/取数/删除回调），
/// widget 测试注 fake 即可；真实接线在 `settings_schema_storage.dart`。
class StorageUsageView extends ConsumerStatefulWidget {
  const StorageUsageView({
    required this.service,
    required this.booksProvider,
    required this.dictionaryNamesProvider,
    required this.deleteBook,
    required this.deleteSrtBook,
    required this.deleteDictionary,
    required this.deleteDatabaseSnapshots,
    this.anime4kBytesProvider = anime4kInstalledBytes,
    this.anime4kDelete = deleteAnime4kShaderFiles,
    super.key,
  });

  final StorageUsageService service;

  /// 书籍清单取数（真实现读 `epub_books` 表）。
  final Future<List<StorageBookRef>> Function() booksProvider;

  /// 词典名清单取数（真实现读 `AppModel.dictionaries`）。
  final Future<List<String>> Function() dictionaryNamesProvider;

  /// 删除一本书（真实现 `ReaderFushiSource.instance.deleteBook`）。
  /// 返回 null = 成功，非 null = 失败原因。
  final Future<String?> Function(String bookKey) deleteBook;

  /// 删除一本纯字幕书 / standalone 有声书（真实现 `SrtBookRepository.delete`）。
  /// BUG-1893：这类书没有 EpubBooks 行、`bookKey` 恒空，[deleteBook] 那条路按
  /// bookKey 找行必然落空——必须单独接原语，否则条目有行却删不掉。
  final Future<String?> Function(String uid) deleteSrtBook;

  /// 删除一部词典（真实现 `AppModel.deleteDictionary` + 删除后核对词典表）。
  /// 返回 null = 成功，非 null = 失败原因——`deleteDictionary` 内部 catch-all
  /// 不上抛，接线方必须以「删除后该名是否仍在」为准回报，不能拿无异常当成功。
  final Future<String?> Function(String name) deleteDictionary;

  /// 删除 support 根下全部主库快照残留（BUG-1870；真实现 fushi_core
  /// `deleteDatabaseSnapshotFiles(supportRoot)`，识别口径与扫描侧同源：
  /// 展示什么就删什么，活库/侧车/待恢复副本结构上删不到）。返回逐文件容错的
  /// 结果——部分文件被占用时其余照删，失败清单原样带给用户。
  final Future<DatabaseSnapshotDeletionResult> Function()
      deleteDatabaseSnapshots;

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

  /// 扫描代际：删除成功后无条件重扫（哪怕上一轮还在跑），旧代际的事件按此
  /// 丢弃——否则「GB 级词典类目还在扫时删了一本书」会被 `_scanning` guard
  /// 静默吞掉，数字不刷新（审查 L1）。
  int _scanEpoch = 0;
  StreamSubscription<StorageCategoryUsage>? _scanSub;

  /// 正在删除的条目 id（书 bookKey / 词典名）。非 null 时禁用全部删除入口——
  /// 词典删除原语在 UI isolate 同步删 GB 级目录，期间再点别的删除只会排队
  /// 添乱（审查 M2）。
  String? _busyEntryId;

  List<BundledComponentUsage> _bundled = const <BundledComponentUsage>[];

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
    super.dispose();
  }

  Future<void> _rescan() async {
    final int epoch = ++_scanEpoch;
    setState(() {
      _scanning = true;
      _usage.clear();
    });
    unawaited(_loadExtras());
    List<StorageBookRef> books = const <StorageBookRef>[];
    List<String> dictNames = const <String>[];
    try {
      books = await widget.booksProvider();
      dictNames = await widget.dictionaryNamesProvider();
    } catch (e) {
      debugPrint('[storage] listing failed: $e');
    }
    if (!mounted || epoch != _scanEpoch) return;
    await _scanSub?.cancel();
    if (!mounted || epoch != _scanEpoch) return;
    _scanSub = widget.service
        .scanCategories(books: books, dictionaryNames: dictNames)
        .listen(
      (StorageCategoryUsage usage) {
        if (!mounted || epoch != _scanEpoch) return;
        setState(() => _usage[usage.id] = usage);
      },
      onError: (Object e) {
        debugPrint('[storage] scan failed: $e');
        if (mounted && epoch == _scanEpoch) setState(() => _scanning = false);
      },
      onDone: () {
        if (mounted && epoch == _scanEpoch) setState(() => _scanning = false);
      },
    );
  }

  /// 总览之外的附加信息：Anime4K 预设占用（决定着色器类目行给不给删除按钮）
  /// 与随包组件清单。与类目扫描并行跑，慢的一方不挡另一方。
  Future<void> _loadExtras() async {
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

  /// 条目显示名：快照聚合条目按文件数翻译，其余用服务层给的 label。
  String _entryTitle(StorageEntryUsage entry) =>
      entry.kind == StorageEntryKind.databaseSnapshots
          ? t.storage_entry_database_snapshots_label(n: entry.paths.length)
          : entry.label;

  Future<void> _deleteEntry(StorageEntryUsage entry) async {
    if (_busyEntryId != null) return;
    final String body = switch (entry.kind) {
      StorageEntryKind.book ||
      StorageEntryKind.srtBook =>
        t.storage_entry_delete_book_confirm_body,
      StorageEntryKind.dictionary =>
        t.storage_entry_delete_dictionary_confirm_body,
      StorageEntryKind.databaseSnapshots =>
        t.storage_entry_delete_database_snapshots_confirm_body,
      StorageEntryKind.readOnly => throw StateError('read-only entry'),
    };
    if (!await _confirmDelete(_entryTitle(entry), body)) return;
    setState(() => _busyEntryId = entry.id);
    String? failure;
    // 磁盘是否真的变了。快照删除是逐文件容错的：**部分**成功也必须重扫，否则
    // 页面上的字节数会一直停在删除前的旧值（审查 M3）。
    bool changed = false;
    try {
      switch (entry.kind) {
        case StorageEntryKind.book:
          failure = await widget.deleteBook(entry.id);
          changed = failure == null;
        case StorageEntryKind.srtBook:
          failure = await widget.deleteSrtBook(entry.id);
          changed = failure == null;
        case StorageEntryKind.dictionary:
          failure = await widget.deleteDictionary(entry.id);
          changed = failure == null;
        case StorageEntryKind.databaseSnapshots:
          final DatabaseSnapshotDeletionResult result =
              await widget.deleteDatabaseSnapshots();
          changed = result.deleted.isNotEmpty;
          failure = _snapshotDeleteFailureReason(result);
        case StorageEntryKind.readOnly:
          throw StateError('read-only entry');
      }
    } catch (e) {
      failure = '$e';
    } finally {
      if (mounted) setState(() => _busyEntryId = null);
    }
    if (!mounted) return;
    FushiToast.show(
      msg: failure == null
          ? t.storage_entry_delete_done
          : t.storage_entry_delete_failed(reason: failure),
      severity: failure == null ? ToastSeverity.success : ToastSeverity.error,
    );
    if (changed) await _rescan();
  }

  /// 快照批量删除的失败摘要：全成功 → null；否则「第一个失败的文件名: 原因
  /// (+还有几个)」。不新增 i18n key，直接填进既有的
  /// `storage_entry_delete_failed(reason:)` 模板。
  static String? _snapshotDeleteFailureReason(
      final DatabaseSnapshotDeletionResult result) {
    if (!result.hasFailures) return null;
    final MapEntry<String, String> first = result.failures.entries.first;
    final int rest = result.failures.length - 1;
    final String head = '${p.basename(first.key)}: ${first.value}';
    return rest > 0 ? '$head (+$rest)' : head;
  }

  // ── Anime4K 预设删除 ────────────────────────────────────────────────

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
    } catch (e) {
      if (mounted) {
        FushiToast.show(
          msg: t.storage_entry_delete_failed(reason: '$e'),
          severity: ToastSeverity.error,
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _anime4kBusy = false);
    }
    if (!mounted) return;
    FushiToast.show(
      msg: t.storage_modules_anime4k_delete_done(n: deleted.length),
      severity: ToastSeverity.success,
    );
    await _loadExtras();
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
    StorageCategoryId.cache: Icons.cached_outlined,
    StorageCategoryId.other: Icons.more_horiz_outlined,
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
      case StorageCategoryId.cache:
        return t.storage_category_cache;
      case StorageCategoryId.other:
        return t.storage_category_other;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildOverviewSection(),
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
    // Anime4K 预设是唯一「删了还能一键装回来」的着色器资产，而删除原语只此一处
    //（视频设置的画质增强只有下载入口）：挂在着色器类目行上，只删清单内文件，
    // 用户自己导入的同目录 .glsl 不碰。
    final bool showAnime4kDelete =
        id == StorageCategoryId.shaders && _anime4kBytes > 0;
    return <Widget>[
      FushiListItem(
        title: Text(_categoryTitle(id)),
        leading: Icon(_categoryIcons[id]),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showAnime4kDelete)
              _anime4kBusy
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      tooltip: t.storage_shaders_delete_anime4k,
                      icon: const Icon(Icons.auto_fix_off_outlined, size: 18),
                      onPressed: _anime4kDeleteAction,
                    ),
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
      if (expandable && expanded) ..._buildEntryRows(usage),
    ];
  }

  List<Widget> _buildEntryRows(StorageCategoryUsage usage) {
    // 可删性由**条目 kind** 决定（书/词典/数据库快照残留各接自己的删除原语）；
    // readOnly 条目是磁盘子项，删它就是裸 `Directory.delete`——会绕过墓碑/引用
    // 护栏，也可能删掉主库文件，故只读展示。
    final List<StorageEntryUsage> visible =
        usage.entries.take(kMaxVisibleEntries).toList(growable: false);
    final List<StorageEntryUsage> rest =
        usage.entries.skip(kMaxVisibleEntries).toList(growable: false);
    final int restBytes =
        rest.fold<int>(0, (int sum, StorageEntryUsage e) => sum + e.bytes);
    return <Widget>[
      for (final StorageEntryUsage entry in visible)
        FushiListItem(
          title: Text(_entryTitle(entry)),
          // BUG-1893：externalPaths 非空 = 桌面「引用原文件」导入，音频留在 app 目录
          // 外，既不占应用空间也删不掉。不加这句说明的话，条目只显示 EPUB 正文那几百
          // KB，用户会以为音频丢了——体积统计的口径必须自己说清楚。
          subtitle: Text(
            entry.externalPaths.isEmpty
                ? formatStorageBytes(entry.bytes)
                : '${formatStorageBytes(entry.bytes)} · '
                    '${t.storage_entry_external_audio_hint}',
          ),
          padding: const EdgeInsetsDirectional.only(start: 32, end: 8),
          density: FushiListDensity.compact,
          trailing: entry.kind == StorageEntryKind.readOnly
              ? null
              : (_busyEntryId == entry.id
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      tooltip: t.dialog_delete,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: _busyEntryId != null
                          ? null
                          : () => _deleteEntry(entry),
                    )),
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
