import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_catalog_view.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';

/// 漫画库页三视图里的「浏览」视图：mokuro.moe 在线目录。
///
/// 与下载页的 [MokuroMoeCatalogDialog] 共用同一个内容体 [MokuroMoeCatalogView]，
/// 差别只在 chrome：对话框有标题栏与关闭按钮，页面走库页统一的
/// [HibikiPageHeader] + 导航条，且没有「关闭」这个动作（视图不是弹层）。
///
/// 下载不在本页阻塞：选卷后入队 app 级共享队列，切走视图或切走 tab 都继续跑，
/// 落库完成后书架视图自动刷新（书架监听队列的 importedCount 增量）。
class MokuroMoeCatalogPage extends ConsumerStatefulWidget {
  const MokuroMoeCatalogPage({
    super.key,
    this.db,
    this.navigation,
  });

  /// 目标数据库（查已在库书目用；下载落库由队列持有的 db 完成）。
  /// null = 取 [AppModel.database]——本页自己取而不是让库页壳传，是为了让漫画库页
  /// 保持无 provider 依赖（接线守卫测试能纯构造它，不必搭一整套 ProviderScope）。
  final HibikiDatabase? db;

  /// 库页视图导航条（由 `MediaLibraryShell` 传入，作为页头主内容与动作同一行）。
  final Widget? navigation;

  @override
  ConsumerState<MokuroMoeCatalogPage> createState() =>
      _MokuroMoeCatalogPageState();
}

class _MokuroMoeCatalogPageState extends ConsumerState<MokuroMoeCatalogPage> {
  /// 内容体的阶段快照：页面标题跟着「浏览 / 某系列」切换（与对话框同源）。
  final ValueNotifier<MokuroMoeCatalogSnapshot> _snapshot =
      ValueNotifier<MokuroMoeCatalogSnapshot>(const MokuroMoeCatalogSnapshot());

  @override
  void dispose() {
    _snapshot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    // 与书架 / 视频 / 来源同构：DesktopContentLayout + HibikiPageHeader，
    // 外层 Scaffold 由 HomePage 提供。
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context))
            ValueListenableBuilder<MokuroMoeCatalogSnapshot>(
              valueListenable: _snapshot,
              builder: (
                BuildContext context,
                MokuroMoeCatalogSnapshot snapshot,
                Widget? child,
              ) {
                final Widget? navigation = widget.navigation;
                if (navigation != null) {
                  final String? seriesName = snapshot.seriesName;
                  return HibikiPageHeader.customTitle(
                    title: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        navigation,
                        if (seriesName != null && seriesName.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              seriesName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  );
                }
                return HibikiPageHeader(
                  title: t.manga_online_catalog_title,
                  subtitle: snapshot.seriesName,
                );
              },
            ),
          Expanded(
            child: MokuroMoeCatalogView(
              db: widget.db ?? appModel.database,
              embedded: true,
              enabledOverride: appModel.mangaOnlineCatalogEnabled,
              snapshotNotifier: _snapshot,
            ),
          ),
        ],
      ),
    );
  }
}
