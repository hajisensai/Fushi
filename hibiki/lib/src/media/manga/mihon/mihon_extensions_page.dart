import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/media_search_text.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';

/// Mihon 扩展仓库与安装管理。
///
/// **没有自己的顶层 tab**：用户口径是「漫画扩展不就是来源吗」，所以它作为
/// `MangaSourcesPage`（漫画库「来源」视图）里的一节存在，用 [embedded] 打开。
/// 独立页形态（[embedded] 为 false）只剩测试和将来可能的 push 路由在用。
///
/// [embedded] 为 true 时：
/// - 不再包 `DesktopContentLayout` / `HibikiPageHeader`（外层已有一套 chrome），
///   页头那三个动作（刷新仓库 / 导入 APK / 添加仓库）降级成本节顶部的按钮行；
/// - 内容体从 `ListView` 换成 `Column`——它被塞进外层 `ListView` 的无界高度里，
///   再嵌一个可滚动的 `ListView` 会直接抛约束异常。
class MihonExtensionsPage extends ConsumerStatefulWidget {
  const MihonExtensionsPage({
    super.key,
    this.navigation,
    this.manager,
    this.embedded = false,
  });

  final Widget? navigation;
  final MihonManager? manager;

  /// 作为「来源」视图的一节内嵌渲染（无 chrome、不自带滚动）。
  final bool embedded;

  @override
  ConsumerState<MihonExtensionsPage> createState() =>
      _MihonExtensionsPageState();
}

