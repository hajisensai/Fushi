import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/media/manga/extension_catalog_controls.dart';
import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/media/manga/extension_store_list.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 小说插件（LNReader）的「仓库」段与「扩展」段正文，嵌在书的「导入」视图里。
///
/// 与视频 / 漫画那套 `MihonExtensionsPage(embedded: true)` 同构：顶部一行动作
/// 按钮 → 加载条 → 仓库卡片 / 语言 + 搜索筛选 + 下载量门槛与批量动作 + 按仓库
/// 分组（可折叠、组内按下载量排行）的扩展行。扩展行、筛选行、动作行、仓库表头、
/// 批量对话框直接复用共享的 [MangaExtensionManagementTile] /
/// [MangaExtensionFilters] / [ExtensionCatalogActions] /
/// [ExtensionStoreGroupHeader] / `runExtensionBulkWithProgress`，外观逐像素一致；
/// 不复用 Mihon 页面本体是因为那套绑死了 APK 签名 / 信任 / 预览管线，LNReader
/// 插件是纯 JS、一个插件就是一个源，没有这些环节。
///
/// `build` 返回 **sliver**，由外层 `CustomScrollView` 消费。
class LnReaderExtensionsSection extends StatefulWidget {
  const LnReaderExtensionsSection({
    required this.manager,
    required this.showStores,
    required this.showCatalog,
    super.key,
  });

  final LnReaderManager manager;
  final bool showStores;
  final bool showCatalog;

  @override
  State<LnReaderExtensionsSection> createState() =>
      _LnReaderExtensionsSectionState();
}

