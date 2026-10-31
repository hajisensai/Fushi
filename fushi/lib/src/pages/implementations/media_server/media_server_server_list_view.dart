import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_aggregate_search_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_home_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 一台已登录的媒体服务器（浏览器 + 展示用账号名 + 线路）。账号名与线路都不在
/// [MediaServerBrowser] 契约里（契约只管浏览与播放），由装配处从服务器配置带来。
class MediaServerEntry {
  const MediaServerEntry({
    required this.browser,
    this.accountName,
    this.routeUrls = const <String>[],
    this.onSwitchRoute,
    this.library,
  });

  final MediaServerBrowser browser;
  final String? accountName;

  /// 这台服务器的全部访问地址（登录地址在首位）；少于两条 = 卡片不出切换入口。
  /// 当前线路就是 [MediaServerBrowser.serverUrl]（浏览器按当前线路建）。
  final List<String> routeUrls;

  /// 切到某条线路（写配置 + 失效缓存槽）；完成后列表重取，新浏览器按新线路建。
  final Future<void> Function(String url)? onSwitchRoute;

  /// 入库出口（见 [MediaServerSession.library]）。
  final MediaServerVideoLibrary? library;

  bool get canSwitchRoute => onSwitchRoute != null && routeUrls.length > 1;
}

/// 「选择服务器」（2026-10 重做）：设置风格的分组列表——每台一行（类型图标 /
/// 服务器名 / 类型 / 当前线路 / 账号 / 切换线路 / chevron），组下方一行「去设置
/// 添加服务器」。MD3 是分段卡、Apple 是 inset grouped（[FushiGroupedListItem]），
/// 行在进场窗口里错峰淡入。
///
/// 只有一台时**首屏直接进那台的首页**（列表在返回时才出现）。空态 = 提示 +
/// 「去设置添加服务器」。
class MediaServerListView extends StatefulWidget {
  const MediaServerListView({
    required this.loadServers,
    required this.play,
    required this.onOpenSettings,
    super.key,
  });

  final Future<List<MediaServerEntry>> Function() loadServers;
  final MediaServerPlayHandler play;
  final VoidCallback onOpenSettings;

  @override
  State<MediaServerListView> createState() => _MediaServerListViewState();
}

class _MediaServerListViewState extends State<MediaServerListView> {
  late Future<List<MediaServerEntry>> _future = widget.loadServers();

  /// 最近一次取回的服务器清单：首页页头的「切换服务器」菜单从这里取。
  List<MediaServerEntry> _servers = const <MediaServerEntry>[];

  /// 每次重取 +1：状态块（骨架 / 列表 / 空态 / 错误）的 key 带上它，交叉淡入时
  /// 上一轮还在淡出的同态块与新一块不会撞 key（[AnimatedSwitcher] 按子 key 包
  /// 过渡层）。
  int _epoch = 0;

  void _reload() {
    setState(() {
      _epoch += 1;
      _future = widget.loadServers();
    });
  }

  Widget _homeFor(MediaServerEntry entry) {
    return MediaServerHomeView(
      key: ValueKey<String>('media-server-home-${entry.browser.serverId}'),
      session: MediaServerSession(
        browser: entry.browser,
        play: widget.play,
        library: entry.library,
      ),
      showBackButton: true,
      servers: <MediaServerBrowser>[
        for (final MediaServerEntry e in _servers) e.browser,
      ],
      onSwitchServer: _switchServer,
    );
  }

