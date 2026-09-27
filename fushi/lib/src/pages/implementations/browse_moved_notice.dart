/// 「下载」改名「浏览」（2026-09-27）的一次性搬迁提示。
///
/// 这次改造把发现页与漫画 / 视频 / 小说的在线来源从各库页、导入页搬进了「浏览」
/// （持久化键仍是历史名 `module_downloads_enabled`）。升级前把「下载」关掉的用户
/// 升级后照旧关着——尊重原开关，不替用户打开——但他们原来在库页里用得好好的
/// 发现与在线源就这样消失了。所有者 2026-09-28 拍板「保持关闭 + 提示」：只对这些
/// 用户弹一次，告诉他们东西搬到了哪里、在哪里打开。
///
/// 「只对升级前关着的用户」靠**首次启动新版时就落标记**实现：全新安装、升级前
/// 开着的用户在第一次判定时直接记成已处理；之后才关掉浏览的人不会再被提示。
library;

import 'package:flutter/material.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/utils.dart';

/// 一次判定的结果。
enum BrowseMovedNoticeDecision {
  /// 已处理过：什么都不做。
  none,

  /// 本安装不需要提示（全新安装 / 浏览开着 / 本平台没有浏览模块）：只落标记。
  markHandled,

  /// 升级前关着「下载」的用户：弹一次提示再落标记。
  show,
}

/// 纯判定（测试钉住）：[handled] 是已处理标记，[freshInstall] 是本次启动是否
/// 全新安装，[browseAvailable] 是本平台有没有浏览模块（iOS 按上架合规没有），
/// [browseEnabled] 是用户对浏览（原下载）模块的开关。
BrowseMovedNoticeDecision decideBrowseMovedNotice({
  required bool handled,
  required bool freshInstall,
  required bool browseAvailable,
  required bool browseEnabled,
}) {
  if (handled) return BrowseMovedNoticeDecision.none;
  if (freshInstall || !browseAvailable || browseEnabled) {
    return BrowseMovedNoticeDecision.markHandled;
  }
  return BrowseMovedNoticeDecision.show;
}

/// 首页首帧调用：按判定弹提示 / 落标记。标记在弹框**之前**落：弹框期间杀进程
/// 也不会下次再弹一遍（提示只是告知，不需要用户确认后才算数）。
Future<void> maybeShowBrowseMovedNotice({
  required BuildContext context,
  required AppModel appModel,
  required bool freshInstall,
}) async {
  final BrowseMovedNoticeDecision decision = decideBrowseMovedNotice(
    handled: appModel.browseMovedNoticeHandled,
    freshInstall: freshInstall,
    browseAvailable: ModuleId.browse.availableOn(
      isWindows: appModel.platformServices.isWindows,
      isDesktop: appModel.platformServices.isDesktop,
      isIOS: appModel.platformServices.isIOS,
      isAndroid: appModel.platformServices.isAndroid,
    ),
    browseEnabled: appModel.moduleEnabled(ModuleId.browse),
  );
  if (decision == BrowseMovedNoticeDecision.none) return;
  await appModel.setBrowseMovedNoticeHandled();
  if (decision != BrowseMovedNoticeDecision.show || !context.mounted) return;
  await showBrowseMovedNoticeDialog(context);
}

/// 提示框本体。路径里的每一段都取界面上真实显示的标签（底栏「浏览」、设置分类、
/// 「功能模块」节），改名时这里自动跟着变，不会指向一个不存在的名字。
Future<void> showBrowseMovedNoticeDialog(BuildContext context) {
  final String browse = t.nav_browse;
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      key: const ValueKey<String>('browse_moved_notice'),
      icon: const Icon(Icons.explore_outlined),
      title: Text(t.browse_moved_notice_title(browse: browse)),
      content: Text(
        t.browse_moved_notice_body(
          browse: browse,
          settings: t.settings,
          appearance: t.settings_destination_appearance_interaction,
          modules: t.settings_section_modules,
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('browse_moved_notice_ok'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(t.dialog_ok),
        ),
      ],
    ),
  );
}
