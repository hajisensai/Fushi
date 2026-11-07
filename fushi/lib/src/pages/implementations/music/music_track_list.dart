import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/music_resume.dart';
import 'package:fushi/src/media/music/music_resume_points_watch.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart'
    show MusicFloatingBarHost;
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_local_playlist_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_track_detail_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// `mm:ss`。
String formatMusicDuration(int? ms) {
  if (ms == null || ms <= 0) return '';
  final int s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 打开曲目详情（出现在哪些集 / 同一作品）。
void openMusicTrackDetail(BuildContext context, String trackUid) {
  unawaited(
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => MusicTrackDetailPage(trackUid: trackUid),
      ),
    ),
  );
}

/// 本地曲目的菜单（行尾按钮之外的整行右键）：播放 / 曲目详情 / 加入歌单；[extra] 追加在
/// 末尾（歌单页的「从这个歌单移除」）。
MusicItemMenu musicLocalTrackMenu(
  BuildContext context,
  MusicTrackRow track, {
  required VoidCallback onPlay,
  List<MusicMenuAction> extra = const <MusicMenuAction>[],
}) => MusicItemMenu(
  buttonKey: ValueKey<String>('music-track-menu-${track.trackUid}'),
  open: (MusicMenuAnchor? anchor) => unawaited(
    showMusicActionMenu(
      context,
      anchor: anchor,
      errorText: (Object e) => t.music_action_failed(error: '$e'),
      actions: <MusicMenuAction>[
        MusicMenuAction(
          id: 'play',
          label: t.music_play_all,
          icon: FushiIcons.play,
          run: (_) async => onPlay(),
        ),
        MusicMenuAction(
          id: 'detail',
          label: t.music_track_detail,
          icon: FushiIcons.info,
          run: (BuildContext c) async =>
              openMusicTrackDetail(c, track.trackUid),
        ),
        if (_appOf(context) case final AppModel app when app.isDatabaseReady)
          MusicMenuAction(
            id: 'addToLocalPlaylist',
            label: t.music_action_add_to_playlist,
            icon: FushiIcons.playlist,
            run: (BuildContext c) async {
              await musicAddItemsToLocalPlaylist(c, app.database, <
                MusicPlayItem
              >[musicPlayItemOf(track)]);
            },
          ),
        ...extra,
      ],
    ),
  ),
);

AppModel _appOf(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false).read(appProvider);

/// 远程曲目（YouTube / 在线插件，v147）在曲库 / 歌单里的菜单：播放 / 移出音乐库（在库时）/
/// 加入歌单；[extra] 追加在末尾（歌单页的「从这个歌单移除」）。
MusicItemMenu musicRemoteEntryMenu(
  BuildContext context,
  MusicRemoteTrackRow track, {
  required VoidCallback onPlay,
  List<MusicMenuAction> extra = const <MusicMenuAction>[],
}) => MusicItemMenu(
  buttonKey: ValueKey<String>('music-remote-track-menu-${track.trackUid}'),
  open: (MusicMenuAnchor? anchor) {
    final AppModel app = _appOf(context);
    final MusicPlayItem? item = musicPlayItemOfRemote(track);
    unawaited(
      showMusicActionMenu(
        context,
        anchor: anchor,
        errorText: (Object e) => t.music_action_failed(error: '$e'),
        actions: <MusicMenuAction>[
          MusicMenuAction(
            id: 'play',
            label: t.music_play_all,
            icon: FushiIcons.play,
            run: (_) async => onPlay(),
          ),
          if (app.isDatabaseReady && item != null)
            ...musicRemoteLibraryActions(
              app.database,
              item,
              inLibrary: track.libraryAddedAt != null,
            ),
          ...extra,
        ],
      ),
    );
  },
);

/// 远程曲目行副标题里的来源名（YouTube / 插件 id）。
String musicRemoteSourceLabel(MusicRemoteTrackRow track) =>
    switch (MusicRemoteTrackKind.fromWire(track.kind)) {
      MusicRemoteTrackKind.youtube => 'YouTube',
      MusicRemoteTrackKind.plugin || null => track.sourceKey,
    };

/// 曲目列表所在的本地歌单：每行多出「从这个歌单移除」（按条目 id 删，同一首出现两次时只删
/// 点的那一条）。[entryIds] 与列表条目一一对应。
class MusicTrackListPlaylist {
  const MusicTrackListPlaylist({
    required this.playlist,
    required this.entryIds,
  });

