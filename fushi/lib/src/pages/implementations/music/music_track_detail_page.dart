/// 曲目详情（音乐方案 §11.2「曲目详情」的动画出处部分 + 作品图谱区块）。
///
/// 作品图谱 L2（docs/specs/2026-10-24-cross-media-links.md §2）：列出这首歌经声纹识别
/// 「出现在：第 1–12 集 OP」，点一集直接从那一集的 OP 起点播放；「识别出现位置」按钮
/// 对这首歌的全部主题曲连接跑一轮（缓存有效的集跳过）。下面是「同一作品」区块，主题曲
/// 连接就在这里建。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/media_link_opener.dart';
import 'package:fushi/src/media/links/media_links_section.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_detector.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/people/person_entry_sections.dart'
    show MusicTrackPeopleSection;
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart'
    show MusicFloatingBarHost;
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_track_scrape_sections.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';

/// 角色在「出现在」里的短标签（OP / ED / 插入曲 / 主题曲）；没写角色返回 null。
String? themeSongRoleLabel(ThemeSongRole? role) => switch (role) {
  ThemeSongRole.op => t.music_theme_song_role_op,
  ThemeSongRole.ed => t.music_theme_song_role_ed,
  ThemeSongRole.insert => t.music_theme_song_role_insert,
  ThemeSongRole.theme => t.music_theme_song_role_theme,
  null => null,
};

/// 「第 1–12 集 OP」。
String themeSongAppearanceLabel(ThemeSongAppearance a) {
  final String episodes = t.music_track_appears_episodes(
    episodes: a.episodeLabel,
  );
  final String? role = themeSongRoleLabel(a.role);
  return role == null ? episodes : '$episodes $role';
}

/// 从某一集的 [startMs] 开始播放（主题曲的出现位置）。
Future<void> openThemeSongEpisode({
  required BuildContext context,
  required FushiDatabase db,
  required ThemeSongEpisode episode,
  required int startMs,
}) async {
  final NavigatorState navigator = Navigator.of(context);
  final VideoBookRepository repo = VideoBookRepository(db);
  final VideoBookRow? row = await repo.getByBookUid(episode.bookUid);
  if (row == null) return;
  // 旧式「一行多集」播放列表：先把当前集切到这一集（与剧集面板选集同一条持久化），
  // 起播位置才落在这一集上。
  if (episode.episodeIndex != row.currentEpisode &&
      themeSongFilesOf(row).length > 1) {
    await repo.updateCurrentEpisode(episode.bookUid, episode.episodeIndex);
  }
  final Map<String, int> primary = await db.getPrimaryCollectionIdByEntry();
  if (!navigator.mounted) return;
  unawaited(
    navigator.push<void>(
      adaptivePageRoute<void>(
        context: navigator.context,
        builder: (_) => VideoFushiPage.neutralized(
          bookUid: episode.bookUid,
          repo: repo,
          playlistCollectionId:
              primary[MediaKind.video.compositeKey(episode.bookUid)],
          initialCueStartMs: startMs,
        ),
      ),
    ),
  );
}

class MusicTrackDetailPage extends ConsumerStatefulWidget {
  const MusicTrackDetailPage({super.key, required this.trackUid});

  final String trackUid;

  @override
  ConsumerState<MusicTrackDetailPage> createState() =>
      _MusicTrackDetailPageState();
}

class _MusicTrackDetailPageState extends ConsumerState<MusicTrackDetailPage> {
  late final Future<
    ({MusicTrackRow? track, MusicAlbumRow? album, String? cover})
  >
  _track = _loadTrack();
  late Future<List<ThemeSongAppearance>> _appearances = _loadAppearances();
  late Future<({MusicScrapeMetaRow? meta, Map<String, MusicTrackRow> local})>
  _versions = _loadVersions();
  bool _detecting = false;

  /// 识别结论 + 「其它版本」里本地有的曲目（按录音 MBID）。
  Future<({MusicScrapeMetaRow? meta, Map<String, MusicTrackRow> local})>
  _loadVersions() async {
    final MusicScrapeMetaRow? meta = await _db.getMusicScrapeMeta(
      widget.trackUid,
    );
    final Set<String> ids = <String>{
      if (meta?.originalRecordingId != null) meta!.originalRecordingId!,
      for (final MusicStoredRecording r in decodeMusicStoredRecordings(
        meta?.versionsJson,
      ))
        r.id,
    };
    final Map<String, MusicTrackRow> local = <String, MusicTrackRow>{
      for (final MusicTrackRow t in await _db.listMusicTracksByRecordingIds(
        ids,
      ))
        if (t.trackUid != widget.trackUid && t.mbRecordingId != null)
          t.mbRecordingId!: t,
    };
    return (meta: meta, local: local);
  }

