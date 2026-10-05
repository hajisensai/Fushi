import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_repository_client.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_repository_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_installed_sources_section.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_catalog_view.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_source_row.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart' show MangaOnlineSourceRow;
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';

/// 「浏览」模块里漫画域的在线来源面：扩展仓库 / 扩展目录 / 在线源三节之一
/// （由 [section] 选）。
///
/// 2026-09-27 前这三节是漫画库「导入」视图（`MangaSourcesPage`）的后三段；
/// 按 Mihon 的 Browse 形态（Sources / Extensions）它们搬进顶层「浏览」，导入页只剩
/// 本地来源。代码随之原样迁来——Mihon 与 Aidoku 两套仓库 / 目录的状态都是这里的
/// State，与原页面同一套交互。
///
/// - [OnlineSourcesSection.stores]：Mihon 扩展仓库 + Aidoku 仓库（有宿主时）；
/// - [OnlineSourcesSection.extensions]：可装扩展目录 + 已装扩展启停 / 卸载 +
///   导入本地 APK / `.aix`；
/// - [OnlineSourcesSection.sources]：内置 mokuro.moe 与扩展提供的源并列（启停 /
///   排序 / 偏好 / 清数据 / 置顶，[MihonInstalledSourcesSection]）；点已启用的
///   行进该源的浏览页，与小说 / 视频域同一交互。
///
/// 🔴 mokuro.moe 归「在线源」（BUG-1431）：它是个网站，不是本地扫描根。
///
/// 🔴 滚动容器必须是 [CustomScrollView]（BUG-1441）：扩展目录要渲染整个扩展仓库
/// （keiyoushi 有 1900+ 条），只有 sliver 才能懒建。
///
/// 平台差异只在**内容**：没有 Mihon 扩展宿主的平台渲染不可用提示。
/// `AppModel.mihonManager` 在这些平台会抛 [UnsupportedError]，故一切读它的路径
/// 都必须先过 [MihonRuntimeFactory.isSupported]。iOS 上整个「浏览」模块不存在
/// （[StoreRestrictedCapability.onlineMangaSource]），这里再判一次只是纵深防御。
class MangaOnlineSourcesView extends ConsumerStatefulWidget {
  const MangaOnlineSourcesView({required this.section, super.key});

  /// 渲染哪一节。
  final OnlineSourcesSection section;

  @override
  ConsumerState<MangaOnlineSourcesView> createState() =>
      _MangaOnlineSourcesViewState();
}

