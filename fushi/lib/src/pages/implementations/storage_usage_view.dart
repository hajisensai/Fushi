import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart' show DatabaseSnapshotDeletionResult;
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/video_shader_downloader.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart'
    show settingsFootnoteStyle;
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
/// 漫画 OCR 模型的逐模型下载/删除**不在本总览里**：入口是「存储 › 模型与组件 ›
/// 本机 OCR 模型」（`manga_ocr_models_storage_section.dart`，走
/// `MangaOcrService.deleteModels` 原语），本总览只如实显示它占多少。
///
/// 删除一律复用各域既有路径（见 [StorageUsageService] 头注释），本文件零裸
/// `Directory.delete`。所有依赖经构造参数注入（服务/取数/删除回调），
/// widget 测试注 fake 即可；真实接线在 `settings_schema_storage.dart`。
class StorageUsageView extends ConsumerStatefulWidget {
  const StorageUsageView({
    required this.service,
    required this.booksProvider,
    required this.dictionaryNamesProvider,
    this.dictionaryDisplayNamesProvider,
    required this.deleteBook,
    required this.deleteSrtBook,
    required this.deleteDictionary,
    required this.deleteDatabaseSnapshots,
    required this.deleteFiles,
    this.anime4kBytesProvider = anime4kInstalledBytes,
    this.anime4kDelete = deleteAnime4kShaderFiles,
    super.key,
  });

  final StorageUsageService service;

  /// 书籍清单取数（真实现读 `epub_books` 表）。
  final Future<List<StorageBookRef>> Function() booksProvider;

  /// 词典名清单取数（真实现读 `AppModel.dictionaries`）。
  final Future<List<String>> Function() dictionaryNamesProvider;

  /// 词典改名（v95）：真名 -> 显示名。可选——不传（测试 seam / 旧调用点）就按
  /// 真名显示，与改名前逐字节一致。条目 id 与磁盘路径始终是真名，只有 label 翻译。
  final Future<Map<String, String>> Function()? dictionaryDisplayNamesProvider;

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

