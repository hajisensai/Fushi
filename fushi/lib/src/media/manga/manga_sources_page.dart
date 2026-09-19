import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/import/import_page_segments.dart';
import 'package:fushi/src/media/import/quick_import_section.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_repository_client.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_repository_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_installed_sources_section.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_row.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_source_row.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';

/// 漫画库「来源」视图：本域**所有**来源的唯一管理处。
///
/// 顶部一条分段选择器（[ImportPageSegmentBar]，与视频「导入」视图同构），四段
/// 各管一种信息，正文只渲染当前段：
/// 1. 本地：快速导入 + 漫画扫描根（与书 / 视频共用的 [MediaSourcesView]）；
/// 2. 仓库：Mihon 扩展仓库（添加 / 改地址 / 删除 / 刷新）+ Aidoku 仓库
///    （Apple 平台）；
/// 3. 扩展：仓库里可装的扩展目录 + 已装扩展的启停 / 卸载 + 导入本地 APK /
///    `.aix`——用户口径：「漫画扩展不就是来源吗，来源设置里面加上就行了」，因此
///    **不另开顶层 tab**；
/// 4. 在线源：内置的 mokuro.moe、互联对端 **与**扩展提供的源并列（启停 / 排序 /
///    偏好 / 清数据 / 置顶，[MihonInstalledSourcesSection]）。
///
/// 此前四种东西竖着串成一整页长滚动，1900+ 条的扩展目录夹在中间，用户要找
/// 「仓库」得从扩展目录里翻过去（2026-09-19 用户口径「上下拖动感觉可以在上面
/// 弄个多段选择器，不同类型信息分开」）。
///
/// 🔴 mokuro.moe 归第 4 段，不归第 1 段（BUG-1431）：它是个网站，不是本地扫描根。
/// 之前它和「Hibiki 互联」一起挂在「本地扫描根」下，用户口径「mokuro 不应该单独
/// 显示，应该和漫画扩展同一层级」。挪进「在线源」后它与扩展源同构——同一段、同一
/// 种开关语义（关掉 = 不在「浏览」里出现）。
///
/// 🔴 本页的滚动容器必须是 [CustomScrollView]（BUG-1441）：第 3 段要渲染整个扩展
/// 仓库（keiyoushi 有 1900+ 条），只有 sliver 才能懒建。换回 `ListView` +
/// 内嵌 `Column` 会立刻把「语言下拉一展开就卡死」带回来。
///
/// 平台差异只在**内容**：Aidoku 在 macOS / iOS 显示同一套管理入口；iOS / Linux
/// 没有 Mihon 扩展宿主，对应段渲染不可用提示，视图本身与其它平台同构、同位。
/// `AppModel.mihonManager` 在这些平台会抛 [UnsupportedError]，故一切读它的路径
/// 都必须先过 [MihonRuntimeFactory.isSupported]。
class MangaSourcesPage extends ConsumerStatefulWidget {
  const MangaSourcesPage({super.key, this.navigation});

  /// 库页视图导航条（由 `MediaLibraryShell` 传入，作为页头主内容）。
  final Widget? navigation;

  @override
  ConsumerState<MangaSourcesPage> createState() => _MangaSourcesPageState();
}

class _MangaSourcesPageState extends ConsumerState<MangaSourcesPage> {
  final GlobalKey<MediaSourcesViewState> _localSourcesKey =
      GlobalKey<MediaSourcesViewState>();
  MihonManager? _manager;
  AidokuPackageStore? _aidokuStore;
  AidokuRepositoryStore? _aidokuRepositoryStore;
  late final AidokuRepositoryClient _aidokuRepositoryClient;
  List<AidokuInstalledPackage>? _aidokuPackages;
  List<AidokuSavedRepository>? _aidokuRepositories;
  List<AidokuRepositoryIndex> _aidokuIndexes = const <AidokuRepositoryIndex>[];
  final TextEditingController _aidokuSearchController = TextEditingController();