class _MangaOnlineSourcesViewState
    extends ConsumerState<MangaOnlineSourcesView> {
  MihonManager? _manager;
  AidokuPackageStore? _aidokuStore;
  AidokuRepositoryStore? _aidokuRepositoryStore;
  late final AidokuRepositoryClient _aidokuRepositoryClient;
  List<AidokuInstalledPackage>? _aidokuPackages;
  List<AidokuSavedRepository>? _aidokuRepositories;
  List<AidokuRepositoryIndex> _aidokuIndexes = const <AidokuRepositoryIndex>[];
  final TextEditingController _aidokuSearchController = TextEditingController();

  String _aidokuLanguage = '*';
  String _aidokuSearchQuery = '';
  String? _aidokuInstallingSourceId;
  Object? _aidokuError;
  bool _aidokuBusy = false;

  @override
  void initState() {
    super.initState();
    _aidokuRepositoryClient = AidokuRepositoryClient();
    if (AidokuRuntimeFactory.isSupported) {
      unawaited(_initializeAidokuStore());
    }
  }

  Future<void> _initializeAidokuStore() async {
    try {
      final AidokuPackageStore store = await AidokuPackageStore.open();
      final AidokuRepositoryStore repositoryStore =
          await AidokuRepositoryStore.open();
      final List<AidokuInstalledPackage> packages = await store.listInstalled();
      final List<AidokuSavedRepository> repositories = await repositoryStore
          .list();
      if (!mounted) return;
      setState(() {
        _aidokuStore = store;
        _aidokuRepositoryStore = repositoryStore;
        _aidokuPackages = packages;
        _aidokuRepositories = repositories;
        _aidokuError = null;
      });
      unawaited(_refreshAidokuRepositories());
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('Aidoku.repositories.load', error, stack);
      if (!mounted) return;
      setState(() => _aidokuError = error);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MihonRuntimeFactory.isSupported) return;
    final MihonManager manager = ref.read(appProvider).mihonManager;
    if (identical(manager, _manager)) return;
    _manager?.removeListener(_changed);
    _manager = manager..addListener(_changed);
  }

  @override
  void dispose() {
    _manager?.removeListener(_changed);
    _aidokuRepositoryClient.close();
    _aidokuSearchController.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// 点已启用的漫画源进它的浏览页（热门 / 最新 / 搜索），与小说 / 视频源同一
  /// 交互：来源页签的一行就是进源的入口，不必绕到「发现」。
  void _openMihonSource(MangaOnlineSourceRow source) {
    final MihonManager? manager = _manager;
    if (manager == null) return;
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MihonSourceBrowsePage(
          manager: manager,
          target: MihonInstalledTarget(source),
        ),
      ),
    );
  }

  /// 点内置的 mokuro.moe 行进它的目录（与漫画发现页的入口同一个视图）。
  void _openMokuro() {
    final AppModel appModel = ref.read(appProvider);
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => FushiPageScaffold(
          title: t.mihon_source_browse_mokuro,
          body: MokuroMoeCatalogView(db: appModel.database, embedded: true),
        ),
      ),
    );
  }

  Future<void> _importAidoku() async {
    if (!AidokuRuntimeFactory.isSupported || _aidokuBusy) return;
    final bool acceptedRisk = await showFushiConfirmDialog(
      context: context,
      title: t.aidoku_extension_import,
      message: t.aidoku_extension_warning,
      confirmLabel: t.dialog_select,
    );
    if (!acceptedRisk || !mounted) return;

    final String? path = await pickSystemFilePath(
      context: context,
      allowedExtensions: const <String>{'aix'},
    );
    if (!mounted || path == null) return;

    setState(() {
      _aidokuBusy = true;
      _aidokuError = null;
    });
    try {
      final AidokuRuntime runtime = AidokuRuntimeFactory.create();
      final AidokuPackageInspection inspection = await runtime.inspect(path);
      if (!mounted) return;
      if (inspection.requiresWebView) {
        throw AidokuRuntimeException(
          'WEBVIEW_REQUIRED',
          t.aidoku_webview_unsupported,
        );
      }
      final Map<String, Object?> info = inspection.sourceInfo;
      final bool confirmed = await showFushiConfirmDialog(
        context: context,
        title: t.aidoku_extension_confirm_title,
        message:
            '${info['name']}\n${info['id']}\n'
            '${t.aidoku_extension_version}: ${info['version']}',
        confirmLabel: t.dialog_import,
      );
      if (!confirmed || !mounted) return;
      final AidokuPackageStore store =
          _aidokuStore ?? await AidokuPackageStore.open();
      _aidokuStore = store;
      final AidokuInstalledPackage installed = await store.install(
        File(path),
        inspection,
      );
      final List<AidokuInstalledPackage> packages = await store.listInstalled();
      if (!mounted) return;
      setState(() => _aidokuPackages = packages);
      FushiToast.show(
        msg: '${t.aidoku_extension_imported}: ${installed.name}',
        severity: ToastSeverity.success,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('Aidoku.install.local', error, stack);
      if (mounted) {
        // 2026-10 体验优化：错误已在行内画出，不再叠同文 toast。
        setState(() => _aidokuError = error);
      }
    } finally {
      if (mounted) setState(() => _aidokuBusy = false);
    }
  }

  Future<void> _addAidokuRepository() async {
    if (!AidokuRuntimeFactory.isSupported || _aidokuBusy) return;
    final String? repositoryUrl = await showAppDialog<String>(
      context: context,
      builder: (BuildContext context) => const _AidokuRepositoryUrlDialog(),
    );
    if (repositoryUrl == null || !mounted) return;
    setState(() {
      _aidokuBusy = true;
      _aidokuError = null;
    });
    try {
      final AidokuRepositoryIndex index = await _aidokuRepositoryClient.fetch(
        repositoryUrl,
      );
      final AidokuRepositoryStore repositoryStore =
          _aidokuRepositoryStore ?? await AidokuRepositoryStore.open();
      _aidokuRepositoryStore = repositoryStore;
      final List<AidokuSavedRepository> repositories = await repositoryStore
          .add(index);
      if (!mounted) return;
      setState(() {
        _aidokuRepositories = repositories;
        _upsertAidokuIndex(index);
      });
      FushiToast.show(
        msg: '${t.aidoku_repository_added}: ${index.name}',
        severity: ToastSeverity.success,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'Aidoku.repository.add[$repositoryUrl]',
        error,
        stack,
      );
      if (mounted) {
        // 2026-10 体验优化：错误已在行内画出，不再叠同文 toast。
        setState(() => _aidokuError = error);
      }
    } finally {
      if (mounted) setState(() => _aidokuBusy = false);
    }
  }

  Future<void> _browseAidokuRepository(AidokuSavedRepository repository) async {
    if (_aidokuBusy) return;
    setState(() {
      _aidokuBusy = true;
      _aidokuError = null;
    });
    try {
      final AidokuRepositoryIndex index = await _aidokuRepositoryClient.fetch(
        repository.indexUrl,
      );
      if (!mounted) return;
      setState(() => _upsertAidokuIndex(index));
      await _showAidokuRepository(index);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'Aidoku.repository.browse[${repository.indexUrl}]',
        error,
        stack,
      );
      if (mounted) {
        // 2026-10 体验优化：错误已在行内画出，不再叠同文 toast。
        setState(() => _aidokuError = error);
      }
    } finally {
      if (mounted) setState(() => _aidokuBusy = false);
    }
  }

  void _upsertAidokuIndex(AidokuRepositoryIndex index) {
    _aidokuIndexes = <AidokuRepositoryIndex>[
      for (final AidokuRepositoryIndex current in _aidokuIndexes)
        if (current.indexUri != index.indexUri) current,
      index,
    ];
  }

  Future<void> _refreshAidokuRepositories() async {
    final List<AidokuSavedRepository> repositories =
        _aidokuRepositories ?? const <AidokuSavedRepository>[];
    if (repositories.isEmpty || _aidokuBusy) return;
    setState(() {
      _aidokuBusy = true;
      _aidokuError = null;
    });
    try {
      final List<AidokuRepositoryIndex> indexes =
          await Future.wait<AidokuRepositoryIndex>(
            repositories.map(
              (AidokuSavedRepository repository) =>
                  _aidokuRepositoryClient.fetch(repository.indexUrl),
            ),
          );
      if (mounted) setState(() => _aidokuIndexes = indexes);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('Aidoku.repositories.fetch', error, stack);
      if (mounted) setState(() => _aidokuError = error);
    } finally {
      if (mounted) setState(() => _aidokuBusy = false);
    }
  }

  Future<void> _showAidokuRepository(AidokuRepositoryIndex index) async {
    final AidokuPackageStore packageStore =
        _aidokuStore ?? await AidokuPackageStore.open();
    _aidokuStore = packageStore;
    final List<AidokuInstalledPackage> installed = await packageStore
        .listInstalled();
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => _AidokuRepositorySourcesDialog(
        index: index,
        client: _aidokuRepositoryClient,
        packageStore: packageStore,
        installed: installed,
        onInstalled: _reloadAidokuPackages,
      ),
    );
  }

  Future<void> _reloadAidokuPackages() async {
    final AidokuPackageStore? store = _aidokuStore;
    if (store == null) return;
    final List<AidokuInstalledPackage> packages = await store.listInstalled();
    if (mounted) setState(() => _aidokuPackages = packages);
  }

  Future<void> _removeAidokuRepository(AidokuSavedRepository repository) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.aidoku_repository_remove,
      message: '${repository.name}\n${repository.indexUrl}',
      icon: Icons.delete_outline,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      final List<AidokuSavedRepository> repositories =
          await _aidokuRepositoryStore!.remove(repository);
      if (mounted) {
        setState(() {
          _aidokuRepositories = repositories;
          _aidokuIndexes = _aidokuIndexes
              .where(
                (AidokuRepositoryIndex index) =>
                    index.indexUri.toString() != repository.indexUrl,
              )
              .toList(growable: false);
        });
      }
    } on Object catch (error) {
      if (mounted) {
        FushiToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    }
  }

  Future<void> _removeAidoku(AidokuInstalledPackage package) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.aidoku_extension_remove,
      message: package.name,
      icon: Icons.delete_outline,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await _aidokuStore!.remove(package);
      final List<AidokuInstalledPackage> packages = await _aidokuStore!
          .listInstalled();
      if (mounted) setState(() => _aidokuPackages = packages);
    } on Object catch (error) {
      if (mounted) {
        FushiToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    }
  }

  Future<void> _setAidokuEnabled(
    AidokuInstalledPackage package,
    bool enabled,
  ) async {
    final AidokuPackageStore? store = _aidokuStore;
    if (store == null) return;
    try {
      await store.setEnabled(package, enabled);
      final List<AidokuInstalledPackage> packages = await store.listInstalled();
      if (mounted) setState(() => _aidokuPackages = packages);
    } on Object catch (error) {
      if (mounted) {
        FushiToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    }
  }

  Future<void> _installAidokuSource(AidokuRepositorySource source) async {
    if (_aidokuInstallingSourceId != null) return;
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: '${t.aidoku_repository_install}: ${source.name}',
      message: t.aidoku_extension_warning,
      confirmLabel: t.dialog_import,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _aidokuInstallingSourceId = source.id;
      _aidokuError = null;
    });
    Directory? temporaryDirectory;
    try {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'fushi-aidoku-repository-',
      );
      final File downloaded = await _aidokuRepositoryClient.download(
        source,
        File('${temporaryDirectory.path}/source.aix'),
      );
      final AidokuPackageInspection inspection =
          await AidokuRuntimeFactory.create().inspect(downloaded.path);
      final Map<String, Object?> info = inspection.sourceInfo;
      if (info['id']?.toString() != source.id ||
          (info['version'] as num?)?.toInt() != source.version) {
        throw AidokuRepositoryException(
          'PACKAGE_MISMATCH',
          t.aidoku_repository_identity_mismatch,
        );
      }
      if (inspection.requiresWebView) {
        throw AidokuRuntimeException(
          'WEBVIEW_REQUIRED',
          t.aidoku_webview_unsupported,
        );
      }
      final AidokuPackageStore store =
          _aidokuStore ?? await AidokuPackageStore.open();
      _aidokuStore = store;
      final AidokuInstalledPackage installed = await store.install(
        downloaded,
        inspection,
      );
      await _reloadAidokuPackages();
      FushiToast.show(
        msg: '${t.aidoku_extension_imported}: ${installed.name}',
        severity: ToastSeverity.success,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'Aidoku.install.repository[${source.id}]',
        error,
        stack,
      );
      if (mounted) {
        // 2026-10 体验优化：错误已在行内画出，不再叠同文 toast。
        setState(() => _aidokuError = error);
      }
    } finally {
      if (temporaryDirectory != null && await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
      if (mounted) setState(() => _aidokuInstallingSourceId = null);
    }
  }

  Widget _sectionTitle(String title) =>
      Text(title, style: Theme.of(context).textTheme.titleLarge);

  /// 扩展宿主不可用时统一的占位（iOS）。结构不变，只是这一节没内容。
  Widget _unavailableNote() => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(t.mihon_runtime_unavailable, textAlign: TextAlign.center),
  );

  /// Aidoku 仓库管理（「仓库」段）：刷新 / 添加仓库 + 已保存仓库卡。
  Widget _buildAidokuRepositories() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FushiIconButton(
              tooltip: t.mihon_store_refresh,
              label: t.mihon_store_refresh,
              icon: Icons.refresh,
              onTap: _aidokuBusy ? null : _refreshAidokuRepositories,
            ),
            FushiIconButton(
              key: const ValueKey<String>('aidoku_add_repository'),
              tooltip: t.aidoku_repository_add,
              label: t.aidoku_repository_add,
              icon: Icons.cloud_download_outlined,
              onTap: _aidokuBusy ? null : _addAidokuRepository,
            ),
          ],
        ),
        ..._aidokuStatusRows(),
        const SizedBox(height: 8),
        if (_aidokuRepositories?.isEmpty == true)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(t.aidoku_repository_empty),
          ),
        for (final AidokuSavedRepository repository
            in _aidokuRepositories ?? const <AidokuSavedRepository>[])
          FushiCard(
            margin: EdgeInsets.only(bottom: tokens.spacing.gap),
            padding: EdgeInsets.zero,
            child: FushiListItem(
              leading: const FushiIcon(Icons.cloud_outlined),
              title: Text(repository.name),
              subtitle: Text(mangaSourceHostLabel(repository.indexUrl)),
              trailing: Wrap(
                children: <Widget>[
                  FushiIconButtonControl(
                    tooltip: t.aidoku_repository_browse,
                    onPressed: _aidokuBusy
                        ? null
                        : () => unawaited(_browseAidokuRepository(repository)),
                    icon: const FushiIcon(Icons.view_list_outlined),
                  ),
                  FushiIconButtonControl(
                    tooltip: t.aidoku_repository_remove,
                    onPressed: _aidokuBusy
                        ? null
                        : () => unawaited(_removeAidokuRepository(repository)),
                    icon: const FushiIcon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Aidoku 的忙碌进度条与错误行：仓库段与目录段都要显示（busy 是共享状态）。
  List<Widget> _aidokuStatusRows() => <Widget>[
    if (_aidokuBusy || (_aidokuPackages == null && _aidokuError == null))
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: FushiLinearProgressIndicator(),
      ),
    if (_aidokuError != null)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          describeOnlineSourceError(_aidokuError!),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
  ];

  /// Aidoku 扩展目录（「扩展」段）：刷新 / 导入 `.aix` + 筛选 + 可装 / 已装条目。
  Widget _buildAidokuCatalog() {
    final Map<String, AidokuRepositorySource> availableById =
        <String, AidokuRepositorySource>{};
    for (final AidokuRepositoryIndex index in _aidokuIndexes) {
      for (final AidokuRepositorySource source in index.sources) {
        final AidokuRepositorySource? previous = availableById[source.id];
        if (previous == null || previous.version < source.version) {
          availableById[source.id] = source;
        }
      }
    }
    final List<AidokuRepositorySource> available = availableById.values.toList()
      ..sort(
        (AidokuRepositorySource a, AidokuRepositorySource b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    final Map<String, AidokuInstalledPackage> installed =
        <String, AidokuInstalledPackage>{
          for (final AidokuInstalledPackage package
              in _aidokuPackages ?? const <AidokuInstalledPackage>[])
            package.id: package,
        };
    final List<String> languages =
        available
            .expand((AidokuRepositorySource source) => source.languages)
            .map((String language) => language.toLowerCase())
            .where((String language) => language.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final String query = _aidokuSearchQuery.trim().toLowerCase();
    bool matchesLanguage(List<String> values) =>
        _aidokuLanguage == '*' ||
        values.any(
          (String language) => language.toLowerCase() == _aidokuLanguage,
        );
    bool matchesSearch(Iterable<String?> values) =>
        query.isEmpty ||
        values.any(
          (String? value) => value?.toLowerCase().contains(query) ?? false,
        );
    final List<AidokuRepositorySource> visibleAvailable = available
        .where(
          (AidokuRepositorySource source) =>
              matchesLanguage(source.languages) &&
              matchesSearch(<String?>[source.name, source.id, source.baseUrl]),
        )
        .toList(growable: false);
    final List<AidokuInstalledPackage> visibleLocalOnly = installed.values
        .where(
          (AidokuInstalledPackage package) =>
              !availableById.containsKey(package.id) &&
              matchesLanguage(package.languages) &&
              matchesSearch(<String?>[package.name, package.id]),
        )
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FushiIconButton(
              tooltip: t.mihon_store_refresh,
              label: t.mihon_store_refresh,
              icon: Icons.refresh,
              onTap: _aidokuBusy ? null : _refreshAidokuRepositories,
            ),
            FushiIconButton(
              key: const ValueKey<String>('aidoku_import_aix'),
              tooltip: t.aidoku_extension_import,
              label: t.aidoku_extension_import,
              icon: Icons.file_open_outlined,
              onTap: _aidokuBusy ? null : _importAidoku,
            ),
          ],
        ),
        ..._aidokuStatusRows(),
        if (available.isNotEmpty || installed.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          MangaExtensionFilters(
            keyPrefix: 'aidoku_extension',
            languages: languages,
            selectedLanguage: _aidokuLanguage,
            languageLabel: t.mihon_extension_language_filter,
            allLanguagesLabel: t.mihon_extension_language_all,
            searchHint: t.search,
            searchController: _aidokuSearchController,
            searchQuery: _aidokuSearchQuery,
            onLanguageChanged: (String value) =>
                setState(() => _aidokuLanguage = value),
            onSearchChanged: (String value) =>
                setState(() => _aidokuSearchQuery = value),
            onSearchCleared: () {
              _aidokuSearchController.clear();
              setState(() => _aidokuSearchQuery = '');
            },
          ),
          const SizedBox(height: 8),
        ],
        for (final AidokuRepositorySource source in visibleAvailable)
          Builder(
            builder: (BuildContext context) {
              final AidokuInstalledPackage? package = installed[source.id];
              final bool update =
                  package != null && package.version < source.version;
              return MangaExtensionManagementTile(
                title: source.name,
                iconUrl: source.iconUri?.toString(),
                contentWarning: (source.contentRating ?? 0) >= 3,
                busy: _aidokuInstallingSourceId == source.id,
                subtitle: Text(
                  mangaSourceMetaLine(<String?>[
                    source.languages.join(', ').toUpperCase(),
                    '${t.aidoku_extension_version} ${source.version}',
                    mangaSourceHostLabel(source.baseUrl ?? source.id),
                  ]),
                ),
                enabled: package?.enabled,
                onEnabledChanged: package == null
                    ? null
                    : (bool value) =>
                          unawaited(_setAidokuEnabled(package, value)),
                primaryLabel: package == null
                    ? t.aidoku_repository_install
                    : update
                    ? t.aidoku_repository_update
                    // 2026-10 体验优化：行内按钮与 Mihon / LNReader 同叫「卸载」，
                    // 长文案「移除 Aidoku 扩展」只留给确认框标题。
                    : t.mihon_extension_uninstall,
                onPrimary: _aidokuInstallingSourceId != null
                    ? null
                    : package == null || update
                    ? () => unawaited(_installAidokuSource(source))
                    : () => unawaited(_removeAidoku(package)),
              );
            },
          ),
        for (final AidokuInstalledPackage package in visibleLocalOnly)
          MangaExtensionManagementTile(
            title: package.name,
            subtitle: Text(
              mangaSourceMetaLine(<String?>[
                package.languages.join(', ').toUpperCase(),
                '${t.aidoku_extension_version} ${package.version}',
                mangaSourceHostLabel(package.id),
              ]),
            ),
            enabled: package.enabled,
            onEnabledChanged: (bool value) =>
                unawaited(_setAidokuEnabled(package, value)),
            primaryLabel: t.mihon_extension_uninstall,
            onPrimary: () => unawaited(_removeAidoku(package)),
          ),
        if (available.isEmpty && installed.isEmpty && !_aidokuBusy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(t.aidoku_extension_empty),
          ),
        if (query.isNotEmpty &&
            visibleAvailable.isEmpty &&
            visibleLocalOnly.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text(t.no_search_results)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final MihonManager? manager = _manager;
    final bool onlineSourcesAvailable =
        StoreRestrictedCapability.onlineMangaSource.isAvailable;
    // Aidoku 与 Mihon 共用「仓库」「扩展」两节时各带一行小标题分开；没有
    // Aidoku 宿主的构建整节不挂，也就不需要小标题。
    final bool aidoku =
        onlineSourcesAvailable && AidokuRuntimeFactory.isSupported;
    final OnlineSourcesSection section = widget.section;
    final List<Widget> slivers = <Widget>[
      if (aidoku && section != OnlineSourcesSection.sources)
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _sectionTitle(t.aidoku_extensions_title),
              const SizedBox(height: 8),
              if (section == OnlineSourcesSection.stores)
                _buildAidokuRepositories()
              else
                _buildAidokuCatalog(),
              const SizedBox(height: 28),
              _sectionTitle(t.mihon_extensions_title),
              const SizedBox(height: 8),
            ],
          ),
        ),
      if (section == OnlineSourcesSection.sources)
        if (onlineSourcesAvailable && manager != null)
          MihonInstalledSourcesSection(
            key: const ValueKey<String>('manga_mihon_sources'),
            manager: manager,
            // 内置在线源与扩展提供的源同节同级：mokuro.moe 是个网站，不是本地
            // 扫描根（BUG-1431）。
            leading: <Widget>[
              MokuroMoeSourceRow(onOpen: _openMokuro),
              const SizedBox(height: 8),
            ],
            onOpenSource: _openMihonSource,
          )
        else if (onlineSourcesAvailable)
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                MokuroMoeSourceRow(onOpen: _openMokuro),
                const SizedBox(height: 8),
                _unavailableNote(),
              ],
            ),
          )
        else
          const SliverToBoxAdapter(child: SizedBox.shrink())
      else if (onlineSourcesAvailable && manager != null)
        MihonExtensionsPage(
          key: ValueKey<String>('manga_mihon_extensions_${section.name}'),
          embedded: true,
          sections: <MihonExtensionsSection>[
            if (section == OnlineSourcesSection.stores)
              MihonExtensionsSection.stores
            else
              MihonExtensionsSection.catalog,
          ],
        )
      else if (onlineSourcesAvailable)
        SliverToBoxAdapter(child: _unavailableNote()),
    ];
    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverMainAxisGroup(slivers: slivers),
        ),
      ],
    );
  }
}

