import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/dandanplay_client.dart';
import 'package:fushi/src/media/video/scraper/tmdb_default_key.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/utils.dart';
import 'package:url_launcher/url_launcher.dart';

/// 描述服务的用户侧准备工作，不持有账号或 API 密钥。
class OnlineServiceOnboardingItem {
  const OnlineServiceOnboardingItem({
    required this.id,
    required this.title,
    required this.requirement,
    required this.description,
    this.link,
  });

  final String id;
  final String title;
  final String requirement;
  final String description;
  final Uri? link;
}

/// 当前已接入服务的准备工作；资料源、发现和字幕保持各自职责。
List<OnlineServiceOnboardingItem> onlineServiceOnboardingItems() =>
    <OnlineServiceOnboardingItem>[
      OnlineServiceOnboardingItem(
        id: 'anidb',
        title: 'AniDB',
        requirement: t.onboarding_online_services_account,
        description: t.onboarding_online_services_anidb,
        link: Uri.parse('https://anidb.net/user/register'),
      ),
      OnlineServiceOnboardingItem(
        id: 'mal_anilist',
        title: 'MAL / Jikan · AniList',
        requirement: t.onboarding_online_services_ready,
        description: t.onboarding_online_services_public,
      ),
      OnlineServiceOnboardingItem(
        id: 'tmdb',
        title: 'TMDB',
        requirement: kBuiltinTmdbApiKey.trim().isNotEmpty
            ? t.onboarding_online_services_embedded
            : t.onboarding_online_services_key,
        description: kBuiltinTmdbApiKey.trim().isNotEmpty
            ? t.onboarding_online_services_tmdb
            : t.onboarding_online_services_tmdb_missing,
        link: Uri.parse('https://www.themoviedb.org/settings/api'),
      ),
      OnlineServiceOnboardingItem(
        id: 'jimaku',
        title: 'Jimaku',
        requirement: t.onboarding_online_services_key,
        description: t.onboarding_online_services_jimaku,
        link: Uri.parse('https://jimaku.cc/account'),
      ),
      OnlineServiceOnboardingItem(
        id: 'opensubtitles',
        title: 'OpenSubtitles',
        requirement: OpenSubtitlesConfig.embeddedApiKey.trim().isNotEmpty
            ? t.onboarding_online_services_embedded
            : t.onboarding_online_services_key,
        description: OpenSubtitlesConfig.embeddedApiKey.trim().isNotEmpty
            ? t.onboarding_online_services_opensubtitles_embedded
            : t.onboarding_online_services_opensubtitles,
        link: Uri.parse('https://www.opensubtitles.com/en/consumers'),
      ),
      OnlineServiceOnboardingItem(
        id: 'dandanplay',
        title: 'DanDanPlay',
        requirement: _dandanplayEmbedded
            ? t.onboarding_online_services_embedded
            : t.onboarding_online_services_build_missing,
        description: _dandanplayEmbedded
            ? t.onboarding_online_services_dandanplay
            : t.onboarding_online_services_dandanplay_missing,
      ),
      OnlineServiceOnboardingItem(
        id: 'servers',
        title: 'Torznab · Jellyfin / Emby · OPDS',
        requirement: t.onboarding_online_services_server,
        description: t.onboarding_online_services_servers,
      ),
    ];

bool get _dandanplayEmbedded =>
    DandanplayConfig.embeddedAppId.trim().isNotEmpty &&
    DandanplayConfig.embeddedAppSecret.trim().isNotEmpty;

/// 新手向导与视频提示共用的总览。展示和点击注册入口不会修改服务开关。
class OnlineServicesOnboardingView extends StatelessWidget {
  const OnlineServicesOnboardingView({
    required this.items,
    required this.onConfigure,
    required this.onOpenLink,
    super.key,
  });

  final List<OnlineServiceOnboardingItem> items;
  final VoidCallback onConfigure;
  final ValueChanged<Uri> onOpenLink;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(t.onboarding_online_services_title,
            style: theme.textTheme.headlineSmall),
        SizedBox(height: tokens.spacing.gap),
        Text(t.onboarding_online_services_body,
            style: theme.textTheme.bodyMedium),
        SizedBox(height: tokens.spacing.card),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            onPressed: onConfigure,
            icon: const Icon(Icons.settings_outlined),
            label: Text(t.onboarding_online_services_configure),
          ),
        ),
        SizedBox(height: tokens.spacing.card),
        for (final OnlineServiceOnboardingItem item in items)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: FushiCard(
              key: ValueKey<String>('online-service-${item.id}'),
              margin: EdgeInsets.zero,
              child: Padding(
                padding: EdgeInsets.all(tokens.spacing.card),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(item.title, style: theme.textTheme.titleMedium),
                    SizedBox(height: tokens.spacing.gap / 2),
                    Text(item.requirement,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                        )),
                    SizedBox(height: tokens.spacing.gap),
                    Text(item.description),
                    if (item.link != null) ...<Widget>[
                      SizedBox(height: tokens.spacing.gap),
                      TextButton.icon(
                        onPressed: () => onOpenLink(item.link!),
                        icon: const Icon(Icons.open_in_new_outlined),
                        label: Text(t.onboarding_online_services_link),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 视频横幅等入口使用独立页；设置编辑仍由现有在线服务页面负责。
class OnlineServicesOnboardingPage extends StatelessWidget {
  const OnlineServicesOnboardingPage({super.key});

  @override
  Widget build(BuildContext context) => FushiPageScaffold(
        title: t.settings_destination_services,
        body: SingleChildScrollView(
          // BUG-2440：scaffold 底部安全区不再从 viewport 扣掉，滚动内容末尾自己
          // 补上 home indicator / 手势条的高度。
          padding: withBottomSafeInset(context, const EdgeInsets.all(24)),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: OnlineServicesOnboardingView(
                items: onlineServiceOnboardingItems(),
                onConfigure: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsDetailPage(
                        destination: buildServicesDestination()),
                  ),
                ),
                onOpenLink: (Uri url) => launchUrl(
                  url,
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ),
          ),
        ),
      );
}