class _LnReaderExtensionsSectionState extends State<LnReaderExtensionsSection> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _language = '*';

  /// 仓库筛选（indexUrl；`'*'` = 全部仓库）。并入 [_filteredAvailable]——批量
  /// 安装装的就是当前筛出来的那批。
  String _store = '*';

  /// 用户手动点过的仓库分组展开态（indexUrl → 展开）；没点过的按条数自适应。
  final Map<String, bool> _storeExpansionOverrides = <String, bool>{};

  /// 「最低下载量」筛选的当前档位（0 = 不筛）。
  int _minDownloads = 0;

  /// 批量安装 / 一键更新进行中：按钮置灰，防止连点重复排队。
  bool _bulkRunning = false;

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_changed);
    unawaited(widget.manager.initialise());
  }

  @override
  void didUpdateWidget(covariant LnReaderExtensionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.manager, widget.manager)) return;
    oldWidget.manager.removeListener(_changed);
    widget.manager.addListener(_changed);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_changed);
    _searchController.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _showError(Object error) {
    if (!mounted) return;
    FushiToast.show(
      msg: '${t.mihon_extension_error}: $error',
      severity: ToastSeverity.error,
    );
  }

  Future<String?> _askStoreUrl({
    required String title,
    String initial = '',
    bool warn = false,
  }) => showExtensionStoreUrlDialog(
    context: context,
    title: title,
    confirmLabel: title,
    initial: initial,
    // 添加时把「插件是第三方脚本」的信任提示放在输入框上方。
    warning: warn ? t.novel_store_add_warning : null,
    fieldKey: const ValueKey<String>('novel_store_url_field'),
  );

  Future<void> _addStore() async {
    final String? url = await _askStoreUrl(
      title: t.mihon_store_add,
      warn: true,
    );
    if (url == null || url.trim().isEmpty) return;
    try {
      await widget.manager.addStore(url);
    } on Object catch (error) {
      _showError(error);
    }
  }

  Future<void> _editStore(LnReaderStore store) async {
    final String? url = await _askStoreUrl(
      title: t.mihon_store_edit,
      initial: store.indexUrl,
    );
    if (url == null || url.trim().isEmpty || url.trim() == store.indexUrl) {
      return;
    }
    try {
      await widget.manager.editStore(store, url);
    } on Object catch (error) {
      _showError(error);
    }
  }

  Future<bool> _confirm(String title, String message, String action) =>
      showFushiConfirmDialog(
        context: context,
        title: title,
        message: message,
        icon: FushiIcons.delete,
        confirmLabel: action,
        destructive: true,
      );

  Future<void> _removeStore(LnReaderStore store) async {
    if (!await _confirm(
      t.mihon_store_remove,
      store.indexUrl,
      t.mihon_store_remove,
    )) {
      return;
    }
    await widget.manager.removeStore(store);
  }

  Future<void> _install(LnReaderRepoPlugin plugin) async {
    try {
      await widget.manager.install(plugin);
    } on Object catch (error) {
      _showError(error);
    }
  }

  Future<void> _uninstall(LnReaderInstalledPlugin plugin) async {
    if (!await _confirm(
      t.mihon_extension_uninstall,
      plugin.name,
      t.mihon_extension_uninstall,
    )) {
      return;
    }
    try {
      await widget.manager.uninstall(plugin);
    } on Object catch (error) {
      _showError(error);
    }
  }

  /// 当前筛选（语言 + 搜索 + 最低下载量）之后的目录。列表渲染与批量安装**必须**
  /// 共用这一份判据：批量安装的语义就是「把你现在看见的这些装上」。
  List<LnReaderRepoPlugin> _filteredAvailable() => visibleLnReaderCatalog(
    widget.manager.available,
    language: _language,
    query: _searchQuery,
    minDownloads: _minDownloads,
    store: _effectiveStore(),
  );

  /// 实际生效的仓库筛选：选中的仓库已不在目录里（被删 / 刷新后零插件）时退回
  /// 「全部仓库」，与 chip 行的选中态同一判据（chip 只列有插件的仓库）。
  String _effectiveStore() =>
      _store != '*' &&
          widget.manager.available.any(
            (LnReaderRepoPlugin plugin) => plugin.storeUrl == _store,
          )
      ? _store
      : '*';

  /// 把当前筛选结果里**还没装**的插件一次装完。只装未安装的：升级会换掉正在用的
  /// 源的代码，那必须是逐条的、看得见版本号的决定（与漫画 / 视频同口径）。
  Future<void> _bulkInstall() async {
    final LnReaderManager manager = widget.manager;
    final List<LnReaderRepoPlugin> targets = _filteredAvailable()
        .where(
          (LnReaderRepoPlugin plugin) =>
              manager.installedById(plugin.id) == null,
        )
        .toList(growable: false);
    if (targets.isEmpty) {
      unawaited(
        showExtensionBulkNothing(
          context,
          title: t.mihon_extension_bulk_install,
          message: t.mihon_extension_bulk_install_nothing,
        ),
      );
      return;
    }
    final bool confirmed = await confirmExtensionBulk(
      context,
      title: t.mihon_extension_bulk_install,
      message: t.mihon_extension_bulk_install_confirm(count: targets.length),
      actionLabel: t.mihon_extension_install,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _runBulk(targets, upgrade: false);
  }

  /// 「一键更新」：已装且来源仓库里版本更高的全部更新（判据与行内「更新」同为
  /// [LnReaderManager.hasUpdate]）。
  Future<void> _updateAll() async {
    final LnReaderManager manager = widget.manager;
    final List<LnReaderRepoPlugin> targets = manager.available
        .where(manager.hasUpdate)
        .toList(growable: false);
    if (targets.isEmpty) {
      unawaited(
        showExtensionBulkNothing(
          context,
          title: t.mihon_extension_update_all,
          message: t.mihon_extension_update_all_nothing,
        ),
      );
      return;
    }
    final bool confirmed = await confirmExtensionBulk(
      context,
      title: t.mihon_extension_update_all,
      message: t.mihon_extension_update_all_confirm(count: targets.length),
      actionLabel: t.mihon_extension_update,
      destructive: false,
    );
    if (!confirmed || !mounted) return;
    await _runBulk(targets, upgrade: true);
  }

  /// 批量安装 / 一键更新共用的执行体：进度框 → 逐条 [LnReaderManager.install]
  /// （每条之间读取消闸门，正在下载的那条跑完）→ 结果框。单条失败只进失败清单，
  /// 不打断同批其它插件。
  Future<void> _runBulk(
    List<LnReaderRepoPlugin> targets, {
    required bool upgrade,
  }) async {
    final LnReaderManager manager = widget.manager;
    final String title = upgrade
        ? t.mihon_extension_update_all
        : t.mihon_extension_bulk_install;
    setState(() => _bulkRunning = true);
    final LnReaderBulkReport? report;
    try {
      report = await runExtensionBulkWithProgress<LnReaderBulkReport>(
        context,
        title: title,
        total: targets.length,
        firstName: targets.first.name,
        progressText: (int current, int total, String name) => upgrade
            ? t.mihon_extension_update_all_progress(
                current: current,
                total: total,
                name: name,
              )
            : t.mihon_extension_bulk_install_progress(
                current: current,
                total: total,
                name: name,
              ),
        run: (onProgress, isCancelled) => installLnReaderPlugins(
          manager,
          targets,
          onProgress: onProgress,
          isCancelled: isCancelled,
        ),
      );
    } finally {
      if (mounted) setState(() => _bulkRunning = false);
    }
    if (report == null || !mounted) return;
    unawaited(
      showExtensionBulkReport(
        context,
        title: title,
        summary: upgrade
            ? t.mihon_extension_update_all_done(
                installed: report.installed,
                skipped: report.skipped,
                failed: report.failed.length,
              )
            : t.mihon_extension_bulk_install_done(
                installed: report.installed,
                skipped: report.skipped,
                failed: report.failed.length,
              ),
        failures: report.failed,
      ),
    );
  }

  /// 内嵌目录顶部的动作行（M3E 按钮）。库页「扩展」子标签的页头动作组已挂着
  /// 「刷新仓库」（[ExtensionCatalogHeaderScope]）时这里不再重复；没有页头的宿主
  /// （浏览模块、测试）刷新仍留在这里，入口一个不丢。仓库段同在时附「添加仓库」。
  List<Widget> _actions({required bool stores}) {
    final LnReaderManager manager = widget.manager;
    final bool refreshInHeader = ExtensionCatalogHeaderScope.refreshInHeaderOf(
      context,
    );
    return <Widget>[
      if (!refreshInHeader)
        FushiTextButton.icon(
          key: const ValueKey<String>('novel_extension_refresh'),
          onPressed: manager.loading
              ? null
              : () => unawaited(manager.refreshStores()),
          icon: const FushiIcon(FushiIcons.refresh),
          label: Text(t.mihon_store_refresh),
        ),
      if (stores)
        FushiFilledButton.tonalIcon(
          onPressed: manager.loading ? null : _addStore,
          icon: const FushiIcon(FushiIcons.link),
          label: Text(t.mihon_store_add),
        ),
    ];
  }

  /// 刷新中的波浪进度条：弹簧展开 / 收起。
  Widget _loadingSlot(bool loading) {
    final FushiSpringSpec spring = context.fushiMotion.spatialDefault;
    return AnimatedSize(
      duration: spring.duration,
      curve: spring.curve,
      alignment: Alignment.topCenter,
      child: loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: FushiLinearProgressIndicator(),
            )
          : const SizedBox(width: double.infinity),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool stores = widget.showStores;
    final bool catalog = widget.showCatalog;
    if (!stores && !catalog) {
      return const SliverMainAxisGroup(slivers: <Widget>[]);
    }
    if (stores && !catalog) {
      return FushiEntranceScope(child: _buildStorePage());
    }
    final List<Widget> actions = _actions(stores: stores);
    // 进场窗口按筛选维度重开：换仓库 / 语言 / 下载量门槛时新的一屏也错峰进场。
    return FushiEntranceScope(
      replayKey: (_language, _store, _minDownloads),
      child: SliverMainAxisGroup(
        slivers: <Widget>[
          if (actions.isNotEmpty)
            SliverToBoxAdapter(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
              ),
            ),
          SliverToBoxAdapter(child: _loadingSlot(widget.manager.loading)),
          if (stores) _buildStores(),
          if (catalog) ..._buildCatalog(),
        ],
      ),
    );
  }

  /// 「仓库」页（扩展页签「仓库」动作 push 出的子页）：限宽居中的一列——
  /// 顶部刷新 / 添加仓库、信任提示、加载条、仓库分组列表。与漫画 / 视频
  /// 扩展仓库页同一组零件（`extension_store_list.dart`）。
  Widget _buildStorePage() {
    final LnReaderManager manager = widget.manager;
    return ExtensionStorePageSliver(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: ExtensionStoreToolbar(
            refreshLabel: t.mihon_store_refresh,
            addLabel: t.mihon_store_add,
            onRefresh: manager.loading
                ? null
                : () => unawaited(manager.refreshStores()),
            onAdd: manager.loading ? null : _addStore,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: FushiInlineNotice(
              severity: FushiNoticeSeverity.warning,
              icon: FushiIcons.shield,
              message: t.novel_store_add_warning,
            ),
          ),
        ),
        // 加载条占一条固定高度的槽：刷新开始 / 结束时列表不上下跳。
        SliverToBoxAdapter(
          child: SizedBox(
            height: 20,
            child: Center(
              child: manager.loading
                  ? const FushiLinearProgressIndicator()
                  : const SizedBox.shrink(),
            ),
          ),
        ),
        _buildStores(),
      ],
    );
  }

  Widget _buildStores() {
    final LnReaderManager manager = widget.manager;
    if (manager.stores.isEmpty) {
      return SliverToBoxAdapter(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.hub,
          message: t.novel_store_empty,
          action: FushiFilledButton.icon(
            onPressed: manager.loading ? null : _addStore,
            icon: const FushiIcon(FushiIcons.add),
            label: Text(t.mihon_store_add),
          ),
        ),
      );
    }
    return SliverList.builder(
      itemCount: manager.stores.length,
      itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int index) {
        final LnReaderStore store = manager.stores[index];
        final bool builtin = manager.isBuiltinStore(store);
        final int count = manager.available
            .where((LnReaderRepoPlugin p) => p.storeUrl == store.indexUrl)
            .length;
        // 与 Mihon 仓库行同一判据：刷新中不判「零扩展」，否则每次进页都误报。
        final bool returnedNothing =
            !manager.loading && store.lastError == null && count == 0;
        final ExtensionStoreStatus status =
            switch ((store.lastError, returnedNothing)) {
              (final String error, _) => (
                text: error,
                tone: FushiStatusTone.error,
              ),
              (null, true) => (
                text: t.mihon_store_zero_extensions,
                tone: FushiStatusTone.warning,
              ),
              (null, false) => (
                text: t.mihon_store_extension_count(count: count),
                tone: null,
              ),
            };
        // 仓库列表整段读作一个分组（MD3 分段 / Apple inset grouped）。内置
        // 仓库只能复制地址，不给改 / 删。
        return ExtensionStoreTile(
          index: index,
          count: manager.stores.length,
          rowKey: ValueKey<String>('novel_store_${store.indexUrl}'),
          menuKey: ValueKey<String>('novel_store_menu_${store.indexUrl}'),
          name: store.name,
          url: store.indexUrl,
          builtin: builtin,
          builtinLabel: t.novel_store_builtin_label,
          status: status,
          actions: <ExtensionStoreRowAction>[
            extensionStoreCopyAction(store.indexUrl),
            if (!builtin) ...<ExtensionStoreRowAction>[
              ExtensionStoreRowAction(
                label: t.mihon_store_edit,
                icon: FushiIcons.edit,
                onTap: () => unawaited(_editStore(store)),
              ),
              ExtensionStoreRowAction(
                label: t.mihon_store_remove,
                icon: FushiIcons.delete,
                destructive: true,
                onTap: () => unawaited(_removeStore(store)),
              ),
            ],
          ],
        );
      }),
    );
  }

  /// 某个仓库当前是否展开：搜索态一律展开；用户点过表头就听用户的；否则按
  /// 条数自适应（与漫画 / 视频扩展目录同一判据）。
  bool _storeExpanded(String indexUrl, int count) {
    if (_searchQuery.trim().isNotEmpty) return true;
    return _storeExpansionOverrides[indexUrl] ??
        count <= kExtensionStoreAutoCollapseThreshold;
  }

  void _toggleStore(String indexUrl, int count) {
    setState(() {
      _storeExpansionOverrides[indexUrl] = !_storeExpanded(indexUrl, count);
    });
  }

  Widget _buildPluginTile(
    LnReaderRepoPlugin plugin, {
    int? groupIndex,
    int? groupCount,
  }) {
    final LnReaderManager manager = widget.manager;
    final LnReaderInstalledPlugin? installed = manager.installedById(plugin.id);
    final bool update = manager.hasUpdate(plugin);
    final bool busy = manager.isBusy(plugin.id);
    return MangaExtensionManagementTile(
      key: ValueKey<String>('novel_extension_${plugin.id}'),
      groupIndex: groupIndex,
      groupCount: groupCount,
      title: plugin.name,
      iconUrl: plugin.iconUrl,
      busy: busy,
      updateAvailable: update,
      subtitleMaxLines: 2,
      metaChips: <String>[
        plugin.lang,
        update && installed != null
            ? '${installed.version} → ${plugin.version}'
            : plugin.version,
        mangaSourceHostLabel(plugin.site),
      ],
      downloadsLabel: extensionDownloadCountLabel(plugin.downloadCount),
      enabled: installed?.enabled,
      onEnabledChanged: installed == null
          ? null
          : (bool value) => unawaited(manager.setEnabled(installed, value)),
      secondaryLabel: installed != null && update
          ? t.mihon_extension_uninstall
          : null,
      secondaryStyle: ExtensionTileActionStyle.outlined,
      onSecondary: installed != null && update
          ? () => unawaited(_uninstall(installed))
          : null,
      primaryLabel: installed == null
          ? t.mihon_extension_install
          : update
          ? t.mihon_extension_update
          : t.mihon_extension_uninstall,
      // 安装 = filled 主操作；有更新 = tonal 强调；卸载 = outlined 次要。
      primaryStyle: installed == null
          ? ExtensionTileActionStyle.filled
          : update
          ? ExtensionTileActionStyle.tonal
          : ExtensionTileActionStyle.outlined,
      onPrimary: busy
          ? null
          : installed == null || update
          ? () => unawaited(_install(plugin))
          : () => unawaited(_uninstall(installed)),
    );
  }

  List<Widget> _buildCatalog() {
    final LnReaderManager manager = widget.manager;
    final List<String> languages =
        manager.available
            .map((LnReaderRepoPlugin plugin) => plugin.lang)
            .where((String lang) => lang.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final List<LnReaderRepoPlugin> visible = _filteredAvailable();
    final List<LnReaderCatalogRow> rows = buildLnReaderGroupedRows(
      stores: manager.stores,
      plugins: visible,
      expanded: _storeExpanded,
    );
    // 每个仓库（表头 + 展开的插件行）读作一个分组：逐行算出组内位置。
    final List<(int, int)> groupSlots = extensionGroupSlots(
      rows.map((LnReaderCatalogRow row) => row is LnReaderStoreHeaderRow),
    );
    // 已装但仓库目录里已经没有的插件（仓库删了 / 下架了）：仍要能卸载。
    final Set<String> availableIds = manager.available
        .map((LnReaderRepoPlugin plugin) => plugin.id)
        .toSet();
    // 孤儿插件不属于任何仓库：选了某个仓库时它们不在「当前看到的那批」里。
    final bool allStores = _effectiveStore() == '*';
    final Set<String> storesWithPlugins = manager.available
        .map((LnReaderRepoPlugin plugin) => plugin.storeUrl)
        .toSet();
    final List<LnReaderInstalledPlugin> orphans =
        filterByMediaSearch<LnReaderInstalledPlugin>(
          manager.installed
              .where(
                (LnReaderInstalledPlugin plugin) =>
                    allStores &&
                    !availableIds.contains(plugin.id) &&
                    (_language == '*' || plugin.lang == _language),
              )
              .toList(growable: false),
          _searchQuery,
          (LnReaderInstalledPlugin plugin) => <String>[plugin.name, plugin.id],
        );
    return <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              MangaExtensionFilters(
                keyPrefix: 'novel_extension',
                stores: <ExtensionFilterOption<String>>[
                  for (final LnReaderStore store in manager.stores)
                    if (storesWithPlugins.contains(store.indexUrl))
                      (
                        value: store.indexUrl,
                        label: store.name.isEmpty
                            ? mangaSourceHostLabel(store.indexUrl)
                            : store.name,
                      ),
                ],
                selectedStore: _effectiveStore(),
                onStoreChanged: (String value) =>
                    setState(() => _store = value),
                languages: languages,
                selectedLanguage: _language,
                languageLabel: t.mihon_extension_language_filter,
                allLanguagesLabel: t.mihon_extension_language_all,
                searchHint: t.novel_extensions_search_hint,
                searchController: _searchController,
                searchQuery: _searchQuery,
                onLanguageChanged: (String value) =>
                    setState(() => _language = value),
                onSearchChanged: (String value) =>
                    setState(() => _searchQuery = value),
                onSearchCleared: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
              ),
              const SizedBox(height: 8),
              ExtensionCatalogActions(
                keyPrefix: 'novel_extension',
                minDownloads: _minDownloads,
                onMinDownloadsChanged: (int value) =>
                    setState(() => _minDownloads = value),
                onBulkInstall: manager.loading || _bulkRunning
                    ? null
                    : () => unawaited(_bulkInstall()),
                onUpdateAll: manager.loading || _bulkRunning
                    ? null
                    : () => unawaited(_updateAll()),
              ),
            ],
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
      SliverList.builder(
        itemCount: rows.length,
        itemBuilder: fushiStaggeredItemBuilder((
          BuildContext context,
          int index,
        ) {
          final LnReaderCatalogRow row = rows[index];
          return switch (row) {
            LnReaderStoreHeaderRow() => ExtensionStoreGroupHeader(
              groupCount: groupSlots[index].$2,
              keyPrefix: 'novel',
              indexUrl: row.indexUrl,
              label: row.label,
              count: row.count,
              expanded: row.expanded,
              // 搜索态是强制展开的，这时点表头没有意义（点了也还是展开）。
              onTap: _searchQuery.trim().isNotEmpty
                  ? null
                  : () => _toggleStore(row.indexUrl, row.count),
            ),
            LnReaderPluginRow() => _buildPluginTile(
              row.plugin,
              groupIndex: groupSlots[index].$1,
              groupCount: groupSlots[index].$2,
            ),
          };
        }),
      ),
      SliverList.builder(
        itemCount: orphans.length,
        itemBuilder: fushiStaggeredItemBuilder((
          BuildContext context,
          int index,
        ) {
          final LnReaderInstalledPlugin plugin = orphans[index];
          return MangaExtensionManagementTile(
            key: ValueKey<String>('novel_extension_local_${plugin.id}'),
            groupIndex: index,
            groupCount: orphans.length,
            title: plugin.name,
            iconUrl: plugin.iconUrl,
            metaChips: <String>[
              plugin.lang,
              plugin.version,
              mangaSourceHostLabel(plugin.site),
            ],
            enabled: plugin.enabled,
            onEnabledChanged: (bool value) =>
                unawaited(manager.setEnabled(plugin, value)),
            primaryLabel: t.mihon_extension_uninstall,
            primaryStyle: ExtensionTileActionStyle.outlined,
            onPrimary: () => unawaited(_uninstall(plugin)),
          );
        }),
      ),
      // 搜索 / 筛选后一条都不剩：统一占位（M3E 色块图标 + 弹入），不是一行裸字。
      if ((_searchQuery.trim().isNotEmpty ||
              _language != '*' ||
              !allStores ||
              _minDownloads > 0) &&
          visible.isEmpty &&
          orphans.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: FushiPlaceholderMessage(
              icon: FushiIcons.searchOff,
              message: t.no_search_results,
            ),
          ),
        ),
    ];
  }
}