class _AidokuRepositoryUrlDialog extends StatefulWidget {
  const _AidokuRepositoryUrlDialog();

  @override
  State<_AidokuRepositoryUrlDialog> createState() =>
      _AidokuRepositoryUrlDialogState();
}

class _AidokuRepositoryUrlDialogState
    extends State<_AidokuRepositoryUrlDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: 'https://aidoku-community.github.io/sources/index.min.json',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _controller.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => FushiAlertDialog(
    title: Text(t.aidoku_repository_add),
    content: SizedBox(
      width: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.aidoku_repository_hint),
          const SizedBox(height: 12),
          FushiTextFieldControl(
            key: const ValueKey<String>('aidoku_repository_url'),
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: t.aidoku_repository_url,
              prefixIcon: const FushiIcon(Icons.link),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
    ),
    actions: <Widget>[
      adaptiveDialogAction(
        context: context,
        onPressed: () => Navigator.pop(context),
        child: Text(t.dialog_cancel),
      ),
      adaptiveDialogAction(
        context: context,
        isDefaultAction: true,
        onPressed: _submit,
        child: Text(t.dialog_add),
      ),
    ],
  );
}

class _AidokuRepositorySourcesDialog extends StatefulWidget {
  const _AidokuRepositorySourcesDialog({
    required this.index,
    required this.client,
    required this.packageStore,
    required this.installed,
    required this.onInstalled,
  });

