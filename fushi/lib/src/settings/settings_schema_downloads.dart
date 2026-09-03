import 'package:flutter/material.dart';

import 'package:fushi/src/pages/implementations/downloads_page.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/src/pages/implementations/video_external_provider_settings_section.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/utils.dart';

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
          // 副标题说清它打开的是下载**页**（任务 / 资源 / 订阅）。此前写的是
          // `download_settings`（「下载设置」），与本 destination 的 summary 同一个
          // 词——用户看到的就是「下载设置里面还有一个下载设置」。
          SettingsNavigationItem(
            id: 'downloads.open_page',
            title: t.nav_downloads,
            subtitle: t.settings_downloads_open_page_hint,
            icon: Icons.download_outlined,
            showIcon: true,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const DownloadsPage(),
              );
            },
          ),
          // 索引器 / 字幕来源 / 发现来源已迁到「在线服务」分区（第三方凭据一个家，
          // settings_schema_services.dart）；下载语境里留一条跳转。
          buildOpenServicesItem('downloads.online_services'),
        ],
      ),
    ],
    // 内联既有 torrent 设置组件（不改写）。包一层 AdaptiveSettingsSection 让它拿到
    // 与其它 section 一致的卡片表面（body 契约：自带 section 布局、不自带脚手架/滚动）。
    // 宽度：BUG-1858 起本组件只有一条规则——与普通设置行同一条 16px 左右基线、
    // 正文吃满剩下的宽度，不再有「560 居中限宽」那一档。
    // 下载落盘管道（路径映射 / 目标视频来源）是本机配置，跟在后端配置之后；它与
    // 后端表单是平级兄弟而非嵌套——各自承接同一条 rowHorizontal 基线。
    body: (SettingsContext context) => const AdaptiveSettingsSection(
      children: <Widget>[
        TorrentSettingsSection(),
        VideoExternalProviderSettingsSection(
          scope: VideoExternalProviderScope.downloadRouting,
        ),
      ],
    ),
  );
}
