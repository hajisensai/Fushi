/// 库首页菜单 / 库内合集详情页「移出媒体库」前的确认框。
///
/// 移出删的是入库行本身：观看进度、挂载的字幕、标签、刮削附加信息随行消失，且没有
/// 撤销；从库页再加回来还得回服务器浏览页找到这部作品。所以这两个入口先确认。
/// 服务器详情页的「+ / −」就在作品旁边、点「+」即可加回，不走这里。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show showFushiConfirmDialog;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 弹确认框；用户确认返回 true。[title] 与菜单项同一文案（整部剧 / 单部作品）。
Future<bool> confirmMediaServerLibraryRemoval(
  BuildContext context, {
  required String title,
}) => showFushiConfirmDialog(
  context: context,
  title: title,
  message: t.video_online_library_remove_confirm,
  confirmLabel: t.video_online_library_remove,
  icon: FushiIcons.removeCircle,
  destructive: true,
);
