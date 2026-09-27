import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/manga_online_sources_view.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_installed_sources_section.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/media/novel/online/lnreader_extensions_section.dart';
import 'package:fushi/src/media/novel/online/lnreader_installed_sources_section.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_source_browse_page.dart';
import 'package:fushi/src/media/novel/online/novel_online_sources_gate.dart';
import 'package:fushi/src/media/video/online/video_online_sources_gate.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart' show MangaOnlineSourceRow;

/// 「浏览」模块里在线来源的三节（Mihon 的 Browse 形态：Sources / Extensions，
/// 扩展仓库挂在扩展页的工具栏上）。
enum OnlineSourcesSection {
  /// 已装扩展提供的在线源：点进源的浏览页（热门 / 最新 / 搜索）。
  sources,

  /// 可装扩展目录 + 已装扩展的启停 / 卸载 / 更新。
  extensions,

  /// 扩展仓库（添加 / 改地址 / 删除 / 刷新）。
  stores,
}

/// 有在线来源的三个内容域。游戏没有扩展系统，不在此列。
enum OnlineSourcesDomain { novel, manga, video }

/// [domain] 在当前平台上是否有在线来源宿主。
///
/// 判据只是把各域既有的门拼起来，不另写平台判断：小说 = LNReader 门，视频 =
/// Aniyomi 门，漫画 = 合规门。
///
/// 漫画域**不**再叠 Mihon 宿主门：内置的 mokuro.moe 是个网站、不需要扩展宿主，
/// 它的启停开关就在漫画域的「来源」里——叠了宿主门，Linux（没有 Mihon 宿主）上
/// 整个漫画域消失，mokuro.moe 开关随之没有任何入口。没有宿主时扩展相关的节由
/// [MangaOnlineSourcesView] 自己换成「本平台不可用」的说明。
bool isOnlineSourcesDomainAvailable(OnlineSourcesDomain domain) =>
    switch (domain) {
      OnlineSourcesDomain.novel => isNovelOnlineSourcesAvailable,
      OnlineSourcesDomain.manga =>
        StoreRestrictedCapability.onlineMangaSource.isAvailable,
      OnlineSourcesDomain.video => isVideoOnlineSourcesAvailable,
    };

/// 一个内容域的一节在线来源面。
///
/// 书 / 视频两域的实现此前住在 `MediaSourcesPage`（书 / 视频「导入」视图的后三段），
/// 漫画在 `MangaSourcesPage`；2026-09-27 起三域统一搬进「浏览」，导入页只剩本地
/// 来源。漫画域原样委托给 [MangaOnlineSourcesView]（它带着 Aidoku 仓库状态）。
///
/// 🔴 滚动容器是 [CustomScrollView]：扩展目录是按仓库分组懒建的 sliver
/// （1400+ 条不能一次全建，BUG-1441）。
class BrowseOnlineSourcesView extends ConsumerStatefulWidget {
  const BrowseOnlineSourcesView({
    required this.domain,
    required this.section,
    super.key,
  });

  final OnlineSourcesDomain domain;
  final OnlineSourcesSection section;

  @override
  ConsumerState<BrowseOnlineSourcesView> createState() =>
      _BrowseOnlineSourcesViewState();
}

class _BrowseOnlineSourcesViewState
    extends ConsumerState<BrowseOnlineSourcesView> {
  /// BUG-513 同款纪律：AppModel 在 initState 捕获，async gap 之后不再 `ref.read`。
  late final AppModel _appModel = ref.read(appProvider);

  /// 视频源扩展（Aniyomi）的管理器：`AppModel.animeMihonManager` 在没有 Mihon
  /// 宿主的平台会抛 [UnsupportedError]，所以先过门再取。
  MihonManager? get _animeManager =>
      isVideoOnlineSourcesAvailable ? _appModel.animeMihonManager : null;

  /// 小说源（LNReader 插件）的管理器：过了合规门 + 运行时平台门才取。
  LnReaderManager? get _novelManager =>
      isNovelOnlineSourcesAvailable ? _appModel.lnReaderManager : null;

  /// 点已启用的视频源进它的浏览页（与漫画源同一个页面，按 manager.kind 分派）。
  void _openAnimeSource(MangaOnlineSourceRow source) {
    final MihonManager? manager = _animeManager;
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

  /// 点已启用的小说源进它的浏览页。
  void _openNovelSource(LnReaderInstalledPlugin plugin) {
    final LnReaderManager? manager = _novelManager;
    if (manager == null) return;
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) =>
            LnReaderSourceBrowsePage(manager: manager, plugin: plugin),
      ),
    );
  }

  Widget _hint(String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    ),
  );

  List<Widget> _videoSlivers(MihonManager manager) => <Widget>[
    _hint(t.video_online_sources_hint),
    if (widget.section == OnlineSourcesSection.sources)
      MihonInstalledSourcesSection(
        key: const ValueKey<String>('video_mihon_sources'),
        manager: manager,
        onOpenSource: _openAnimeSource,
        emptyLabel: t.video_online_sources_empty,
      )
    else
      MihonExtensionsPage(
        key: ValueKey<String>('video_mihon_extensions_${widget.section.name}'),
        manager: manager,
        embedded: true,
        sections: <MihonExtensionsSection>[
          if (widget.section == OnlineSourcesSection.stores)
            MihonExtensionsSection.stores
          else
            MihonExtensionsSection.catalog,
        ],
      ),
  ];

  List<Widget> _novelSlivers(LnReaderManager manager) => <Widget>[
    _hint(t.novel_online_sources_hint),
    if (widget.section == OnlineSourcesSection.sources)
      LnReaderInstalledSourcesSection(
        key: const ValueKey<String>('book_lnreader_sources'),
        manager: manager,
        onOpenSource: _openNovelSource,
      )
    else
      LnReaderExtensionsSection(
        key: ValueKey<String>(
          'book_lnreader_extensions_${widget.section.name}',
        ),
        manager: manager,
        showStores: widget.section == OnlineSourcesSection.stores,
        showCatalog: widget.section == OnlineSourcesSection.extensions,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    if (widget.domain == OnlineSourcesDomain.manga) {
      return MangaOnlineSourcesView(
        key: ValueKey<String>('manga_online_${widget.section.name}'),
        section: widget.section,
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> slivers = switch (widget.domain) {
      OnlineSourcesDomain.video => switch (_animeManager) {
        final MihonManager manager => _videoSlivers(manager),
        null => const <Widget>[],
      },
      OnlineSourcesDomain.novel => switch (_novelManager) {
        final LnReaderManager manager => _novelSlivers(manager),
        null => const <Widget>[],
      },
      OnlineSourcesDomain.manga => const <Widget>[],
    };
    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page,
            0,
            tokens.spacing.page,
            tokens.spacing.page,
          ),
          sliver: SliverMainAxisGroup(slivers: slivers),
        ),
      ],
    );
  }
}
