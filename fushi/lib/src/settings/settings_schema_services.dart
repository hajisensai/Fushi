import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/dandanplay_client.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/media/video/scraper/tmdb_default_key.dart';
import 'package:fushi/src/media/video/video_settings_actions.dart';
import 'package:fushi/src/pages/implementations/discovery_source_settings_section.dart';
import 'package:fushi/src/pages/implementations/video_external_provider_settings_section.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/sync/jellyfin_settings_widget.dart';
import 'package:fushi/utils.dart';

/// 「在线服务」一级设置分类：第三方 API / 索引器 / 媒体服务器的凭据与端点。
///
/// 此前这些东西按「服务于哪个媒介」散在两页：字幕两家（Jimaku / OpenSubtitles）
/// 在视频页与下载页各挂一份同一组件，刮削三家（AniDB / TMDB / Jellyfin）在视频，
/// 索引器（内置来源 / Torznab / 发现来源）在下载，Dandanplay 服务器在视频·弹幕。
/// 用户在视频页配完 Jimaku 不知道下载页还有 Torznab；BUG-1712 的双挂载修法是把
/// 症状固化成结构。互联分区那条「同步主机服务配置」开关早已把这组服务当成一个
/// 整体下发（interconnect_service_config.dart），设置页却没有对应的编辑面。
///
/// 成员判据：**第三方**在线服务的凭据/端点/开关。不归此的：qBittorrent（本机下载
/// 后端）、云盘备份后端（与同步模式选择器绑死）、AnkiConnect / Yomitan（各自域的
/// 核心集成）。持久化键一个不动——只是编辑面搬家，零数据迁移。
///
/// 原分区各留一条 [buildOpenServicesItem] 跳转行，用户在字幕/下载语境里仍一步可达。
SettingsDestination buildServicesDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.services,
    title: t.settings_destination_services,
    summary: t.settings_destination_services_summary,
    icon: Icons.cloud_outlined,
    sections: <SettingsSection>[
      // ── 字幕来源（Jimaku + OpenSubtitles + 默认字幕语言）────────────────
      // 两家 registry 并列（video_subtitle_registry.dart），必须并列出现在同一节。
      SettingsSection(
        title: t.section_services_subtitles,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'services.subtitle_sources',
            // 搜索得命中两家品牌名，否则搜 "Jimaku" 会是死胡同。
            searchTitle: 'Jimaku · ${t.video_opensubtitles_settings_title}',
            builder: (SettingsContext settingsContext) =>
                const VideoExternalProviderSettingsSection(
              scope: VideoExternalProviderScope.subtitleSources,
            ),
          ),
        ],
      ),
      // ── 资源索引器（内置来源 / Torznab / 发现来源）──────────────────────
      // 三块「来源开关」同屏可比，用户不必去三个页面找同一件事。
      SettingsSection(
        title: t.section_services_resources,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'services.resource_sources',
            searchTitle: '${t.video_builtin_sources_title} · '
                '${t.video_torznab_settings_title}',
            builder: (SettingsContext settingsContext) =>
                const VideoExternalProviderSettingsSection(
              scope: VideoExternalProviderScope.resourceSources,
            ),
          ),
          SettingsCustomItem(
            id: 'services.discovery_sources',
            searchTitle: t.discovery_sources_settings_title,
            builder: (SettingsContext settingsContext) =>
                const DiscoverySourceSettingsSection(),
          ),
        ],
      ),
      // ── 元数据刮削（AniDB 身份 + TMDB 补充）─────────────────────────────
      // 刮削语言等行为偏好仍在视频·媒体库；这里只放服务凭据。写 prefsRepo 后
      // 重建下载刮削快照（commitVideoMetadataRuntimePreference）。
      SettingsSection(
        title: t.section_services_metadata,
        items: <SettingsItem>[
          SettingsTextItem(
            id: 'services.metadata.anidb_client',
            title: t.video_source_scrape_anidb_client,
            subtitle: t.video_source_scrape_anidb_client_hint,
            icon: Icons.badge_outlined,
            value: (SettingsContext settingsContext) => settingsContext
                .appModel.prefsRepo
                .getPref(kVideoMetadataAniDbClientNamePref,
                    defaultValue: '') as String,
            onChanged: (SettingsContext settingsContext, String value) async {
              await commitVideoMetadataRuntimePreference(
                settingsContext,
                kVideoMetadataAniDbClientNamePref,
                value,
              );
            },
          ),
          SettingsTextItem(
            id: 'services.metadata.anidb_client_version',
            title: t.video_source_scrape_anidb_client_version,
            subtitle: t.video_source_scrape_anidb_client_version_hint,
            icon: Icons.numbers_outlined,
            placeholder: '1',
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.prefsRepo.getPref(
              kVideoMetadataAniDbClientVersionPref,
              defaultValue: '',
            ) as String,
            onChanged: (SettingsContext settingsContext, String value) async {
              await commitVideoMetadataRuntimePreference(
                settingsContext,
                kVideoMetadataAniDbClientVersionPref,
                value,
              );
            },
          ),
          // 自定义 TMDB API key —— **内置 key 的逃生口**，不是必填项。
          //
          // 刮削默认用随包内置的项目 key（见 tmdb_default_key.dart），绝大多数用户
          // 永远不需要碰这里。留这个入口只为两种情况：① 内置 key 被 TMDB 吊销/限流
          // 时用户能自救；② 用户想用自己的配额。留空 = 用内置 key。
          //
          // secret: true → 明文遮蔽 + 眼睛按钮，与其它 API key 项一致。
          SettingsTextItem(
            id: 'services.metadata.tmdb_api_key',
            title: t.video_setting_tmdb_key,
            subtitle: t.video_setting_tmdb_key_hint,
            icon: Icons.key_outlined,
            secret: true,
            value: (SettingsContext settingsContext) => settingsContext
                    .appModel.prefsRepo
                    .getPref(kVideoScraperTmdbApiKeyPref, defaultValue: '')
                as String,
            onChanged: (SettingsContext settingsContext, String value) =>
                commitVideoMetadataRuntimePreference(
              settingsContext,
              kVideoScraperTmdbApiKeyPref,
              value,
            ),
          ),
        ],
      ),
      // ── 媒体服务器（Jellyfin / Emby）───────────────────────────────────
      // 登录后服务器条目混排进视频库网格（home_video_page 远端源解析链），
      // 点击直连串流播放；配置读写全在 JellyfinConfigWidget（SyncRepository
      // `sync_jellyfin_server`，设备本地键，不随备份跨设备）。
      SettingsSection(
        title: t.jellyfin_settings_title,
        collapsedByDefault: true,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'services.media_server.jellyfin',
            // 搜索得命中品牌名（Jellyfin/Emby），t 标题只有「媒体服务器」语义。
            searchTitle: 'Jellyfin · Emby · ${t.jellyfin_settings_title}',
            builder: (SettingsContext settingsContext) =>
                JellyfinConfigWidget(settingsContext: settingsContext),
          ),
        ],
      ),
      // ── 弹幕（Dandanplay 服务器）────────────────────────────────────────
      // 只剩自建/镜像服务器地址（高级项，空=官方 api.dandanplay.net）。官方
      // AppId/AppSecret 已内置（dandanplay_secret.dart，见
      // DandanplayConfig.embeddedAppId），请求自动 v2 签名，用户**无需手动输入
      // API**——故原 AppId/AppSecret 两个输入框已删除。写入 videoDanmakuConfig
      // （纯 pref），同步推进程级 DandanplayConfig.current，下次匹配弹幕即生效。
      // 弹幕的行为开关（启用/在线匹配/同屏上限）留在视频·弹幕。
      SettingsSection(
        title: t.section_video_danmaku,
        collapsedByDefault: true,
        items: <SettingsItem>[
          SettingsTextItem(
            id: 'services.danmaku.server_url',
            title: t.video_setting_danmaku_server_url,
            icon: Icons.dns_outlined,
            keyboardType: TextInputType.url,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoDanmakuConfig.baseUrl,
            onChanged: (SettingsContext settingsContext, String value) async {
              final DandanplayConfig current =
                  settingsContext.appModel.videoDanmakuConfig;
              await settingsContext.appModel.setVideoDanmakuConfig(
                current.copyWith(baseUrl: value.trim()),
              );
              settingsContext.refresh();
            },
          ),
        ],
      ),
    ],
  );
}

/// 从别的分区跳到「在线服务」的导航行（视频·字幕、下载各放一条）。
///
/// 迁走的条目不在原地留副本——那正是 BUG-1712 双挂载的老路；留一条跳转让原语境
/// 里的用户一步到达。推整页详情路由而非切主从选中态：主从壳没有对外的选分区
/// API，而 pushed 详情页在宽/窄两种布局下都成立（搜索结果在窄屏也是这样跳的）。
SettingsNavigationItem buildOpenServicesItem(String id) {
  return SettingsNavigationItem(
    id: id,
    title: t.settings_destination_services,
    subtitle: t.settings_services_link_subtitle,
    icon: Icons.cloud_outlined,
    showIcon: true,
    onTap: (SettingsContext settingsContext) async {
      await pushSettingsPage(
        settingsContext,
        (_) => SettingsDetailPage(destination: buildServicesDestination()),
      );
    },
  );
}