  final AidokuRepositoryIndex index;
  final AidokuRepositoryClient client;
  final AidokuPackageStore packageStore;
  final List<AidokuInstalledPackage> installed;
  final Future<void> Function() onInstalled;

  @override
  State<_AidokuRepositorySourcesDialog> createState() =>
      _AidokuRepositorySourcesDialogState();
}

class _AidokuRepositorySourcesDialogState
    extends State<_AidokuRepositorySourcesDialog> {
  late final Map<String, AidokuInstalledPackage> _installed =
      <String, AidokuInstalledPackage>{
        for (final AidokuInstalledPackage package in widget.installed)
          package.id: package,
      };
  String _query = '';
  String? _installingSourceId;
  Object? _error;

  List<AidokuRepositorySource> get _visibleSources {
    final String query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.index.sources;
    return widget.index.sources
        .where(
          (AidokuRepositorySource source) =>
              source.name.toLowerCase().contains(query) ||
              source.id.toLowerCase().contains(query) ||
              source.languages.any(
                (String language) => language.toLowerCase().contains(query),
              ),
        )
        .toList(growable: false);
  }

  Future<void> _install(AidokuRepositorySource source) async {
    if (_installingSourceId != null) return;
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: '${t.aidoku_repository_install}: ${source.name}',
      message: t.aidoku_extension_warning,
      confirmLabel: t.dialog_import,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _installingSourceId = source.id;
      _error = null;
    });
    Directory? temporaryDirectory;
    try {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'fushi-aidoku-repository-',
      );
      final File downloaded = await widget.client.download(
        source,
        File('${temporaryDirectory.path}/source.aix'),
      );
      final AidokuPackageInspection inspection =
          await AidokuRuntimeFactory.create().inspect(downloaded.path);
      final Map<String, Object?> info = inspection.sourceInfo;
      if (info['id']?.toString() != source.id ||
          (info['version'] as num?)?.toInt() != source.version) {
        throw AidokuRepositoryException(
          'PACKAGE_MISMATCH',
          t.aidoku_repository_identity_mismatch,
        );
      }
      if (inspection.requiresWebView) {
        throw AidokuRuntimeException(
          'WEBVIEW_REQUIRED',
          t.aidoku_webview_unsupported,
        );
      }
      final AidokuInstalledPackage installed = await widget.packageStore
          .install(downloaded, inspection);
      if (!mounted) return;
      setState(() => _installed[installed.id] = installed);
      await widget.onInstalled();
      FushiToast.show(
        msg: '${t.aidoku_extension_imported}: ${installed.name}',
        severity: ToastSeverity.success,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'Aidoku.install.dialog[${source.id}]',
        error,
        stack,
      );
      if (mounted) {
        // 2026-10 体验优化：错误已在行内画出，不再叠同文 toast。
        setState(() => _error = error);
      }
    } finally {
      if (temporaryDirectory != null && await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
      if (mounted) setState(() => _installingSourceId = null);
    }
  }

  Future<void> _setEnabled(AidokuInstalledPackage package, bool enabled) async {
    try {
      final AidokuInstalledPackage updated = await widget.packageStore
          .setEnabled(package, enabled);
      if (!mounted) return;
      setState(() => _installed[updated.id] = updated);
      await widget.onInstalled();
    } on Object catch (error) {
      if (mounted) {
        // 2026-10 体验优化：错误已在行内画出，不再叠同文 toast。
        setState(() => _error = error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<AidokuRepositorySource> sources = _visibleSources;
    return FushiAlertDialog(
      title: Text('${widget.index.name} · ${t.aidoku_repository_sources}'),
      content: SizedBox(
        width: 760,
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiSearchBar(
              fieldKey: const ValueKey<String>('aidoku_repository_search'),
              hintText: t.aidoku_repository_search,
              onQueryChanged: (String value) => setState(() => _query = value),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  describeOnlineSourceError(_error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: sources.isEmpty
                  ? Center(child: Text(t.mihon_source_no_results))
                  : ListView.builder(
                      itemCount: sources.length,
                      itemBuilder: (BuildContext context, int index) {
                        final AidokuRepositorySource source = sources[index];
                        final AidokuInstalledPackage? installed =
                            _installed[source.id];
                        final bool isInstalling =
                            _installingSourceId == source.id;
                        final bool isCurrent =
                            installed != null &&
                            installed.version >= source.version;
                        final String actionLabel = isCurrent
                            ? t.aidoku_repository_installed
                            : installed == null
                            ? t.aidoku_repository_install
                            : t.aidoku_repository_update;
                        final List<String> metadata = <String>[
                          source.languages.join(', ').toUpperCase(),
                          '${t.aidoku_extension_version} ${source.version}',
                          if (source.minimumAppVersion != null)
                            'Aidoku ${source.minimumAppVersion}+',
                        ];
                        return MangaExtensionManagementTile(
                          title: source.name,
                          iconUrl: source.iconUri?.toString(),
                          contentWarning: (source.contentRating ?? 0) >= 3,
                          subtitle: Text(
                            mangaSourceMetaLine(<String?>[
                              ...metadata,
                              mangaSourceHostLabel(source.id),
                            ]),
                          ),
                          busy: isInstalling,
                          enabled: installed?.enabled,
                          onEnabledChanged: installed == null
                              ? null
                              : (bool value) =>
                                    unawaited(_setEnabled(installed, value)),
                          primaryLabel: actionLabel,
                          onPrimary: isCurrent || _installingSourceId != null
                              ? null
                              : () => unawaited(_install(source)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: _installingSourceId == null
              ? () => Navigator.pop(context)
              : null,
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}