class _MihonExtensionsPageState extends ConsumerState<MihonExtensionsPage> {
  MihonManager? _manager;
  String _language = '*';
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MihonManager manager =
        widget.manager ?? ref.read(appProvider).mihonManager;
    if (identical(_manager, manager)) return;
    _manager?.removeListener(_onChanged);
    _manager = manager..addListener(_onChanged);
  }

  @override
  void dispose() {
    _manager?.removeListener(_onChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _addStore() async {
    final TextEditingController controller = TextEditingController();
    final String? url = await showAppDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(t.mihon_store_add),
        content: HibikiTextField(
          controller: controller,
          labelText: t.mihon_store_url,
          hintText: 'https://example.org/repo.json',
          autofocus: true,
        ),
        actions: <Widget>[
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: dialogContext,
            isDefaultAction: true,
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(t.mihon_store_add),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || url == null || url.isEmpty) return;
    bool allowInsecure = false;
    if (Uri.tryParse(url)?.scheme == 'http') {
      allowInsecure = await _confirmInsecureUrl(url);
      if (!allowInsecure) return;
    }
    try {
      await _manager!.addStore(url, allowInsecure: allowInsecure);
    } catch (error) {
      if (mounted) HibikiToast.show(msg: '$error');
    }
  }

  Future<bool> _confirmInsecureUrl(String url) async =>
      await showAppDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog.adaptive(
          title: Text(t.mihon_store_add),
          content: Text('${t.mihon_extension_warning}\n\n$url'),
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
              child: Text(t.dialog_ok),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _importApk() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['apk'],
      allowMultiple: false,
      withData: false,
    );
    final String? path = result?.files.single.path;
    if (!mounted || path == null) return;
    try {
      final MihonInstallProposal proposal =
          await _manager!.prepareLocalInstall(path);
      await _confirmAndInstall(proposal);
    } catch (error) {
      if (mounted) HibikiToast.show(msg: '$error');
    }
  }

  Future<void> _install(MihonAvailableExtension extension) async {
    try {
      final MihonInstallProposal proposal =
          await _manager!.prepareStoreInstall(extension);
      await _confirmAndInstall(proposal);
    } catch (error) {
      if (mounted) HibikiToast.show(msg: '$error');
    }
  }

  Future<void> _confirmAndInstall(MihonInstallProposal proposal) async {
    if (!mounted) return;
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog.adaptive(
        title: Text(t.mihon_signer_trust_title),
        content: SelectableText(
          '${t.mihon_extension_warning}\n\n'
          '${proposal.inspection.name} '
          '${proposal.inspection.versionName}\n'
          '${t.mihon_signer_fingerprint}:\n'
          '${proposal.inspection.signerSha256}',
        ),
        actions: <Widget>[
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: dialogContext,
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              proposal.current == null
                  ? t.mihon_extension_install
                  : t.mihon_extension_update,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _manager!.commitInstall(proposal, trustSigner: true);
    } catch (error) {
      if (mounted) HibikiToast.show(msg: '$error');
    }
  }

  Future<void> _uninstall(MangaExtensionRow extension) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog.adaptive(
        title: Text(t.mihon_extension_uninstall),
        content: Text(extension.name),
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
            child: Text(t.mihon_extension_uninstall),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _manager!.uninstallExtension(extension);
    }
  }

  /// 页头三动作。内嵌时降级成本节顶部的按钮行，能力一个不少。
  List<Widget> _actions(MihonManager manager) => <Widget>[
        HibikiIconButton(
          tooltip: t.mihon_store_refresh,
          label: t.mihon_store_refresh,
          icon: Icons.refresh,
          onTap:
              manager.loading ? null : () => unawaited(manager.refreshStores()),
        ),
        HibikiIconButton(
          tooltip: t.mihon_extension_import,
          label: t.mihon_extension_import,
          icon: Icons.file_open_outlined,
          onTap: manager.loading ? null : _importApk,
        ),
        HibikiIconButton(
          tooltip: t.mihon_store_add,
          label: t.mihon_store_add,
          icon: Icons.add_link,
          onTap: manager.loading ? null : _addStore,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final MihonManager manager =
        _manager ?? widget.manager ?? ref.read(appProvider).mihonManager;
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _actions(manager),
          ),
          if (manager.loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            ),
          _buildContent(manager),
        ],
      );
    }
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context))
            HibikiPageHeader(
              title: t.mihon_extensions_title,
              bottom: widget.navigation,
              actions: _actions(manager),
            ),
          Expanded(
            child: Stack(
              children: <Widget>[
                _buildContent(manager),
                if (manager.loading)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0x22000000),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(MihonManager manager) {
    final Map<String, MangaExtensionRow> installed =
        <String, MangaExtensionRow>{
      for (final MangaExtensionRow row in manager.installed)
        row.packageName: row,
    };
    if (manager.stores.isEmpty && manager.installed.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.extension_outlined, size: 48),
              const SizedBox(height: 12),
              Text(
                t.mihon_store_empty,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: _addStore,
                    icon: const Icon(Icons.add_link),
                    label: Text(t.mihon_store_add),
                  ),
                  OutlinedButton.icon(
                    onPressed: _importApk,
                    icon: const Icon(Icons.file_open_outlined),
                    label: Text(t.mihon_extension_import),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final Set<String> availablePackages = manager.available
        .map((MihonAvailableExtension extension) => extension.packageName)
        .toSet();
    final List<String> languages = manager.available
        .map((MihonAvailableExtension extension) => extension.language)
        .where((String language) =>
            language.isNotEmpty && language.toLowerCase() != 'all')
        .toSet()
        .toList()
      ..sort();
    final List<MihonAvailableExtension> visibleAvailable =
        filterByMediaSearch<MihonAvailableExtension>(
      manager.available
          .where((MihonAvailableExtension extension) =>
              _language == '*' ||
              extension.language == _language ||
              extension.language.toLowerCase() == 'all')
          .toList(growable: false),
      _searchQuery,
      (MihonAvailableExtension extension) => <String>[
        extension.name,
        extension.packageName,
        extension.storeUrl,
        extension.language,
        ...extension.sources.expand(
          (MihonAvailableSource source) => <String>[
            source.name,
            source.baseUrl,
          ],
        ),
      ],
    );
    final List<MangaExtensionRow> localOnly = manager.installed
        .where((MangaExtensionRow row) =>
            !availablePackages.contains(row.packageName))
        .toList(growable: false);
    final List<MangaExtensionRow> visibleLocalOnly =
        filterByMediaSearch<MangaExtensionRow>(
      localOnly,
      _searchQuery,
      (MangaExtensionRow extension) => <String>[
        extension.name,
        extension.packageName,
        extension.language,
      ],
    );
    return _contentContainer(<Widget>[
      for (final MangaExtensionStoreRow store in manager.stores)
        Card(
          child: ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: Text(store.name),
            subtitle: Text(
              store.lastError == null
                  ? store.indexUrl
                  : '${store.indexUrl}\n${store.lastError}',
            ),
            trailing: IconButton(
              tooltip: t.dialog_delete,
              onPressed: () => unawaited(
                manager.removeStore(store.indexUrl),
              ),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
        ),
      if (manager.available.isNotEmpty || manager.installed.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: _buildFilters(languages),
        ),
      const SizedBox(height: 8),
      for (final MihonAvailableExtension extension in visibleAvailable)
        _AvailableExtensionTile(
          extension: extension,
          installed: installed[extension.packageName],
          onInstall: () => unawaited(_install(extension)),
          onUninstall: installed[extension.packageName] == null
              ? null
              : () => unawaited(
                    _uninstall(installed[extension.packageName]!),
                  ),
          onEnabledChanged: installed[extension.packageName] == null
              ? null
              : (bool value) => unawaited(manager.setExtensionEnabled(
                    installed[extension.packageName]!,
                    value,
                  )),
        ),
      for (final MangaExtensionRow extension in visibleLocalOnly)
        _InstalledExtensionTile(
          extension: extension,
          onUninstall: () => unawaited(_uninstall(extension)),
          onEnabledChanged: (bool value) => unawaited(
            manager.setExtensionEnabled(extension, value),
          ),
        ),
      if (_searchQuery.trim().isNotEmpty &&
          visibleAvailable.isEmpty &&
          visibleLocalOnly.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Center(child: Text(t.no_search_results)),
        ),
    ]);
  }

  /// 独立页自带滚动；内嵌时外层 `ListView` 已经在滚了，这里必须是裸 `Column`。
  Widget _contentContainer(List<Widget> children) {
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: children,
    );
  }

  Widget _buildFilters(List<String> languages) {
    final Widget languageFilter = DropdownButtonFormField<String>(
      value: languages.contains(_language) ? _language : '*',
      decoration: InputDecoration(
        labelText: t.mihon_extension_language_filter,
      ),
      items: <DropdownMenuItem<String>>[
        DropdownMenuItem<String>(
          value: '*',
          child: Text(t.mihon_extension_language_all),
        ),
        for (final String language in languages)
          DropdownMenuItem<String>(
            value: language,
            child: Text(language.toUpperCase()),
          ),
      ],
      onChanged: (String? value) {
        setState(() => _language = value ?? '*');
      },
    );
    final Widget searchField = TextField(
      key: const ValueKey<String>('mihon_extension_search_field'),
      controller: _searchController,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: t.search,
        border: const OutlineInputBorder(),
        suffixIcon: _searchQuery.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
              ),
      ),
      onChanged: (String value) => setState(() => _searchQuery = value),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < 700) {
          return Column(
            children: <Widget>[
              languageFilter,
              const SizedBox(height: 12),
              searchField,
            ],
          );
        }
        return Row(
          children: <Widget>[
            Expanded(child: languageFilter),
            const SizedBox(width: 12),
            Expanded(child: searchField),
          ],
        );
      },
    );
  }
}

