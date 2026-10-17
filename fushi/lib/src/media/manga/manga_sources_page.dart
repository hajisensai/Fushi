import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/import/quick_import_section.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_row.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 漫画库「导入」视图：本地来源的管理处。
///
/// 自上而下：快速导入（单卷 / 单文件 + 导入文件夹）、常驻来源（漫画扫描根，与书 /
/// 视频共用的 [MediaSourcesView]），以及互联对端的漫画库（读的是用户自己另一台
/// 设备上的库，与 Plex / Jellyfin 客户端连自己的服务器同类，不受商店合规边界约束，
/// iOS 上照常提供）。
///
/// 扩展仓库 / 扩展目录 / 扩展提供的在线源（含 mokuro.moe）2026-09-27 起只住在顶层
/// 「浏览」模块（`MangaOnlineSourcesView`，Mihon 的 Browse 形态），本页不再挂在线
/// 入口。
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

  Widget _sectionTitle(String title) =>
      Text(title, style: context.fushiType.titleLargeEmphasized);

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

  /// 「本地」段：快速导入区 + 常驻来源。
  Widget _buildLocalSegment() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 快速导入区：单卷 / 单文件入口（与书 / 视频「导入」视图同构同位；
        // 对话框内含文件 / 文件夹 / OCR 向导）。
        QuickImportSection(
          heroIcon: FushiIcons.manga,
          formats: const <String>['CBZ', 'ZIP', 'PDF', 'MOKURO', 'JPG', 'PNG'],
          actions: <QuickImportAction>[
            QuickImportAction(
              icon: FushiIcons.manga,
              label: t.manga_import_action,
              onTap: _importManga,
            ),
            QuickImportAction(
              icon: FushiIcons.folder,
              label: t.media_import_folder,
              onTap: () async => _localSourcesKey.currentState?.importFolder(),
            ),
          ],
          // 网络来源也是一种导入方式：与「常驻来源」区头的添加按钮同一个入口。
          extraActions: <QuickImportAction>[
            QuickImportAction(
              icon: FushiIcons.cloud,
              label: t.media_source_add_network,
              description: t.media_source_network_subtitle,
              onTap: () async => _localSourcesKey.currentState?.addSource(),
            ),
          ],
        ),
        const SizedBox(height: 28),
        FushiStaggeredEntrance(
          index: 4,
          child: Row(
            children: <Widget>[
              Expanded(child: _sectionTitle(t.media_source_section_title)),
              FushiIconButton(
                tooltip: t.media_source_add,
                label: t.media_source_add,
                icon: FushiIcons.add,
                onTap: () => _localSourcesKey.currentState?.addSource(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        FushiStaggeredEntrance(
          index: 5,
          child: MediaSourcesView(key: _localSourcesKey, mediaKind: 'manga'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context)) _buildHeader(),
          Expanded(
            // 顶部让出库页壳浮动工具区的高度（不在壳里时为 0）：内容滚到工具区
            // 底下，工具区收起后上方不再留一条空白。
            child: FushiEntranceScope(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  FushiFloatingChromeInset.of(context) + tokens.spacing.gap,
                  tokens.spacing.page,
                  tokens.spacing.page,
                ),
                children: <Widget>[
                  _buildLocalSegment(),
                  const SizedBox(height: 28),
                  FushiStaggeredEntrance(
                    index: 6,
                    child: _sectionTitle(t.media_import_segment_sources),
                  ),
                  const SizedBox(height: 8),
                  // 互联那一行不受商店合规边界约束，iOS 上照常提供。
                  const FushiStaggeredEntrance(
                    index: 7,
                    child: InterconnectMangaSourceRow(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
