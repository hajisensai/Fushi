import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/extension_catalog_controls.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/novel_online_sources_gate.dart';
import 'package:fushi/src/media/video/online/video_online_sources_gate.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 库页的「来源」/「扩展」子标签：本库内容域的在线来源面。
///
/// 正文就是「浏览 › 来源 / 扩展」同一个 [BrowseOnlineSourcesView]，只是不再
/// 选内容域（库页本身就是那个域）。页头主位放库页壳交来的分段条，与其它库页视图
/// 同构；「扩展」子标签在页头动作组里挂「刷新仓库」与「仓库」（后者与浏览页签同一个
/// [openOnlineSourceStores]）。刷新挪进页头后，目录正文顶部经
/// [ExtensionCatalogHeaderScope] 得知、不再重复画一枚刷新按钮。
///
/// 2026-10-01 用户拍板：浏览模块保留，发现 / 来源 / 扩展同时作为各库页的子标签
/// ——「往库里加东西」本来就该在库里找得到（OPDS 搬走后用户找不到）。
class LibraryOnlineSourcesView extends ConsumerWidget {
  const LibraryOnlineSourcesView({
    required this.domain,
    required this.section,
    required this.navigation,
    super.key,
  }) : assert(
          section != OnlineSourcesSection.stores,
          '仓库是「扩展」子标签的页头动作，不是子标签',
        );

  final OnlineSourcesDomain domain;
  final OnlineSourcesSection section;

  /// 库页壳交来的分段条，作为页头主位。
  final Widget navigation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Widget body = BrowseOnlineSourcesView(
      key: ValueKey<String>('library-${domain.name}-${section.name}'),
      domain: domain,
      section: section,
    );
    final bool header = !isCupertinoPlatform(context);
    final _StoreRefreshTarget? refresh =
        header && section == OnlineSourcesSection.extensions
            ? _storeRefreshTarget(ref.read(appProvider), domain)
            : null;
    if (!header) {
      return DesktopContentLayout(
        kind: DesktopContentKind.readerShelf,
        child: Column(children: <Widget>[Expanded(child: body)]),
      );
    }
    // 页头随仓库刷新状态重建（刷新中置灰）；正文作为 child 传入，不跟着重建。
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: ListenableBuilder(
        listenable: refresh?.listenable ?? const _NeverListenable(),
        child:
            refresh == null ? body : ExtensionCatalogHeaderScope(child: body),
        builder: (BuildContext context, Widget? child) => Column(
          children: <Widget>[
            FushiPageHeader.customTitle(
              title: navigation,
              actions: <Widget>[
                if (refresh != null)
                  FushiIconButton(
                    key: ValueKey<String>(
                      'library-${domain.name}-extensions-refresh',
                    ),
                    icon: FushiIcons.refresh,
                    tooltip: t.mihon_store_refresh,
                    label: t.mihon_store_refresh,
                    onTap: refresh.loading()
                        ? null
                        : () => unawaited(refresh.refresh()),
                  ),
                if (section == OnlineSourcesSection.extensions)
                  FushiIconButton(
                    key: ValueKey<String>(
                      'library-${domain.name}-extensions-stores',
                    ),
                    icon: FushiIcons.hub,
                    tooltip: t.media_import_segment_stores,
                    label: t.media_import_segment_stores,
                    onTap: () => openOnlineSourceStores(context, domain),
                  ),
              ],
            ),
            Expanded(child: child!),
          ],
        ),
      ),
    );
  }
}

/// 页头「刷新仓库」要驱动的对象：该域的扩展管理器（Mihon / LNReader 都是
/// `ChangeNotifier`，都有 `loading` 与 `refreshStores()`）。
typedef _StoreRefreshTarget = ({
  Listenable listenable,
  bool Function() loading,
  Future<void> Function() refresh,
});

/// [domain] 的仓库刷新目标；该域在本平台没有在线来源宿主时为 null（页头不挂
/// 刷新，正文目录自己也不会渲染）。门与 [BrowseOnlineSourcesView] 取管理器
/// 的门逐字相同——`AppModel` 上这些 getter 在没有宿主的平台会抛。
_StoreRefreshTarget? _storeRefreshTarget(
  AppModel appModel,
  OnlineSourcesDomain domain,
) {
  switch (domain) {
    case OnlineSourcesDomain.manga:
      if (!StoreRestrictedCapability.onlineMangaSource.isAvailable ||
          !MihonRuntimeFactory.isSupported) {
        return null;
      }
      final MihonManager manager = appModel.mihonManager;
      return (
        listenable: manager,
        loading: () => manager.loading,
        refresh: manager.refreshStores,
      );
    case OnlineSourcesDomain.video:
      if (!isVideoOnlineSourcesAvailable) return null;
      final MihonManager manager = appModel.animeMihonManager;
      return (
        listenable: manager,
        loading: () => manager.loading,
        refresh: manager.refreshStores,
      );
    case OnlineSourcesDomain.novel:
      if (!isNovelOnlineSourcesAvailable) return null;
      final LnReaderManager manager = appModel.lnReaderManager;
      return (
        listenable: manager,
        loading: () => manager.loading,
        refresh: manager.refreshStores,
      );
  }
}

/// 永不通知的 [Listenable]（没有刷新目标时给 [ListenableBuilder] 占位）。
class _NeverListenable implements Listenable {
  const _NeverListenable();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