  /// 进服务器 = 打开二级页面（根 Navigator，2026-10-30 用户「点击进去媒体服务器
  /// 应该要是二级界面」）：首页 / 网格 / 搜索都在这一页之上叠，自带返回，不再
  /// 压在库页顶栏与分区页签底下。
  void _openServer(MediaServerEntry entry) {
    Navigator.of(context, rootNavigator: true).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => _homeFor(entry),
      ),
    );
  }

  /// 首页页头切到另一台：把当前这台的首页换成那台的（返回仍回到本列表）。
  void _switchServer(MediaServerBrowser browser) {
    MediaServerEntry? target;
    for (final MediaServerEntry entry in _servers) {
      if (entry.browser.serverId == browser.serverId) target = entry;
    }
    if (target == null) return;
    final MediaServerEntry entry = target;
    Navigator.of(context, rootNavigator: true).pushReplacement<void, void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => _homeFor(entry),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 本视图是分区里的一级列表，就在库页分区页签下方：页头不再是悬浮胶囊
    // （2026-10-30 用户「底部就不该显示胶囊了」），只是一行平铺的小标题 +
    // 动作按钮。点进某台服务器才是带悬浮页头的二级页面（见 [_openServer]）。
    return MediaServerPageFrame(
      header: _PlainListHeader(
        title: t.media_server_servers_title,
        actions: <Widget>[
          // 多台服务器时才有「搜索所有服务器」：与列表同一份清单（同一个 future），
          // 清单回来后这里随之出现。
          FutureBuilder<List<MediaServerEntry>>(
            future: _future,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<List<MediaServerEntry>> snapshot,
                ) {
                  final List<MediaServerEntry> servers =
                      snapshot.data ?? const <MediaServerEntry>[];
                  if (servers.length < 2) return const SizedBox.shrink();
                  return FushiIconButton(
                    key: const ValueKey<String>('media-server-list-search-all'),
                    icon: FushiIcons.travelExplore,
                    tooltip: t.media_server_search_all,
                    focusId: const FushiFocusId('media-server-list-search-all'),
                    onTap: () => openMediaServerAggregateSearch(
                      context,
                      <MediaServerSession>[
                        for (final MediaServerEntry e in servers)
                          MediaServerSession(
                            browser: e.browser,
                            play: widget.play,
                            library: e.library,
                          ),
                      ],
                    ),
                  );
                },
          ),
          FushiIconButton(
            key: const ValueKey<String>('media-server-list-refresh'),
            icon: FushiIcons.refresh,
            tooltip: t.refresh,
            focusId: const FushiFocusId('media-server-list-refresh'),
            onTap: _reload,
          ),
        ],
      ),
      // 页头叠在正文上：列表把让位加成顶部内边距，空态 / 错误整体让开。
      body: MediaServerBodyInset(
        builder: (BuildContext context, double top) =>
            FutureBuilder<List<MediaServerEntry>>(
              future: _future,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<MediaServerEntry>> snapshot,
                  ) {
                    // 三态之间交叉淡入（effects 弹簧，不过冲）：骨架 → 列表 / 空态 /
                    // 错误不硬切。
                    final FushiMotionScheme motion = context.fushiMotion;
                    final Widget child;
                    if (snapshot.connectionState != ConnectionState.done) {
                      child = _buildSkeleton(top);
                    } else if (snapshot.hasError) {
                      child = Padding(
                        key: ValueKey<String>(
                          'media-server-list-error-$_epoch',
                        ),
                        padding: EdgeInsets.only(top: top),
                        child: FushiPlaceholderMessage(
                          icon: FushiIcons.cloudOff,
                          tone: FushiPlaceholderTone.error,
                          message: t.media_server_items_load_failed,
                          detail: '${snapshot.error}',
                          action: FushiFilledButton.icon(
                            onPressed: _reload,
                            icon: const FushiIcon(FushiIcons.refresh),
                            label: Text(t.retry),
                          ),
                        ),
                      );
                    } else {
                      final List<MediaServerEntry> servers =
                          snapshot.data ?? const <MediaServerEntry>[];
                      _servers = servers;
                      if (servers.isEmpty) {
                        child = _buildEmpty(top);
                      } else {
                        child = _buildList(servers, top);
                      }
                    }
                    return AnimatedSwitcher(
                      duration: motion.effectsDefault.duration,
                      switchInCurve: motion.effectsDefault.curve,
                      switchOutCurve: motion.effectsDefault.curve,
                      child: child,
                    );
                  },
            ),
      ),
    );
  }

  /// 加载骨架：与真实列表同宽同形的两行分段卡（行首方块 + 两行文字条）。
  Widget _buildSkeleton(double top) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiSkeletonShimmer(
      key: ValueKey<String>('media-server-list-skeleton-$_epoch'),
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          top + tokens.spacing.gap,
          tokens.spacing.page,
          tokens.spacing.gap,
        ),
        children: <Widget>[
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  MediaServerListRowSkeleton(index: 0, count: 2),
                  MediaServerListRowSkeleton(index: 1, count: 2),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(double top) {
    return MediaServerListEmpty(
      key: ValueKey<String>('media-server-list-empty-$_epoch'),
      top: top,
      onOpenSettings: widget.onOpenSettings,
    );
  }

  Widget _buildList(List<MediaServerEntry> servers, double top) {
    return MediaServerGroupedList(
      key: ValueKey<String>('media-server-list-body-$_epoch'),
      top: top,
      onOpenSettings: widget.onOpenSettings,
      rows: <MediaServerListRowData>[
        for (final MediaServerEntry entry in servers) _rowFor(entry),
      ],
    );
  }

  MediaServerListRowData _rowFor(MediaServerEntry entry) {
    final MediaServerBrowser browser = entry.browser;
    final MediaServerFamily family = mediaServerFamilyOf(browser.serverId);
    return MediaServerListRowData(
      id: browser.serverId,
      name: browser.displayName,
      url: browser.serverUrl,
      kindLabel: mediaServerFamilyLabel(family),
      icon: mediaServerFamilyIcon(family),
      accountName: entry.accountName,
      onTap: () => _openServer(entry),
      // 多线路时行尾一个「切换线路」菜单：出门在外从局域网地址切到公网地址
      // 不用进设置；只有一条线路时不出这个入口。
      trailing: entry.canSwitchRoute
          ? FushiPopupMenuButton<String>(
              key: ValueKey<String>(
                'media-server-route-switch-${browser.serverId}',
              ),
              tooltip: t.media_server_route_switch,
              icon: const FushiIcon(FushiIcons.swap),
              initialValue: browser.serverUrl,
              onSelected: (String url) {
                if (url == browser.serverUrl) return;
                unawaited(() async {
                  await entry.onSwitchRoute?.call(url);
                  if (mounted) _reload();
                }());
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                for (final String url in entry.routeUrls)
                  CheckedPopupMenuItem<String>(
                    value: url,
                    checked: url == browser.serverUrl,
                    child: Text(url, overflow: TextOverflow.ellipsis),
                  ),
              ],
            )
          : null,
    );
  }
}