/// 扩展目录的可见行：语言精确筛选 + 最低下载量门槛 + 统一归一化搜索。顺序交给
/// [buildLnReaderGroupedRows] 在组内按下载量排（与漫画 / 视频目录同口径）。
/// 纯函数，便于测试。
List<LnReaderRepoPlugin> visibleLnReaderCatalog(
  List<LnReaderRepoPlugin> available, {
  required String language,
  required String query,
  int minDownloads = 0,
  String store = '*',
}) => filterByMediaSearch<LnReaderRepoPlugin>(
  available
      .where(
        (LnReaderRepoPlugin plugin) =>
            (store == '*' || plugin.storeUrl == store) &&
            (language == '*' || plugin.lang == language) &&
            passesExtensionMinDownloads(plugin.downloadCount, minDownloads),
      )
      .toList(growable: false),
  query,
  (LnReaderRepoPlugin plugin) => <String>[plugin.name, plugin.id, plugin.site],
);

/// 扩展目录按仓库分组压平后的一行：仓库表头或一个插件（与漫画 / 视频目录的
/// `buildMihonGroupedRows` 同构，整表仍交给 [SliverList.builder] 懒建）。
sealed class LnReaderCatalogRow {
  const LnReaderCatalogRow();
}

class LnReaderStoreHeaderRow extends LnReaderCatalogRow {
  const LnReaderStoreHeaderRow({
    required this.indexUrl,
    required this.label,
    required this.count,
    required this.expanded,
  });

