/// 音乐页的统一搜索（用户 2026-10-29 拍板「搜索在首页完成、多加载、少进二级页」，设计稿
/// `fushi/build/music_design/music_ia.html`）：
/// - 页签只表示「看什么类型」，搜索词只是过滤条件，来源（本地 / 各插件）是 chip 过滤；
/// - 歌曲 / 专辑 / 艺人 / 歌单页签 + 搜索词 = [MusicSearchResultsView]：本地匹配在前、各插件
///   结果在后的一条无限下滑列表，哨兵行被 build 时才取下一页；
/// - 推荐页签 + 搜索词 = [MusicSearchOverview]：最佳匹配 + 歌曲前 5 + 专辑 / 艺人 / 歌单各一行，
///   段标题的「全部」切页签，不进二级页。
/// 详情页（专辑 / 歌单 / 艺人）是唯一保留的二级页。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart'
    show MusicAlbumRow, MusicArtistRow, MusicPlaylistRow, MusicTrackRow;
import 'package:fushi_music/fushi_music.dart'
    show
        MusicPluginAlbum,
        MusicPluginArtist,
        MusicPluginCapability,
        MusicPluginManifest,
        MusicPluginPage,
        MusicPluginPlaylist,
        MusicPluginSearchBest,
        MusicPluginSearchType,
        MusicPluginSource,
        MusicPluginTrack;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 来源过滤里「本地」的取值（`null` = 全部来源，其余为插件 id）。
const String kMusicSearchLocalSource = '\u0000local';

/// 输入停顿多久才发在线请求：逐字发会把在线接口打爆。
const Duration kMusicSearchDebounce = Duration(milliseconds: 450);

/// 统一搜索列表每页条数。
const int kMusicSearchPageSize = 30;

/// 综合结果每个插件每种类型取的条数（只取第一页）。
const int kMusicSearchOverviewPageSize = 10;

/// 综合结果右栏的歌曲条数。
const int kMusicSearchOverviewSongCount = 5;

/// 本地（含混排服务器专辑）已按搜索词筛过的结果，与 [filterByMediaSearch] 同口径。
class MusicSearchLocalItems {
  const MusicSearchLocalItems({
    this.tracks = const <MusicTrackRow>[],
    this.albums = const <MusicAlbumRow>[],
    this.serverAlbums = const <MusicServerAlbumRef>[],
    this.artists = const <MusicArtistRow>[],
    this.playlists = const <MusicPlaylistRow>[],
    this.albumByUid = const <String, MusicAlbumRow>{},
  });

  static const MusicSearchLocalItems none = MusicSearchLocalItems();

  final List<MusicTrackRow> tracks;
  final List<MusicAlbumRow> albums;
  final List<MusicServerAlbumRef> serverAlbums;
  final List<MusicArtistRow> artists;
  final List<MusicPlaylistRow> playlists;

  /// 曲目 → 所属专辑（播放项要带专辑名 / 封面）。
  final Map<String, MusicAlbumRow> albumByUid;

  /// [type] 对应的本地条目（专辑含混排服务器专辑，排在本地专辑之后）。
  List<Object> of(MusicPluginSearchType type) => switch (type) {
    MusicPluginSearchType.song => tracks,
    MusicPluginSearchType.album => <Object>[...albums, ...serverAlbums],
    MusicPluginSearchType.artist => artists,
    MusicPluginSearchType.playlist => playlists,
  };
}

/// 本地条目的卡片与跳转由曲库页提供（本地专辑卡带光盘菜单 / 格式徽章，住在曲库页里）。
class MusicSearchLocalActions {
  const MusicSearchLocalActions({
    required this.albumCard,
    required this.openAlbum,
    required this.openArtist,
  });

  /// 本地专辑卡（祖先已有专辑材质 Scope）。
  final Widget Function(BuildContext context, MusicAlbumRow album) albumCard;
  final ValueChanged<MusicAlbumRow> openAlbum;
  final ValueChanged<MusicArtistRow> openArtist;
}

/// 按类型取插件搜索的一页。
Future<MusicPluginPage<Object>> musicPluginSearchPage(
  MusicPluginSource source,
  MusicPluginSearchType type,
  String query, {
  required int page,
  required int pageSize,
}) async => switch (type) {
  MusicPluginSearchType.song => await source.searchTracks(
    query,
    page: page,
    pageSize: pageSize,
  ),
  MusicPluginSearchType.album => await source.searchAlbums(
    query,
    page: page,
    pageSize: pageSize,
  ),
  MusicPluginSearchType.artist => await source.searchArtists(
    query,
    page: page,
    pageSize: pageSize,
  ),
  MusicPluginSearchType.playlist => await source.searchPlaylists(
    query,
    page: page,
    pageSize: pageSize,
  ),
};

/// 搜索框下面的来源过滤：全部来源 / 本地 / 每个插件。单选，`null` = 全部来源。
class MusicSearchSourceChips extends StatelessWidget {
  const MusicSearchSourceChips({
    super.key,
    required this.sources,
    required this.selected,
    required this.onSelected,
  });

