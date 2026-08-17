import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/media/manga/discovery/anilist_manga_discovery_provider.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_detail_page.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/utils.dart';

/// 漫画库「发现」视图：AniList 元数据的趋势 / 热门 / 高分 / 最新完结四条横滑行。
///
/// 结构对齐 hayase 化后的视频首页决策（用户拍板）：**不做自动播轮播**，趋势行
/// 用更大的卡片充当页首视觉锚点，其余行标准卡片，全部是可拖动的横滑行。
///
/// 条目是元数据不是来源条目；点开进 [MangaDiscoveryDetailPage]，由它在已启用
/// 来源里自动匹配可读条目。本页因此在**五个平台都可用**（AniList 公开查询与
/// 扩展宿主无关），与库页「视图列表无条件常量」的纪律一致。
///
/// 首次切到本视图才发请求（库页壳惰性构建），结果保活在 State 里（壳 Offstage
/// 保活），切走切回不重抓；显式刷新走页头按钮。
class MangaDiscoveryPage extends StatefulWidget {
  const MangaDiscoveryPage({
    super.key,
    this.navigation,
    this.provider,
  });

  /// 库页视图导航条（由 `MediaLibraryShell` 传入，作为页头主内容）。
  final Widget? navigation;

  /// 数据源。为空时创建 AniList provider；测试注入假实现。
  final MangaDiscoveryProvider? provider;

  @override
  State<MangaDiscoveryPage> createState() => _MangaDiscoveryPageState();
}

class _MangaDiscoveryPageState extends State<MangaDiscoveryPage> {
  AniListMangaDiscoveryProvider? _ownedProvider;
  MangaDiscoverySnapshot? _snapshot;
  Object? _error;
  bool _loading = false;

  MangaDiscoveryProvider get _provider =>
      widget.provider ?? (_ownedProvider ??= AniListMangaDiscoveryProvider());

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _ownedProvider?.close();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MangaDiscoverySnapshot snapshot = await _provider.fetchSnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _openEntry(MangaDiscoveryEntry entry) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) =>
            MangaDiscoveryDetailPage(entry: entry),
      ),
    );
  }

  /// 页头。与 `MangaBrowsePage` 同一范式：导航条存在时即页头主位。
  Widget _buildHeader() {
    final List<Widget> actions = <Widget>[
      IconButton(
        key: const ValueKey<String>('manga_discovery_refresh'),
        tooltip: t.retry,
        onPressed: _loading ? null : () => unawaited(_load()),
        icon: const Icon(Icons.refresh),
      ),
    ];
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(title: navigation, actions: actions);
    }
    return FushiPageHeader(title: t.library_view_discover, actions: actions);
  }

  @override
  Widget build(BuildContext context) {
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context)) _buildHeader(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final MangaDiscoverySnapshot? snapshot = _snapshot;
    if (snapshot == null) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return _buildError();
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: <Widget>[
        _buildSection(
          title: t.manga_discovery_section_trending,
          entries: snapshot[MangaDiscoveryFeed.trending],
          cardWidth: 165,
          stripHeight: 265,
        ),
        _buildSection(
          title: t.manga_discovery_section_popular,
          entries: snapshot[MangaDiscoveryFeed.popular],
        ),
        _buildSection(
          title: t.manga_discovery_section_top_rated,
          entries: snapshot[MangaDiscoveryFeed.topRated],
        ),
        _buildSection(
          title: t.manga_discovery_section_latest_finished,
          entries: snapshot[MangaDiscoveryFeed.latestFinished],
        ),
      ],
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              t.manga_discovery_load_failed,
              textAlign: TextAlign.center,
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '$_error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.tonal(
              key: const ValueKey<String>('manga_discovery_retry'),
              onPressed: () => unawaited(_load()),
              child: Text(t.retry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required List<MangaDiscoveryEntry> entries,
    double cardWidth = 130,
    double stripHeight = 214,
  }) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 8),
          // 桌面端默认 dragDevices 不含 mouse，横滑行必须包
          // HorizontalDragScrollable（横向滚动守卫，与全局搜索页同一处理）。
          SizedBox(
            height: stripHeight,
            child: HorizontalDragScrollable(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: entries.length,
                itemBuilder: (BuildContext context, int index) =>
                    _buildCard(entries[index], width: cardWidth),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(MangaDiscoveryEntry entry, {required double width}) {
    final double? score = entry.averageScore;
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: FushiCard(
          padding: EdgeInsets.zero,
          onTap: () => _openEntry(entry),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: MangaDiscoveryCover(url: entry.coverUrl)),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      entry.preferredTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (score != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.star_rate_rounded,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            score.toStringAsFixed(1),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// AniList 封面（公开 CDN，普通 `Image.network` 即可）；空/失败给占位图标。
class MangaDiscoveryCover extends StatelessWidget {
  const MangaDiscoveryCover({required this.url, super.key});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final String value = url?.trim() ?? '';
    if (value.isEmpty) {
      return const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: Icon(Icons.image_not_supported_outlined)),
      );
    }
    return Image.network(
      value,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
  }
}
