import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/extension_catalog_controls.dart';
import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/media/manga/extension_store_list.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_updates.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_bottom_action_bar.dart';
import 'package:fushi/src/utils/misc/error_details_dialog.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';

/// [MihonExtensionsPage] 内嵌时可单独渲染的两节。
enum MihonExtensionsSection {
  /// 扩展仓库：仓库卡（改地址 / 删除）+ 刷新 / 添加仓库动作。
  stores,

  /// 扩展目录：筛选 + 按仓库分组的可装扩展 + 只在本机的已装扩展 + 导入 APK。
  catalog,
}

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
///
/// [sections] 决定内嵌时渲染哪几节：「浏览 › 扩展」页签只要
/// [MihonExtensionsSection.catalog]，它的「仓库」动作 push 出的仓库页只要
/// [MihonExtensionsSection.stores]（两处各是一个实例）。传空集渲染空 sliver。
/// 扩展目录那个实例由浏览页按域保活（Offstage），筛选 / 折叠 / 批量安装进度这些
/// State 切页签域不丢（批量安装的进度框还握着本 State 的 notifier）。
class MihonExtensionsPage extends ConsumerStatefulWidget {
  const MihonExtensionsPage({
    super.key,
    this.navigation,
    this.manager,
    this.embedded = false,
    this.sections = MihonExtensionsSection.values,
  });

  final Widget? navigation;
  final MihonManager? manager;

  /// 作为「来源」视图的一节内嵌渲染（无 chrome、不自带滚动）。
  final bool embedded;

  /// 内嵌时渲染的节；独立页形态忽略它、恒渲染全部。
  final List<MihonExtensionsSection> sections;

  bool get _showStores => sections.contains(MihonExtensionsSection.stores);
  bool get _showCatalog => sections.contains(MihonExtensionsSection.catalog);

  @override
  ConsumerState<MihonExtensionsPage> createState() =>
      _MihonExtensionsPageState();
}

class _MihonExtensionsPageState extends ConsumerState<MihonExtensionsPage> {
  MihonManager? _manager;
  String _language = '*';

  /// 用户手动改过展开状态的仓库（覆盖默认判据）。没记录的仓库按条数自适应。
  final Map<String, bool> _storeExpansionOverrides = <String, bool>{};
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  /// 「最低下载量」筛选的当前档位（0 = 不筛）。
  int _minDownloads = 0;