  final MusicPlaylistRow playlist;
  final List<int> entryIds;
}

/// 曲目列表（歌曲分区 / 艺人 / 专辑碟内 / 本地歌单）：点一首 = 以该列表为队列从这首开始播；
/// 长按 / 行尾「详情」= 曲目详情页。有没听完的断点（点开会接着放的，`music_resume.dart`）
/// 的行：行尾显示剩余时间，副标题下一条细进度条。
///
/// 条目可以是本地曲库曲目，也可以是加入音乐库 / 歌单的远程曲目（[MusicLibraryEntry]，v147）：
/// 两种排在同一条队列里，远程曲目行带封面缩略图与来源名、行尾是「更多」菜单。
class MusicTrackList extends ConsumerStatefulWidget {
  MusicTrackList({
    super.key,
    required List<MusicTrackRow> tracks,
    required this.albums,
    required this.context,
    this.shrinkWrap = false,
    this.showTrackNumbers = false,
  }) : entries = <MusicLibraryEntry>[
         for (final MusicTrackRow t in tracks) MusicLocalEntry(t),
       ],
       playlist = null,
       source = null;

  const MusicTrackList.entries({
    super.key,
    required this.entries,
    required this.albums,
    required this.context,
    this.shrinkWrap = false,
    this.showTrackNumbers = false,
    this.playlist,
    this.source,
  });

  final List<MusicLibraryEntry> entries;
  final Map<String, MusicAlbumRow> albums;

  /// 队列语境（决定 ReplayGain 模式）。
  final MusicQueueContext context;
  final bool shrinkWrap;
  final bool showTrackNumbers;

  /// 列表所在的本地歌单（多出「从这个歌单移除」）；不在歌单页为 null。
  final MusicTrackListPlaylist? playlist;

  /// 起播时记进播放流的来源（歌单页 = 这个歌单）；null = 不记。
  final MusicPlaySource? source;

  @override
  ConsumerState<MusicTrackList> createState() => _MusicTrackListState();
}

class _MusicTrackListState extends ConsumerState<MusicTrackList> {
  /// 这一列曲目的断点：挂上时按块查齐，之后只吃这一列里那几首的改动。
  late final MusicResumePointsWatch _resume;

  List<MusicLibraryEntry> get entries => widget.entries;

  static List<String> _uids(List<MusicLibraryEntry> entries) => <String>[
    for (final MusicLibraryEntry e in entries) e.trackUid,
  ];

  @override
  void initState() {
    super.initState();
    _resume =
        ref
            .read(appProvider)
            .musicSession
            .watchResumePoints(_uids(widget.entries))
          ..addListener(_onResumeChanged);
  }

  @override
  void didUpdateWidget(MusicTrackList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 本地构造每次重建都新建条目列表：按 uid 序列比，不按身份比（否则每帧重查断点）。
    if (!identical(oldWidget.entries, widget.entries) &&
        !listEquals(_uids(oldWidget.entries), _uids(widget.entries))) {
      _resume.watch(_uids(widget.entries));
    }
  }

  @override
  void dispose() {
    _resume
      ..removeListener(_onResumeChanged)
      ..dispose();
    super.dispose();
  }

  void _onResumeChanged() {
    if (mounted) setState(() {});
  }

  /// 以整列为队列从第 [index] 条起播。换不成播放项的条目（将来版本写的远程种类）不进队列。
  void _play(int index) {
    final List<MusicPlayItem> items = <MusicPlayItem>[];
    int start = 0;
    for (int i = 0; i < entries.length; i++) {
      final MusicPlayItem? item = entries[i].playItem(widget.albums);
      if (item == null) continue;
      if (i == index) start = items.length;
      items.add(item);
    }
    unawaited(
      ref
          .read(appProvider)
          .musicSession
          .engine
          .playQueue(
            items,
            startIndex: start,
            context: widget.context,
            source: widget.source,
          ),
    );
  }

