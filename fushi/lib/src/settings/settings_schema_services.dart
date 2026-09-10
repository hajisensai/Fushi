import 'package:flutter/material.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:fushi/src/media/video/dandanplay_client.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/media/video/scraper/tmdb_default_key.dart';
import 'package:fushi/src/media/video/video_settings_actions.dart';
import 'package:fushi/src/pages/implementations/discovery_source_settings_section.dart';
import 'package:fushi/src/pages/implementations/opds_server_settings_section.dart';
import 'package:fushi/src/pages/implementations/video_external_provider_settings_section.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/sync/jellyfin_settings_widget.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart'
    show JellyfinServerConfig;
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';

/// 「在线服务」一级设置分类：第三方 API / 索引器 / 媒体服务器的凭据与端点。
///
/// 此前这些东西按「服务于哪个媒介」散在两页：字幕两家（Jimaku / OpenSubtitles）
/// 在视频页与下载页各挂一份同一组件，刮削三家（MAL / TMDB / AniDB 文件识别 / Jellyfin）在视频，
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
    // 「功能模块」门控：关掉本模块 = 整条分类不渲染 / 不进搜索索引 / 主从详情不可选
    // （三条渲染路径共用 isVisible）。归属表见 module_registry.dart，别在此另写判据。
    visible: (SettingsContext c) => isSettingsDestinationVisible(
      SettingsDestinationId.services,
      c.appModel.moduleVisibility,
    ),
    title: t.settings_destination_services,
    summary: t.settings_destination_services_summary,
    icon: Icons.cloud_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'services.subtitles',
        title: t.section_services_subtitles,
        items: <SettingsItem>[
          _externalServicePage(
            id: 'services.jimaku',
            title: 'Jimaku',
            scope: VideoExternalProviderScope.jimaku,
            status: (SettingsContext c) => !c.appModel.jimakuEnabled
                ? t.settings_service_disabled
                : c.appModel.jimakuApiKey.trim().isEmpty
                ? t.settings_service_not_configured
                : t.settings_service_configured,
            entries: <SettingsBodySearchEntry>[
              SettingsBodySearchEntry(
                id: 'services.jimaku.api_key',
                title: t.video_jimaku_api_key,
                hasRevealTarget: true,
              ),
            ],
          ),
          _externalServicePage(
            id: 'services.opensubtitles',
            title: t.video_opensubtitles_settings_title,
            scope: VideoExternalProviderScope.openSubtitles,
            status: (SettingsContext c) {
              final OpenSubtitlesConfig config =
                  c.appModel.prefsRepo.videoSubtitleOpenSubtitlesConfig ??
                  OpenSubtitlesConfig(apiKey: '');
              if (!config.enabled) {
                return t.settings_service_disabled;
              }
              if (config.effectiveApiKey.isEmpty) {
                return t.settings_service_not_configured;
              }
              return config.apiKey.trim().isEmpty
                  ? t.settings_service_builtin
                  : t.settings_service_configured;
            },
            entries: <SettingsBodySearchEntry>[
              SettingsBodySearchEntry(
                id: 'services.opensubtitles.endpoint',
                title: t.video_opensubtitles_endpoint,
                hasRevealTarget: true,
              ),
              SettingsBodySearchEntry(
                id: 'services.opensubtitles.api_key',
                title: t.video_external_api_key,
                hasRevealTarget: true,
              ),
              SettingsBodySearchEntry(
                id: 'services.opensubtitles.username',
                title: t.video_external_username_optional,
                hasRevealTarget: true,
              ),
              SettingsBodySearchEntry(
                id: 'services.opensubtitles.password',
                title: t.video_external_password_optional,
                hasRevealTarget: true,
              ),
              SettingsBodySearchEntry(
                id: 'services.opensubtitles.user_agent',
                title: t.video_opensubtitles_user_agent,
                hasRevealTarget: true,
              ),
            ],
          ),
          SettingsCustomItem(
            id: 'services.subtitle_preferences',
            searchTitle: 'AJATT · ${t.video_setting_jimaku_default_language}',
            builder: (SettingsContext c) =>
                const VideoExternalProviderSettingsSection(
                  scope: VideoExternalProviderScope.subtitlePreferences,
                ),
          ),
        ],
      ),
      SettingsSection(
        id: 'services.resources',
        title: t.section_services_resources,
        // iOS 上整节不渲染：内置索引器、Torznab、发现来源、OPDS 服务器四项配置的
        // 全部消费端（发现页与下载中心）都已按 App Store 合规移除
        // （[StoreRestrictedCapability.externalDiscovery]），留着就是一组配了也
        // 不会生效的字段。用 section 级 `visible` 而不是逐项加判据：三条渲染路径
        // （分类正文 / 主从详情 / 设置搜索索引）共用它，逐项写会漏掉搜索索引。
        visible: (_) => StoreRestrictedCapability.externalDiscovery.isAvailable,
        items: <SettingsItem>[
          _externalServicePage(
            id: 'services.builtin_sources',
            title: t.video_builtin_sources_title,
            scope: VideoExternalProviderScope.builtinSources,
            status: (SettingsContext c) => t.settings_service_builtin,
          ),
          _externalServicePage(
            id: 'services.torznab',
            title: t.video_torznab_settings_title,
            scope: VideoExternalProviderScope.torznab,
            status: (SettingsContext c) =>
                c.appModel.prefsRepo.videoResourceTorznabConfigs.isEmpty
                ? t.settings_service_not_configured
                : c.appModel.prefsRepo.videoResourceTorznabConfigs.any(
                    (TorznabIndexerConfig config) => config.enabled,
                  )
                ? t.settings_service_configured
                : t.settings_service_disabled,
          ),
          _servicePage(
            id: 'services.discovery_sources',
            title: t.discovery_sources_settings_title,
            status: (SettingsContext c) => t.settings_service_builtin,
            body: (SettingsContext c) => const DiscoverySourceSettingsSection(),
          ),
          _servicePage(
            id: 'services.opds_servers',
            title: t.discovery_opds_settings_title,
            status: (SettingsContext c) =>
                c.appModel.prefsRepo.discoveryOpdsServers.isEmpty
                ? t.settings_service_not_configured
                : t.settings_service_configured,
            body: (SettingsContext c) => const OpdsServerSettingsSection(),
          ),
        ],
      ),
      SettingsSection(
        id: 'services.metadata',
        title: t.section_services_metadata,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'services.metadata.configure',
            title: 'AniDB',
            subtitleBuilder: (SettingsContext c) {
              if (!(c.appModel.prefsRepo.getPref(
                    kVideoAniDbHashEnabledPref,
                    defaultValue: false,
                  )
                  as bool)) {
                return t.settings_service_disabled;
              }
              return <String>[
                    kVideoAniDbUsernamePref,
                    kVideoAniDbPasswordPref,
                    kVideoMetadataAniDbClientNamePref,
                    kVideoMetadataAniDbClientVersionPref,
                  ].every(
                    (String key) =>
                        (c.appModel.prefsRepo.getPref(key, defaultValue: '')
                                as String)
                            .trim()
                            .isNotEmpty,
                  )
                  ? t.settings_service_configured
                  : t.settings_service_not_configured;
            },
            child: () => SettingsDestination(
              id: SettingsDestinationId.services,
              title: t.section_services_metadata,
              icon: Icons.fingerprint,
              sections: <SettingsSection>[
                SettingsSection(
                  id: 'services.metadata.credentials',
                  items: <SettingsItem>[
                    SettingsSwitchItem(
                      id: 'services.metadata.anidb_hash_enabled',
                      title: t.video_anidb_hash_enabled,
                      subtitle: t.video_anidb_hash_hint,
                      icon: Icons.fingerprint,
                      value: (SettingsContext settingsContext) =>
                          settingsContext.appModel.prefsRepo.getPref(
                                kVideoAniDbHashEnabledPref,
                                defaultValue: false,
                              )
                              as bool,
                      onChanged:
                          (SettingsContext settingsContext, bool value) async {
                            await settingsContext.appModel.prefsRepo.setPref(
                              kVideoAniDbHashEnabledPref,
                              value,
                            );
                            await settingsContext.appModel
                                .reloadVideoDownloadPipelineRuntime();
                          },
                    ),
                    SettingsTextItem(
                      id: 'services.metadata.anidb_username',
                      title: t.video_anidb_username,
                      icon: Icons.person_outline,
                      value: (SettingsContext settingsContext) =>
                          settingsContext.appModel.prefsRepo.getPref(
                                kVideoAniDbUsernamePref,
                                defaultValue: '',
                              )
                              as String,
                      onChanged:
                          (SettingsContext settingsContext, String value) =>
                              commitVideoMetadataRuntimePreference(
                                settingsContext,
                                kVideoAniDbUsernamePref,
                                value,
                              ),
                    ),
                    SettingsTextItem(
                      id: 'services.metadata.anidb_password',
                      title: t.video_anidb_password,
                      icon: Icons.lock_outline,
                      secret: true,
                      value: (SettingsContext settingsContext) =>
                          settingsContext.appModel.prefsRepo.getPref(
                                kVideoAniDbPasswordPref,
                                defaultValue: '',
                              )
                              as String,
                      onChanged:
                          (SettingsContext settingsContext, String value) =>
                              commitVideoMetadataRuntimePreference(
                                settingsContext,
                                kVideoAniDbPasswordPref,
                                value,
                                trimValue: false,
                              ),
                    ),
                    SettingsTextItem(
                      id: 'services.metadata.anidb_client',
                      title: t.video_source_scrape_anidb_client,
                      subtitle: t.video_source_scrape_anidb_client_hint,
                      icon: Icons.badge_outlined,
                      value: (SettingsContext settingsContext) =>
                          settingsContext.appModel.prefsRepo.getPref(
                                kVideoMetadataAniDbClientNamePref,
                                defaultValue: '',
                              )
                              as String,
                      onChanged:
                          (
                            SettingsContext settingsContext,
                            String value,
                          ) async {
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
                              )
                              as String,
                      onChanged:
                          (
                            SettingsContext settingsContext,
                            String value,
                          ) async {
                            await commitVideoMetadataRuntimePreference(
                              settingsContext,
                              kVideoMetadataAniDbClientVersionPref,
                              value,
                            );
                          },
                    ),
                  ],
                ),
              ],
            ),
          ),
          SettingsNavigationItem(
            id: 'services.metadata.tmdb',
            title: 'TMDB',
            subtitleBuilder: (SettingsContext c) =>
                (c.appModel.prefsRepo.getPref(
                          kVideoScraperTmdbApiKeyPref,
                          defaultValue: '',
                        )
                        as String)
                    .trim()
                    .isEmpty
                ? t.settings_service_builtin
                : t.settings_service_configured,
            child: () => SettingsDestination(
              id: SettingsDestinationId.services,
              title: 'TMDB',
              icon: Icons.key_outlined,
              sections: <SettingsSection>[
                SettingsSection(
                  id: 'services.tmdb.credentials',
                  items: <SettingsItem>[
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
                      value: (SettingsContext settingsContext) =>
                          settingsContext.appModel.prefsRepo.getPref(
                                kVideoScraperTmdbApiKeyPref,
                                defaultValue: '',
                              )
                              as String,
                      onChanged:
                          (SettingsContext settingsContext, String value) =>
                              commitVideoMetadataRuntimePreference(
                                settingsContext,
                                kVideoScraperTmdbApiKeyPref,
                                value,
                              ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      SettingsSection(
        id: 'services.media',
        title: t.jellyfin_settings_title,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'services.media_server.jellyfin',
            searchTitle: 'Jellyfin · Emby · ${t.jellyfin_settings_title}',
            builder: (SettingsContext c) =>
                _JellyfinSettingsLink(settingsContext: c),
          ),
          SettingsNavigationItem(
            id: 'services.danmaku.configure',
            title: 'Dandanplay',
            subtitleBuilder: (SettingsContext c) =>
                c.appModel.videoDanmakuConfig.baseUrl.trim().isEmpty
                ? t.settings_service_builtin
                : t.settings_service_configured,
            child: () => SettingsDestination(
              id: SettingsDestinationId.services,
              title: 'Dandanplay',
              icon: Icons.dns_outlined,
              sections: <SettingsSection>[
                SettingsSection(
                  id: 'services.danmaku.endpoint',
                  items: <SettingsItem>[
                    SettingsTextItem(
                      id: 'services.danmaku.server_url',
                      title: t.video_setting_danmaku_server_url,
                      icon: Icons.dns_outlined,
                      keyboardType: TextInputType.url,
                      value: (SettingsContext settingsContext) =>
                          settingsContext.appModel.videoDanmakuConfig.baseUrl,
                      onChanged:
                          (
                            SettingsContext settingsContext,
                            String value,
                          ) async {
                            final DandanplayConfig current =
                                settingsContext.appModel.videoDanmakuConfig;
                            await settingsContext.appModel
                                .setVideoDanmakuConfig(
                                  current.copyWith(baseUrl: value.trim()),
                                );
                            settingsContext.refresh();
                          },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ],
  );
}

SettingsNavigationItem _externalServicePage({
  required String id,
  required String title,
  required VideoExternalProviderScope scope,
  required SettingsSubtitleBuilder status,
  List<SettingsBodySearchEntry> entries = const <SettingsBodySearchEntry>[],
}) => _servicePage(
  id: id,
  title: title,
  status: status,
  entries: entries,
  body: (SettingsContext c) =>
      VideoExternalProviderSettingsSection(scope: scope),
);

SettingsNavigationItem _servicePage({
  required String id,
  required String title,
  required SettingsSubtitleBuilder status,
  required SettingsItemBuilder body,
  List<SettingsBodySearchEntry> entries = const <SettingsBodySearchEntry>[],
}) => SettingsNavigationItem(
  id: id,
  title: title,
  subtitleBuilder: status,
  child: () => SettingsDestination(
    id: SettingsDestinationId.services,
    title: title,
    icon: Icons.cloud_outlined,
    sections: const <SettingsSection>[],
    body: body,
    bodySearchEntries: entries,
  ),
);

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
    // 与它指向的分类同门控：services 模块关掉时整行不渲染。留着就是一条通往已关
    // 模块的暗门（宿主分类——视频 / 下载——可能仍开着，所以宿主的 destination 级
    // 门控盖不住这一行）。
    visible: (SettingsContext c) => isSettingsDestinationVisible(
      SettingsDestinationId.services,
      c.appModel.moduleVisibility,
    ),
    onTap: (SettingsContext settingsContext) async {
      await pushSettingsPage(
        settingsContext,
        (_) => SettingsDetailPage(destination: buildServicesDestination()),
      );
    },
  );
}

/// Reads saved authentication locally; a saved token is configuration, not proof
/// of a currently reachable server. Network validation remains in its real page.
class _JellyfinSettingsLink extends StatefulWidget {
  const _JellyfinSettingsLink({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_JellyfinSettingsLink> createState() => _JellyfinSettingsLinkState();
}

class _JellyfinSettingsLinkState extends State<_JellyfinSettingsLink> {
  late Future<JellyfinServerConfig?> _config;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _config = SyncRepository(
      widget.settingsContext.appModel.database,
    ).getJellyfinServer();
  }

  Future<void> _open() async {
    await pushSettingsPage(
      widget.settingsContext,
      (_) => SettingsDetailPage(
        destination: SettingsDestination(
          id: SettingsDestinationId.services,
          title: 'Jellyfin · Emby',
          icon: Icons.cloud_outlined,
          sections: const <SettingsSection>[],
          body: (SettingsContext c) => JellyfinConfigWidget(settingsContext: c),
        ),
      ),
    );
    if (mounted) {
      setState(_load);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<JellyfinServerConfig?>(
    future: _config,
    builder:
        (BuildContext context, AsyncSnapshot<JellyfinServerConfig?> snapshot) =>
            AdaptiveSettingsNavigationRow(
              title: 'Jellyfin · Emby',
              subtitle: snapshot.connectionState != ConnectionState.done
                  ? t.jellyfin_settings_title
                  : snapshot.data == null
                  ? t.settings_service_not_configured
                  : t.settings_service_configured,
              onTap: _open,
            ),
  );
}