  /// 批量安装正在跑：期间禁掉入口，避免用户点第二次把同一批再排一遍。
  bool _bulkInstalling = false;

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
    final String? url = await showExtensionStoreUrlDialog(
      context: context,
      title: t.mihon_store_add,
      confirmLabel: t.mihon_store_add,
      fieldKey: const ValueKey<String>('mihon_store_url_field'),
    );
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
        unawaited(
          showErrorDetails(
            context,
            title: t.mihon_extension_error,
            error: error,
          ),
        );
      }
    }
  }

  /// 改仓库地址（BUG-1806）。输入框预填当前地址——改地址的典型场景是
  /// 「同一个仓库换了路径」，从零重打一遍长 URL 没有道理。
  Future<void> _editStore(MangaExtensionStoreRow store) async {
    final String? url = await showExtensionStoreUrlDialog(
      context: context,
      title: t.mihon_store_edit,
      confirmLabel: t.mihon_store_edit,
      initial: store.indexUrl,
      fieldKey: const ValueKey<String>('mihon_store_url_field'),
    );
    if (!mounted || url == null || url.isEmpty || url == store.indexUrl) return;
    bool allowInsecure = false;
    if (Uri.tryParse(url)?.scheme == 'http') {
      allowInsecure = await _confirmInsecureUrl(url);
      if (!allowInsecure) return;
    }
    try {
      await _manager!.editStoreUrl(
        store.indexUrl,
        url,
        allowInsecure: allowInsecure,
      );
    } catch (error) {
      if (mounted) {
        unawaited(
          showErrorDetails(
            context,
            title: t.mihon_extension_error,
            error: error,
          ),
        );
      }
    }
  }

  Future<bool> _confirmInsecureUrl(String url) => showFushiConfirmDialog(
    context: context,
    title: t.mihon_store_add,
    message: '${t.mihon_extension_warning}\n\n$url',
    icon: Icons.warning_amber_rounded,
    confirmLabel: t.dialog_ok,
    destructive: true,
  );

  Future<void> _importApk() async {
    final String? path = await pickSystemFilePath(
      context: context,
      allowedExtensions: const <String>{'apk'},
    );
    if (!mounted || path == null) return;
    try {
      final MihonInstallProposal proposal = await _manager!.prepareLocalInstall(
        path,
      );
      await _confirmAndInstall(proposal);
    } catch (error) {
      if (mounted) {
        unawaited(
          showErrorDetails(
            context,
            title: t.mihon_extension_error,
            error: error,
          ),
        );
      }
    }
  }

  Future<void> _install(MihonAvailableExtension extension) async {
    try {
      final MihonInstallProposal proposal = await _manager!.prepareStoreInstall(
        extension,
      );
      await _confirmAndInstall(proposal);
    } catch (error) {
      if (mounted) {
        unawaited(
          showErrorDetails(
            context,
            title: t.mihon_extension_error,
            error: error,
          ),
        );
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
      final MihonPreviewSession started = await _manager!.beginPreview(
        proposal,
      );
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
        unawaited(
          showErrorDetails(
            context,
            title: t.mihon_extension_error,
            error: error,
          ),
        );
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
      builder: (BuildContext dialogContext) => FushiAlertDialog(
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
      builder: (BuildContext dialogContext) => FushiAlertDialog.adaptive(
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
        unawaited(
          showErrorDetails(
            context,
            title: t.mihon_extension_error,
            error: error,
          ),
        );
      }
      return false;
    }
  }

  /// 删仓库也要确认（BUG-1716）：与卸载扩展、Aidoku 仓库删除同一套语义。
  /// 删掉仓库会让它提供的整页可装扩展从列表消失，误触成本远高于一次确认。
  Future<void> _removeStore(MangaExtensionStoreRow store) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.mihon_store_remove,
      message: '${store.name}\n${store.indexUrl}',
      icon: Icons.delete_outline,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
    if (confirmed) {
      await _manager!.removeStore(store.indexUrl);
    }
  }

  Future<void> _uninstall(MangaExtensionRow extension) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.mihon_extension_uninstall,
      message: extension.name,
      icon: Icons.delete_outline,
      confirmLabel: t.mihon_extension_uninstall,
      destructive: true,
    );
    if (confirmed) {
      await _manager!.uninstallExtension(extension);
    }
  }

  /// 页头三动作。内嵌时降级成本节顶部的按钮行，能力一个不少。
  ///
  /// 分段渲染时按节挑：「仓库」段要刷新 + 添加仓库，「扩展」段要刷新 + 导入
  /// APK（刷新两边都给——在目录里看到过期版本号时就地刷，不必切回仓库段）。
  List<Widget> _actions(
    MihonManager manager, {
    bool stores = true,
    bool catalog = true,
  }) => <Widget>[
    if (stores || catalog)
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
        tooltip: t.mihon_extension_import,
        label: t.mihon_extension_import,
        icon: Icons.file_open_outlined,
        onTap: manager.loading ? null : _importApk,
      ),
    if (stores)
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
      if (widget.sections.isEmpty) {
        return const SliverMainAxisGroup(slivers: <Widget>[]);
      }
      if (widget._showStores && !widget._showCatalog) {
        return _buildStorePage(manager);
      }
      return SliverMainAxisGroup(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _actions(
                manager,
                stores: widget._showStores,
                catalog: widget._showCatalog,
              ),
            ),
          ),
          if (manager.loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: FushiLinearProgressIndicator(),
              ),
            ),
          ..._buildContentSlivers(
            manager,
            stores: widget._showStores,
            catalog: widget._showCatalog,
          ),
        ],
      );
    }
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context))
            FushiPageHeader(
              title: switch (manager.kind) {
                MihonMediaKind.manga => t.mihon_extensions_title,
                MihonMediaKind.anime => t.video_extensions_title,
              },
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
                      child: FushiLoadingView(),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 没有仓库时的空态：添加仓库 / 导入本地 APK 两个出口。
  Widget _emptyStores() {
    // 空态走统一占位（MD3 中性分组卡 / Apple ContentUnavailableView），
    // 不再手搓一列图标 + 文字。
    return FushiPlaceholderMessage(
      icon: Icons.extension_outlined,
      iconSize: 48,
      message: t.mihon_store_empty,
      action: Wrap(
        spacing: 12,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: <Widget>[
          FushiFilledButton.icon(
            onPressed: _addStore,
            icon: const FushiIcon(Icons.add_link),
            label: Text(t.mihon_store_add),
          ),
          FushiOutlinedButton.icon(
            onPressed: _importApk,
            icon: const FushiIcon(Icons.file_open_outlined),
            label: Text(t.mihon_extension_import),
          ),
        ],
      ),
    );
  }

  /// 「仓库」页（扩展页签「仓库」动作 push 出的子页）：限宽居中的一列——
  /// 顶部刷新 / 添加仓库、信任提示、加载条、仓库分组列表。与小说插件仓库页
  /// 同一组零件（`extension_store_list.dart`）。
  Widget _buildStorePage(MihonManager manager) {
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
              icon: Icons.shield_outlined,
              message: t.mihon_extension_warning,
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
        if (manager.stores.isEmpty)
          SliverToBoxAdapter(child: _emptyStores())
        else
          ..._buildContentSlivers(manager, catalog: false),
      ],
    );
  }

  List<Widget> _buildContentSlivers(
    MihonManager manager, {
    bool stores = true,
    bool catalog = true,
  }) {
    final Map<String, MangaExtensionRow> installed =
        <String, MangaExtensionRow>{
          for (final MangaExtensionRow row in manager.installed)
            row.packageName: row,
        };
    if (manager.stores.isEmpty && manager.installed.isEmpty) {
      final Widget empty = _emptyStores();
      return <Widget>[
        // 独立页把空态撑满视口垂直居中；内嵌时它只是页面中的一节，撑满会把下面的
        // 「漫画源」一节顶出屏幕。
        if (widget.embedded)
          SliverToBoxAdapter(child: empty)
        else
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: empty),
          ),
      ];
    }
    final Set<String> availablePackages = manager.available
        .map((MihonAvailableExtension extension) => extension.packageName)
        .toSet();
    // 语言码一律折成小写做值域：仓库里同一门语言大小写不统一时不会分裂成两项。
    // `all`（多语言扩展）是**一个普通语言项**，不再被强行混进每一种语言里——
    // 选 JA 却整屏都是 `all`（而且 keiyoushi 的 `all` 大多是聚合站）正是用户说的
    // 「筛选不生效」的一半（BUG-1441）。要看它就在下拉里选 ALL。
    final List<String> languages =
        manager.available
            .map(
              (MihonAvailableExtension extension) =>
                  extension.language.toLowerCase(),
            )
            .where((String language) => language.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final List<MihonAvailableExtension> visibleAvailable = _filteredAvailable(
      manager,
    );
    final List<MangaExtensionRow> localOnly = manager.installed
        .where(
          (MangaExtensionRow row) =>
              !availablePackages.contains(row.packageName) &&
              (_language == '*' || row.language.toLowerCase() == _language),
        )
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
    final List<MihonExtensionListRow> groupedRows = buildMihonGroupedRows(
      stores: manager.stores,
      extensions: visibleAvailable,
      expanded: _storeExpanded,
    );
    // 每个仓库（表头 + 展开的扩展行）读作一个分组：逐行算出组内位置。
    final List<(int, int)> groupSlots = extensionGroupSlots(
      groupedRows.map((MihonExtensionListRow row) => row is MihonStoreHeaderRow),
    );
    final Widget storesSliver = SliverList.builder(
      itemCount: manager.stores.length,
      itemBuilder: (BuildContext context, int index) {
        final MangaExtensionStoreRow store = manager.stores[index];
        // 「请求成功但目录为空」以前是一条完全无声的路径：lastError 会在
        // 刷新成功时被清空，页面上只剩一张干净的卡片配零插件，用户拿不到
        // 任何线索（BUG-1805）。上游把 legacy 的 index.min.json 掏空成
        // 「你的 app 太旧」占位哨兵之后，这恰恰是最常见的失败形态。
        //
        // 判据必须带上 `!manager.loading`：`available` 是**纯内存**字段（不落
        // 库），进程重启后恒为空，而 `stores` 一读 DB 就 notify。少这一条，每个
        // 进程第一次进这页、在整个刷新窗口内（单次预算 30s）都会给每张正常仓库
        // 卡挂上「返回 0 个扩展，地址可能指向了旧版索引」——正好把用户推去改一个
        // 完全没问题的地址。误报比无声更糟。
        final bool returnedNothing =
            store.enabled &&
            !manager.loading &&
            store.lastError == null &&
            !manager.available.any(
              (MihonAvailableExtension item) => item.storeUrl == store.indexUrl,
            );
        final int extensionCount = manager.available
            .where(
              (MihonAvailableExtension item) => item.storeUrl == store.indexUrl,
            )
            .length;
        final ExtensionStoreStatus? status =
            switch ((store.lastError, returnedNothing)) {
              (final String error, _) => (
                text: error,
                tone: FushiStatusTone.error,
              ),
              (null, true) => (
                text: t.mihon_store_zero_extensions,
                tone: FushiStatusTone.warning,
              ),
              // 刷新中 / 停用的仓库没有可信的条数，只显示地址。
              (null, false) when extensionCount > 0 => (
                text: t.mihon_store_extension_count(count: extensionCount),
                tone: null,
              ),
              (null, false) => null,
            };
        // 仓库列表整段读作一个分组（MD3 分段 / Apple inset grouped），组尾
        // 留组间距与下面的目录隔开。
        return ExtensionStoreTile(
          index: index,
          count: manager.stores.length,
          rowKey: ValueKey<String>('mihon_store_${store.indexUrl}'),
          menuKey: ValueKey<String>('mihon_store_menu_${store.indexUrl}'),
          name: store.name,
          url: store.indexUrl,
          status: status,
          actions: <ExtensionStoreRowAction>[
            extensionStoreCopyAction(store.indexUrl),
            ExtensionStoreRowAction(
              label: t.mihon_store_edit,
              icon: Icons.edit_outlined,
              onTap: () => unawaited(_editStore(store)),
            ),
            ExtensionStoreRowAction(
              label: t.mihon_store_remove,
              icon: Icons.delete_outline,
              destructive: true,
              onTap: () => unawaited(_removeStore(store)),
            ),
          ],
        );
      },
    );
    final List<Widget> catalogSlivers = <Widget>[
      if (manager.available.isNotEmpty || manager.installed.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _buildFilters(languages),
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
      SliverList.builder(
        itemCount: groupedRows.length,
        itemBuilder: (BuildContext context, int index) {
          final MihonExtensionListRow entry = groupedRows[index];
          if (entry is MihonStoreHeaderRow) {
            return ExtensionStoreGroupHeader(
              groupCount: groupSlots[index].$2,
              keyPrefix: 'mihon',
              indexUrl: entry.indexUrl,
              label: entry.label,
              count: entry.count,
              expanded: entry.expanded,
              // 搜索态是强制展开的，这时点表头没有意义（点了也还是展开）。
              onTap: _searchQuery.trim().isNotEmpty
                  ? null
                  : () => _toggleStore(entry.indexUrl, entry.count),
            );
          }
          final MihonAvailableExtension extension =
              (entry as MihonExtensionEntryRow).extension;
          final MangaExtensionRow? row = installed[extension.packageName];
          final bool busy = manager.isExtensionActionBusy(
            extension.packageName,
          );
          return _AvailableExtensionTile(
            // 身份键，**必需**：这个 tile 是 StatefulWidget，自己持有
            // `_showAllSources`（「展开全部源 / 收起源列表」）。
            // SliverChildBuilderDelegate 按位置槽复用 Element，`Widget.canUpdate`
            // 只看 runtimeType + key —— 都是 null 的话，折叠上方任一仓库分组、
            // 改语言筛选、或输入搜索让行表一位移，同一个 index 上换了扩展，
            // `_AvailableExtensionTileState` 连同 `_showAllSources` 被原样复用：
            // 另一个扩展显示成「已展开全部源」，原来那个反而收了回去。
            // 身份就是 packageName（同文件 toggle 按钮的 key 已经这么用了）。
            key: ValueKey<String>(extension.packageName),
            groupIndex: groupSlots[index].$1,
            groupCount: groupSlots[index].$2,
            extension: extension,
            installed: row,
            busy: busy,
            showPreview: row == null,
            onInstall: busy
                ? null
                : () =>
                      _runExtensionAction(extension, () => _install(extension)),
            // 只对未安装的开放：Android 的 native install 会覆盖 exts/ 里同包名的
            // 文件，对已装扩展预览等于拿未确认的版本顶掉用户正在用的那份。
            onPreview: row == null && !busy
                ? () =>
                      _runExtensionAction(extension, () => _preview(extension))
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
            groupIndex: index,
            groupCount: visibleLocalOnly.length,
            extension: extension,
            onUninstall: () => unawaited(_uninstall(extension)),
            onEnabledChanged: (bool value) =>
                unawaited(manager.setExtensionEnabled(extension, value)),
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
    return <Widget>[if (stores) storesSliver, if (catalog) ...catalogSlivers];
  }

  /// 某个仓库当前是否展开。
  ///
  /// 三段判据，从强到弱：
  /// 1. **搜索态一律展开** —— 结果躲在收起的分组里等于搜索失效。
  /// 2. 用户手动点过表头就听用户的。
  /// 3. 否则按条数自适应（[kMihonStoreAutoCollapseThreshold]）。
  bool _storeExpanded(String indexUrl, int count) {
    if (_searchQuery.trim().isNotEmpty) return true;
    return _storeExpansionOverrides[indexUrl] ??
        count <= kMihonStoreAutoCollapseThreshold;
  }

  void _toggleStore(String indexUrl, int count) {
    setState(() {
      _storeExpansionOverrides[indexUrl] = !_storeExpanded(indexUrl, count);
    });
  }

  /// 当前筛选（语言 + 搜索 + 最低下载量）之后的可安装扩展。
  ///
  /// 列表渲染和批量安装**必须**共用这一份判据：批量安装的语义就是「把你现在看见
  /// 的这些装上」，两处各写一遍过滤链迟早会分叉成「看到的和装上的不是一批」。
  List<MihonAvailableExtension> _filteredAvailable(
    MihonManager manager,
  ) => filterByMediaSearch<MihonAvailableExtension>(
    manager.available
        .where(
          (MihonAvailableExtension extension) =>
              _language == '*' || extension.language.toLowerCase() == _language,
        )
        // 下载量筛选只对**有数据**的条目成立（见 passesExtensionMinDownloads）。
        .where(
          (MihonAvailableExtension extension) => passesExtensionMinDownloads(
            extension.downloadCount,
            _minDownloads,
          ),
        )
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
        (MihonAvailableSource source) => <String>[source.name, source.baseUrl],
      ),
    ],
  );

  /// 把当前筛选结果里**还没装**的扩展一次装完。
  ///
  /// 只装未安装的（[MihonManager.installMany] 也会再判一次）：批量的意义是铺满一
  /// 个语言的可用源，不是替用户决定升级——升级会换掉正在用的源的代码，那必须是
  /// 逐条的、看得见版本号的决定。
  Future<void> _bulkInstall() async {
    final MihonManager manager = _manager!;
    final Set<String> installedPackages = manager.installed
        .map((MangaExtensionRow row) => row.packageName)
        .toSet();
    final List<MihonAvailableExtension> targets = _filteredAvailable(manager)
        .where(
          (MihonAvailableExtension extension) =>
              !installedPackages.contains(extension.packageName),
        )
        .toList(growable: false);
    if (targets.isEmpty) {
      if (mounted) {
        unawaited(
          showExtensionBulkNothing(
            context,
            title: t.mihon_extension_bulk_install,
            message: t.mihon_extension_bulk_install_nothing,
          ),
        );
      }
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

  /// 「一键更新」（BUG-2481）：已装且仓库里版本更高的全部更新。判据与角标 / 更新
  /// 提醒共用 [mihonExtensionUpdates]，同一包多仓库取版本最高的那条。
  /// 签名换了的那条不顺手信任（`trustSigner: false`），以 `SIGNER_NOT_TRUSTED`
  /// 进失败清单，让用户回到单条流程看着指纹确认。
  Future<void> _updateAll() async {
    final MihonManager manager = _manager!;
    final List<MihonAvailableExtension> targets = mihonExtensionUpdates(
      available: manager.available,
      installed: manager.installed,
    ).map((MihonExtensionUpdate update) => update.available).toList();
    if (targets.isEmpty) {
      if (mounted) {
        unawaited(
          showExtensionBulkNothing(
            context,
            title: t.mihon_extension_update_all,
            message: t.mihon_extension_update_all_nothing,
          ),
        );
      }
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

  /// 批量安装 / 一键更新共用的执行体：进度框 → [MihonManager.installMany] →
  /// 结果框。两条入口只在「选哪些」和「信不信新签名」上不同。
  Future<void> _runBulk(
    List<MihonAvailableExtension> targets, {
    required bool upgrade,
  }) async {
    final MihonManager manager = _manager!;
    final String title = upgrade
        ? t.mihon_extension_update_all
        : t.mihon_extension_bulk_install;
    setState(() => _bulkInstalling = true);
    final MihonBulkInstallReport? report;
    try {
      report = await runExtensionBulkWithProgress<MihonBulkInstallReport>(
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
        // 取消闸门由 [MihonManager.installMany] 在每条之间读——正在下载的那一条
        // 会跑完，不会半途留下残骸。
        run: (onProgress, isCancelled) => manager.installMany(
          targets,
          trustSigner: !upgrade,
          upgrade: upgrade,
          onProgress: (int done, int total, MihonAvailableExtension current) =>
              onProgress(done, total, current.name),
          isCancelled: isCancelled,
        ),
      );
    } finally {
      if (mounted) setState(() => _bulkInstalling = false);
    }
    if (report == null || !mounted) return;
    unawaited(
      showExtensionBulkReport(
        context,
        title: title,
        summary: upgrade
            ? t.mihon_extension_update_all_done(
                installed: report.installed.length,
                skipped: report.skipped.length,
                failed: report.failed.length,
              )
            : t.mihon_extension_bulk_install_done(
                installed: report.installed.length,
                skipped: report.skipped.length,
                failed: report.failed.length,
              ),
        failures: report.failed,
      ),
    );
  }

  Widget _buildFilters(List<String> languages) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _buildSearchAndLanguageFilters(languages),
        const SizedBox(height: 8),
        ExtensionCatalogActions(
          keyPrefix: 'mihon_extension',
          minDownloads: _minDownloads,
          onMinDownloadsChanged: (int value) =>
              setState(() => _minDownloads = value),
          onBulkInstall: _bulkInstalling ? null : _bulkInstall,
          onUpdateAll: _bulkInstalling ? null : _updateAll,
        ),
      ],
    );
  }

  Widget _buildSearchAndLanguageFilters(List<String> languages) {
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
/// 超过这个条数的仓库默认收起，见 [kExtensionStoreAutoCollapseThreshold]。
const int kMihonStoreAutoCollapseThreshold =
    kExtensionStoreAutoCollapseThreshold;

/// 按公开下载量降序排一个仓库内的扩展；没有下载量数据的排在所有有数据的后面，
/// 同一档内按名字（大小写不敏感）稳定排序。
///
/// **为什么排在组内而不是全局**：分组顺序编码的是用户自己排的仓库 `sortOrder`
/// （见 [buildMihonGroupedRows]），把 1400 条跨仓库拍平重排会把那条规则连同折叠、
/// 表头计数一起打散。而「哪个源热门」本来就是仓库内部的比较——不同仓库的下载量
/// 来自不同 release 页面，横着比没有意义。
///
/// null 排最后而不是当 0：null 是「这个仓库没有公开计数」（自建仓库、API 限流），
/// 把它当 0 会让一个完全没有数据的仓库看起来像是「所有扩展都没人下」。
List<MihonAvailableExtension> sortMihonExtensionsByDownloads(
  List<MihonAvailableExtension> extensions,
) => sortExtensionsByDownloads<MihonAvailableExtension>(
  extensions,
  downloads: (MihonAvailableExtension extension) => extension.downloadCount,
  name: (MihonAvailableExtension extension) => extension.name,
);

/// 把「按仓库分组 + 折叠」压平成一维行表，交给 [SliverList.builder] 懒建。
///
/// **不要**改回「每个仓库一个 Column / ExpansionTile」：keiyoushi 的 1900+ 扩展
/// 塞进 Column 会一次性构建全部子树，这一页直接卡死（BUG-1441 就是这么来的）。
/// 收起的仓库只贡献一行表头，展开的才把它的扩展铺进去，整表始终是懒建的。
List<MihonExtensionListRow> buildMihonGroupedRows({
  required List<MangaExtensionStoreRow> stores,
  required List<MihonAvailableExtension> extensions,
  required bool Function(String indexUrl, int count) expanded,
}) {
  final Map<String, List<MihonAvailableExtension>> byStore =
      <String, List<MihonAvailableExtension>>{};
  for (final MihonAvailableExtension extension in extensions) {
    byStore
        .putIfAbsent(extension.storeUrl, () => <MihonAvailableExtension>[])
        .add(extension);
  }
  final List<MihonExtensionListRow> rows = <MihonExtensionListRow>[];
  void emit(String indexUrl, String label) {
    final List<MihonAvailableExtension>? group = byStore.remove(indexUrl);
    if (group == null || group.isEmpty) return;
    final bool isExpanded = expanded(indexUrl, group.length);
    rows.add(
      MihonStoreHeaderRow(
        indexUrl: indexUrl,
        label: label,
        count: group.length,
        expanded: isExpanded,
      ),
    );
    if (!isExpanded) return;
    for (final MihonAvailableExtension extension
        in sortMihonExtensionsByDownloads(group)) {
      rows.add(MihonExtensionEntryRow(extension));
    }
  }

  // 先按仓库表的顺序发（sortOrder 是用户排的），再兜底发孤儿分组：扩展的
  // storeUrl 可能指向一个刚被删掉的仓库，那些条目不能凭空消失。
  for (final MangaExtensionStoreRow store in stores) {
    emit(store.indexUrl, store.name);
  }
  for (final String orphan in byStore.keys.toList(growable: false)) {
    emit(orphan, orphan);
  }
  return rows;
}

/// 分组行表的一行：要么是仓库表头，要么是一个扩展条目。
sealed class MihonExtensionListRow {
  const MihonExtensionListRow();
}

class MihonStoreHeaderRow extends MihonExtensionListRow {
  const MihonStoreHeaderRow({
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

class MihonExtensionEntryRow extends MihonExtensionListRow {
  const MihonExtensionEntryRow(this.extension);

  final MihonAvailableExtension extension;
}

class _AvailableExtensionTile extends StatefulWidget {
  const _AvailableExtensionTile({
    super.key,
    required this.extension,
    required this.installed,
    required this.busy,
    required this.showPreview,
    required this.onInstall,
    required this.onPreview,
    required this.onUninstall,
    required this.onEnabledChanged,
    this.groupIndex,
    this.groupCount,
  });

  /// 所属仓库分组里的位置（见 [MangaExtensionManagementTile.groupIndex]）。
  final int? groupIndex;
  final int? groupCount;
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
  State<_AvailableExtensionTile> createState() =>
      _AvailableExtensionTileState();
}

class _AvailableExtensionTileState extends State<_AvailableExtensionTile> {
  /// 「包含的源」默认只显示前 [_sourcePreviewCount] 条。
  ///
  /// 截图里那一屏的主因就是这里：Akuma 一个扩展铺了 30 行
  /// `Akuma (xx) — https://akuma.moe`，把整页撑成一条看不到头的列表。
  /// FushiListItem 的 subtitleMaxLines 管不到它（那是 DefaultTextStyle.merge，
  /// 对 Column 里每个 Text 各自生效）。
  static const int _sourcePreviewCount = 3;

  bool _showAllSources = false;

  @override
  Widget build(BuildContext context) {
    final MihonAvailableExtension extension = widget.extension;
    final MangaExtensionRow? installed = widget.installed;
    // 两侧同量（DB 列存的就是 APK 的 android:versionCode，索引给的是同一个数），
    // 比大小自洽。BUG-1996 一度改成 `versionName !=`，理由是「跨尺度比大小、角标
    // 永不亮」——前提已被实测证伪（见 [MihonExtensionInspection.apkVersionCode]），
    // 且 `!=` 会在**已装版本比仓库新**时（本地侧载 / 同包多仓库）误报「有更新」并
    // 顶掉下面的「卸载」按钮，点下去必得 DOWNGRADE_REJECTED。`>` 结构上不可能有
    // 这个假阳性，保留。
    // 判据本体收口在 mihon_extension_updates.dart：更新提醒（v101）与这里的角标
    // 必须是同一个答案，否则会出现「角标亮了但没提醒」这类不一致。
    final bool update = hasMihonExtensionUpdate(
      available: extension,
      installed: installed,
    );
    final ThemeData theme = Theme.of(context);
    final int hiddenSources = _showAllSources
        ? 0
        : (extension.sources.length - _sourcePreviewCount).clamp(
            0,
            extension.sources.length,
          );
    final List<MihonAvailableSource> shownSources = _showAllSources
        ? extension.sources
        : extension.sources.take(_sourcePreviewCount).toList(growable: false);
    return MangaExtensionManagementTile(
      groupIndex: widget.groupIndex,
      groupCount: widget.groupCount,
      title: extension.name,
      iconUrl: extension.iconUrl,
      contentWarning: extension.contentWarning >= 3,
      busy: widget.busy,
      enabled: installed?.enabled,
      onEnabledChanged: widget.onEnabledChanged,
      secondaryLabel: widget.showPreview ? t.mihon_extension_preview : null,
      onSecondary: widget.onPreview,
      primaryLabel: installed == null
          ? t.mihon_extension_install
          : update
          ? t.mihon_extension_update
          : t.mihon_extension_uninstall,
      onPrimary: installed == null || update
          ? widget.onInstall
          : widget.onUninstall,
      // 这一行的副标题是可展开的「包含的源」清单，不是一行元信息。
      subtitleMaxLines: 2,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '${extension.language} · ${extension.versionName} · '
            'lib ${extension.libVersion}',
          ),
          Text(
            extensionDownloadCountLabel(extension.downloadCount),
            style: theme.textTheme.labelSmall,
          ),
          if (extension.sources.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              t.mihon_extension_sources_included,
              style: theme.textTheme.labelSmall,
            ),
            for (final MihonAvailableSource source in shownSources)
              Text(
                source.baseUrl.isEmpty
                    ? '· ${source.name} (${source.language})'
                    : '· ${source.name} (${source.language}) — '
                          '${source.baseUrl}',
                style: theme.textTheme.bodySmall,
              ),
            if (hiddenSources > 0 || _showAllSources)
              FushiTextButton(
                key: ValueKey<String>(
                  'mihon-sources-toggle-${extension.packageName}',
                ),
                onPressed: () =>
                    setState(() => _showAllSources = !_showAllSources),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  _showAllSources
                      ? t.mihon_extension_sources_less
                      : t.mihon_extension_sources_more(
                          count: extension.sources.length,
                        ),
                ),
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
  const _PreviewFooter({required this.onDiscard, required this.onInstall});

  final VoidCallback onDiscard;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    // 共享底部动作条：MD3 贴底 surfaceContainer 条，Apple 悬浮液态玻璃面。
    return FushiBottomActionBar(
      message: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(t.mihon_extension_preview_warning),
          const SizedBox(height: 4),
          Text(t.mihon_extension_preview_read_only),
        ],
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: onDiscard,
          child: Text(t.mihon_extension_preview_discard),
        ),
        FushiFilledButton(
          onPressed: onInstall,
          child: Text(t.mihon_extension_install),
        ),
      ],
    );
  }
}

class _InstalledExtensionTile extends StatelessWidget {
  const _InstalledExtensionTile({
    required this.extension,
    required this.onUninstall,
    required this.onEnabledChanged,
    this.groupIndex,
    this.groupCount,
  });

  /// 本地扩展段里的位置（见 [MangaExtensionManagementTile.groupIndex]）。
  final int? groupIndex;
  final int? groupCount;
  final MangaExtensionRow extension;
  final VoidCallback onUninstall;
  final ValueChanged<bool> onEnabledChanged;

  @override
  Widget build(BuildContext context) => MangaExtensionManagementTile(
    groupIndex: groupIndex,
    groupCount: groupCount,
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