/// 「选择服务器」列表里的一行（视频 Jellyfin / Emby / Plex 与书 / 漫画的
/// Kavita / Audiobookshelf 共用同一种行）。
class MediaServerListRowData {
  const MediaServerListRowData({
    required this.id,
    required this.name,
    required this.url,
    required this.kindLabel,
    required this.icon,
    required this.onTap,
    this.accountName,
    this.trailing,
  });

  /// 行身份（key / 焦点 id 用），同一列表内唯一。
  final String id;
  final String name;
  final String url;

  /// 类型名（产品名不翻译）。
  final String kindLabel;
  final IconData icon;

  /// 点行：进这台服务器。
  final VoidCallback onTap;

  /// 登录账号名；空则不显示。
  final String? accountName;

  /// 行尾 chevron 前的附加动作（视频的「切换线路」菜单）。
  final Widget? trailing;
}

/// 打开「设置 › 服务」（媒体服务器在这里增删）。
void openMediaServerSettings(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) =>
          SettingsDetailPage(destination: buildServicesDestination()),
    ),
  );
}

/// 没有服务器的空态：提示 + 「去设置添加服务器」。
class MediaServerListEmpty extends StatelessWidget {
  const MediaServerListEmpty({
    required this.top,
    required this.onOpenSettings,
    super.key,
  });

  /// 顶部让位（浮动工具区高度）。
  final double top;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: FushiPlaceholderMessage(
        icon: FushiIcons.server,
        message: t.media_server_servers_empty_hint,
        action: FushiFilledButton.tonalIcon(
          key: const ValueKey<String>('media-server-list-go-settings'),
          onPressed: onOpenSettings,
          icon: const FushiIcon(FushiIcons.settingsGear),
          label: Text(t.media_server_servers_go_settings),
        ),
      ),
    );
  }
}

/// 「选择服务器」正文（2026-10 重做，视频 / 书 / 漫画共用）：设置风格的分组
/// 列表——每台一行（类型图标 / 服务器名 / 当前地址 / 类型 · 账号 / 行尾动作 /
/// chevron），组下方一行「去设置添加服务器」。MD3 是分段卡、Apple 是 inset
/// grouped（[FushiGroupedListItem]），行在进场窗口里错峰淡入。
class MediaServerGroupedList extends StatelessWidget {
  const MediaServerGroupedList({
    required this.rows,
    required this.top,
    required this.onOpenSettings,
    super.key,
  });