  FushiDatabase get _db => ref.read(appProvider).database;

  Future<({MusicTrackRow? track, MusicAlbumRow? album, String? cover})>
  _loadTrack() async {
    final MusicTrackRow? track = await _db.getMusicTrack(widget.trackUid);
    final String? albumUid = track?.albumUid;
    final MusicAlbumRow? album = albumUid == null
        ? null
        : await _db.getMusicAlbum(albumUid);
    String? cover;
    final String? coverTrack = album?.coverTrackUid;
    if (coverTrack != null) {
      cover = (await _db.getMusicTrack(coverTrack))?.path;
    }
    return (track: track, album: album, cover: cover);
  }

  Future<List<ThemeSongAppearance>> _loadAppearances() =>
      loadThemeSongAppearances(_db, widget.trackUid);

  Future<void> _detect() async {
    if (_detecting) return;
    setState(() => _detecting = true);
    try {
      final ThemeSongDetectionReport report = await themeSongDetectorFor(
        _db,
      ).detect(onlyTrackUid: widget.trackUid);
      if (!mounted) return;
      FushiToast.show(
        msg: report.decodeFailures > 0
            ? t.music_theme_song_detect_partial(
                hits: report.hits,
                failed: report.decodeFailures,
              )
            : t.music_theme_song_detect_done(hits: report.hits),
        severity: report.decodeFailures > 0
            ? ToastSeverity.warning
            : ToastSeverity.success,
      );
      setState(() => _appearances = _loadAppearances());
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return FutureBuilder<
      ({MusicTrackRow? track, MusicAlbumRow? album, String? cover})
    >(
      future: _track,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<
              ({MusicTrackRow? track, MusicAlbumRow? album, String? cover})
            >
            snap,
          ) {
            final MusicTrackRow? track = snap.data?.track;
            final MusicAlbumRow? album = snap.data?.album;
            final String title = track?.title ?? '';
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
                                onPressed: () =>
                                    unawaited(navigator.maybePop()),
                              ),
                          ],
                        ),
                      ),
                body: track == null
                    ? const SizedBox.shrink()
                    : _body(context, tokens, track, album, snap.data?.cover),
              ),
            );
          },
    );
  }

  Widget _body(
    BuildContext context,
    FushiDesignTokens tokens,
    MusicTrackRow track,
    MusicAlbumRow? album,
    String? embeddedCover,
  ) {
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    final List<Widget> children = <Widget>[
      Wrap(
        spacing: tokens.spacing.section,
        runSpacing: tokens.spacing.gap,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: <Widget>[
          musicMaterialCover(
            MusicCover(
              coverPath: album?.coverPath,
              embeddedFromPath: embeddedCover ?? track.path,
              size: 160,
            ),
            size: 160,
            tilt: true,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: tokens.spacing.gap * 0.5,
              children: <Widget>[
                Text(track.title, style: context.fushiType.headlineSmall),
                Text(
                  <String>[
                    track.artistCredit ??
                        album?.albumArtistCredit ??
                        t.music_artist_unknown,
                    if (album != null) album.title,
                  ].join(' · '),
                  style: context.fushiType.bodyMedium,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap,
                  children: <Widget>[
                    FushiPressScale(
                      child: FushiFilledButton.icon(
                        size: FushiButtonSize.m,
                        key: const ValueKey<String>('music_track_play'),
                        onPressed: () => unawaited(
                          engine.playQueue(<MusicPlayItem>[
                            musicPlayItemOf(track, album: album),
                          ], context: MusicQueueContext.mixed),
                        ),
                        icon: const FushiIcon(FushiIcons.play),
                        label: Text(t.music_play_all),
                      ),
                    ),
                    FushiPressScale(
                      child: FushiFilledButton.tonalIcon(
                        size: FushiButtonSize.m,
                        key: const ValueKey<String>(
                          'music_track_detect_theme_song',
                        ),
                        onPressed: _detecting
                            ? null
                            : () => unawaited(_detect()),
                        icon: const FushiIcon(FushiIcons.refresh),
                        label: Text(
                          _detecting
                              ? t.music_theme_song_detecting
                              : t.music_theme_song_detect,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      FutureBuilder<List<ThemeSongAppearance>>(
        future: _appearances,
        builder:
            (BuildContext context, AsyncSnapshot<List<ThemeSongAppearance>> s) {
              final List<ThemeSongAppearance> list =
                  s.data ?? const <ThemeSongAppearance>[];
              if (list.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  FushiSectionTitle(t.music_track_appears_in),
                  for (int i = 0; i < list.length; i++)
                    ThemeSongAppearanceTile(
                      key: ValueKey<String>('music-track-appearance-$i'),
                      appearance: list[i],
                      index: i,
                      count: list.length,
                      onOpenEpisode:
                          (({ThemeSongEpisode episode, int startMs}) e) =>
                              unawaited(
                                openThemeSongEpisode(
                                  context: context,
                                  db: _db,
                                  episode: e.episode,
                                  startMs: e.startMs,
                                ),
                              ),
                    ),
                ],
              );
            },
      ),
      MusicTrackIdentificationSection(
        database: _db,
        track: track,
        service: ref.read(appProvider).musicScrape,
        onChanged: () => setState(() => _versions = _loadVersions()),
      ),
      FutureBuilder<
        ({MusicScrapeMetaRow? meta, Map<String, MusicTrackRow> local})
      >(
        future: _versions,
        builder:
            (
              BuildContext context,
              AsyncSnapshot<
                ({MusicScrapeMetaRow? meta, Map<String, MusicTrackRow> local})
              >
              v,
            ) {
              final MusicScrapeMetaRow? meta = v.data?.meta;
              if (meta == null || meta.status != 'matched') {
                return const SizedBox.shrink();
              }
              return MusicTrackVersionsSection(
                meta: meta,
                localByRecording: v.data!.local,
                onOpenLocal: (MusicTrackRow other) => unawaited(
                  Navigator.of(context).push<void>(
                    adaptivePageRoute<void>(
                      context: context,
                      builder: (_) =>
                          MusicTrackDetailPage(trackUid: other.trackUid),
                    ),
                  ),
                ),
              );
            },
      ),
      MusicTrackVideosSection(database: _db, track: track),
      // 署名（作品图谱 L5）：点演唱者 / 艺人进人物聚合页；没有署名数据时不渲染。
      MusicTrackPeopleSection(database: _db, trackUid: track.trackUid),
      MediaLinksSection(
        database: _db,
        self: (kind: MediaLinkKind.musicTrack, key: track.trackUid),
        onOpen: (MediaLinkEntry e) =>
            openMediaLinkEntry(context: context, ref: ref, entry: e),
        searchActionFor: (MediaLinkKind k) =>
            mediaLinkSearchAction(context: context, ref: ref, kind: k),
      ),
    ];
    return FushiEntranceScope(
      child: ListView.separated(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: children.length,
        separatorBuilder: (_, _) => SizedBox(height: tokens.spacing.gap),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int i) => children[i],
        ),
      ),
    );
  }
}

/// 「出现在」的一行：视频标题 + 「第 1–12 集 OP」，下面一排集号，点一集从 OP 起点播。
/// 点整行 = 第一集。
class ThemeSongAppearanceTile extends StatelessWidget {
  const ThemeSongAppearanceTile({
    super.key,
    required this.appearance,
    required this.onOpenEpisode,
    this.index = 0,
    this.count = 1,
  });

  final ThemeSongAppearance appearance;
  final ValueChanged<({ThemeSongEpisode episode, int startMs})> onOpenEpisode;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiPressScale(
      child: FushiGroupedListItem(
        index: index,
        count: count,
        onTap: () => onOpenEpisode(appearance.episodes.first),
        child: Padding(
          padding: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              FushiListItem(
                leading: const FushiListLeadingIcon(FushiIcons.video),
                title: Text(
                  appearance.videoTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(themeSongAppearanceLabel(appearance)),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final ({ThemeSongEpisode episode, int startMs}) e
                        in appearance.episodes)
                      _EpisodeChip(
                        key: ValueKey<String>(
                          'music-appearance-episode-${e.episode.episodeNumber}',
                        ),
                        label: '${e.episode.episodeNumber}',
                        tooltip: t.music_theme_song_open_episode(
                          n: e.episode.episodeNumber,
                        ),
                        onTap: () => onOpenEpisode(e),
                      ),
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

class _EpisodeChip extends StatelessWidget {
  const _EpisodeChip({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final ShapeBorder shape = apple
        ? const RoundedRectangleBorder(borderRadius: FushiM3eShape.smallRadius)
        : const StadiumBorder();
    return FushiTooltip(
      message: tooltip,
      child: FushiHoverLift(
        scale: kMusicHoverLiftScale,
        builder: (BuildContext context, bool hovering) => FushiPressScale(
          child: Material(
            color: cs.secondaryContainer,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: shape,
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Center(
                  widthFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      label,
                      style: TextStyle(color: cs.onSecondaryContainer),
                    ),
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
