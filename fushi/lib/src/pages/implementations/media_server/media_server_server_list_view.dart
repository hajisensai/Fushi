import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_home_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/utils.dart';

/// 一台已登录的媒体服务器（浏览器 + 展示用账号名 + 线路）。账号名与线路都不在
/// [MediaServerBrowser] 契约里（契约只管浏览与播放），由装配处从服务器配置带来。
class MediaServerEntry {
  const MediaServerEntry({
    required this.browser,
    this.accountName,
    this.routeUrls = const <String>[],
    this.onSwitchRoute,
  });

  final MediaServerBrowser browser;
  final String? accountName;

  /// 这台服务器的全部访问地址（登录地址在首位）；少于两条 = 卡片不出切换入口。
  /// 当前线路就是 [MediaServerBrowser.serverUrl]（浏览器按当前线路建）。
  final List<String> routeUrls;

  /// 切到某条线路（写配置 + 失效缓存槽）；完成后列表重取，新浏览器按新线路建。
  final Future<void> Function(String url)? onSwitchRoute;

  bool get canSwitchRoute => onSwitchRoute != null && routeUrls.length > 1;
}

/// 「选择服务器」：每台一张卡（服务器名 / URL / 账号），点进那台的首页。
/// 只有一台时**首屏直接进那台的首页**（列表在返回时才出现）。空态 = 提示 +
/// 「去设置添加服务器」。
class MediaServerListView extends StatefulWidget {
  const MediaServerListView({
    required this.navigation,
    required this.loadServers,
    required this.play,
    required this.onOpenSettings,
    super.key,
  });

  /// 分区页签（由视频壳传入，放页头）。
  final Widget navigation;
  final Future<List<MediaServerEntry>> Function() loadServers;
  final MediaServerPlayHandler play;
  final VoidCallback onOpenSettings;

  @override
  State<MediaServerListView> createState() => _MediaServerListViewState();
}

class _MediaServerListViewState extends State<MediaServerListView> {
  late Future<List<MediaServerEntry>> _future = widget.loadServers();

  /// 单台直进只做一次：用户从首页按返回回到列表时，列表就该老实待着。
  bool _autoEntered = false;

  void _reload() {
    setState(() {
      _future = widget.loadServers();
    });
  }

  void _openServer(MediaServerEntry entry) {
    final MediaServerSession session = MediaServerSession(
      browser: entry.browser,
      play: widget.play,
    );
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) =>
            MediaServerHomeView(session: session, showBackButton: true),
      ),
    );
  }

  void _maybeAutoEnter(List<MediaServerEntry> servers) {
    if (_autoEntered || servers.length != 1) return;
    _autoEntered = true;
    // 在 build 里不能 push；等这一帧画完再压首页上去。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _openServer(servers.single);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 本视图是嵌套 Navigator 里的一条路由：没有 Scaffold 就没有 Material 祖先。
    return Scaffold(
      body: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context))
            FushiPageHeader.customTitle(
              title: widget.navigation,
              actions: <Widget>[
                FushiIconButton(
                  key: const ValueKey<String>('media-server-list-refresh'),
                  icon: Icons.refresh_rounded,
                  tooltip: t.refresh,
                  focusId: const FushiFocusId('media-server-list-refresh'),
                  onTap: _reload,
                ),
              ],
            ),
          Expanded(
            child: FutureBuilder<List<MediaServerEntry>>(
              future: _future,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<MediaServerEntry>> snapshot,
                  ) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return Center(child: adaptiveIndicator(context: context));
                    }
                    if (snapshot.hasError) {
                      return FushiPlaceholderMessage(
                        icon: Icons.cloud_off_outlined,
                        message: t.media_server_items_load_failed,
                        detail: '${snapshot.error}',
                        action: FilledButton.icon(
                          onPressed: _reload,
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(t.retry),
                        ),
                      );
                    }
                    final List<MediaServerEntry> servers =
                        snapshot.data ?? const <MediaServerEntry>[];
                    if (servers.isEmpty) return _buildEmpty();
                    _maybeAutoEnter(servers);
                    return _buildList(servers);
                  },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return FushiPlaceholderMessage(
      icon: Icons.dns_outlined,
      message: t.media_server_servers_empty_hint,
      action: FilledButton.tonalIcon(
        key: const ValueKey<String>('media-server-list-go-settings'),
        onPressed: widget.onOpenSettings,
        icon: const Icon(Icons.settings_outlined),
        label: Text(t.media_server_servers_go_settings),
      ),
    );
  }

  Widget _buildList(List<MediaServerEntry> servers) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ListView(
      key: const PageStorageKey<String>('media-server-list'),
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.page,
        vertical: tokens.spacing.gap,
      ),
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(bottom: tokens.spacing.gap),
          child: Text(
            t.media_server_servers_title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        for (final MediaServerEntry entry in servers)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: _ServerCard(
              key: ValueKey<String>(
                'media-server-card-${entry.browser.serverId}',
              ),
              entry: entry,
              onTap: () => _openServer(entry),
              onSwitchRoute: (String url) async {
                await entry.onSwitchRoute?.call(url);
                if (mounted) _reload();
              },
            ),
          ),
      ],
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.entry,
    required this.onTap,
    required this.onSwitchRoute,
    super.key,
  });

  final MediaServerEntry entry;
  final VoidCallback onTap;
  final Future<void> Function(String url) onSwitchRoute;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MediaServerBrowser browser = entry.browser;
    final String? account = entry.accountName;
    return FushiCard(
      onTap: onTap,
      focusId: FushiFocusId('media-server-card-${browser.serverId}'),
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal,
        vertical: tokens.spacing.rowVertical,
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.dns_outlined, size: 32),
          SizedBox(width: tokens.spacing.rowHorizontal),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  browser.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle,
                ),
                Text(
                  browser.serverUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
                if (account != null && account.isNotEmpty)
                  Text(
                    account,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata,
                  ),
              ],
            ),
          ),
          // 多线路时卡片右侧一个「切换线路」菜单：出门在外从局域网地址切到公网地址
          // 不用进设置；只有一条线路时不出这个入口。
          if (entry.canSwitchRoute)
            PopupMenuButton<String>(
              key: ValueKey<String>(
                'media-server-route-switch-${browser.serverId}',
              ),
              tooltip: t.media_server_route_switch,
              icon: const Icon(Icons.alt_route_rounded),
              initialValue: browser.serverUrl,
              onSelected: (String url) {
                if (url != browser.serverUrl) unawaited(onSwitchRoute(url));
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                for (final String url in entry.routeUrls)
                  PopupMenuItem<String>(
                    value: url,
                    child: Row(
                      children: <Widget>[
                        Icon(
                          url == browser.serverUrl
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(url, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}