  /// 删除 [StorageEntryKind.derivedFile] 明细指向的路径（文件或目录）。
  ///
  /// 只有 [kDeletableEntryCategories] 里的类目会产出这种明细 —— 那里装的都是派生
  /// 数据 / 缓存 / 可重新获取的资源，没有 DB 行引用，所以这条原语就是裸删；本 widget
  /// 自身仍不碰磁盘（真实现在 `settings_schema_storage.dart` 接线）。
  /// 返回 null = 成功，非 null = 失败原因。
  final Future<String?> Function(List<String> paths) deleteFiles;

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
    Map<String, String> dictDisplayNames = const <String, String>{};
    try {
      books = await widget.booksProvider();
      dictNames = await widget.dictionaryNamesProvider();
      dictDisplayNames =
          await widget.dictionaryDisplayNamesProvider?.call() ??
              const <String, String>{};
    } catch (e) {
      debugPrint('[storage] listing failed: $e');
    }
    if (!mounted || epoch != _scanEpoch) return;
    await _scanSub?.cancel();
    if (!mounted || epoch != _scanEpoch) return;
    _scanSub = widget.service
        .scanCategories(
          books: books,
          dictionaryNames: dictNames,
          dictionaryDisplayNames: dictDisplayNames,
        )
        .listen(
      (StorageCategoryUsage usage) {
        if (!mounted || epoch != _scanEpoch) return;
        setState(() => _usage[usage.id] = usage);
      },
      onError: (Object e) {
        debugPrint('[storage] scan failed: $e');
        if (mounted && epoch == _scanEpoch) {
          setState(() => _scanning = false);
        }
      },
      onDone: () {
        if (mounted && epoch == _scanEpoch) {
          setState(() => _scanning = false);
        }
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
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.storage_entry_delete_confirm_title(name: name),
      message: body,
      icon: FushiIcons.delete,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
    return ok && mounted;
  }

  /// 条目显示名：快照聚合条目按文件数翻译，其余用服务层给的 label。
  String _entryTitle(StorageEntryUsage entry) =>
      entry.kind == StorageEntryKind.databaseSnapshots
          ? t.storage_entry_database_snapshots_label(n: entry.paths.length)
          : entry.kind == StorageEntryKind.backupArchives
              ? t.storage_entry_backups_label(n: entry.paths.length)
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
      StorageEntryKind.backupArchives =>
        t.storage_entry_delete_backups_confirm_body,
      StorageEntryKind.derivedFile =>
        t.storage_entry_delete_files_confirm_body,
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
        case StorageEntryKind.backupArchives:
          failure = await widget.deleteFiles(entry.paths);
          changed = failure == null;
        case StorageEntryKind.derivedFile:
          failure = await widget.deleteFiles(entry.paths);
          changed = failure == null;
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
    StorageCategoryId.books: FushiIcons.books,
    StorageCategoryId.dictionaries: FushiIcons.dictionary,
    StorageCategoryId.videoDownloads: FushiIcons.video,
    StorageCategoryId.covers: FushiIcons.image,
    StorageCategoryId.subtitles: FushiIcons.subtitles,
    StorageCategoryId.shaders: FushiIcons.ai,
    StorageCategoryId.customFonts: FushiIcons.font,
    StorageCategoryId.web: FushiIcons.globe,
    StorageCategoryId.exports: FushiIcons.upload,
    StorageCategoryId.backups: FushiIcons.backup,
    StorageCategoryId.database: FushiIcons.storage,
    StorageCategoryId.ocrModels: FushiIcons.ocr,
    StorageCategoryId.cache: FushiIcons.history,
    StorageCategoryId.other: FushiIcons.moreHoriz,
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
      case StorageCategoryId.backups:
        return t.storage_category_backups;
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

  /// 非零类目按体积降序——环上的段序、卡内图例的行序都用这一份。
  List<StorageCategoryUsage> get _rankedUsage => _usage.values
      .where((StorageCategoryUsage u) => u.bytes > 0)
      .toList()
    ..sort((StorageCategoryUsage a, StorageCategoryUsage b) {
      final int byBytes = b.bytes.compareTo(a.bytes);
      return byBytes != 0 ? byBytes : a.id.index.compareTo(b.id.index);
    });

  @override
  Widget build(BuildContext context) {
    final Map<StorageCategoryId, _SliceStyle> colors = _storageSliceStyles(
      Theme.of(context).colorScheme,
      eink: isEinkTheme(context),
      ranked: <StorageCategoryId>[
        for (final StorageCategoryUsage u in _rankedUsage) u.id,
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiStaggeredEntrance(index: 0, child: _buildHero(colors)),
        const SizedBox(height: 12),
        FushiStaggeredEntrance(
          index: 1,
          child: _buildOverviewSection(colors),
        ),
        if (_bundled.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          FushiStaggeredEntrance(index: 2, child: _buildBundledSection()),
        ],
      ],
    );
  }

  int get _totalBytes => _usage.values
      .fold<int>(0, (int sum, StorageCategoryUsage u) => sum + u.bytes);

  /// M3E 总览卡：环形占比图 + 图例（类目名 / 大小 / 百分比 / 色点）。
  ///
  /// 环上的段与图例行**同一份数据、同一份配色**：段序 = 图例行序 =
  /// [_rankedUsage]（体积降序），颜色 = [_storageSliceStyles]（下方磁盘占用列表
  /// 的色点也取这一份）。宽屏环在左、图例在右；窄屏上下排。圆心是 Display
  /// 等宽大号总量。进场时各段沿顺时针依次扫出（弹簧曲线，墨水屏/减弱动效归零）。
  Widget _buildHero(Map<StorageCategoryId, _SliceStyle> styles) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
    final bool eink = isEinkTheme(context);
    final int total = _totalBytes;
    final List<StorageCategoryUsage> ranked = _rankedUsage;
    // 逐类目（按枚举序，长度恒定）插值，段序在绘制时再按 ranked 排。
    final List<double> fractions = <double>[
      for (final StorageCategoryId id in StorageCategoryId.values)
        total <= 0 ? 0 : (_usage[id]?.bytes ?? 0) / total,
    ];
    final List<int> order = <int>[
      for (final StorageCategoryUsage u in ranked) u.id.index,
    ];
    final List<_SliceStyle> sliceStyles = <_SliceStyle>[
      for (final StorageCategoryId id in StorageCategoryId.values)
        styles[id] ?? _SliceStyle(color: cs.outline),
    ];
    final Widget header = Row(
      children: <Widget>[
        const FushiListLeadingIcon(
          FushiIcons.sdStorage,
          shape: FushiLeadingShape.cookie,
          tone: FushiCardTone.primary,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(t.storage_overview_total, style: type.titleMediumEmphasized),
              AnimatedSwitcher(
                duration: motion.effectsFast.duration,
                switchInCurve: motion.effectsFast.curve,
                switchOutCurve: motion.effectsFast.curve,
                child: _scanning
                    ? Text(
                        t.storage_overview_scanning,
                        key: const ValueKey<String>('storage-scanning'),
                        style: type.bodySmall
                            .copyWith(color: cs.onSurfaceVariant),
                      )
                    : const SizedBox(
                        key: ValueKey<String>('storage-idle'),
                        height: 0,
                      ),
              ),
            ],
          ),
        ),
        if (_scanning)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: 18,
              height: 18,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        FushiIconButtonControl(
          tooltip: t.storage_overview_refresh,
          icon: const FushiIcon(FushiIcons.refresh),
          onPressed: _scanning ? null : _rescan,
        ),
      ],
    );

    Widget buildRing(double size) {
      return SizedBox.square(
        dimension: size,
        // 进场扫出：有数据后才起跑（key 随「有无数据」切换 → 重建即从 0 扫），
        // 之后扫描进度 / 删除引起的占比变化走里层的占比插值，不再重扫。
        child: TweenAnimationBuilder<double>(
          key: ValueKey<bool>(total > 0),
          tween: Tween<double>(begin: 0, end: total > 0 ? 1 : 0),
          duration: motion.spatialSlow.duration,
          curve: motion.spatialSlow.curve,
          builder: (BuildContext context, double reveal, _) =>
              TweenAnimationBuilder<List<double>>(
            // begin 只在首帧生效（= end，首帧不插值，进场交给扫出）；之后
            // end 变化时 TweenAnimationBuilder 从当前值插到新值。
            tween: _FractionsTween(begin: fractions, end: fractions),
            duration: motion.spatialSlow.duration,
            curve: motion.spatialSlow.curve,
            builder: (BuildContext context, List<double> value, _) =>
                CustomPaint(
              painter: _StorageDonutPainter(
                fractions: value,
                order: order,
                styles: sliceStyles,
                reveal: reveal,
                trackColor: eink ? cs.outline : cs.surfaceContainerHighest,
                strokeWidth: size * 0.12,
                eink: eink,
              ),
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(size * 0.2),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      formatStorageBytes(total),
                      maxLines: 1,
                      style: type.displaySmallEmphasized.tabular
                          .copyWith(color: cs.onSurface),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final Widget legend = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final StorageCategoryUsage u in ranked)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                _SliceSwatch(
                  style: styles[u.id] ?? _SliceStyle(color: cs.outline),
                  size: 12,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _categoryTitle(u.id),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodyMedium.copyWith(color: cs.onSurface),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatStorageBytes(u.bytes),
                  style: type.bodyMedium.tabular.copyWith(color: cs.onSurface),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    total > 0 ? _percentLabel(u.bytes / total) : '',
                    textAlign: TextAlign.end,
                    style: type.bodySmall.tabular
                        .copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    return FushiCard(
      pressScale: false,
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          header,
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 宽屏：环在左、图例在右（图例行要放得下 名称 + 大小 + 百分比）。
              if (constraints.maxWidth >= 460) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    children: <Widget>[
                      buildRing(184),
                      const SizedBox(width: 28),
                      Expanded(child: legend),
                    ],
                  ),
                );
              }
              final double size =
                  math.min(200, math.max(150, constraints.maxWidth * 0.55));
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Center(child: buildRing(size)),
                    if (ranked.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 16),
                      legend,
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewSection(Map<StorageCategoryId, _SliceStyle> colors) {
    final int total = _totalBytes;
    return AdaptiveSettingsSection(
      title: t.storage_overview_section,
      children: <Widget>[
        for (final StorageCategoryId id in StorageCategoryId.values)
          ..._buildCategoryRows(id, colors[id], total),
      ],
    );
  }

  List<Widget> _buildCategoryRows(
    StorageCategoryId id,
    _SliceStyle? sliceStyle,
    int total,
  ) {
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
      // 类目行与同组首行「总计」同一个共享设置行（行首图标位 / 行高 / 文字起点
      // 一致；Apple 下图标是强调色单色、按下是 systemFill 高亮），不再混用列表项。
      AdaptiveSettingsRow(
        title: _categoryTitle(id),
        // 占比（与环形图同一口径）；0 字节 / 扫描中不显示。
        subtitle: usage != null && usage.bytes > 0 && total > 0
            ? _percentLabel(usage.bytes / total)
            : null,
        icon: _categoryIcons[id],
        showIcon: true,
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
                        child: FushiCircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : FushiIconButtonControl(
                      tooltip: t.storage_shaders_delete_anime4k,
                      icon: const FushiIcon(FushiIcons.deleteSweep, size: 18),
                      onPressed: _anime4kDeleteAction,
                    ),
            // 图例色点：与环形图里这一段、总览卡图例同一份样式
            //（[_storageSliceStyles]）；0 字节类目不在环上，也不画点。
            if (sliceStyle != null && usage != null && usage.bytes > 0)
              ...<Widget>[
              _SliceSwatch(style: sliceStyle, size: 10),
              const SizedBox(width: 8),
            ],
            Text(
              usage == null ? '…' : formatStorageBytes(usage.bytes),
              style: context.fushiType.bodyMedium.tabular,
            ),
            if (expandable) ...<Widget>[
              const SizedBox(width: 4),
              // 展开指示：Apple = iOS 披露 chevron（展开转到朝下），MD3 =
              // expand_more（展开翻转朝上）；与可折叠设置分组同一口径。
              AnimatedRotation(
                turns: expanded ? (isGlassDesign(context) ? 0.25 : 0.5) : 0.0,
                duration: context.fushiMotion.spatialFast.duration,
                curve: context.fushiMotion.spatialFast.curve,
                child: isGlassDesign(context)
                    ? const FushiAppleChevron()
                    : const FushiIcon(FushiIcons.expandMore, size: 18),
              ),
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

  /// 占比文案：不足 1% 保留一位小数（0.4%），否则取整。
  static String _percentLabel(double fraction) {
    final double pct = fraction * 100;
    return '${pct.toStringAsFixed(pct < 1 ? 1 : 0)}%';
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
                      child: FushiCircularProgressIndicator(strokeWidth: 2),
                    )
                  : FushiIconButtonControl(
                      tooltip: t.dialog_delete,
                      icon: const FushiIcon(FushiIcons.delete, size: 18),
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
            icon: FushiIcons.widgets,
            showIcon: true,
            trailing: Text(formatStorageBytes(c.bytes)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            t.storage_bundled_hint,
            // 分组内说明走设置脚注的统一口径（Apple footnote + secondaryLabel /
            // MD3 bodySmall + onVariant）。
            style: settingsFootnoteStyle(context),
          ),
        ),
      ],
    );
  }
}

/// 各类目占比的逐元素插值（长度恒为类目数，顺序固定）。
class _FractionsTween extends Tween<List<double>> {
  _FractionsTween({required super.begin, required super.end});

  @override
  List<double> lerp(double t) {
    final List<double> a = begin!;
    final List<double> b = end!;
    return <double>[
      for (int i = 0; i < b.length; i++)
        (i < a.length ? a[i] : 0) + (b[i] - (i < a.length ? a[i] : 0)) * t,
    ];
  }
}

/// 占比段的填充方式：彩色主题一律 [solid]；墨水屏没有色相可用，靠
/// 灰阶 × 纹理（实心 / 斜线 / 描边）区分相邻段。
enum _SliceFill { solid, hatched, outlined }

/// 一个类目在环上（以及所有图例色点上）的样式。
@immutable
class _SliceStyle {
  const _SliceStyle({required this.color, this.fill = _SliceFill.solid});

  final Color color;
  final _SliceFill fill;

  @override
  bool operator ==(Object other) =>
      other is _SliceStyle && other.color == color && other.fill == fill;

  @override
  int get hashCode => Object.hash(color, fill);
}

/// 存储占比的唯一配色来源：环上的段、总览卡图例、磁盘占用列表的色点都只
/// 从这里取色，保证同类目同色。
///
/// 彩色主题：以当前 [ColorScheme.primary] 的色相为起点，按 HCT 等间隔色相
/// 给每个类目一个**固定**槽位（与体积排名无关，扫描中排名变动不会换色），
/// 同一色调 / 彩度——亮色 tone 55、暗色（含纯黑）tone 78，彩度 56（HCT 按
/// 色域自动收）。槽位按「枚举序 × 5 mod 13」打散，枚举里相邻的类目色相相距
/// 约 138°。「其他」用低彩度中性色。不再用 onPrimaryContainer 一类的 on 色
///（暗色下是去饱和的灰紫，彼此分不开）。
///
/// 墨水屏：按体积排名轮换 灰阶（onSurface / outline）× 纹理（实心 / 斜线 /
/// 描边），前六名互不相同。
Map<StorageCategoryId, _SliceStyle> _storageSliceStyles(
  ColorScheme cs, {
  required bool eink,
  required List<StorageCategoryId> ranked,
}) {
  if (eink) {
    final List<_SliceStyle> combos = <_SliceStyle>[
      _SliceStyle(color: cs.onSurface),
      _SliceStyle(color: cs.onSurface, fill: _SliceFill.hatched),
      _SliceStyle(color: cs.onSurface, fill: _SliceFill.outlined),
      _SliceStyle(color: cs.outline),
      _SliceStyle(color: cs.outline, fill: _SliceFill.hatched),
      _SliceStyle(color: cs.outline, fill: _SliceFill.outlined),
    ];
    return <StorageCategoryId, _SliceStyle>{
      for (final StorageCategoryId id in StorageCategoryId.values)
        id: ranked.contains(id)
            ? combos[ranked.indexOf(id) % combos.length]
            : _SliceStyle(color: cs.outline),
    };
  }
  final bool dark = cs.brightness == Brightness.dark;
  final double baseHue = Hct.fromInt(cs.primary.toARGB32()).hue;
  final double tone = dark ? 78 : 55;
  final List<StorageCategoryId> hued = <StorageCategoryId>[
    for (final StorageCategoryId id in StorageCategoryId.values)
      if (id != StorageCategoryId.other) id,
  ];
  final int slots = hued.length;
  // 与 slots 互素的步长，把枚举相邻的类目打散到色环两侧。
  int step = 5;
  while (_gcd(step, slots) != 1) {
    step++;
  }
  return <StorageCategoryId, _SliceStyle>{
    for (int i = 0; i < hued.length; i++)
      hued[i]: _SliceStyle(
        color: Color(
          Hct.from(
            (baseHue + (i * step % slots) * 360 / slots) % 360,
            56,
            tone,
          ).toInt(),
        ),
      ),
    StorageCategoryId.other: _SliceStyle(
      color: Color(Hct.from(baseHue, 8, dark ? 64 : 60).toInt()),
    ),
  };
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

/// 斜线纹理（墨水屏用）：在 [bounds] 内画 45° 平行线，调用方负责裁剪。
void _paintHatch(Canvas canvas, Rect bounds, Color color, double spacing) {
  final Paint line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2
    ..color = color;
  final double span = bounds.width + bounds.height;
  for (double d = 0; d <= span; d += spacing) {
    canvas.drawLine(
      Offset(bounds.left + d, bounds.top),
      Offset(bounds.left + d - bounds.height, bounds.bottom),
      line,
    );
  }
}

/// 图例色点：与环上同一类目的段同色同纹理。
class _SliceSwatch extends StatelessWidget {
  const _SliceSwatch({required this.style, required this.size});

  final _SliceStyle style;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _SliceSwatchPainter(style)),
    );
  }
}