  final String indexUrl;
  final String label;
  final int count;
  final bool expanded;
}

class LnReaderPluginRow extends LnReaderCatalogRow {
  const LnReaderPluginRow(this.plugin);

  final LnReaderRepoPlugin plugin;
}

/// 把 [plugins]（已按 [visibleLnReaderCatalog] 筛选）按仓库分组：先按 [stores]
/// 的顺序发，再兜底发仓库表里已经没有的孤儿分组（仓库刚被删，条目不能凭空消失）；
/// 收起的仓库只贡献一行表头。组内按公开下载量降序（[sortExtensionsByDownloads]，
/// 没有数据的排最后、同档按名字）。纯函数，便于测试。
List<LnReaderCatalogRow> buildLnReaderGroupedRows({
  required List<LnReaderStore> stores,
  required List<LnReaderRepoPlugin> plugins,
  required bool Function(String indexUrl, int count) expanded,
}) {
  final Map<String, List<LnReaderRepoPlugin>> byStore =
      <String, List<LnReaderRepoPlugin>>{};
  for (final LnReaderRepoPlugin plugin in plugins) {
    byStore
        .putIfAbsent(plugin.storeUrl, () => <LnReaderRepoPlugin>[])
        .add(plugin);
  }
  final List<LnReaderCatalogRow> rows = <LnReaderCatalogRow>[];
  void emit(String indexUrl, String label) {
    final List<LnReaderRepoPlugin>? group = byStore.remove(indexUrl);
    if (group == null || group.isEmpty) return;
    final bool isExpanded = expanded(indexUrl, group.length);
    rows.add(
      LnReaderStoreHeaderRow(
        indexUrl: indexUrl,
        label: label,
        count: group.length,
        expanded: isExpanded,
      ),
    );
    if (!isExpanded) return;
    for (final LnReaderRepoPlugin plugin in sortExtensionsByDownloads(
      group,
      downloads: (LnReaderRepoPlugin plugin) => plugin.downloadCount,
      name: (LnReaderRepoPlugin plugin) => plugin.name,
    )) {
      rows.add(LnReaderPluginRow(plugin));
    }
  }

  for (final LnReaderStore store in stores) {
    emit(store.indexUrl, store.name.isEmpty ? store.indexUrl : store.name);
  }
  for (final String orphan in byStore.keys.toList(growable: false)) {
    emit(orphan, orphan);
  }
  return rows;
}

/// 批量安装 / 一键更新一轮的结果：装上（或更新）几条、跳过几条、插件名 → 失败原因。
typedef LnReaderBulkReport = ({
  int installed,
  int skipped,
  Map<String, String> failed,
});

/// 逐条装 [targets]：每条之前读 [isCancelled]（正在下载的那条跑完才停），正被
/// 单条流程装着的跳过，单条失败只进失败清单、不打断同批其它插件。
Future<LnReaderBulkReport> installLnReaderPlugins(
  LnReaderManager manager,
  List<LnReaderRepoPlugin> targets, {
  required void Function(int done, int total, String name) onProgress,
  required bool Function() isCancelled,
}) async {
  int installed = 0;
  int skipped = 0;
  final Map<String, String> failed = <String, String>{};
  for (int i = 0; i < targets.length; i++) {
    if (isCancelled()) break;
    final LnReaderRepoPlugin plugin = targets[i];
    onProgress(i, targets.length, plugin.name);
    if (manager.isBusy(plugin.id)) {
      skipped++;
      continue;
    }
    try {
      await manager.install(plugin);
      installed++;
    } on Object catch (error) {
      failed[plugin.name] = '$error';
    }
  }
  return (installed: installed, skipped: skipped, failed: failed);
}
