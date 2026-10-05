import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/utils.dart';

/// 「查看更新日志」页（TODO-1310）：应用内在线拉取本仓库全部 GitHub releases，
/// 用 Markdown 渲染每个版本的发布说明（版本号 / 发布日期 / 预发布标记 / 正文）。
///
/// 数据经 [fetchAllGitHubReleases] 拉取，复用「检查更新」同一套镜像回退 + 代理注入
/// + 超时管线。`api.github.com` 列表 API 无镜像/302 逃生口（见该函数注释），纯 GFW
/// 无代理会拿到空列表——空态给「打开发布页」逃生口。
///
/// [customProxy] 由设置页透传（`appModel.updateCustomProxy`），与检查更新同源。
class ChangelogPage extends StatefulWidget {
  const ChangelogPage({
    super.key,
    this.customProxy = '',
    this.initialReleases,
  });

  final String customProxy;

  /// 测试注入口：非 null 时跳过网络拉取，直接以给定列表渲染（widget 测试无法也不该
  /// 打真实 GitHub API）。生产路径恒为 null，走 [UpdateChecker.fetchAllReleases]。
  @visibleForTesting
  final List<Map<String, dynamic>>? initialReleases;

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage>
    with FushiPagePlaceholders<ChangelogPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _releases = const <Map<String, dynamic>>[];

  static const String _releasesPageUrl =
      'https://github.com/$kGitHubRepo/releases';

  @override
  void initState() {
    super.initState();
    if (widget.initialReleases != null) {
      _releases = widget.initialReleases!;
      _loading = false;
      return;
    }
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final List<Map<String, dynamic>> releases =
        await fetchAllGitHubReleases(customProxy: widget.customProxy);
    if (!mounted) return;
    setState(() {
      _releases = releases;
      _loading = false;
    });
  }

  Future<void> _openReleasesPage() async {
    await launchUrl(
      Uri.parse(_releasesPageUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.settings_view_changelog,
      actions: <Widget>[
        FushiIconButton(
          icon: Icons.open_in_new_outlined,
          tooltip: t.changelog_open_releases,
          onTap: _openReleasesPage,
        ),
        FushiIconButton(
          icon: Icons.refresh,
          tooltip: t.refresh,
          onTap: _loading ? null : _load,
        ),
      ],
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return buildLoading();
    }
    if (_releases.isEmpty) {
      return _ChangelogEmptyState(
        onRetry: _load,
        onOpenReleases: _openReleasesPage,
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ListView.builder(
      // BUG-2440：scaffold 底部安全区不再从 viewport 扣掉，末条卡片得靠内容
      // padding 自己让开 home indicator / 手势条。
      padding: withBottomSafeInset(context, EdgeInsets.all(tokens.spacing.gap)),
      itemCount: _releases.length,
      itemBuilder: (BuildContext context, int index) {
        return Padding(
          padding: EdgeInsets.only(bottom: tokens.spacing.gap),
          child: _ReleaseCard(release: _releases[index]),
        );
      },
    );
  }
}

/// 空态 / 拉取失败：给「重试」与「打开发布页」两个逃生口。
class _ChangelogEmptyState extends StatelessWidget {
  const _ChangelogEmptyState({
    required this.onRetry,
    required this.onOpenReleases,
  });

  final VoidCallback onRetry;
  final VoidCallback onOpenReleases;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 统一空态：MD3 中性分组底块 / Apple 无底块大图标 + 灰字（各自在
    // FushiPlaceholderMessage 里分派），不再自画 outline 色图标 + 裸文字。
    return FushiPlaceholderMessage(
      icon: Icons.cloud_off_outlined,
      message: t.changelog_empty,
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          FushiOutlinedButton.icon(
            onPressed: onRetry,
            icon: const FushiIcon(Icons.refresh),
            label: Text(t.retry),
          ),
          FushiFilledButton.icon(
            onPressed: onOpenReleases,
            icon: const FushiIcon(Icons.open_in_new_outlined),
            label: Text(t.changelog_open_releases),
          ),
        ],
      ),
    );
  }
}

/// 单个版本卡片：版本号 + 通道徽标 + 发布日期 + Markdown 正文。
class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({required this.release});

  final Map<String, dynamic> release;

  /// 发布日期取 `published_at`（ISO8601）的日期段（`YYYY-MM-DD`）；缺失返空串。
  String get _publishedDate {
    final Object? raw = release['published_at'];
    if (raw is! String || raw.isEmpty) return '';
    final int tIndex = raw.indexOf('T');
    return tIndex > 0 ? raw.substring(0, tIndex) : raw;
  }

  /// 是否预发布：直接读 GitHub `prerelease` 字段（beta/debug 通道对"看更新日志"
  /// 的用户无区分意义，统一显示一个「预发布」徽标即可，不引入内部通道推断逻辑）。
  bool get _isPrerelease => release['prerelease'] == true;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final Object? tagName = release['tag_name'];
    final String title =
        tagName is String && tagName.isNotEmpty ? tagName : '—';
    final Object? bodyRaw = release['body'];
    final String body = bodyRaw is String ? bodyRaw.trim() : '';
    final String date = _publishedDate;

    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_isPrerelease) ...<Widget>[
                SizedBox(width: tokens.spacing.gap / 2),
                _ChannelBadge(label: t.changelog_prerelease),
              ],
            ],
          ),
          if (date.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.gap / 4),
            Text(date, style: tokens.type.metadata),
          ],
          if (body.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            MarkdownBody(
              data: body,
              selectable: true,
              // TODO-966: flutter_markdown 0.6.23 在 selectable 时会无条件解引用
              // onSelectionChanged!，不传则选中文本即崩；补空回调保留可选能力
              // （与 UpdateAvailableDialog 同一约定）。
              onSelectionChanged: (String? text, TextSelection selection,
                  SelectionChangedCause? cause) {},
              onTapLink: (_, String? href, __) {
                if (href == null) return;
                launchUrl(
                  Uri.parse(href),
                  mode: LaunchMode.externalApplication,
                );
              },
              styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                p: tokens.type.listSubtitle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChannelBadge extends StatelessWidget {
  const _ChannelBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    // 标签统一（2026-10-04）：不可交互小标签走共享 FushiTag（MD3 圆角 6
    // secondaryContainer，Apple 空心胶囊 + secondaryLabel 字）。
    return FushiTag(
      text: label,
      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
      dense: true,
    );
  }
}