  final List<MusicPluginManifest> sources;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    Widget chip(String? value, String label) => Padding(
      padding: EdgeInsetsDirectional.only(end: tokens.spacing.gap / 2),
      child: FushiChoiceChip(
        key: ValueKey<String>('music-search-source-${value ?? 'all'}'),
        label: Text(label),
        selected: selected == value,
        onSelected: (_) => onSelected(value),
      ),
    );
    return HorizontalDragScrollable(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            chip(null, t.music_search_source_all),
            chip(kMusicSearchLocalSource, t.music_search_source_local),
            for (final MusicPluginManifest m in sources) chip(m.id, m.name),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 共用件：曲目行、封面卡、艺人卡、播放与跳转。
// ---------------------------------------------------------------------------

/// 一首搜索结果：[plugin] 为空 = 本地曲目（[MusicTrackRow]），否则 [MusicPluginTrack]。
typedef _Song = ({MusicPluginManifest? plugin, Object track});

/// 把 [songs] 整列作为队列，从第 [start] 首开始播（不可播的插件曲目跳过）。
void _playSongs(
  WidgetRef ref,
  List<_Song> songs,
  Map<String, MusicAlbumRow> albums,
  int start,
) {
  final List<MusicPlayItem> items = <MusicPlayItem>[];
  int startIndex = 0;
  for (int i = 0; i < songs.length; i++) {
    final _Song s = songs[i];
    // 起点那首不可播时顺延到它后面第一首可播的。
    if (i == start) startIndex = items.length;
    final MusicPlayItem? item = switch (s.track) {
      MusicTrackRow r => musicPlayItemOf(
        r,
        album: r.albumUid == null ? null : albums[r.albumUid!],
      ),
      MusicPluginTrack p when p.playable && s.plugin != null =>
        musicPluginPlayItem(s.plugin!.id, p),
      _ => null,
    };
    if (item != null) items.add(item);
  }
  if (items.isEmpty) {
    FushiToast.show(msg: t.music_plugin_unplayable);
    return;
  }
  unawaited(
    ref
        .read(appProvider)
        .musicSession
        .engine
        .playQueue(
          items,
          startIndex: math.min(startIndex, items.length - 1),
          context: MusicQueueContext.mixed,
        ),
  );
}

Future<void> _pushPage(BuildContext context, Widget page) => Navigator.of(
  context,
).push<void>(adaptivePageRoute<void>(context: context, builder: (_) => page));

/// 打开插件专辑 / 歌单 / 艺人的详情页。
void _openPluginItem(
  BuildContext context,
  MusicPluginManifest manifest,
  Object item,
) {
  final Widget? page = switch (item) {
    MusicPluginAlbum a => MusicPluginCollectionPage.album(
      manifest: manifest,
      album: a,
    ),
    MusicPluginPlaylist p => MusicPluginCollectionPage.playlist(
      manifest: manifest,
      playlist: p,
    ),
    MusicPluginArtist a => MusicPluginArtistPage(manifest: manifest, artist: a),
    _ => null,
  };
  if (page != null) unawaited(_pushPage(context, page));
}

/// 一行歌曲（本地或插件）。
class _SongTile extends ConsumerWidget {
  const _SongTile({
    required this.song,
    required this.index,
    required this.count,
    required this.onTap,
    this.sourceLabel,
  });

  final _Song song;
  final int index;
  final int count;
  final VoidCallback onTap;

  /// 综合结果里混排时行尾标出来源。
  final String? sourceLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Object track = song.track;
    final String id;
    final String title;
    final String subtitle;
    final int? durationMs;
    final bool playable;
    final Widget leading;
    VoidCallback? onLongPress;
    switch (track) {
      case MusicTrackRow r:
        final String badge = musicFormatBadge(
          codec: r.codec,
          isLossless: r.isLossless,
          sampleRate: r.sampleRate,
          bitDepth: r.bitDepth,
          bitrateKbps: r.bitrate,
        );
        id = 'local-${r.trackUid}';
        title = r.title;
        subtitle = <String>[
          r.artistCredit ?? t.music_artist_unknown,
          if (badge.isNotEmpty) badge,
        ].join(' · ');
        durationMs = r.durationMs;
        playable = true;
        leading = const FushiListLeadingIcon(FushiIcons.music);
        onLongPress = () => openMusicTrackDetail(context, r.trackUid);
      case MusicPluginTrack p:
        id = '${song.plugin?.id}-${p.id}';
        title = p.title;
        subtitle = <String>[
          if (p.artists.isNotEmpty) p.artistText,
          ?p.albumTitle,
          if (!p.playable) t.music_plugin_unplayable else ?p.note,
        ].join(' · ');
        durationMs = p.durationMs;
        playable = p.playable;
        leading = musicMaterialCover(
          MusicCover(coverPath: p.coverUrl, size: 48),
          size: 48,
          compact: true,
        );
      default:
        return const SizedBox.shrink();
    }
    final String? source = sourceLabel;
    return Opacity(
      opacity: playable ? 1 : 0.5,
      child: FushiPressScale(
        child: FushiGroupedListItem(
          key: ValueKey<String>('music-search-song-$id'),
          index: index,
          count: count,
          onTap: playable ? onTap : null,
          onLongPress: onLongPress,
          child: FushiListItem(
            leading: leading,
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: subtitle.isEmpty
                ? null
                : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: FushiDesignTokens.of(context).spacing.gap,
              children: <Widget>[
                if (source != null) _SourceTag(label: source),
                Text(
                  formatMusicDuration(durationMs),
                  style: context.fushiType.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 来源小标（「本地」/ 插件名）。
class _SourceTag extends StatelessWidget {
  const _SourceTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: FushiBorderRadius.chip,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.fushiType.labelSmall.copyWith(
            color: scheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}

/// 方形「唱片」材质封面卡（插件专辑 / 歌单、本地歌单）。材质由外层
/// [ShelfCoverMaterialScope] 给。
class _CoverCard extends StatelessWidget {
  const _CoverCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.coverUrl,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String? coverUrl;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => FushiHoverLift(
    scale: kMusicHoverLiftScale,
    builder: (BuildContext context, bool _) => shelfCoverCard(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AspectRatio(
            aspectRatio: kShelfAlbumAspectRatio,
            child: ShelfCoverFrame(child: MusicCover(coverPath: coverUrl)),
          ),
          ShelfCardMeta(title: title, subtitle: subtitle),
        ],
      ),
    ),
  );
}

/// 圆形头像艺人卡（艺人不是唱片，不套专辑材质）。
class _ArtistCard extends StatelessWidget {
  const _ArtistCard({
    super.key,
    required this.name,
    required this.onTap,
    this.coverUrl,
  });

  final String name;
  final String? coverUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiHoverLift(
      scale: kMusicHoverLiftScale,
      builder: (BuildContext context, bool _) => shelfCoverCard(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 1,
              child: ClipOval(
                child: coverUrl == null
                    ? ColoredBox(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        child: Center(
                          child: FushiIcon(
                            FushiIcons.person,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSecondaryContainer,
                            size: 40,
                          ),
                        ),
                      )
                    : MusicCover(coverPath: coverUrl),
              ),
            ),
            SizedBox(height: tokens.spacing.gap / 2),
            Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// 一个网格 / 横滑条目的卡片。[plugin] 为空 = 本地条目。
Widget _entityCard(
  BuildContext context,
  MusicPluginManifest? plugin,
  Object item,
  MusicSearchLocalActions local,
) {
  switch (item) {
    case MusicAlbumRow a:
      return KeyedSubtree(
        key: ValueKey<String>('music-search-local-album-${a.albumUid}'),
        child: local.albumCard(context, a),
      );
    case MusicServerAlbumRef s:
      return MusicServerAlbumCard(
        key: ValueKey<String>(
          'music-search-server-album-${s.browser.serverId}-${s.album.id}',
        ),
        browser: s.browser,
        album: s.album,
      );
    case MusicArtistRow a:
      return _ArtistCard(
        key: ValueKey<String>('music-search-local-artist-${a.artistUid}'),
        name: a.name,
        onTap: () => local.openArtist(a),
      );
    case MusicPlaylistRow p:
      return _CoverCard(
        key: ValueKey<String>('music-search-local-playlist-${p.playlistUid}'),
        title: p.name,
        subtitle: t.music_search_source_local,
      );
  }
  final MusicPluginManifest? m = plugin;
  if (m == null) return const SizedBox.shrink();
  return switch (item) {
    MusicPluginAlbum a => _CoverCard(
      key: ValueKey<String>('music-search-album-${m.id}-${a.id}'),
      title: a.title,
      coverUrl: a.coverUrl,
      subtitle: <String>[
        if (a.artists.isNotEmpty) a.artistText,
        if (a.year != null) '${a.year}',
      ].join(' · '),
      onTap: () => _openPluginItem(context, m, a),
    ),
    MusicPluginPlaylist p => _CoverCard(
      key: ValueKey<String>('music-search-playlist-${m.id}-${p.id}'),
      title: p.title,
      coverUrl: p.coverUrl,
      subtitle: <String>[
        ?p.owner,
        if (p.trackCount != null) t.music_tracks_count(count: p.trackCount!),
      ].join(' · '),
      onTap: () => _openPluginItem(context, m, p),
    ),
    MusicPluginArtist a => _ArtistCard(
      key: ValueKey<String>('music-search-artist-${m.id}-${a.id}'),
      name: a.name,
      coverUrl: a.coverUrl,
      onTap: () => _openPluginItem(context, m, a),
    ),
    _ => const SizedBox.shrink(),
  };
}

/// 网格列数：与曲库专辑网格同一公式（[musicAlbumGridDelegate]），宽度不扣页边。
int _gridColumns(double width, double spacing) =>
    (math.max(1, width) / (kMusicAlbumGridMaxExtent + spacing)).ceil().clamp(
      2,
      1 << 10,
    );

/// 来源小标题行（「本地」/ 插件名）。
class _SourceHeader extends StatelessWidget {
  const _SourceHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(
        top: tokens.spacing.section,
        bottom: tokens.spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.labelLarge.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 某个插件出错：错误文字 + 重试。
class _ErrorLine extends StatelessWidget {
  const _ErrorLine({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: Text(
          musicPluginErrorText(error),
          style: context.fushiType.bodySmall,
        ),
      ),
      FushiPressScale(
        child: FushiTextButton(onPressed: onRetry, child: Text(t.retry)),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// 歌曲 / 专辑 / 艺人 / 歌单页签 + 搜索词：一条无限下滑的结果列表。
// ---------------------------------------------------------------------------

/// 一个插件在当前查询下的分页状态。
class _PluginFeed {
  final List<Object> items = <Object>[];
  int page = 0;
  bool hasMore = true;
  bool loading = false;
  Object? error;
}

/// 拍平后的一行。
sealed class _Row {
  const _Row();
}

final class _PlayAllRow extends _Row {
  const _PlayAllRow();
}

final class _HeaderRow extends _Row {
  const _HeaderRow(this.key, this.label);
  final String key;
  final String label;
}

final class _SongRow extends _Row {
  const _SongRow(this.songIndex, this.groupIndex, this.groupCount);
  final int songIndex;
  final int groupIndex;
  final int groupCount;
}

final class _GridRow extends _Row {
  const _GridRow(this.key, this.plugin, this.items, this.columns);
  final String key;
  final MusicPluginManifest? plugin;
  final List<Object> items;
  final int columns;
}

final class _SentinelRow extends _Row {
  const _SentinelRow(this.plugin);
  final MusicPluginManifest plugin;
}

final class _ErrorRow extends _Row {
  const _ErrorRow(this.plugin, this.error);
  final MusicPluginManifest plugin;
  final Object error;
}

final class _EmptyRow extends _Row {
  const _EmptyRow(this.plugin);
  final MusicPluginManifest plugin;
}

/// 有搜索词时的歌曲 / 专辑 / 艺人 / 歌单页签：本地匹配在前，各插件结果按插件顺序接在后面；
/// 每个插件一段的末尾是哨兵行，被 build（滚到附近）时才请求它的下一页，同一插件同时只发
/// 一个请求。查询词 / 页签变化后防抖 [kMusicSearchDebounce] 再重新取。
class MusicSearchResultsView extends ConsumerStatefulWidget {
  const MusicSearchResultsView({
    super.key,
    required this.type,
    required this.query,
    required this.sources,
    required this.local,
    required this.localActions,
  });

  final MusicPluginSearchType type;
  final String query;

  /// 参与本类型搜索的插件（已按来源过滤）。
  final List<MusicPluginManifest> sources;

  /// 本地匹配（来源过滤为某个插件时传 [MusicSearchLocalItems.none]）。
  final MusicSearchLocalItems local;
  final MusicSearchLocalActions localActions;

  @override
  ConsumerState<MusicSearchResultsView> createState() =>
      _MusicSearchResultsViewState();
}

class _MusicSearchResultsViewState
    extends ConsumerState<MusicSearchResultsView> {
  Map<String, _PluginFeed> _feeds = <String, _PluginFeed>{};
  Timer? _debounce;

  /// 防抖结束前哨兵只转圈、不发请求。
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(MusicSearchResultsView old) {
    super.didUpdateWidget(old);
    if (old.query.trim() != widget.query.trim() || old.type != widget.type) {
      _feeds = <String, _PluginFeed>{};
      _schedule();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _schedule() {
    _armed = false;
    _debounce?.cancel();
    _debounce = Timer(kMusicSearchDebounce, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  _PluginFeed _feedOf(String id) => _feeds.putIfAbsent(id, _PluginFeed.new);

  /// 哨兵行被 build 时调：够条件就排一次取页（在 build 之后执行，不在 build 里 setState）。
  void _requestNext(MusicPluginManifest m) {
    final _PluginFeed feed = _feedOf(m.id);
    if (!_armed || feed.loading || !feed.hasMore || feed.error != null) return;
    feed.loading = true;
    scheduleMicrotask(() => unawaited(_fetch(m, feed)));
  }

  Future<void> _fetch(MusicPluginManifest m, _PluginFeed feed) async {
    final String q = widget.query.trim();
    try {
      final MusicPluginSource src = ref
          .read(appProvider)
          .musicPluginManager
          .source(m.id);
      final MusicPluginPage<Object> page = await musicPluginSearchPage(
        src,
        widget.type,
        q,
        page: feed.page,
        pageSize: kMusicSearchPageSize,
      );
      if (!mounted || !identical(_feeds[m.id], feed)) return;
      setState(() {
        feed.items.addAll(page.items);
        feed.page++;
        feed.hasMore = page.hasMore && page.items.isNotEmpty;
        feed.loading = false;
      });
    } on Object catch (e) {
      if (!mounted || !identical(_feeds[m.id], feed)) return;
      setState(() {
        feed.error = e;
        feed.loading = false;
      });
    }
  }

  void _retry(MusicPluginManifest m) {
    setState(() => _feedOf(m.id).error = null);
  }

  /// 当前已加载的全部歌曲（本地在前，按显示顺序）。
  List<_Song> _songs() => <_Song>[
    for (final MusicTrackRow r in widget.local.tracks) (plugin: null, track: r),
    for (final MusicPluginManifest m in widget.sources)
      for (final Object o in _feedOf(m.id).items)
        if (o is MusicPluginTrack) (plugin: m, track: o),
  ];

  List<_Row> _rows(List<_Song> songs, int columns) {
    final bool isSongs = widget.type == MusicPluginSearchType.song;
    final List<_Row> rows = <_Row>[];
    if (isSongs && songs.isNotEmpty) rows.add(const _PlayAllRow());
    int songCursor = 0;
    void addItems(String key, MusicPluginManifest? plugin, List<Object> items) {
      if (isSongs) {
        for (int i = 0; i < items.length; i++) {
          rows.add(_SongRow(songCursor++, i, items.length));
        }
        return;
      }
      for (int i = 0; i < items.length; i += columns) {
        rows.add(
          _GridRow(
            '$key-$i',
            plugin,
            items.sublist(i, math.min(i + columns, items.length)),
            columns,
          ),
        );
      }
    }

    final List<Object> local = widget.local.of(widget.type);
    if (local.isNotEmpty) {
      rows.add(_HeaderRow('local', t.music_search_source_local));
      addItems('local', null, local);
    }
    for (final MusicPluginManifest m in widget.sources) {
      final _PluginFeed feed = _feedOf(m.id);
      rows.add(_HeaderRow('plugin-${m.id}', m.name));
      final List<Object> items = isSongs
          ? feed.items.whereType<MusicPluginTrack>().toList()
          : feed.items;
      addItems('plugin-${m.id}', m, items);
      final Object? error = feed.error;
      if (error != null) {
        rows.add(_ErrorRow(m, error));
      } else if (feed.hasMore) {
        rows.add(_SentinelRow(m));
      } else if (feed.items.isEmpty) {
        rows.add(_EmptyRow(m));
      }
    }
    return rows;
  }

  Widget _buildRow(
    BuildContext context,
    _Row row,
    List<_Song> songs,
    double spacing,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    switch (row) {
      case _PlayAllRow():
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: EdgeInsets.only(top: tokens.spacing.gap),
            child: FushiPressScale(
              child: FushiFilledButton.icon(
                key: const ValueKey<String>('music-search-play-all'),
                onPressed: () =>
                    _playSongs(ref, songs, widget.local.albumByUid, 0),
                icon: const FushiIcon(FushiIcons.play),
                label: Text(t.music_search_play_all),
              ),
            ),
          ),
        );
      case _HeaderRow(:final String key, :final String label):
        return _SourceHeader(
          key: ValueKey<String>('music-search-header-$key'),
          label: label,
        );
      case _SongRow(
        :final int songIndex,
        :final int groupIndex,
        :final int groupCount,
      ):
        return _SongTile(
          song: songs[songIndex],
          index: groupIndex,
          count: groupCount,
          onTap: () =>
              _playSongs(ref, songs, widget.local.albumByUid, songIndex),
        );
      case _GridRow(
        :final String key,
        :final MusicPluginManifest? plugin,
        :final List<Object> items,
        :final int columns,
      ):
        return Padding(
          key: ValueKey<String>('music-search-grid-$key'),
          padding: EdgeInsets.only(bottom: spacing),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: spacing,
            children: <Widget>[
              for (int c = 0; c < columns; c++)
                Expanded(
                  child: c < items.length
                      ? _entityCard(
                          context,
                          plugin,
                          items[c],
                          widget.localActions,
                        )
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        );
      case _SentinelRow(:final MusicPluginManifest plugin):
        _requestNext(plugin);
        return Padding(
          key: ValueKey<String>('music-search-sentinel-${plugin.id}'),
          padding: EdgeInsets.all(tokens.spacing.gap),
          child: const FushiLinearProgressIndicator(),
        );
      case _ErrorRow(:final MusicPluginManifest plugin, :final Object error):
        return _ErrorLine(
          key: ValueKey<String>('music-search-error-${plugin.id}'),
          error: error,
          onRetry: () => _retry(plugin),
        );
      case _EmptyRow(:final MusicPluginManifest plugin):
        return Text(
          t.music_server_search_empty,
          key: ValueKey<String>('music-search-empty-${plugin.id}'),
          style: context.fushiType.bodySmall,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (widget.sources.isEmpty && widget.local.of(widget.type).isEmpty) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.search,
          message: t.music_library_search_empty,
        ),
      );
    }
    final double spacing = tokens.spacing.gap * 1.5;
    final EdgeInsets padding = musicBrowsePagePadding(context);
    return ShelfCoverMaterialScope(
      material: ShelfCoverMaterial.glossyAlbum,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final int columns = _gridColumns(
            constraints.maxWidth - padding.horizontal,
            spacing,
          );
          final List<_Song> songs = _songs();
          final List<_Row> rows = _rows(songs, columns);
          return FushiEntranceScope(
            child: ListView.builder(
              key: ValueKey<String>('music-search-results-${widget.type.wire}'),
              padding: padding,
              itemCount: rows.length,
              itemBuilder: fushiStaggeredItemBuilder(
                (BuildContext context, int i) =>
                    _buildRow(context, rows[i], songs, spacing),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 推荐页签 + 搜索词：综合结果。
// ---------------------------------------------------------------------------

/// 一个插件一种类型的第一页结果。
typedef _OverviewResult = ({List<Object>? items, Object? error});

/// 最佳匹配：[plugin] 为空 = 本地条目。
typedef _Best = MusicSearchBestItem;

/// 综合结果里的一张最佳匹配卡：[plugin] 为空 = 本地条目；[item] 是本地行或插件实体。
typedef MusicSearchBestItem = ({MusicPluginManifest? plugin, Object item});

/// 插件艺人的名字或别名 / 译名是否与查询词一致（[normalizeMediaSearchText] 归一化后全等）。
bool musicPluginArtistMatchesQuery(MusicPluginArtist artist, String query) {
  final String needle = normalizeMediaSearchText(query);
  if (needle.isEmpty) return false;
  return <String>[
    artist.name,
    ...artist.aliases,
  ].any((String s) => normalizeMediaSearchText(s) == needle);
}

/// 综合结果的最佳匹配（纯函数；docs/specs/2026-10-28-music-plugins.md §4 `searchBest`）。
/// 返回 0–2 张卡，按插件顺序：
///
/// 1. 第一个给出 `searchBest` 的插件说了算：第一张是它的艺人（其次专辑、歌单），第二张是它
///    同时给的歌单（主卡是艺人时也可以是专辑），像主流平台的综合页那样并排。
/// 2. 没有插件给最佳匹配：取**第一个有在线艺人结果的插件返回的第一个艺人**，名字或别名 /
///    译名与查询词一致才用——不在全部结果里按名字全等挑（同名小号常排在后面）。
/// 3. 再看本地同名艺人；然后同名专辑、同名歌曲；都没有时取第一首歌 / 第一张专辑 / 第一位
///    本地艺人。
List<MusicSearchBestItem> pickMusicSearchBest({
  required String query,
  required List<({MusicPluginManifest plugin, MusicPluginSearchBest best})>
  pluginBest,
  required List<({MusicPluginManifest plugin, List<Object> artists})>
  onlineArtists,
  required List<MusicArtistRow> localArtists,
  required List<MusicSearchBestItem> albums,
  required List<MusicSearchBestItem> tracks,
}) {
  for (final ({MusicPluginManifest plugin, MusicPluginSearchBest best}) e
      in pluginBest) {
    final MusicPluginSearchBest b = e.best;
    if (b.isEmpty) continue;
    final Object primary = b.artist ?? b.album ?? b.playlist!;
    final Object? secondary = switch (primary) {
      MusicPluginArtist() => b.playlist ?? b.album,
      MusicPluginAlbum() => b.playlist,
      _ => null,
    };
    return <MusicSearchBestItem>[
      (plugin: e.plugin, item: primary),
      if (secondary != null) (plugin: e.plugin, item: secondary),
    ];
  }
  for (final ({MusicPluginManifest plugin, List<Object> artists}) e
      in onlineArtists) {
    if (e.artists.isEmpty) continue;
    final Object first = e.artists.first;
    if (first is MusicPluginArtist &&
        musicPluginArtistMatchesQuery(first, query)) {
      return <MusicSearchBestItem>[(plugin: e.plugin, item: first)];
    }
    break;
  }
  final String needle = normalizeMediaSearchText(query);
  bool same(String s) => normalizeMediaSearchText(s) == needle;
  for (final MusicArtistRow a in localArtists) {
    if (same(a.name)) return <MusicSearchBestItem>[(plugin: null, item: a)];
  }
  for (final MusicSearchBestItem b in albums) {
    if (same(_bestTitleOf(b.item))) return <MusicSearchBestItem>[b];
  }
  for (final MusicSearchBestItem b in tracks) {
    if (same(_bestTitleOf(b.item))) return <MusicSearchBestItem>[b];
  }
  if (tracks.isNotEmpty) return <MusicSearchBestItem>[tracks.first];
  if (albums.isNotEmpty) return <MusicSearchBestItem>[albums.first];
  if (localArtists.isNotEmpty) {
    return <MusicSearchBestItem>[(plugin: null, item: localArtists.first)];
  }
  return const <MusicSearchBestItem>[];
}

String _bestTitleOf(Object item) => switch (item) {
  MusicArtistRow a => a.name,
  MusicAlbumRow a => a.title,
  MusicTrackRow r => r.title,
  MusicPluginArtist a => a.name,
  MusicPluginAlbum a => a.title,
  MusicPluginTrack p => p.title,
  MusicPluginPlaylist p => p.title,
  _ => '',
};

/// 推荐页签上有搜索词时的综合结果（设计稿「示意 1」）：左「最佳匹配」、右「歌曲」前 5，下面
/// 「专辑」「艺人」「歌单」各一行横滑。段标题右侧「全部」调 [onSeeAll] 切页签（保留搜索词）。
/// 各插件第一页并行取（每种类型 [kMusicSearchOverviewPageSize] 条）。
class MusicSearchOverview extends ConsumerStatefulWidget {
  const MusicSearchOverview({
    super.key,
    required this.query,
    required this.sources,
    required this.local,
    required this.localActions,
    required this.onSeeAll,
  });

  final String query;

  /// 声明 `search` 能力的插件（已按来源过滤）；各类型按插件的 `searchTypes` 再筛。
  final List<MusicPluginManifest> sources;
  final MusicSearchLocalItems local;
  final MusicSearchLocalActions localActions;
  final ValueChanged<MusicPluginSearchType> onSeeAll;

  @override
  ConsumerState<MusicSearchOverview> createState() =>
      _MusicSearchOverviewState();
}

class _MusicSearchOverviewState extends ConsumerState<MusicSearchOverview> {
  static const double _cardWidth = 144;

  /// `插件 id|类型` → 结果；缺键 = 还没取 / 在途。
  Map<String, _OverviewResult> _results = <String, _OverviewResult>{};

  /// 插件 id → `searchBest` 结果（出错当没有）；缺键 = 还没取 / 在途。只取声明了该能力的插件。
  Map<String, MusicPluginSearchBest> _best = <String, MusicPluginSearchBest>{};
  final Set<String> _inFlight = <String>{};
  Timer? _debounce;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(MusicSearchOverview old) {
    super.didUpdateWidget(old);
    if (old.query.trim() != widget.query.trim()) {
      _results = <String, _OverviewResult>{};
      _best = <String, MusicPluginSearchBest>{};
      _inFlight.clear();
      _schedule();
    } else if (_armed) {
      // 来源过滤放宽后补取新出现的插件（已取过的保留）。
      _fetchMissing();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _schedule() {
    _armed = false;
    _debounce?.cancel();
    _debounce = Timer(kMusicSearchDebounce, () {
      if (!mounted) return;
      setState(() => _armed = true);
      _fetchMissing();
    });
  }

  bool _supports(MusicPluginManifest m, MusicPluginSearchType type) =>
      m.searchTypes.contains(type.wire);

  bool _wantsBest(MusicPluginManifest m) =>
      m.can(MusicPluginCapability.searchBest);

  Future<void> _fetchBest(
    MusicPluginManifest m,
    String key,
    Map<String, MusicPluginSearchBest> generation,
  ) async {
    MusicPluginSearchBest best;
    try {
      best = await ref
          .read(appProvider)
          .musicPluginManager
          .source(m.id)
          .searchBest(widget.query.trim());
    } on Object catch (e, st) {
      // 最佳匹配只是排序提示：失败按「没给」回退，不打断综合结果。
      ErrorLogService.instance.log('MusicSearchOverview.searchBest', e, st);
      best = MusicPluginSearchBest.none;
    }
    if (!mounted || !identical(generation, _best)) return;
    setState(() {
      _inFlight.remove(key);
      _best[m.id] = best;
    });
  }

  void _fetchMissing() {
    for (final MusicPluginManifest m in widget.sources) {
      final String bestKey = '${m.id}|best';
      if (_wantsBest(m) &&
          !_best.containsKey(m.id) &&
          !_inFlight.contains(bestKey)) {
        _inFlight.add(bestKey);
        unawaited(_fetchBest(m, bestKey, _best));
      }
      for (final MusicPluginSearchType type in MusicPluginSearchType.values) {
        if (!_supports(m, type)) continue;
        final String key = '${m.id}|${type.wire}';
        if (_results.containsKey(key) || _inFlight.contains(key)) continue;
        _inFlight.add(key);
        unawaited(_fetch(m, type, key, _results));
      }
    }
  }

  Future<void> _fetch(
    MusicPluginManifest m,
    MusicPluginSearchType type,
    String key,
    Map<String, _OverviewResult> generation,
  ) async {
    _OverviewResult result;
    try {
      final MusicPluginPage<Object> page = await musicPluginSearchPage(
        ref.read(appProvider).musicPluginManager.source(m.id),
        type,
        widget.query.trim(),
        page: 0,
        pageSize: kMusicSearchOverviewPageSize,
      );
      result = (items: page.items, error: null);
    } on Object catch (e) {
      result = (items: null, error: e);
    }
    if (!mounted || !identical(generation, _results)) return;
    setState(() {
      _inFlight.remove(key);
      _results[key] = result;
    });
  }

  void _retry(MusicPluginManifest m) {
    setState(() {
      _results.removeWhere(
        (String k, _OverviewResult r) =>
            k.startsWith('${m.id}|') && r.error != null,
      );
    });
    _fetchMissing();
  }

  /// [type] 下各插件已到的条目，按插件顺序。
  List<(MusicPluginManifest, Object)> _online(MusicPluginSearchType type) =>
      <(MusicPluginManifest, Object)>[
        for (final MusicPluginManifest m in widget.sources)
          for (final Object o
              in _results['${m.id}|${type.wire}']?.items ?? const <Object>[])
            (m, o),
      ];

  bool get _pending =>
      !_armed ||
      widget.sources.any(
        (MusicPluginManifest m) =>
            (_wantsBest(m) && !_best.containsKey(m.id)) ||
            MusicPluginSearchType.values.any(
              (MusicPluginSearchType type) =>
                  _supports(m, type) &&
                  !_results.containsKey('${m.id}|${type.wire}'),
            ),
      );

  /// 最佳匹配卡（0–2 张），规则见 [pickMusicSearchBest]。
  List<_Best> _bestMatches(List<_Song> songs) => pickMusicSearchBest(
    query: widget.query,
    pluginBest: <({MusicPluginManifest plugin, MusicPluginSearchBest best})>[
      for (final MusicPluginManifest m in widget.sources)
        if (_best[m.id] case final MusicPluginSearchBest b)
          (plugin: m, best: b),
    ],
    onlineArtists: <({MusicPluginManifest plugin, List<Object> artists})>[
      for (final MusicPluginManifest m in widget.sources)
        if (_results['${m.id}|${MusicPluginSearchType.artist.wire}']?.items
            case final List<Object> items)
          (plugin: m, artists: items),
    ],
    localArtists: widget.local.artists,
    albums: <_Best>[
      for (final MusicAlbumRow a in widget.local.albums)
        (plugin: null, item: a),
      for (final (MusicPluginManifest m, Object o) in _online(
        MusicPluginSearchType.album,
      ))
        (plugin: m, item: o),
    ],
    tracks: <_Best>[
      for (final _Song s in songs) (plugin: s.plugin, item: s.track),
    ],
  );

  static String _titleOf(Object item) => _bestTitleOf(item);

  Widget _sectionHeader(String label, MusicPluginSearchType type) {
    return Padding(
      padding: EdgeInsets.only(
        top: FushiDesignTokens.of(context).spacing.section,
        bottom: FushiDesignTokens.of(context).spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: context.fushiType.titleLarge.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          FushiPressScale(
            child: FushiTextButton(
              key: ValueKey<String>('music-search-see-all-${type.wire}'),
              onPressed: () => widget.onSeeAll(type),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(t.music_search_see_all),
                  const FushiIcon(FushiIcons.chevronRight, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _carousel(MusicPluginSearchType type, List<_Best> items) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double height = type == MusicPluginSearchType.artist
        ? _cardWidth + 48
        : _cardWidth / kShelfAlbumAspectRatio +
              ShelfCardMeta.heightFor(context) +
              8;
    return SizedBox(
      height: height,
      child: HorizontalDragScrollable(
        child: FushiEntranceScope(
          child: ListView.separated(
            key: ValueKey<String>('music-search-row-${type.wire}'),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, _) => SizedBox(width: tokens.spacing.gap),
            itemBuilder: fushiStaggeredItemBuilder(
              (BuildContext context, int i) => SizedBox(
                width: _cardWidth,
                child: _entityCard(
                  context,
                  items[i].plugin,
                  items[i].item,
                  widget.localActions,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bestCard(_Best best, List<_Song> songs, {int slot = 0}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Object item = best.item;
    final MusicPluginManifest? plugin = best.plugin;
    final String source = plugin?.name ?? t.music_search_source_local;
    const double size = 112;
    final bool round = item is MusicArtistRow || item is MusicPluginArtist;
    final String? coverUrl = switch (item) {
      MusicPluginArtist a => a.coverUrl,
      MusicPluginPlaylist p => p.coverUrl,
      MusicPluginAlbum a => a.coverUrl,
      MusicPluginTrack p => p.coverUrl,
      MusicAlbumRow a => a.coverPath,
      MusicTrackRow r =>
        r.albumUid == null
            ? null
            : widget.local.albumByUid[r.albumUid!]?.coverPath,
      _ => null,
    };
    final String kind = switch (item) {
      MusicArtistRow() || MusicPluginArtist() => t.music_section_artists,
      MusicAlbumRow() || MusicPluginAlbum() => t.music_section_albums,
      MusicPluginPlaylist() => t.music_section_playlists,
      _ => t.music_section_songs,
    };
    final String detail = switch (item) {
      MusicPluginArtist a => <String>[
        if (a.aliases.isNotEmpty) a.aliases.first,
        musicPluginArtistStatsText(context, a.stats),
      ].where((String s) => s.isNotEmpty).join(' · '),
      MusicPluginPlaylist p => <String>[
        ?p.owner,
        if (p.trackCount != null) t.music_tracks_count(count: p.trackCount!),
        if (p.playCount case final int plays)
          t.music_plugin_play_count(
            count: formatMusicCompactCount(context, plays),
          ),
      ].join(' · '),
      MusicAlbumRow a => a.albumArtistCredit ?? '',
      MusicPluginAlbum a => a.artistText,
      MusicTrackRow r => r.artistCredit ?? '',
      MusicPluginTrack p => p.artistText,
      _ => '',
    };
    final int songIndex = songs.indexWhere(
      (_Song s) => identical(s.track, item),
    );
    void open() {
      switch (item) {
        case MusicArtistRow a:
          widget.localActions.openArtist(a);
        case MusicAlbumRow a:
          widget.localActions.openAlbum(a);
        case MusicTrackRow() || MusicPluginTrack():
          if (songIndex >= 0) {
            _playSongs(ref, songs, widget.local.albumByUid, songIndex);
          }
        default:
          if (plugin != null) _openPluginItem(context, plugin, item);
      }
    }

    final Widget cover = round
        ? SizedBox.square(
            dimension: size,
            child: MusicCover(
              coverPath: coverUrl,
              size: size,
              // 艺人头像是正圆：半径随尺寸走，几何而非圆角档位。
              borderRadius: BorderRadius.all(Radius.circular(size / 2)),
            ),
          )
        : musicMaterialCover(
            MusicCover(coverPath: coverUrl, size: size),
            size: size,
          );
    return FushiCard(
      key: ValueKey<String>(
        slot == 0 ? 'music-search-top-result' : 'music-search-top-result-$slot',
      ),
      onTap: open,
      padding: EdgeInsets.all(tokens.spacing.section),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '${t.music_search_top_result} · $kind',
            style: context.fushiType.labelLarge.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          cover,
          SizedBox(height: tokens.spacing.gap),
          Text(
            _titleOf(item),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.headlineSmall.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            <String>[source, if (detail.isNotEmpty) detail].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.bodySmall,
          ),
          if (songIndex >= 0) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            FushiPressScale(
              child: FushiFilledButton.icon(
                onPressed: open,
                icon: const FushiIcon(FushiIcons.play),
                label: Text(t.music_play_all),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<_Song> songs = <_Song>[
      for (final MusicTrackRow r in widget.local.tracks)
        (plugin: null, track: r),
      for (final (MusicPluginManifest m, Object o) in _online(
        MusicPluginSearchType.song,
      ))
        if (o is MusicPluginTrack) (plugin: m, track: o),
    ];
    final List<_Best> bests = _bestMatches(songs);
    List<_Best> entities(MusicPluginSearchType type) => <_Best>[
      for (final Object o in widget.local.of(type)) (plugin: null, item: o),
      for (final (MusicPluginManifest m, Object o) in _online(type))
        (plugin: m, item: o),
    ];
    final List<_Best> albums = entities(MusicPluginSearchType.album);
    final List<_Best> artists = entities(MusicPluginSearchType.artist);
    final List<_Best> playlists = entities(MusicPluginSearchType.playlist);
    final List<MapEntry<MusicPluginManifest, Object>> errors =
        <MapEntry<MusicPluginManifest, Object>>[
          for (final MusicPluginManifest m in widget.sources)
            if (MusicPluginSearchType.values
                    .map(
                      (MusicPluginSearchType ty) =>
                          _results['${m.id}|${ty.wire}']?.error,
                    )
                    .nonNulls
                    .firstOrNull
                case final Object e)
              MapEntry<MusicPluginManifest, Object>(m, e),
        ];
    final bool pending = _pending;
    if (!pending &&
        songs.isEmpty &&
        albums.isEmpty &&
        artists.isEmpty &&
        playlists.isEmpty &&
        errors.isEmpty) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.search,
          message: t.music_library_search_empty,
        ),
      );
    }

    final List<_Song> topSongs = songs
        .take(kMusicSearchOverviewSongCount)
        .toList();
    final Widget songsColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _sectionHeader(t.music_section_songs, MusicPluginSearchType.song),
        for (int i = 0; i < topSongs.length; i++)
          _SongTile(
            song: topSongs[i],
            index: i,
            count: topSongs.length,
            sourceLabel:
                topSongs[i].plugin?.name ?? t.music_search_source_local,
            onTap: () => _playSongs(ref, songs, widget.local.albumByUid, i),
          ),
      ],
    );
    final List<Widget> blocks = <Widget>[
      if (pending) const FushiLinearProgressIndicator(),
      if (bests.isNotEmpty || topSongs.isNotEmpty)
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            // 插件给了两张最佳匹配（艺人 + 歌单）：两张并排一行，歌曲在下面整行。
            if (bests.length > 1) {
              final List<Widget> cards = <Widget>[
                for (int i = 0; i < bests.length; i++)
                  _bestCard(bests[i], songs, slot: i),
              ];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: EdgeInsets.only(top: tokens.spacing.section),
                    child: c.maxWidth < 560
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: tokens.spacing.gap,
                            children: cards,
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: tokens.spacing.section,
                            children: <Widget>[
                              for (final Widget card in cards)
                                Expanded(child: card),
                            ],
                          ),
                  ),
                  if (topSongs.isNotEmpty) songsColumn,
                ],
              );
            }
            final Widget? bestCard = bests.isEmpty
                ? null
                : Padding(
                    padding: EdgeInsets.only(top: tokens.spacing.section),
                    child: _bestCard(bests.first, songs),
                  );
            if (c.maxWidth < 720 || bestCard == null || topSongs.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ?bestCard,
                  if (topSongs.isNotEmpty) songsColumn,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: tokens.spacing.section,
              children: <Widget>[
                Expanded(flex: 2, child: bestCard),
                Expanded(flex: 3, child: songsColumn),
              ],
            );
          },
        ),
      if (albums.isNotEmpty) ...<Widget>[
        _sectionHeader(t.music_section_albums, MusicPluginSearchType.album),
        _carousel(MusicPluginSearchType.album, albums),
      ],
      if (artists.isNotEmpty) ...<Widget>[
        _sectionHeader(t.music_section_artists, MusicPluginSearchType.artist),
        _carousel(MusicPluginSearchType.artist, artists),
      ],
      if (playlists.isNotEmpty) ...<Widget>[
        _sectionHeader(
          t.music_section_playlists,
          MusicPluginSearchType.playlist,
        ),
        _carousel(MusicPluginSearchType.playlist, playlists),
      ],
      for (final MapEntry<MusicPluginManifest, Object> e in errors) ...<Widget>[
        _SourceHeader(
          key: ValueKey<String>('music-search-overview-error-${e.key.id}'),
          label: e.key.name,
        ),
        _ErrorLine(error: e.value, onRetry: () => _retry(e.key)),
      ],
    ];
    return ShelfCoverMaterialScope(
      material: ShelfCoverMaterial.glossyAlbum,
      child: FushiEntranceScope(
        child: ListView.builder(
          key: const ValueKey<String>('music-search-overview'),
          padding: musicBrowsePagePadding(context),
          itemCount: blocks.length,
          itemBuilder: fushiStaggeredItemBuilder(
            (BuildContext context, int i) => blocks[i],
          ),
        ),
      ),
    );
  }
}
