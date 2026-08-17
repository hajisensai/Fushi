import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/error_details_dialog.dart';
import 'package:fushi/utils.dart';

/// Mihon 扩展仓库与安装管理。
///
/// **没有自己的顶层 tab**：用户口径是「漫画扩展不就是来源吗」，所以它作为
/// `MangaSourcesPage`（漫画库「来源」视图）里的一节存在，用 [embedded] 打开。
/// 独立页形态（[embedded] 为 false）只剩测试和将来可能的 push 路由在用。
///
/// [embedded] 为 true 时：
/// - 不再包 `DesktopContentLayout` / `FushiPageHeader`（外层已有一套 chrome），
///   页头那三个动作（刷新仓库 / 导入 APK / 添加仓库）降级成本节顶部的按钮行；
/// - `build` 返回的是**sliver**（[SliverMainAxisGroup]），由外层 `CustomScrollView`
///   直接消费。
///
/// 🔴 内嵌形态必须是 sliver，不能是 `Column`（BUG-1441）：keiyoushi 这类完整仓库
/// 有 1900+ 个扩展，塞进 `Column` 就是 1900 个 RenderObject 全部实体化——`Column`
/// 没有视口裁剪，每一帧都要布局并绘制全部条目，于是「语言下拉一展开就卡死」「改一
/// 次筛选卡几秒」。外层滚动容器换成 `CustomScrollView` 后，这里用 `SliverList`
/// 只建可见的那十几行。
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
        content: FushiTextField(
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
      if (mounted) {
        unawaited(showErrorDetails(
          context,
          title: t.mihon_extension_error,
          error: error,
        ));
      }
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
      if (mounted) {
        unawaited(showErrorDetails(
          context,
          title: t.mihon_extension_error,
          error: error,
        ));
      }
    }
  }

  Future<void> _install(MihonAvailableExtension extension) async {
    try {
      final MihonInstallProposal proposal =
          await _manager!.prepareStoreInstall(extension);
      await _confirmAndInstall(proposal);
    } catch (error) {
      if (mounted) {
        unawaited(showErrorDetails(
          context,
          title: t.mihon_extension_error,
          error: error,
        ));
      }
    }
  }

  void _runExtensionAction(
    MihonAvailableExtension extension,
    Future<void> Function() action,
  ) {
    final String packageName = extension.packageName;
    if (!_manager!.tryBeginExtensionAction(packageName)) return;
    unawaited(() async {
      try {
        await action();
      } finally {
        _manager!.endExtensionAction(packageName);
      }
    }());
  }

  /// 「装之前先看看这个源有什么漫画」。
  ///
  /// 与 [_install] 共用同一个 proposal——下载、校验签名指纹、比对仓库元数据都已经
  /// 做完了，差别只在拿到 proposal 之后走 [MihonManager.beginPreview] 而不是直接
  /// commit：扩展代码会真跑起来（它是代码不是配置，不跑就没有任何内容可看），但
  /// **不写库、不进受信任签名表**。用户看完在预览页底部二选一：放弃（删干净）
  /// 或安装（走与直接安装完全相同的签名确认框）。
  Future<void> _preview(MihonAvailableExtension extension) async {
    MihonPreviewSession? session;
    MihonInstallProposal? proposal;
    try {
      proposal = await _manager!.prepareStoreInstall(extension);
      final MihonPreviewSession started =
          await _manager!.beginPreview(proposal);
      session = started;
      final MihonSource? source = await _pickPreviewSource(started);
      if (source == null) {
        session = null;
        await _manager!.endPreview(started, keep: false);
        return;
      }
      final bool install = await _openPreviewBrowse(started, source);
      session = null;
      // keep 时落地的文件留给 commitInstall 复用，只清运行时缓存与崩溃标记。
      await _manager!.endPreview(started, keep: install);
      if (install) await _confirmAndInstall(started.proposal);
    } catch (error) {
      final MihonPreviewSession? pending = session;
      if (pending != null) {
        try {
          await _manager!.endPreview(pending, keep: false);
        } on Object {
          // 清理失败不能掩盖真正的错误，继续把原始错误报给用户。
        }
      } else if (proposal != null) {
        try {
          await _manager!.discardProposal(proposal);
        } on Object {
          // 同上：保留原始预览错误；残留 staging 会在下次启动清理。
        }
      }
      if (mounted) {
        unawaited(showErrorDetails(
          context,
          title: t.mihon_extension_error,
          error: error,
        ));
      }
    }
  }

  /// 一个扩展可能提供多个源（不同站点 / 不同语言），得先问预览哪一个。
  /// 只有一个就别多一次点击。
  Future<MihonSource?> _pickPreviewSource(MihonPreviewSession session) async {
    if (session.sources.length == 1) return session.sources.single;
    if (!mounted) return null;
    return showAppDialog<MihonSource>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(t.mihon_extension_preview_source_select),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (final MihonSource source in session.sources)
                FushiListItem(
                  title: Text(source.name),
                  subtitle: Text(
                    source.baseUrl.isEmpty
                        ? source.language.toUpperCase()
                        : '${source.language.toUpperCase()} · '
                            '${source.baseUrl}',
                  ),
                  onTap: () => Navigator.pop(dialogContext, source),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t.dialog_cancel),
          ),
        ],
      ),
    );
  }

  /// 打开只读预览浏览页，返回用户是否选择了安装。
  /// 系统返回键 / 手势返回 pop 出 null，按「放弃」处理。
  Future<bool> _openPreviewBrowse(
    MihonPreviewSession session,
    MihonSource source,
  ) async {
    if (!mounted) return false;
    final bool? install = await Navigator.of(context).push<bool>(
      adaptivePageRoute<bool>(
        context: context,
        builder: (BuildContext pageContext) => MihonSourceBrowsePage(
          manager: _manager!,
          target: MihonPreviewTarget(session: session, source: source),
          footer: _PreviewFooter(
            onDiscard: () => Navigator.pop(pageContext, false),
            onInstall: () => Navigator.pop(pageContext, true),
          ),
        ),
      ),
    );
    return install ?? false;
  }

  /// 签名确认 + 落地安装。返回**是否真的装上了**。
  ///
  /// 用户点取消时把已下载的 APK 一并丢掉：走到这一步文件已经在 `tmp/` 里躺着了。
  Future<bool> _confirmAndInstall(MihonInstallProposal proposal) async {
    if (!mounted) {
      await _manager!.discardProposal(proposal);
      return false;
    }
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
    if (confirmed != true) {
      await _manager!.discardProposal(proposal);
      return false;
    }
    try {
      await _manager!.commitInstall(proposal, trustSigner: true);
      return true;
    } catch (error) {
      if (mounted) {
        unawaited(showErrorDetails(
          context,
          title: t.mihon_extension_error,
          error: error,
        ));
      }
      return false;
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
        FushiIconButton(
          tooltip: t.mihon_store_refresh,
          label: t.mihon_store_refresh,
          icon: Icons.refresh,
          onTap:
              manager.loading ? null : () => unawaited(manager.refreshStores()),
        ),
        FushiIconButton(
          tooltip: t.mihon_extension_import,
          label: t.mihon_extension_import,
          icon: Icons.file_open_outlined,
          onTap: manager.loading ? null : _importApk,
        ),
        FushiIconButton(
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
      return SliverMainAxisGroup(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _actions(manager),
            ),
          ),
          if (manager.loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              ),
            ),
          ..._buildContentSlivers(manager),
        ],
      );
    }
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context))
            FushiPageHeader(
              title: t.mihon_extensions_title,
              bottom: widget.navigation,
              actions: _actions(manager),
            ),
          Expanded(
            child: Stack(
              children: <Widget>[
                CustomScrollView(
                  slivers: <Widget>[
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverMainAxisGroup(
                        slivers: _buildContentSlivers(manager),
                      ),
                    ),
                  ],
                ),
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

  List<Widget> _buildContentSlivers(MihonManager manager) {
    final Map<String, MangaExtensionRow> installed =
        <String, MangaExtensionRow>{
      for (final MangaExtensionRow row in manager.installed)
        row.packageName: row,
    };
    if (manager.stores.isEmpty && manager.installed.isEmpty) {
      final Widget empty = Padding(
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
      );
      return <Widget>[
        // 独立页把空态撑满视口垂直居中；内嵌时它只是页面中的一节，撑满会把下面的
        // 「漫画源」一节顶出屏幕。
        if (widget.embedded)
          SliverToBoxAdapter(child: empty)
        else
          SliverFillRemaining(
              hasScrollBody: false, child: Center(child: empty)),
      ];
    }
    final Set<String> availablePackages = manager.available
        .map((MihonAvailableExtension extension) => extension.packageName)
        .toSet();
    // 语言码一律折成小写做值域：仓库里同一门语言大小写不统一时不会分裂成两项。
    // `all`（多语言扩展）是**一个普通语言项**，不再被强行混进每一种语言里——
    // 选 JA 却整屏都是 `all`（而且 keiyoushi 的 `all` 大多是聚合站）正是用户说的
    // 「筛选不生效」的一半（BUG-1441）。要看它就在下拉里选 ALL。
    final List<String> languages = manager.available
        .map((MihonAvailableExtension extension) =>
            extension.language.toLowerCase())
        .where((String language) => language.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final List<MihonAvailableExtension> visibleAvailable =
        filterByMediaSearch<MihonAvailableExtension>(
      manager.available
          .where((MihonAvailableExtension extension) =>
              _language == '*' || extension.language.toLowerCase() == _language)
          .toList(growable: false),
      _searchQuery,
      // 🔴 可搜字段只能是**条目自身**的标识。`storeUrl` 是仓库级字段，同一仓库的
      // 每个扩展都一样：keiyoushi 的索引地址是
      // `https://github.com/keiyoushi/extensions/raw/repo/index.pb`，归一化后含
      // `raw`/`github`/`repo`/`index`，于是搜「raw」整个仓库 1900 个扩展全部命中，
      // 看起来就是「筛选完全没生效」（BUG-1441）。`language` 同理是低基数共享值，
      // 且已有专门的语言下拉，留在这里只会把「all」这类查询打成全命中。
      (MihonAvailableExtension extension) => <String>[
        extension.name,
        extension.packageName,
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
            !availablePackages.contains(row.packageName) &&
            (_language == '*' || row.language.toLowerCase() == _language))
        .toList(growable: false);
    final List<MangaExtensionRow> visibleLocalOnly =
        filterByMediaSearch<MangaExtensionRow>(
      localOnly,
      _searchQuery,
      (MangaExtensionRow extension) => <String>[
        extension.name,
        extension.packageName,
      ],
    );
    return <Widget>[
      SliverList.builder(
        itemCount: manager.stores.length,
        itemBuilder: (BuildContext context, int index) {
          final MangaExtensionStoreRow store = manager.stores[index];
          return FushiCard(
            padding: EdgeInsets.zero,
            child: FushiListItem(
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
          );
        },
      ),
      if (manager.available.isNotEmpty || manager.installed.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _buildFilters(languages),
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
      SliverList.builder(
        itemCount: visibleAvailable.length,
        itemBuilder: (BuildContext context, int index) {
          final MihonAvailableExtension extension = visibleAvailable[index];
          final MangaExtensionRow? row = installed[extension.packageName];
          final bool busy =
              manager.isExtensionActionBusy(extension.packageName);
          return _AvailableExtensionTile(
            extension: extension,
            installed: row,
            busy: busy,
            showPreview: row == null,
            onInstall: busy
                ? null
                : () => _runExtensionAction(
                      extension,
                      () => _install(extension),
                    ),
            // 只对未安装的开放：Android 的 native install 会覆盖 exts/ 里同包名的
            // 文件，对已装扩展预览等于拿未确认的版本顶掉用户正在用的那份。
            onPreview: row == null && !busy
                ? () => _runExtensionAction(
                      extension,
                      () => _preview(extension),
                    )
                : null,
            onUninstall: row == null ? null : () => unawaited(_uninstall(row)),
            onEnabledChanged: row == null
                ? null
                : (bool value) =>
                    unawaited(manager.setExtensionEnabled(row, value)),
          );
        },
      ),
      SliverList.builder(
        itemCount: visibleLocalOnly.length,
        itemBuilder: (BuildContext context, int index) {
          final MangaExtensionRow extension = visibleLocalOnly[index];
          return _InstalledExtensionTile(
            extension: extension,
            onUninstall: () => unawaited(_uninstall(extension)),
            onEnabledChanged: (bool value) => unawaited(
              manager.setExtensionEnabled(extension, value),
            ),
          );
        },
      ),
      if (_searchQuery.trim().isNotEmpty &&
          visibleAvailable.isEmpty &&
          visibleLocalOnly.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text(t.no_search_results)),
          ),
        ),
    ];
  }

  Widget _buildFilters(List<String> languages) {
    return MangaExtensionFilters(
      keyPrefix: 'mihon_extension',
      languages: languages,
      selectedLanguage: _language,
      languageLabel: t.mihon_extension_language_filter,
      allLanguagesLabel: t.mihon_extension_language_all,
      searchHint: t.search,
      searchController: _searchController,
      searchQuery: _searchQuery,
      onLanguageChanged: (String value) => setState(() => _language = value),
      onSearchChanged: (String value) => setState(() => _searchQuery = value),
      onSearchCleared: () {
        _searchController.clear();
        setState(() => _searchQuery = '');
      },
    );
  }
}

/// 仓库里一条可用扩展。
///
/// 副标题不止版本号：仓库 index 里本来就带着**这个扩展装完会给你哪几个站**
/// （[MihonAvailableExtension.sources] 的名字 + 域名）和 NSFW 标记，以前这些数据
/// 只喂给搜索匹配，一个字都没显示，用户只能靠扩展名猜。安装前能看清装的是什么，
/// 是「预览」的第一层——不需要跑任何代码，也没有任何网络请求。
class _AvailableExtensionTile extends StatelessWidget {
  const _AvailableExtensionTile({
    required this.extension,
    required this.installed,
    required this.busy,
    required this.showPreview,
    required this.onInstall,
    required this.onPreview,
    required this.onUninstall,
    required this.onEnabledChanged,
  });

  final MihonAvailableExtension extension;
  final MangaExtensionRow? installed;
  final bool busy;
  final bool showPreview;
  final VoidCallback? onInstall;

  /// 未安装时才有：跑一次 staged 试用，看真实内容。
  final VoidCallback? onPreview;
  final VoidCallback? onUninstall;
  final ValueChanged<bool>? onEnabledChanged;

  @override
  Widget build(BuildContext context) {
    final bool update =
        installed != null && extension.versionCode > installed!.versionCode;
    final ThemeData theme = Theme.of(context);
    return MangaExtensionManagementTile(
      title: extension.name,
      iconUrl: extension.iconUrl,
      contentWarning: extension.contentWarning >= 3,
      busy: busy,
      enabled: installed?.enabled,
      onEnabledChanged: onEnabledChanged,
      secondaryLabel: showPreview ? t.mihon_extension_preview : null,
      onSecondary: onPreview,
      primaryLabel: installed == null
          ? t.mihon_extension_install
          : update
              ? t.mihon_extension_update
              : t.mihon_extension_uninstall,
      onPrimary: installed == null || update ? onInstall : onUninstall,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '${extension.language} · ${extension.versionName} · '
            'lib ${extension.libVersion}',
          ),
          if (extension.sources.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              t.mihon_extension_sources_included,
              style: theme.textTheme.labelSmall,
            ),
            for (final MihonAvailableSource source in extension.sources)
              Text(
                source.baseUrl.isEmpty
                    ? '· ${source.name} (${source.language})'
                    : '· ${source.name} (${source.language}) — '
                        '${source.baseUrl}',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ],
      ),
    );
  }
}

/// 预览页底部的操作条。
///
/// 两句说明不是装饰，是这个功能唯一诚实的地方：**预览已经在跑这个扩展的代码了**
/// （否则不可能有内容），它与安装的差别是「有没有写进你的库」，不是「有没有执行」。
/// 说清楚，用户才知道自己在同意什么。
class _PreviewFooter extends StatelessWidget {
  const _PreviewFooter({
    required this.onDiscard,
    required this.onInstall,
  });

  final VoidCallback onDiscard;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ColoredBox(
      color: tokens.surfaces.overlay,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                t.mihon_extension_preview_warning,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                t.mihon_extension_preview_read_only,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: onDiscard,
                    child: Text(t.mihon_extension_preview_discard),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: onInstall,
                    child: Text(t.mihon_extension_install),
                  ),
                ],
              ),
            ],
          ),
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
  Widget build(BuildContext context) => MangaExtensionManagementTile(
        title: extension.name,
        subtitle: Text(
          '${extension.language} · ${extension.versionName} · '
          'lib ${extension.libVersion}',
        ),
        enabled: extension.enabled,
        onEnabledChanged: onEnabledChanged,
        primaryLabel: t.mihon_extension_uninstall,
        onPrimary: onUninstall,
      );
}
