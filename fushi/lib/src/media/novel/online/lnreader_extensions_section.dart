import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/utils.dart';

/// 小说插件（LNReader）的「仓库」段与「扩展」段正文，嵌在书的「导入」视图里。
///
/// 与视频 / 漫画那套 `MihonExtensionsPage(embedded: true)` 同构：顶部一行动作
/// 按钮 → 加载条 → 仓库卡片 / 语言 + 搜索筛选 + 扩展行。扩展行、筛选行直接复用
/// 共享的 [MangaExtensionManagementTile] / [MangaExtensionFilters]，外观逐像素
/// 一致；不复用 Mihon 页面本体是因为那套绑死了 APK 签名 / 信任 / 预览管线，
/// LNReader 插件是纯 JS、一个插件就是一个源，没有这些环节。
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
  }) async {
    final TextEditingController controller = TextEditingController(
      text: initial,
    );
    try {
      return await showAppDialog<String>(
        context: context,
        // 普通 AlertDialog：内含 TextField，`.adaptive` 在 iOS / macOS 主题下渲染成
        // CupertinoAlertDialog、没有 Material 祖先（与 Mihon 输入框同一做法）。
        builder: (BuildContext dialogContext) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (warn) ...<Widget>[
                Text(t.novel_store_add_warning),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const ValueKey<String>('novel_store_url_field'),
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(labelText: t.mihon_store_url),
                onSubmitted: (String value) =>
                    Navigator.pop(dialogContext, value),
              ),
            ],
          ),
          actions: <Widget>[
            adaptiveDialogAction(
              context: dialogContext,
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: dialogContext,
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: Text(title),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

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

  Future<bool> _confirm(String title, String message, String action) async =>
      await showAppDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog.adaptive(
          title: Text(title),
          content: Text(message),
          actions: <Widget>[
            adaptiveDialogAction(
              context: dialogContext,
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: dialogContext,
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

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

  Future<void> _updateAll() async {
    final LnReaderManager manager = widget.manager;
    final List<LnReaderRepoPlugin> targets = manager.available
        .where(manager.hasUpdate)
        .toList(growable: false);
    if (targets.isEmpty) {
      FushiToast.show(msg: t.mihon_extension_update_all_nothing);
      return;
    }
    int updated = 0;
    int failed = 0;
    for (final LnReaderRepoPlugin plugin in targets) {
      try {
        await manager.install(plugin);
        updated++;
      } on Object {
        failed++;
      }
    }
    if (!mounted) return;
    FushiToast.show(
      msg: t.mihon_extension_update_all_done(
        installed: updated,
        skipped: 0,
        failed: failed,
      ),
      severity: failed == 0 ? ToastSeverity.success : ToastSeverity.warning,
    );
  }

  List<Widget> _actions({required bool stores, required bool catalog}) {
    final LnReaderManager manager = widget.manager;
    return <Widget>[
      FushiIconButton(
        tooltip: t.mihon_store_refresh,
        label: t.mihon_store_refresh,
        icon: Icons.refresh,
        onTap: manager.loading
            ? null
            : () => unawaited(manager.refreshStores()),
      ),
      if (catalog)
        FushiIconButton(
          tooltip: t.mihon_extension_update_all,
          label: t.mihon_extension_update_all,
          icon: Icons.system_update_alt,
          onTap: manager.loading ? null : () => unawaited(_updateAll()),
        ),
      if (stores)
        FushiIconButton(
          tooltip: t.mihon_store_add,
          label: t.mihon_store_add,
          icon: Icons.add_link,
          onTap: manager.loading ? null : _addStore,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final bool stores = widget.showStores;
    final bool catalog = widget.showCatalog;
    if (!stores && !catalog) {
      return const SliverMainAxisGroup(slivers: <Widget>[]);
    }
    return SliverMainAxisGroup(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _actions(stores: stores, catalog: catalog),
          ),
        ),
        if (widget.manager.loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            ),
          ),
        if (stores) _buildStores(),
        if (catalog) ..._buildCatalog(),
      ],
    );
  }

  Widget _buildStores() {
    final LnReaderManager manager = widget.manager;
    if (manager.stores.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(t.novel_store_empty, textAlign: TextAlign.center),
        ),
      );
    }
    return SliverList.builder(
      itemCount: manager.stores.length,
      itemBuilder: (BuildContext context, int index) {
        final LnReaderStore store = manager.stores[index];
        final bool builtin = manager.isBuiltinStore(store);
        final int count = manager.available
            .where((LnReaderRepoPlugin p) => p.storeUrl == store.indexUrl)
            .length;
        // 与 Mihon 仓库卡同一判据：刷新中不判「零扩展」，否则每次进页都误报。
        final bool returnedNothing =
            !manager.loading && store.lastError == null && count == 0;
        final String detail = switch ((store.lastError, returnedNothing)) {
          (final String error, _) => '${store.indexUrl}\n$error',
          (null, true) => '${store.indexUrl}\n${t.mihon_store_zero_extensions}',
          (null, false) =>
            '${store.indexUrl}\n${t.mihon_store_extension_count(count: count)}',
        };
        return FushiCard(
          margin: EdgeInsets.only(
            bottom: FushiDesignTokens.of(context).spacing.gap,
          ),
          padding: EdgeInsets.zero,
          child: FushiListItem(
            key: ValueKey<String>('novel_store_${store.indexUrl}'),
            leading: const Icon(Icons.hub_outlined),
            title: Text(
              builtin
                  ? '${store.name} · ${t.novel_store_builtin_label}'
                  : store.name,
            ),
            subtitle: Text(detail),
            trailing: builtin
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        tooltip: t.mihon_store_edit,
                        onPressed: () => unawaited(_editStore(store)),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: t.mihon_store_remove,
                        onPressed: () => unawaited(_removeStore(store)),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
          ),
        );
      },
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
    final List<LnReaderRepoPlugin> visible = visibleLnReaderCatalog(
      manager.available,
      language: _language,
      query: _searchQuery,
      isInstalled: (LnReaderRepoPlugin plugin) =>
          manager.installedById(plugin.id) != null,
    );
    // 已装但仓库目录里已经没有的插件（仓库删了 / 下架了）：仍要能卸载。
    final Set<String> availableIds = manager.available
        .map((LnReaderRepoPlugin plugin) => plugin.id)
        .toSet();
    final List<LnReaderInstalledPlugin> orphans =
        filterByMediaSearch<LnReaderInstalledPlugin>(
          manager.installed
              .where(
                (LnReaderInstalledPlugin plugin) =>
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
          child: MangaExtensionFilters(
            keyPrefix: 'novel_extension',
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
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
      SliverList.builder(
        itemCount: visible.length,
        itemBuilder: (BuildContext context, int index) {
          final LnReaderRepoPlugin plugin = visible[index];
          final LnReaderInstalledPlugin? installed = manager.installedById(
            plugin.id,
          );
          final bool update = manager.hasUpdate(plugin);
          final bool busy = manager.isBusy(plugin.id);
          return MangaExtensionManagementTile(
            key: ValueKey<String>('novel_extension_${plugin.id}'),
            title: plugin.name,
            iconUrl: plugin.iconUrl,
            busy: busy,
            subtitle: Text(
              mangaSourceMetaLine(<String?>[
                plugin.lang,
                update && installed != null
                    ? '${installed.version} → ${plugin.version}'
                    : plugin.version,
                mangaSourceHostLabel(plugin.site),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            enabled: installed?.enabled,
            onEnabledChanged: installed == null
                ? null
                : (bool value) =>
                      unawaited(manager.setEnabled(installed, value)),
            secondaryLabel: installed != null && update
                ? t.mihon_extension_uninstall
                : null,
            onSecondary: installed != null && update
                ? () => unawaited(_uninstall(installed))
                : null,
            primaryLabel: installed == null
                ? t.mihon_extension_install
                : update
                ? t.mihon_extension_update
                : t.mihon_extension_uninstall,
            onPrimary: busy
                ? null
                : installed == null || update
                ? () => unawaited(_install(plugin))
                : () => unawaited(_uninstall(installed)),
          );
        },
      ),
      SliverList.builder(
        itemCount: orphans.length,
        itemBuilder: (BuildContext context, int index) {
          final LnReaderInstalledPlugin plugin = orphans[index];
          return MangaExtensionManagementTile(
            key: ValueKey<String>('novel_extension_local_${plugin.id}'),
            title: plugin.name,
            iconUrl: plugin.iconUrl,
            subtitle: Text(
              mangaSourceMetaLine(<String?>[
                plugin.lang,
                plugin.version,
                mangaSourceHostLabel(plugin.site),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            enabled: plugin.enabled,
            onEnabledChanged: (bool value) =>
                unawaited(manager.setEnabled(plugin, value)),
            primaryLabel: t.mihon_extension_uninstall,
            onPrimary: () => unawaited(_uninstall(plugin)),
          );
        },
      ),
      if (_searchQuery.trim().isNotEmpty && visible.isEmpty && orphans.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text(t.no_search_results)),
          ),
        ),
    ];
  }
}

/// 扩展目录的可见行：语言精确筛选 + 统一归一化搜索；已装的排前面，其余按语言、
/// 名称排。纯函数，便于测试。
List<LnReaderRepoPlugin> visibleLnReaderCatalog(
  List<LnReaderRepoPlugin> available, {
  required String language,
  required String query,
  required bool Function(LnReaderRepoPlugin plugin) isInstalled,
}) {
  final List<LnReaderRepoPlugin> filtered =
      filterByMediaSearch<LnReaderRepoPlugin>(
        available
            .where(
              (LnReaderRepoPlugin plugin) =>
                  language == '*' || plugin.lang == language,
            )
            .toList(growable: false),
        query,
        (LnReaderRepoPlugin plugin) => <String>[
          plugin.name,
          plugin.id,
          plugin.site,
        ],
      );
  return List<LnReaderRepoPlugin>.of(filtered)
    ..sort((LnReaderRepoPlugin a, LnReaderRepoPlugin b) {
      final bool ai = isInstalled(a);
      final bool bi = isInstalled(b);
      if (ai != bi) return ai ? -1 : 1;
      final int lang = a.lang.compareTo(b.lang);
      return lang != 0
          ? lang
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
}
