import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_source_browse_page.dart';
import 'package:fushi/src/media/manga/manga_global_search_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_enabled_sources.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_catalog_view.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_source_row.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

/// 漫画库「浏览」视图：可浏览内容的**在线来源清单**。
///
/// 内置的 mokuro.moe 目录在第一行；已启用的 Mihon 在线来源与它**并列**排在
/// 后面（用户口径：扩展来的在线源不另开 tab，与 mokuro.moe 同处「浏览」）。
///
/// mokuro.moe 与扩展源遵守**同一条**可见性规则（BUG-1431）：在「来源」视图里被
/// 关掉的源不出现在这里。此前 mokuro.moe 那个开关只让它的目录页显示成禁用态，
/// 行却照旧列着——同一节里两种开关语义，用户没法解释。
///
/// 平台差异只体现在**内容**上，不体现在结构上：Mihon 仍只在桌面平台提供宿主，
/// Aidoku 则在 macOS / iOS 共用同一套入口与浏览界面。Linux 没有扩展宿主时，
/// 这一页仍然存在、仍然在同一个 tab 位置，只显示内置来源。注意
/// `AppModel.mihonManager` 在不支持的平台上会抛 [UnsupportedError]，所以任何
/// 读它的路径都必须先过 [MihonRuntimeFactory.isSupported] 这道门。
class MangaBrowsePage extends ConsumerStatefulWidget {
  const MangaBrowsePage({
    super.key,
    this.navigation,
  });

  /// 库页视图导航条（由 `MediaLibraryShell` 传入，作为页头主内容）。
  final Widget? navigation;

  @override
  ConsumerState<MangaBrowsePage> createState() => _MangaBrowsePageState();
}

class _MangaBrowsePageState extends ConsumerState<MangaBrowsePage> {
  MihonManager? _manager;
  StreamSubscription<void>? _aidokuChanges;
  List<AidokuInstalledPackage> _aidokuPackages =
      const <AidokuInstalledPackage>[];
  Object? _aidokuError;

  @override
  void initState() {
    super.initState();
    if (AidokuRuntimeFactory.isSupported) {
      _aidokuChanges = AidokuPackageStore.changes.listen((_) => _loadAidoku());
      unawaited(_loadAidoku());
    }
  }

  Future<void> _loadAidoku() async {
    try {
      final List<AidokuInstalledPackage> packages =
          await (await AidokuPackageStore.open()).listInstalled();
      if (!mounted) return;
      setState(() {
        _aidokuPackages = packages;
        _aidokuError = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _aidokuError = error);
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
    unawaited(_aidokuChanges?.cancel());
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _openMokuro() {
    final AppModel appModel = ref.read(appProvider);
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => FushiPageScaffold(
          title: t.mihon_source_browse_mokuro,
          body: MokuroMoeCatalogView(
            db: appModel.database,
            embedded: true,
          ),
        ),
      ),
    );
  }

  void _openSource(MangaOnlineSourceRow source) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MihonSourceBrowsePage(
          manager: _manager!,
          target: MihonInstalledTarget(source),
        ),
      ),
    );
  }

  void _openAidokuSource(AidokuInstalledPackage package) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) =>
            AidokuSourceBrowsePage(package: package),
      ),
    );
  }

  /// 一次跨所有已启用来源搜索。传入当前平台上「已启用」的两类源，页面不自己发现。
  void _openGlobalSearch() {
    final List<AidokuInstalledPackage> aidokuPackages = _aidokuPackages
        .where((AidokuInstalledPackage package) => package.enabled)
        .toList(growable: false);
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MangaGlobalSearchPage(
          mihonManager: _manager,
          mihonSources: _enabledSources(),
          aidokuPackages: aidokuPackages,
        ),
      ),
    );
  }

  /// 至少有一个可搜索的来源时才提供全局搜索入口。
  bool get _hasSearchableSources =>
      _enabledSources().isNotEmpty ||
      _aidokuPackages.any((AidokuInstalledPackage package) => package.enabled);

  /// 已启用扩展提供的、且用户没有停用的在线来源。不支持扩展的平台恒为空表。
  List<MangaOnlineSourceRow> _enabledSources() {
    final MihonManager? manager = _manager;
    if (manager == null) return const <MangaOnlineSourceRow>[];
    return enabledMangaOnlineSources(manager);
  }

  /// 页头。与 `MediaSourcesPage` / `MangaSourcesPage` 同一范式：库页视图导航条
  /// 存在时它就是页头主位，**不再另渲染一个页面大标题**——导航条自己已经标明了当前
  /// 在哪个视图。仅在没有导航条（独立 push 进来）时才回退到文字标题。
  Widget _buildHeader() {
    final List<Widget> actions = <Widget>[
      if (_hasSearchableSources)
        IconButton(
          key: const ValueKey<String>('manga_global_search_open'),
          tooltip: t.manga_global_search_title,
          onPressed: _openGlobalSearch,
          icon: const Icon(Icons.travel_explore),
        ),
    ];
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(title: navigation, actions: actions);
    }
    return FushiPageHeader(title: t.library_view_browse, actions: actions);
  }

  @override
  Widget build(BuildContext context) {
    final List<MangaOnlineSourceRow> sources = _enabledSources();
    // watch（不是 read）：偏好改动经 PreferencesRepository -> AppModel 转发过来，
    // 本页在库页壳里是 Offstage 保活的，不 watch 就永远停在旧值上。
    final bool mokuroEnabled = isMokuroMoeSourceEnabled(ref.watch(appProvider));
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context)) _buildHeader(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                if (mokuroEnabled)
                  FushiCard(
                    padding: EdgeInsets.zero,
                    child: FushiListItem(
                      leading: const Icon(Icons.auto_stories_outlined),
                      title: Text(t.mihon_source_browse_mokuro),
                      subtitle: const Text('mokuro.moe'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _openMokuro,
                    ),
                  ),
                for (final AidokuInstalledPackage package
                    in _aidokuPackages.where(
                  (AidokuInstalledPackage package) => package.enabled,
                ))
                  FushiCard(
                    padding: EdgeInsets.zero,
                    child: FushiListItem(
                      leading: CircleAvatar(
                        child: Text(
                          package.languages.isEmpty
                              ? '?'
                              : package.languages.first.toUpperCase(),
                        ),
                      ),
                      title: Text(package.name),
                      subtitle: Text(package.id),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openAidokuSource(package),
                    ),
                  ),
                for (final MangaOnlineSourceRow source in sources)
                  FushiCard(
                    padding: EdgeInsets.zero,
                    child: FushiListItem(
                      leading: CircleAvatar(
                        child: Text(
                          source.language.isEmpty
                              ? '?'
                              : source.language.toUpperCase(),
                        ),
                      ),
                      title: Text(source.name),
                      subtitle: Text(
                        source.baseUrl.isEmpty
                            ? source.extensionPackage
                            : source.baseUrl,
                      ),
                      trailing: source.pinned
                          ? const Icon(Icons.push_pin_outlined)
                          : const Icon(Icons.chevron_right),
                      onTap: () => _openSource(source),
                    ),
                  ),
                if (_aidokuError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 16,
                    ),
                    child: Text(
                      '$_aidokuError',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (MihonRuntimeFactory.isSupported &&
                    sources.isEmpty &&
                    !_aidokuPackages.any(
                      (AidokuInstalledPackage package) => package.enabled,
                    ))
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 32,
                    ),
                    child: Text(
                      t.mihon_source_empty,
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