  final List<MediaServerListRowData> rows;

  /// 顶部让位（浮动工具区高度），加成列表顶部内边距。
  final double top;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int count = rows.length;
    return FushiEntranceScope(
      child: ListView(
        key: const PageStorageKey<String>('media-server-list'),
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          top + tokens.spacing.gap,
          tokens.spacing.page,
          tokens.spacing.gap,
        ),
        children: <Widget>[
          // 设置风格的窄栏：宽屏上一行拉满 1600 宽读不下去，限在 760 居中。
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < count; i++)
                    FushiStaggeredEntrance(
                      index: i,
                      child: _ServerRow(
                        key: ValueKey<String>(
                          'media-server-card-${rows[i].id}',
                        ),
                        row: rows[i],
                        index: i,
                        count: count,
                      ),
                    ),
                  SizedBox(height: tokens.spacing.section),
                  FushiStaggeredEntrance(
                    index: count,
                    child: FushiGroupedListItem(
                      key: const ValueKey<String>('media-server-list-add'),
                      index: 0,
                      count: 1,
                      focusId: const FushiFocusId('media-server-list-add'),
                      onTap: onOpenSettings,
                      child: const _AddServerRow(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一台服务器的分组行。整行可点（进这台服务器），焦点目标由行外壳挂。
class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.row,
    required this.index,
    required this.count,
    super.key,
  });

  final MediaServerListRowData row;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final String? account = row.accountName;
    final Widget? trailing = row.trailing;
    const double badge = 40;
    final double rowPad = tokens.spacing.rowHorizontal;
    final TextStyle secondary = tokens.type.metadata.copyWith(
      color: apple ? appleColorsOf(context).secondaryLabel : null,
    );
    return FushiGroupedListItem(
      index: index,
      count: count,
      // Apple 分隔线从文字起点开始（行内边距 + 图标盒 + 间距）。
      separatorIndent: rowPad + badge + rowPad,
      focusId: FushiFocusId('media-server-card-${row.id}'),
      onTap: row.onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: rowPad,
          vertical: tokens.spacing.rowVertical,
        ),
        child: Row(
          children: <Widget>[
            // 类型图标走 M3E 行首形状底（secondaryContainer 方圆角；Apple 是
            // iOS 设置式彩色圆角方块；墨水屏描边无底）。
            FushiListLeadingIcon(
              row.icon,
              shape: FushiLeadingShape.square,
              size: badge,
              iconSize: 22,
            ),
            SizedBox(width: rowPad),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.listTitle,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    row.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: secondary,
                  ),
                  Row(
                    children: <Widget>[
                      Text(row.kindLabel, style: secondary),
                      if (account != null && account.isNotEmpty) ...<Widget>[
                        Text('  ·  ', style: secondary),
                        Flexible(
                          child: Text(
                            account,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: secondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing,
            const SizedBox(width: 4),
            if (apple)
              const FushiAppleChevron()
            else
              FushiIcon(
                FushiIcons.chevronRight,
                color: tokens.surfaces.onVariant,
              ),
          ],
        ),
      ),
    );
  }
}

/// 组下方的「去设置添加服务器」行：primary 色块圆底加号 + 强调色文字（iOS 设置
/// 「添加账户」口径）。
class _AddServerRow extends StatelessWidget {
  const _AddServerRow();

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color accent = isGlassDesign(context)
        ? appleColorsOf(context).accent
        : Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal,
        vertical: tokens.spacing.rowVertical,
      ),
      child: Row(
        children: <Widget>[
          const FushiListLeadingIcon(
            FushiIcons.add,
            tone: FushiCardTone.primary,
            iconSize: 22,
          ),
          SizedBox(width: tokens.spacing.rowHorizontal),
          Expanded(
            child: Text(
              t.media_server_servers_go_settings,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listTitle.copyWith(color: accent),
            ),
          ),
        ],
      ),
    );
  }
}

/// 服务器列表的平铺页头：左边一枚小标题，右边一排普通图标按钮，没有悬浮胶囊。
class _PlainListHeader extends StatelessWidget {
  const _PlainListHeader({required this.title, required this.actions});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.page + tokens.spacing.gap,
        tokens.spacing.gap,
        tokens.spacing.page,
        0,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}