class _SliceSwatchPainter extends CustomPainter {
  _SliceSwatchPainter(this.style);

  final _SliceStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = math.min(size.width, size.height) / 2;
    switch (style.fill) {
      case _SliceFill.solid:
        canvas.drawCircle(center, radius, Paint()..color = style.color);
      case _SliceFill.outlined:
        canvas.drawCircle(
          center,
          radius - 0.75,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = style.color,
        );
      case _SliceFill.hatched:
        final Rect bounds = Rect.fromCircle(center: center, radius: radius);
        canvas.save();
        canvas.clipPath(Path()..addOval(bounds));
        _paintHatch(canvas, bounds, style.color, 3);
        canvas.restore();
        canvas.drawCircle(
          center,
          radius - 0.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = style.color,
        );
    }
  }

  @override
  bool shouldRepaint(_SliceSwatchPainter old) => old.style != style;
}

/// M3E 环形占比图：底轨一整圈，各非零段按 [order]（体积降序）从 12 点方向
/// 顺时针排开。
///
/// - 段间缝隙固定 [_gapPx] 像素（不随段长、端帽变化）：圆头端帽各向外伸半个
///   线宽，所以圆头段的几何扫角先扣掉一个线宽再居中；
/// - 只有长度够容纳两个半圆端帽的段才用圆头，更短的段画平头——旧实现对
///   极小段也画圆头（扫角取 0.0001），两个端帽叠成一个突兀的小圆点；
/// - 每段至少 [_minVisiblePx] 像素可见长度，不足的从大段按比例借；
/// - [reveal] 0→1 是进场扫出进度：从 12 点起累计角度不超过 reveal·2π，段依次
///   出现；
/// - 墨水屏画平头扇环（实心 / 斜线 / 描边），不画圆头。
/// 弹簧过冲或插值中途总和偏离 1 时按总和归一。
class _StorageDonutPainter extends CustomPainter {
  _StorageDonutPainter({
    required this.fractions,
    required this.order,
    required this.styles,
    required this.reveal,
    required this.trackColor,
    required this.strokeWidth,
    required this.eink,
  });