  /// 歌单页每行的「从这个歌单移除」；不在歌单页回空。
  List<MusicMenuAction> _playlistActions(int index) {
    final MusicTrackListPlaylist? p = widget.playlist;
    if (p == null || index >= p.entryIds.length) {
      return const <MusicMenuAction>[];
    }
    return <MusicMenuAction>[
      MusicMenuAction(
        id: 'removeFromPlaylist',
        label: t.music_action_remove_from_playlist,
        icon: FushiIcons.close,
        run: (_) async {
          await ref
              .read(appProvider)
              .database
              .removeMusicPlaylistEntry(
                p.playlist.playlistUid,
                p.entryIds[index],
                at: DateTime.now().millisecondsSinceEpoch,
              );
          FushiToast.show(
            msg: t.music_action_removed_from_playlist(name: p.playlist.name),
            severity: ToastSeverity.success,
          );
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext buildContext) {
    final MusicResumeMode mode = watchMusicResumeMode(ref);
    final bool shrinkWrap = widget.shrinkWrap;
    final FushiDesignTokens tokens = FushiDesignTokens.of(buildContext);
    return FushiEntranceScope(
      child: ListView.builder(
        shrinkWrap: shrinkWrap,
        primary: shrinkWrap ? false : null,
        physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
        padding: shrinkWrap
            ? EdgeInsets.zero
            : withBottomSafeInset(
                buildContext,
                EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.gap,
                  tokens.spacing.page,
                  tokens.spacing.section,
                ),
              ),
        itemCount: entries.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext c, int i) => switch (entries[i]) {
            MusicLocalEntry(:final MusicTrackRow track) => _localRow(
              c,
              i,
              track,
              mode,
            ),
            MusicRemoteEntry(:final MusicRemoteTrackRow track) => _remoteRow(
              c,
              i,
              track,
              mode,
            ),
          },
        ),
      ),
    );
  }

