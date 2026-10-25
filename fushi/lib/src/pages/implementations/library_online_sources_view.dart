import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi/utils.dart';

/// 库页的「来源」/「扩展」子标签：本库内容域的在线来源面。
///
/// 正文就是「浏览 › 来源 / 扩展」同一个 [BrowseOnlineSourcesView]，只是不再
/// 选内容域（库页本身就是那个域）。页头主位放库页壳交来的分段条，与其它库页视图
/// 同构。页头不挂动作：「扩展仓库」与导入 APK 在扩展目录批量安装那一排，刷新在
/// 「扩展仓库」页（2026-10-25 用户拍板：页头的仓库 / 刷新图标与正文重复，砍掉）。
///
/// 2026-10-01 用户拍板：浏览模块保留，发现 / 来源 / 扩展同时作为各库页的子标签
/// ——「往库里加东西」本来就该在库里找得到（OPDS 搬走后用户找不到）。
class LibraryOnlineSourcesView extends StatelessWidget {
  const LibraryOnlineSourcesView({
    required this.domain,
    required this.section,
    required this.navigation,
    super.key,
  }) : assert(section != OnlineSourcesSection.stores, '仓库是「扩展」目录里的动作，不是子标签');

  final OnlineSourcesDomain domain;
  final OnlineSourcesSection section;

  /// 库页壳交来的分段条，作为页头主位。
  final Widget navigation;

  @override
  Widget build(BuildContext context) {
    final Widget body = BrowseOnlineSourcesView(
      key: ValueKey<String>('library-${domain.name}-${section.name}'),
      domain: domain,
      section: section,
    );
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context))
            FushiPageHeader.customTitle(title: navigation),
          Expanded(child: body),
        ],
      ),
    );
  }
}