class _AvailableExtensionTile extends StatelessWidget {
  const _AvailableExtensionTile({
    required this.extension,
    required this.installed,
    required this.onInstall,
    required this.onUninstall,
    required this.onEnabledChanged,
  });

  final MihonAvailableExtension extension;
  final MangaExtensionRow? installed;
  final VoidCallback onInstall;
  final VoidCallback? onUninstall;
  final ValueChanged<bool>? onEnabledChanged;

  @override
  Widget build(BuildContext context) {
    final bool update =
        installed != null && extension.versionCode > installed!.versionCode;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.extension_outlined),
        title: Text(extension.name),
        subtitle: Text(
          '${extension.language} · ${extension.versionName} · '
          'lib ${extension.libVersion}',
        ),
        trailing: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (installed != null)
              Switch.adaptive(
                value: installed!.enabled,
                onChanged: onEnabledChanged,
              ),
            TextButton(
              onPressed: installed == null || update ? onInstall : onUninstall,
              child: Text(
                installed == null
                    ? t.mihon_extension_install
                    : update
                        ? t.mihon_extension_update
                        : t.mihon_extension_uninstall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InstalledExtensionTile extends StatelessWidget {
  const _InstalledExtensionTile({
    required this.extension,
    required this.onUninstall,
    required this.onEnabledChanged,
  });

  final MangaExtensionRow extension;
  final VoidCallback onUninstall;
  final ValueChanged<bool> onEnabledChanged;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: const Icon(Icons.extension_outlined),
          title: Text(extension.name),
          subtitle: Text(
            '${extension.language} · ${extension.versionName} · '
            'lib ${extension.libVersion}',
          ),
          trailing: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Switch.adaptive(
                value: extension.enabled,
                onChanged: onEnabledChanged,
              ),
              TextButton(
                onPressed: onUninstall,
                child: Text(t.mihon_extension_uninstall),
              ),
            ],
          ),
        ),
      );
}