  /// 顶部分段选择器当前段；正文只渲染这一段。
  ImportPageSegment _segment = ImportPageSegment.local;
  final ScrollController _scrollController = ScrollController();
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
    } on Object catch (error) {
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
    _scrollController.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// 单卷 / 单文件漫画导入：与旧漫画库页头按钮同一个对话框（目录 / `.mokuro` /
  /// `.cbz` / 图片包 + OCR 向导）。落库成功后失效书架 provider 刷新漫画库。
  Future<void> _importManga() async {
    final FushiDatabase db = ref.read(appProvider).database;
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => MangaImportDialog(db: db),
    );
    if (imported == true && mounted) {
      ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
      ref.invalidate(srtBooksProvider);
    }
  }

  Future<void> _importAidoku() async {
    if (!AidokuRuntimeFactory.isSupported || _aidokuBusy) return;
    final bool acceptedRisk =
        await showAppDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog.adaptive(
            title: Text(t.aidoku_extension_import),
            content: Text(t.aidoku_extension_warning),
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
                child: Text(t.dialog_select),
              ),
            ],
          ),
        ) ??
        false;
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
      final bool confirmed =
          await showAppDialog<bool>(
            context: context,
            builder: (BuildContext dialogContext) => AlertDialog.adaptive(
              title: Text(t.aidoku_extension_confirm_title),
              content: Text(
                '${info['name']}\n${info['id']}\n'
                '${t.aidoku_extension_version}: ${info['version']}',
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
                  child: Text(t.dialog_import),
                ),
              ],
            ),
          ) ??
          false;
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
        setState(() => _aidokuError = error);
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
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
        setState(() => _aidokuError = error);
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
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
        setState(() => _aidokuError = error);
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
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
    } on Object catch (error) {
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
    final bool confirmed =
        await showAppDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog.adaptive(
            title: Text(t.aidoku_repository_remove),
            content: Text('${repository.name}\n${repository.indexUrl}'),
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
                child: Text(t.dialog_delete),
              ),
            ],
          ),
        ) ??
        false;
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
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
  }

  Future<void> _removeAidoku(AidokuInstalledPackage package) async {
    final bool confirmed =
        await showAppDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog.adaptive(
            title: Text(t.aidoku_extension_remove),
            content: Text(package.name),
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
                child: Text(t.dialog_delete),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    try {
      await _aidokuStore!.remove(package);
      final List<AidokuInstalledPackage> packages = await _aidokuStore!
          .listInstalled();
      if (mounted) setState(() => _aidokuPackages = packages);
    } on Object catch (error) {
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
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
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
  }

  Future<void> _installAidokuSource(AidokuRepositorySource source) async {
    if (_aidokuInstallingSourceId != null) return;
    final bool confirmed =
        await showAppDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog.adaptive(
            title: Text('${t.aidoku_repository_install}: ${source.name}'),
            content: Text(t.aidoku_extension_warning),
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
                child: Text(t.dialog_import),
              ),
            ],
          ),
        ) ??
        false;
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
        setState(() => _aidokuError = error);
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
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

  /// 页头。与 `MediaSourcesPage` 同一范式：库页视图导航条存在时它就是页头主位，
  /// **不再另渲染一个页面大标题**——导航条自己已经标明了当前在哪个视图，标题只是
  /// 重复占一行。仅在没有导航条（独立 push 进来）时才回退到文字标题。
  Widget _buildHeader() {
    // 「添加来源」已从页头收敛到「常驻来源」区头（TODO-2930），页头只留导航条。
    const List<Widget> actions = <Widget>[];
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(title: navigation, actions: actions);
    }
    return FushiPageHeader(
      title: t.media_source_manage_title,
      actions: actions,
    );
  }

  /// 扩展宿主不可用时统一的占位（iOS / Linux）。结构不变，只是这一节没内容。
  Widget _unavailableNote() => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(t.mihon_runtime_unavailable, textAlign: TextAlign.center),
  );

  /// 切段：正文换内容、滚动回顶。各段内容互不相干，沿用上一段的滚动偏移会让
  /// 新段一进来就停在半截。
  void _selectSegment(ImportPageSegment segment) {
    if (segment == _segment) return;
    setState(() => _segment = segment);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  /// 本页可用的段。
  ///
  /// 「仓库」「扩展」两段整段受商店合规门约束（iOS 不出现）；「在线源」段任何
  /// 平台都有——互联对端的漫画库那一行不受合规边界约束（读的是用户自己另一台
  /// 设备上的库，与 Plex / Jellyfin 客户端连自己的服务器同类），iOS 上这一段
  /// 只剩它一行。
  List<ImportPageSegment> _segmentsFor({
    required bool onlineSourcesAvailable,
  }) => <ImportPageSegment>[
    ImportPageSegment.local,
    if (onlineSourcesAvailable) ...<ImportPageSegment>[
      ImportPageSegment.stores,
      ImportPageSegment.extensions,
    ],
    ImportPageSegment.sources,
  ];

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
              leading: const Icon(Icons.cloud_outlined),
              title: Text(repository.name),
              subtitle: Text(mangaSourceHostLabel(repository.indexUrl)),
              trailing: Wrap(
                children: <Widget>[
                  IconButton(
                    tooltip: t.aidoku_repository_browse,
                    onPressed: _aidokuBusy
                        ? null
                        : () => unawaited(_browseAidokuRepository(repository)),
                    icon: const Icon(Icons.view_list_outlined),
                  ),
                  IconButton(
                    tooltip: t.aidoku_repository_remove,
                    onPressed: _aidokuBusy
                        ? null
                        : () => unawaited(_removeAidokuRepository(repository)),
                    icon: const Icon(Icons.delete_outline),
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
        child: LinearProgressIndicator(),
      ),
    if (_aidokuError != null)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '$_aidokuError',
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
                    : t.aidoku_extension_remove,
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
            primaryLabel: t.aidoku_extension_remove,
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

  /// 「本地」段：快速导入区 + 常驻来源。
  Widget _buildLocalSegment() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 快速导入区：单卷 / 单文件入口（与书 / 视频「导入」视图同构同位；
        // 对话框内含文件 / 文件夹 / OCR 向导）。
        QuickImportSection(
          actions: <QuickImportAction>[
            QuickImportAction(
              icon: Icons.auto_stories_outlined,
              label: t.manga_import_action,
              onTap: _importManga,
            ),
            QuickImportAction(
              icon: Icons.drive_folder_upload_outlined,
              label: t.media_import_folder,
              onTap: () async => _localSourcesKey.currentState?.importFolder(),
            ),
            if (AidokuRuntimeFactory.isSupported)
              QuickImportAction(
                icon: Icons.extension_outlined,
                label: t.aidoku_extension_import,
                onTap: _importAidoku,
                enabled: !_aidokuBusy,
              ),
            if (AidokuRuntimeFactory.isSupported)
              QuickImportAction(
                icon: Icons.cloud_download_outlined,
                label: t.aidoku_repository_add,
                onTap: _addAidokuRepository,
                enabled: !_aidokuBusy,
              ),
          ],
        ),
        const SizedBox(height: 28),
        Row(
          children: <Widget>[
            Expanded(child: _sectionTitle(t.media_source_section_title)),
            FushiIconButton(
              tooltip: t.media_source_add,
              label: t.media_source_add,
              icon: Icons.create_new_folder_outlined,
              onTap: () => _localSourcesKey.currentState?.addSource(),
            ),
          ],
        ),
        const SizedBox(height: 8),
        MediaSourcesView(key: _localSourcesKey, mediaKind: 'manga'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final MihonManager? manager = _manager;
    // iOS 上「来源」视图只剩本地与在线源里的互联一行：扩展仓库与扩展目录整段
    // 不渲染（[StoreRestrictedCapability.onlineMangaSource]），连「本平台不支持」
    // 的说明也不留——合规要求的是不提供第三方内容源入口，一句「这个功能在
    // macOS 上有」仍然是在向 iOS 用户指路。
    final bool onlineSourcesAvailable =
        StoreRestrictedCapability.onlineMangaSource.isAvailable;
    final List<ImportPageSegment> segments = _segmentsFor(
      onlineSourcesAvailable: onlineSourcesAvailable,
    );
    final ImportPageSegment segment = segments.contains(_segment)
        ? _segment
        : ImportPageSegment.local;
    // Aidoku 与 Mihon 共用「仓库」「扩展」两段时各带一行小标题分开；没有
    // Aidoku 宿主的构建整节不挂，也就不需要小标题（段名已经说明了一切）。
    final bool aidoku =
        onlineSourcesAvailable && AidokuRuntimeFactory.isSupported;
    final List<MihonExtensionsSection> mihonSections = switch (segment) {
      ImportPageSegment.stores => const <MihonExtensionsSection>[
        MihonExtensionsSection.stores,
      ],
      ImportPageSegment.extensions => const <MihonExtensionsSection>[
        MihonExtensionsSection.catalog,
      ],
      _ => const <MihonExtensionsSection>[],
    };
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context)) _buildHeader(),
          if (segments.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: ImportPageSegmentBar(
                segments: segments,
                selected: segment,
                onChanged: _selectSegment,
              ),
            ),
          Expanded(
            child: CustomScrollView(
              controller: _scrollController,
              slivers: <Widget>[
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverMainAxisGroup(
                    slivers: <Widget>[
                      if (segment == ImportPageSegment.local)
                        SliverToBoxAdapter(child: _buildLocalSegment()),
                      if (aidoku && segment == ImportPageSegment.stores)
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              _sectionTitle(t.aidoku_extensions_title),
                              const SizedBox(height: 8),
                              _buildAidokuRepositories(),
                              const SizedBox(height: 28),
                              _sectionTitle(t.mihon_extensions_title),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      if (aidoku && segment == ImportPageSegment.extensions)
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              _sectionTitle(t.aidoku_extensions_title),
                              const SizedBox(height: 8),
                              _buildAidokuCatalog(),
                              const SizedBox(height: 28),
                              _sectionTitle(t.mihon_extensions_title),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      // Mihon 扩展节常驻在树里（key 固定），其它段传空 sections
                      // 渲染成空 sliver：筛选 / 折叠 / 批量安装进度都是它的
                      // State，切段不能把它拆掉（见 MihonExtensionsPage 文档）。
                      if (onlineSourcesAvailable && manager != null)
                        MihonExtensionsPage(
                          key: const ValueKey<String>('manga_mihon_extensions'),
                          embedded: true,
                          sections: mihonSections,
                        )
                      else if (onlineSourcesAvailable &&
                          mihonSections.isNotEmpty)
                        SliverToBoxAdapter(child: _unavailableNote()),
                      if (segment == ImportPageSegment.sources)
                        if (onlineSourcesAvailable && manager != null)
                          MihonInstalledSourcesSection(
                            key: const ValueKey<String>('manga_mihon_sources'),
                            manager: manager,
                            // 内置在线源与扩展提供的源同段同级（见类文档）：
                            // mokuro.moe 是个网站，不是本地扫描根（BUG-1431）；
                            // 已配对互联对端的漫画库也是一个「在线源」——不下
                            // 整卷，直接在对端上翻页（Suwayomi 作为 Tachiyomi
                            // 源的形态）。
                            leading: const <Widget>[
                              MokuroMoeSourceRow(),
                              SizedBox(height: 8),
                              InterconnectMangaSourceRow(),
                              SizedBox(height: 8),
                            ],
                          )
                        else
                          SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                if (onlineSourcesAvailable) ...<Widget>[
                                  const MokuroMoeSourceRow(),
                                  const SizedBox(height: 8),
                                ],
                                // 互联那一行不受商店合规边界约束，iOS 上照常提供。
                                const InterconnectMangaSourceRow(),
                                if (onlineSourcesAvailable) _unavailableNote(),
                              ],
                            ),
                          ),
                    ],
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
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t.aidoku_repository_add),
    content: SizedBox(
      width: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.aidoku_repository_hint),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey<String>('aidoku_repository_url'),
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: t.aidoku_repository_url,
              prefixIcon: const Icon(Icons.link),
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
    final bool confirmed =
        await showAppDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog.adaptive(
            title: Text('${t.aidoku_repository_install}: ${source.name}'),
            content: Text(t.aidoku_extension_warning),
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
                child: Text(t.dialog_import),
              ),
            ],
          ),
        ) ??
        false;
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
        setState(() => _error = error);
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
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
        setState(() => _error = error);
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<AidokuRepositorySource> sources = _visibleSources;
    return AlertDialog(
      title: Text('${widget.index.name} · ${t.aidoku_repository_sources}'),
      content: SizedBox(
        width: 760,
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('aidoku_repository_search'),
              decoration: InputDecoration(
                labelText: t.aidoku_repository_search,
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (String value) => setState(() => _query = value),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '$_error',
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
        TextButton(
          onPressed: _installingSourceId == null
              ? () => Navigator.pop(context)
              : null,
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}
