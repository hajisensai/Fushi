import 'package:flutter/material.dart';

import 'package:hibiki/src/pages/implementations/downloads_page.dart';
import 'package:hibiki/src/pages/implementations/torrent_settings_section.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/utils.dart';

/// 「下载」一级设置分类（阶段 G，演示新增大类路径）。
///
/// 病灶 4：torrent / qBittorrent 后端配置原本只藏在下载页右上角齿轮里，设置主页
/// 不可达、不可搜。这里把它抬成独立 destination：
/// - 一条可搜索的导航项直达下载页（搜「下载」即可命中本大类）；
/// - 正文经 [SettingsDestination.body] 逃生口内联既有 [TorrentSettingsSection]
///   组件（PR#300 正在重写该组件内部，本处只嵌入、绝不改写它），与下载页齿轮
///   共用同一份真相源（都写 `QbConnectionConfig`）。
///
/// 门控：下载页对 [TorrentSettingsSection] 无平台/特性门控（无引擎时组件自身回退
/// 外接 qBittorrent），故本 destination 亦恒可见——与下载底栏 tab 的可见性一致。
///
/// 新增/删除一级分类只需三处：[SettingsDestinationId] 加值、[buildSettingsSchema]
/// 注册本 builder、i18n（此处复用既有 `nav_downloads` / `download_settings`）。
SettingsDestination buildDownloadsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.downloads,
    title: t.nav_downloads,
    summary: t.download_settings,
    icon: Icons.download_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'downloads.open_page',
            title: t.nav_downloads,
            subtitle: t.download_settings,
            icon: Icons.download_outlined,
            showIcon: true,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const DownloadsPage(),
              );
            },
          ),
        ],
      ),
    ],
    // 内联既有 torrent 设置组件（不改写）。包一层 AdaptiveSettingsSection 让它拿到
    // 与其它 section 一致的卡片表面（body 契约：自带 section 布局、不自带脚手架/滚动）。
    // constrainWidth:false —— 下载页那套「560 居中限宽」在设置详情 pane 里会让本组
    // 左边缘变成 (paneWidth-560)/2，与其它 12 个分类的设置行完全对不齐。
    body: (SettingsContext context) => const AdaptiveSettingsSection(
      children: <Widget>[TorrentSettingsSection(constrainWidth: false)],
    ),
  );
}