  static const double _gapPx = 3;
  static const double _minVisiblePx = 3;

  /// 逐类目占比，按枚举序。
  final List<double> fractions;

  /// 绘制顺序（枚举 index），与图例行序一致。
  final List<int> order;

  /// 逐类目样式，按枚举序。
  final List<_SliceStyle> styles;
  final double reveal;
  final Color trackColor;
  final double strokeWidth;
  final bool eink;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    if (radius <= 0) return;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = eink ? 1 : strokeWidth
        ..color = trackColor,
    );

    final List<int> live = <int>[
      for (final int i in order)
        if (i < fractions.length && fractions[i] > 0) i,
    ];
    if (live.isEmpty) return;
    final double sum =
        live.fold<double>(0, (double acc, int i) => acc + fractions[i]);
    if (sum <= 0) return;
    final int n = live.length;
    final double gapA = n > 1 ? _gapPx / radius : 0;
    final double minF = (gapA + _minVisiblePx / radius) / (2 * math.pi);
    final List<double> visual = _withMinimum(
      <double>[for (final int i in live) fractions[i] / sum],
      minF,
    );

    final double limit = reveal.clamp(0.0, 1.0) * 2 * math.pi;
    const double top = -math.pi / 2;
    double acc = 0;
    for (int k = 0; k < n; k++) {
      final double full = visual[k] * 2 * math.pi;
      final double shown = math.min(full, limit - acc);
      if (shown <= 0) break;
      final _SliceStyle style = styles[live[k]];
      if (n == 1 && shown >= 2 * math.pi - 1e-6) {
        _drawFullRing(canvas, center, radius, style);
        break;
      }
      _drawSegment(canvas, center, rect, radius, top + acc, shown, gapA, style);
      acc += full;
    }
  }

  /// 低于下限的段抬到下限，差额从其余段按比例扣。
  static List<double> _withMinimum(List<double> fs, double minF) {
    if (fs.length * minF >= 1) {
      return List<double>.filled(fs.length, 1 / fs.length);
    }
    double deficit = 0;
    double bigSum = 0;
    for (final double f in fs) {
      if (f < minF) {
        deficit += minF - f;
      } else {
        bigSum += f;
      }
    }
    if (deficit <= 0 || bigSum <= 0) return fs;
    return <double>[
      for (final double f in fs) f < minF ? minF : f - deficit * (f / bigSum),
    ];
  }

  void _drawFullRing(
    Canvas canvas,
    Offset center,
    double radius,
    _SliceStyle style,
  ) {
    if (!eink) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = style.color,
      );
      return;
    }
    final Path ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCircle(center: center, radius: radius + strokeWidth / 2))
      ..addOval(Rect.fromCircle(center: center, radius: radius - strokeWidth / 2));
    _fillEinkPath(canvas, ring, style);
  }

  void _drawSegment(
    Canvas canvas,
    Offset center,
    Rect rect,
    double radius,
    double start,
    double allocated,
    double gapA,
    _SliceStyle style,
  ) {
    final double inner = allocated - gapA;
    if (inner <= 0) return;
    final double from = start + gapA / 2;
    if (eink) {
      final Rect outer = Rect.fromCircle(
        center: center,
        radius: radius + strokeWidth / 2,
      );
      final Rect hole = Rect.fromCircle(
        center: center,
        radius: radius - strokeWidth / 2,
      );
      final Path sector = Path()
        ..arcTo(outer, from, inner, true)
        ..arcTo(hole, from + inner, -inner, false)
        ..close();
      _fillEinkPath(canvas, sector, style);
      return;
    }
    // 圆头两端各伸出半个线宽 = 一个线宽对应的扫角。
    final double capA = strokeWidth / radius;
    final bool round = inner > capA * 1.05;
    canvas.drawArc(
      rect,
      round ? from + capA / 2 : from,
      round ? inner - capA : inner,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = round ? StrokeCap.round : StrokeCap.butt
        ..color = style.color,
    );
  }

  void _fillEinkPath(Canvas canvas, Path path, _SliceStyle style) {
    switch (style.fill) {
      case _SliceFill.solid:
        canvas.drawPath(path, Paint()..color = style.color);
      case _SliceFill.outlined:
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = style.color,
        );
      case _SliceFill.hatched:
        canvas.save();
        canvas.clipPath(path);
        _paintHatch(canvas, path.getBounds(), style.color, 5);
        canvas.restore();
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = style.color,
        );
    }
  }

  @override
  bool shouldRepaint(_StorageDonutPainter old) =>
      old.reveal != reveal ||
      old.trackColor != trackColor ||
      old.strokeWidth != strokeWidth ||
      old.eink != eink ||
      !_listEquals(old.fractions, fractions) ||
      !_listEquals(old.order, order) ||
      !_listEquals(old.styles, styles);

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
