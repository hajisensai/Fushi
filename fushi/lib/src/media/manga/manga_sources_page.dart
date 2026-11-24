import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/media/drag_drop/reader_shelf_drop_router.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/import/import_carrier.dart'
    show kMangaCarrierFileExtensions;
import 'package:fushi/src/media/import/import_page_layout.dart';
import 'package:fushi/src/media/import/import_inbox.dart';
import 'package:fushi/src/media/import/import_inbox_text.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart'
    show kMangaImageExtensions;
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_browse_page.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart'
    show openMediaServerSettings;
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 漫画库「导入」视图（导入稿 v2「1. 漫画」）：引导首块 + 三种方式块（导入漫画 →
/// 导入文件夹 → 网络共享）+ 常驻来源色块。
///
/// 互联对端的漫画库（读的是用户自己另一台设备上的库，与 Plex / Jellyfin 客户端连
/// 自己的服务器同类，不受商店合规边界约束，iOS 上照常提供）的浏览入口挪进来源区的
/// 互联块（IM4：此前同一页「Fushi 互联」出现两次——开关行 + 「在线源」区的浏览
/// 行）；「在线源」区标题随之删去（IM5：区里只剩互联一项，名字还和壳上的「在线」
/// 组撞名）。入口本身保留，只是换了位置。
///
/// 整页是拖放落点（IM2），落下交给与书架 / 漫画库同一份 [routeReaderShelfDrop]
/// （漫画库语义：偏好漫画）。
///
/// 扩展仓库 / 扩展目录 / 扩展提供的在线源（含 mokuro.moe）2026-09-27 起只住在顶层
/// 「浏览」模块（`MangaOnlineSourcesView`，Mihon 的 Browse 形态），本页不挂在线入口。
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

  /// BUG-513 同款纪律：AppModel 在 initState 捕获，async gap 之后不再 `ref.read`。
  late final AppModel _appModel = ref.read(appProvider);

  /// 漫画与书共用 `EpubBooks` 表和同一块书架：落库后失效同一组 provider。
  void _invalidateBookProviders() {
    if (!mounted) return;
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(srtBooksProvider);
  }

  /// 单卷 / 单文件漫画导入：目录 / `.mokuro` / `.cbz` / 图片包 + OCR 向导。
  Future<void> _importManga() async {
    final FushiDatabase db = _appModel.database;
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => MangaImportDialog(db: db),
    );
    if (imported == true) _invalidateBookProviders();
  }

  /// 「导入文件夹」：二选一（设为常驻来源 / 仅导入这一次）。
  Future<void> _importFolder() async {
    await _localSourcesKey.currentState?.importFolder();
    _invalidateBookProviders();
  }

  /// 「从『文件』App 导入」：收 `我的 iPhone › Fushi › 漫画子目录` 里的文件（重入保护在
  /// [MediaSourcesViewState.importFromInbox] 入口）。
  Future<void> _importFromInbox() async {
    await _localSourcesKey.currentState?.importFromInbox();
    _invalidateBookProviders();
  }

  /// 「网络共享」：直接打开网络来源表单。
  Future<void> _addNetworkSource() async {
    await _localSourcesKey.currentState?.addNetworkSource();
  }

  /// 互联块里的「浏览对端漫画库 ›」（IM4，原「在线源 › Fushi 互联」行）。
  void _browseInterconnect() {
    unawaited(
      Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (BuildContext context) =>
              const InterconnectMangaBrowsePage(),
        ),
      ),
    );
  }

  /// 整页落点：与漫画库同一份分发（IM2），导入视图没有卡片可命中。
  Future<void> _handleDrop(List<String> paths, Offset globalPosition) =>
      routeReaderShelfDrop(
        context: context,
        appModel: _appModel,
        mangaOnly: true,
        paths: paths,
        globalPosition: globalPosition,
        onLibraryChanged: _invalidateBookProviders,
        debugLabel: 'import-manga',
      );

  ImportSurfaceSpec _buildSpec() {
    return ImportSurfaceSpec(
      id: 'manga',
      tone: ImportTone.violet,
      guideIcon: FushiIcons.manga,
      guideTitle: t.import_guide_manga_title,
      guideDescription: t.import_guide_manga_desc,
      guideDescriptionWithoutDrop: t.import_guide_manga_desc_no_drop,
      methods: <ImportMethod>[
        ImportMethod(
          id: 'manga-file',
          kind: ImportMethodKind.primary,
          icon: FushiIcons.manga,
          label: t.manga_import_action,
          description: t.import_method_manga_desc,
          destination: ImportDestination.dialog,
          onTap: _importManga,
        ),
        ImportMethod(
          id: 'manga-folder',
          kind: ImportMethodKind.folder,
          icon: FushiIcons.folder,
          label: t.media_import_folder,
          description: t.import_method_folder_desc,
          destination: ImportDestination.choice,
          onTap: _importFolder,
        ),
        // iOS「文件」App 收件箱（拍板台 nLXhu0d7gV）：其它平台没有收件箱，不放空壳入口。
        if (ImportInbox.isSupported)
          ImportMethod(
            id: 'manga-inbox',
            kind: ImportMethodKind.folder,
            icon: FushiIcons.folderOpen,
            label: t.media_import_inbox,
            description: importInboxHintText(
              folder: ImportInbox.folderNameFor('manga') ?? '',
            ),
            destination: ImportDestination.dialog,
            enabled: _localSourcesKey.currentState?.isBusy != true,
            onTap: _importFromInbox,
          ),
        ImportMethod(
          id: 'manga-network',
          kind: ImportMethodKind.network,
          icon: FushiIcons.cloud,
          label: t.media_source_add_network,
          description: importNetworkTransportsSummary('manga'),
          destination: ImportDestination.source,
          onTap: _addNetworkSource,
        ),
      ],
      // 单卷载体（导入框文件选择器同一份）+ 页图文件夹里认的图片格式。
      formatGroups: <ImportFormatGroup>[
        ImportFormatGroup(
          title: t.import_format_group_manga_carriers,
          labels: importFormatLabels(<Iterable<String>>[
            kMangaCarrierFileExtensions,
          ]),
        ),
        ImportFormatGroup(
          title: t.import_format_group_manga_images,
          labels: importFormatLabels(<Iterable<String>>[kMangaImageExtensions]),
        ),
      ],
      onDrop: _handleDrop,
    );
  }

  /// 页头。库页视图导航条存在时它就是页头主位，**不再另渲染一个页面大标题**——
  /// 导航条自己已经标明了当前在哪个视图。仅在没有导航条（独立 push 进来）时才
  /// 回退到文字标题。「添加来源」在「常驻来源」区头（TODO-2930），页头不放。
  Widget _buildHeader() {
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

  @override
  Widget build(BuildContext context) {
    final ImportSurfaceSpec spec = _buildSpec();
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isGlassDesign(context)) _buildHeader(),
          Expanded(
            child: ImportPageLayout(
              spec: spec,
              onAddSource: () =>
                  unawaited(_localSourcesKey.currentState?.addSource()),
              addSourceEnabled: _localSourcesKey.currentState?.isBusy != true,
              sources: MediaSourcesView(
                key: _localSourcesKey,
                mediaKind: 'manga',
                presentation: MediaSourcesPresentation.blocks,
                entranceIndexOffset: spec.sourceEntranceIndex,
                onBrowseInterconnect: _browseInterconnect,
                interconnectBrowseLabel: t.import_interconnect_browse_manga,
                interconnectBrowseDisabledHint:
                    t.import_interconnect_browse_disabled_hint,
                onConnectServer: () => openMediaServerSettings(context),
                connectServerHint: 'Kavita · OPDS',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
