import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/dandanplay_client.dart';
import 'package:fushi/src/media/video/scraper/tmdb_default_key.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
        id: 'subdl',
        title: 'SubDL',
        requirement: t.onboarding_online_services_key,
        description: t.onboarding_online_services_subdl,
        link: Uri.parse('https://subdl.com/panel/api'),
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

/// 服务条目在总览里的行首图标（按条目 id；未知 id 回落到云）。
IconData onlineServiceOnboardingIcon(String id) => switch (id) {
      'anidb' => FushiIcons.fingerprint,
      'mal_anilist' => FushiIcons.globe,
      'tmdb' => FushiIcons.video,
      'jimaku' || 'opensubtitles' || 'subdl' => FushiIcons.subtitles,
      'dandanplay' => FushiIcons.quote,
      'servers' => FushiIcons.server,
      _ => FushiIcons.cloud,
    };

/// 新手向导与视频提示共用的总览。展示和点击注册入口不会修改服务开关。
///
/// M3E：服务条目是一组分段卡片（首尾大圆角、行间 2px），行首是 M3E 形状图标底，
/// 「需要什么」是一枚 tonal 色块标签；条目错峰进场。[showHeader] = false 时不画
/// 自带的标题与说明（新手向导用自己的 hero 顶替）。
class OnlineServicesOnboardingView extends StatelessWidget {
  const OnlineServicesOnboardingView({
    required this.items,
    required this.onConfigure,
    required this.onOpenLink,
    this.showHeader = true,
    super.key,
  });

  final List<OnlineServiceOnboardingItem> items;
  final VoidCallback onConfigure;
  final ValueChanged<Uri> onOpenLink;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (showHeader) ...<Widget>[
            Text(t.onboarding_online_services_title,
                style: type.headlineSmallEmphasized),
            SizedBox(height: tokens.spacing.gap),
            Text(t.onboarding_online_services_body,
                style: type.bodyLarge.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )),
            SizedBox(height: tokens.spacing.card),
          ],
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiFilledButton.icon(
              onPressed: onConfigure,
              icon: const FushiIcon(FushiIcons.settings),
              label: Text(t.onboarding_online_services_configure),
            ),
          ),
          SizedBox(height: tokens.spacing.card),
          for (int i = 0; i < items.length; i++)
            FushiStaggeredEntrance(
              index: i,
              child: FushiGroupedListItem(
                key: ValueKey<String>('online-service-${items[i].id}'),
                index: i,
                count: items.length,
                child: _OnlineServiceRow(
                  item: items[i],
                  onOpenLink: onOpenLink,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _OnlineServiceRow extends StatelessWidget {
  const _OnlineServiceRow({required this.item, required this.onOpenLink});

  final OnlineServiceOnboardingItem item;
  final ValueChanged<Uri> onOpenLink;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          FushiListLeadingIcon(
            onlineServiceOnboardingIcon(item.id),
            shape: FushiLeadingShape.square,
          ),
          SizedBox(width: tokens.spacing.card),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap / 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(item.title,
                        style: context.fushiType.titleMediumEmphasized),
                    FushiTagChip(
                      label: item.requirement,
                      color: theme.colorScheme.tertiaryContainer,
                    ),
                  ],
                ),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(item.description,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
                if (item.link != null) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap / 2),
                  FushiTextButton.icon(
                    onPressed: () => onOpenLink(item.link!),
                    icon: const FushiIcon(FushiIcons.openInNew),
                    label: Text(t.onboarding_online_services_link),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 视频横幅等入口使用独立页；设置编辑仍由现有在线服务页面负责。
class OnlineServicesOnboardingPage extends StatelessWidget {
  const OnlineServicesOnboardingPage({super.key});

  @override
  Widget build(BuildContext context) => FushiPageScaffold(
        title: t.settings_destination_services,
        // Builder：正文要在页头脚手架之内取 MediaQuery 顶部让位（状态栏 + 浮动
        // 页头），内容才能滚到页头底下。
        body: Builder(
          builder: (BuildContext context) => SingleChildScrollView(
            // BUG-2440：scaffold 底部安全区不再从 viewport 扣掉，滚动内容末尾自己
            // 补上 home indicator / 手势条的高度。
            padding: withBottomSafeInset(
              context,
              EdgeInsets.all(FushiDesignTokens.of(context).spacing.page)
                  .copyWith(
                top: FushiDesignTokens.of(context).spacing.page +
                    MediaQuery.paddingOf(context).top,
              ),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: OnlineServicesOnboardingView(
                  items: onlineServiceOnboardingItems(),
                  onConfigure: () => Navigator.of(context).push<void>(
                    adaptivePageRoute<void>(
                      context: context,
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
        ),
      );
}
