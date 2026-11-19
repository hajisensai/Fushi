/// 设置 · 关于 ·「免费与开源声明」：Fushi 是 GPLv3 授权的免费开源软件、官方版本永久免费、
/// 付了钱怎么办、官方获取渠道与附加条款 / 商标政策链接。本地构建提示生效时
/// （build_listing.dart 的 [localNoticeActive]），页首多一行醒目提示。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/updates/build_listing.dart';
import 'package:fushi/src/updates/notice_layer.dart' show openNoticeUrl;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/official_links.dart';

/// GitHub Releases 下载页。
const String kFushiReleasesUrl = 'https://github.com/hajisensai/Fushi/releases';

/// 仓库里的 GPLv3 第 7 节附加条款。
const String kFushiAdditionalTermsUrl =
    'https://github.com/hajisensai/Fushi/blob/develop/ADDITIONAL_TERMS.md';

/// 仓库里的商标政策。
const String kFushiTrademarkUrl =
    'https://github.com/hajisensai/Fushi/blob/develop/TRADEMARK.md';

/// 「免费与开源声明」页。[showLocalNotice] 为 null 时按 [localNoticeActive] 决定是否显示页首提示
/// （测试可直接给定）。
class FreeSoftwareStatementPage extends StatelessWidget {
  const FreeSoftwareStatementPage({this.showLocalNotice, super.key});

  final bool? showLocalNotice;

  @override
  Widget build(BuildContext context) {
    final bool? given = showLocalNotice;
    return AdaptiveSettingsScaffold(
      title: Text(t.settings_system_free_software_statement),
      children: <Widget>[
        if (given != null)
          _StatementBody(showLocalNotice: given)
        else
          FutureBuilder<bool>(
            future: localNoticeActive(),
            builder: (BuildContext context, AsyncSnapshot<bool> snapshot) =>
                _StatementBody(showLocalNotice: snapshot.data ?? false),
          ),
      ],
    );
  }
}

class _StatementBody extends StatelessWidget {
  const _StatementBody({required this.showLocalNotice});

  final bool showLocalNotice;

  Widget _link({
    required String id,
    required String title,
    required String url,
    required IconData icon,
  }) {
    return FushiPressScale(
      child: AdaptiveSettingsNavigationRow(
        key: ValueKey<String>('free-software-$id'),
        title: title,
        subtitle: url.replaceFirst('https://', ''),
        icon: icon,
        showIcon: true,
        onTap: () => unawaited(openNoticeUrl(Uri.parse(url))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> blocks = <Widget>[
      if (showLocalNotice) _LocalNoticeCard(text: currentLocalNoticeText()),
      Padding(
        padding: EdgeInsets.only(bottom: tokens.spacing.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              t.settings_free_software_license_body,
              key: const ValueKey<String>('free-software-license'),
              style: theme.textTheme.bodyLarge,
            ),
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.settings_free_software_free_forever,
              style: theme.textTheme.titleMedium,
            ),
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.settings_free_software_paid_advice,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      AdaptiveSettingsSection(
        title: t.settings_free_software_channels,
        children: <Widget>[
          _link(
            id: 'releases',
            title: t.settings_free_software_github_releases,
            url: kFushiReleasesUrl,
            icon: FushiIcons.download,
          ),
          _link(
            id: 'website',
            title: t.settings_free_software_website,
            url: kOfficialWebsiteUrl,
            icon: FushiIcons.language,
          ),
        ],
      ),
      AdaptiveSettingsSection(
        title: t.settings_free_software_terms,
        children: <Widget>[
          _link(
            id: 'additional-terms',
            title: t.settings_free_software_additional_terms,
            url: kFushiAdditionalTermsUrl,
            icon: FushiIcons.code,
          ),
          _link(
            id: 'trademark',
            title: t.settings_free_software_trademark,
            url: kFushiTrademarkUrl,
            icon: FushiIcons.shield,
          ),
        ],
      ),
    ];
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < blocks.length; i++)
            FushiStaggeredEntrance(index: i, child: blocks[i]),
        ],
      ),
    );
  }
}

/// 页首醒目提示（本地构建提示生效时）。
class _LocalNoticeCard extends StatelessWidget {
  const _LocalNoticeCard({required this.text});

  final LocalNoticeText text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: FushiPressScale(
          child: Material(
            key: const ValueKey<String>('free-software-local-notice'),
            color: cs.errorContainer,
            borderRadius: tokens.radii.cardRadius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => unawaited(openNoticeUrl(text.url)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: <Widget>[
                      FushiIcon(FushiIcons.warning, color: cs.onErrorContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          text.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: cs.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