  Widget _localRow(
    BuildContext c,
    int i,
    MusicTrackRow track,
    MusicResumeMode mode,
  ) {
    final String badge = musicFormatBadge(
      codec: track.codec,
      isLossless: track.isLossless,
      sampleRate: track.sampleRate,
      bitDepth: track.bitDepth,
      bitrateKbps: track.bitrate,
    );
    final Duration? resume = musicTrackResumeOf(
      track,
      _resume[track.trackUid],
      mode,
    );
    final Text subtitle = Text(
      <String>[
        track.artistCredit ?? t.music_artist_unknown,
        if (badge.isNotEmpty) badge,
      ].join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    void play() => _play(i);
    return musicLocalTrackMenu(
      c,
      track,
      onPlay: play,
      extra: _playlistActions(i),
    ).contextMenu(
      child: FushiPressScale(
        child: FushiGroupedListItem(
          key: ValueKey<String>(_rowKey('music-track', i, track.trackUid)),
          index: i,
          count: entries.length,
          onTap: play,
          onLongPress: () => openMusicTrackDetail(c, track.trackUid),
          child: FushiListItem(
            leading: widget.showTrackNumbers
                ? SizedBox(
                    width: 28,
                    child: Text(
                      track.trackNo?.toString() ?? '',
                      textAlign: TextAlign.end,
                      style: c.fushiType.bodySmall,
                    ),
                  )
                : const FushiListLeadingIcon(FushiIcons.music),
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: musicTrackSubtitleWithResume(track, subtitle, resume),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  musicTrackTimeLabel(track.durationMs, resume),
                  style: c.fushiType.bodySmall,
                ),
                FushiIconButton(
                  key: ValueKey<String>(
                    _rowKey('music-track-detail', i, track.trackUid),
                  ),
                  icon: FushiIcons.info,
                  tooltip: t.music_track_detail,
                  onTap: () => openMusicTrackDetail(c, track.trackUid),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _remoteRow(
    BuildContext c,
    int i,
    MusicRemoteTrackRow track,
    MusicResumeMode mode,
  ) {
    final MusicResumePointRow? point = _resume[track.trackUid];
    final Duration? resume = point == null
        ? null
        : musicResumeDisplayStart(
            mode: mode,
            savedPositionMs: point.positionMs,
            durationMs: track.durationMs ?? point.durationMs,
          );
    final Text subtitle = Text(
      <String>[
        track.artist ?? t.music_artist_unknown,
        musicRemoteSourceLabel(track),
      ].join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    void play() => _play(i);
    final MusicItemMenu menu = musicRemoteEntryMenu(
      c,
      track,
      onPlay: play,
      extra: _playlistActions(i),
    );
    return menu.contextMenu(
      child: FushiPressScale(
        child: FushiGroupedListItem(
          key: ValueKey<String>(_rowKey('music-track', i, track.trackUid)),
          index: i,
          count: entries.length,
          onTap: play,
          child: FushiListItem(
            leading: musicMaterialCover(
              MusicCover(coverPath: track.coverUrl, size: 40),
              size: 40,
              compact: true,
            ),
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: musicSubtitleWithResume(
              track.trackUid,
              track.durationMs,
              subtitle,
              resume,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  musicTrackTimeLabel(track.durationMs, resume),
                  style: c.fushiType.bodySmall,
                ),
                menu.button(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 行 key：歌单里同一首可以出现两次，歌单页的 key 带上行号免得撞。
  String _rowKey(String prefix, int i, String uid) =>
      widget.playlist == null ? '$prefix-$uid' : '$prefix-$i-$uid';
}

/// 当前的断点续播模式（设置 `music_resume_mode`）；设置里切档时调用方跟着重建。
MusicResumeMode watchMusicResumeMode(WidgetRef ref) => ref.watch(
  appProvider.select(
    (AppModel a) =>
        a.isPreferencesReady ? a.musicResumeMode : MusicResumeMode.longTracks,
  ),
);

/// [track] 点开会从哪接着放（与打开时同一判据）；null = 从头（不显示进度）。
Duration? musicTrackResumeOf(
  MusicTrackRow track,
  MusicResumePointRow? row,
  MusicResumeMode mode,
) => row == null
    ? null
    : musicResumeDisplayStart(
        mode: mode,
        savedPositionMs: row.positionMs,
        durationMs: track.durationMs ?? row.durationMs,
      );

/// 行尾时间：有断点显示「剩余 m:ss」，否则曲长。
String musicTrackTimeLabel(int? durationMs, Duration? resume) =>
    resume == null || durationMs == null
    ? formatMusicDuration(durationMs)
    : t.music_track_remaining(
        time: formatMusicDuration(durationMs - resume.inMilliseconds),
      );

/// 有断点的行：副标题下加一条细进度条（key `music-track-resume-<uid>`）。
Widget? musicTrackSubtitleWithResume(
  MusicTrackRow track,
  Widget? subtitle,
  Duration? resume,
) => musicSubtitleWithResume(track.trackUid, track.durationMs, subtitle, resume);

/// [musicTrackSubtitleWithResume] 的通用形（远程曲目也用：只要 uid 与曲长）。
Widget? musicSubtitleWithResume(
  String trackUid,
  int? durationMs,
  Widget? subtitle,
  Duration? resume,
) {
  if (resume == null || durationMs == null) return subtitle;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      if (subtitle != null) ...<Widget>[subtitle, const SizedBox(height: 4)],
      _MusicResumeBar(
        key: ValueKey<String>('music-track-resume-$trackUid'),
        fraction: resume.inMilliseconds / durationMs,
      ),
    ],
  );
}

/// 断点进度条（细、平直；值变化时按动效时长补间，减弱动态效果下瞬间到位）。
class _MusicResumeBar extends StatelessWidget {
  const _MusicResumeBar({super.key, required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(end: fraction.clamp(0, 1).toDouble()),
    duration: fushiMotionDuration(context, FushiMotion.medium),
    curve: FushiMotion.enter,
    builder: (BuildContext context, double value, _) =>
        FushiLinearProgressIndicator(value: value, minHeight: 3, wavy: false),
  );
}

/// 一列曲目的独立页（艺人）。
class MusicTrackListPage extends StatelessWidget {
  const MusicTrackListPage({
    super.key,
    required this.title,
    required this.tracks,
    required this.albums,
  });

  final String title;
  final List<MusicTrackRow> tracks;
  final Map<String, MusicAlbumRow> albums;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return MusicFloatingBarHost(
      child: FushiPageScaffold(
        title: title,
        header: apple
            ? null
            : Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.gap,
                  tokens.spacing.page,
                  tokens.spacing.gap,
                ),
                child: FushiFloatingTopBar(
                  title: title,
                  leading: <FushiToolbarItem>[
                    if (navigator != null && navigator.canPop())
                      FushiToolbarItem(
                        icon: FushiIcons.back,
                        label: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        onPressed: () => unawaited(navigator.maybePop()),
                      ),
                  ],
                ),
              ),
        body: MusicTrackList(
          tracks: tracks,
          albums: albums,
          context: MusicQueueContext.mixed,
        ),
      ),
    );
  }
}
