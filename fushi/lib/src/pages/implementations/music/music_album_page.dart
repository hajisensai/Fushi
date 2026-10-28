/// 专辑页（设计 §11.2）：大封面、碟片分组、格式徽章（`FLAC 24/96` / `DSD64` / `Hi-Res`）、
/// 整碟播放（album ReplayGain）与随机播放（track ReplayGain）。
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/disc/music_disc.dart';

import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_disc_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart'
    show musicAlbumDetailCover, kMusicAlbumDetailCoverSize;
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 一张专辑要显示的格式徽章（去重、按出现顺序；混格式专辑各列一枚）+ 是否 Hi-Res。
({List<String> badges, bool hiRes}) musicAlbumBadges(
  List<MusicTrackRow> tracks,
) {
  final List<String> badges = <String>[];
  bool hiRes = false;
  for (final MusicTrackRow t in tracks) {
    final String b = musicFormatBadge(
      codec: t.codec,
      isLossless: t.isLossless,
      sampleRate: t.sampleRate,
      bitDepth: t.bitDepth,
      bitrateKbps: t.isLossless ? null : t.bitrate,
    );
    if (b.isNotEmpty && !badges.contains(b)) badges.add(b);
    hiRes =
        hiRes ||
        musicIsHiRes(
          codec: t.codec,
          isLossless: t.isLossless,
          sampleRate: t.sampleRate,
          bitDepth: t.bitDepth,
        );
  }
  return (badges: badges, hiRes: hiRes);
}

class MusicAlbumPage extends ConsumerStatefulWidget {
  const MusicAlbumPage({
    super.key,
    required this.album,
    required this.tracks,
    this.embeddedCoverPath,
    this.disc,
  });

  final MusicAlbumRow album;

  /// 已按碟号 / 轨号排好的曲目。
  final List<MusicTrackRow> tracks;
  final String? embeddedCoverPath;

  /// 光盘来源（演唱会 / MV 合集 DVD·BD，§9.2）；普通专辑为 null。
  final MusicDiscSourceRow? disc;

  @override
  ConsumerState<MusicAlbumPage> createState() => _MusicAlbumPageState();
}

class _MusicAlbumPageState extends ConsumerState<MusicAlbumPage> {
  late MusicAlbumRow album = widget.album;
  late List<MusicTrackRow> tracks = widget.tracks;
  late MusicDiscSourceRow? disc = widget.disc;
  StreamSubscription<Set<TableUpdate>>? _dbSub;
  bool _busy = false;

  AppModel get _app => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    if (_app.isDatabaseReady) {
      final FushiDatabase db = _app.database;
      // 表级变更流（不是 drift .watch()：长驻页面订阅 watch 会在 dispose 时挂死测试）。
      // 章节导入 / MusicBrainz 对号 / 重扫都在别处落库，这里跟着重读。
      _dbSub = db
          .tableUpdates(
            TableUpdateQuery.onAllTables(
              <ResultSetImplementation<Object?, Object?>>[
                db.musicTracks,
                db.musicAlbums,
                db.musicDiscSources,
              ],
            ),
          )
          .listen((_) => unawaited(_reload()));
    }
  }

  @override
  void dispose() {
    unawaited(_dbSub?.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    final FushiDatabase db = _app.database;
    final MusicAlbumRow? a = await db.getMusicAlbum(album.albumUid);
    if (!mounted) return;
    if (a == null) {
      // 专辑被移除（光盘从曲库移除）：退回曲库。
      unawaited(Navigator.of(context).maybePop());
      return;
    }
    final List<MusicTrackRow> rows = sortAlbumTracks(
      await db.listMusicTracks(albumUid: album.albumUid),
    );
    final String? discUid = a.discUid;
    final MusicDiscSourceRow? d = discUid == null
        ? null
        : await db.getMusicDiscSource(discUid);
    if (!mounted) return;
    setState(() {
      album = a;
      tracks = rows;
      disc = d;
    });
  }

  Future<void> _runDisc(MusicDiscMenuAction action) async {
    final MusicDiscSourceRow? d = disc;
    if (d == null || _busy) return;
    setState(() => _busy = true);
    try {
      await runMusicDiscMenuAction(
        context: context,
        app: _app,
        action: action,
        album: album,
        disc: d,
        tracks: tracks,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<MusicPlayItem> _items() => <MusicPlayItem>[
    for (final MusicTrackRow t in tracks) musicPlayItemOf(t, album: album),
  ];

  @override
  Widget build(BuildContext context) {
    final String? embeddedCoverPath = widget.embeddedCoverPath;
    final bool apple = isGlassDesign(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    final ({List<String> badges, bool hiRes}) fmt = musicAlbumBadges(tracks);
    final Map<int?, List<MusicTrackRow>> discs = groupTracksByDisc(tracks);
    final Map<String, MusicAlbumRow> albumMap = <String, MusicAlbumRow>{
      album.albumUid: album,
    };
    final MusicDiscSourceRow? disc = this.disc;

    final Widget header = Wrap(
      spacing: tokens.spacing.section,
      runSpacing: tokens.spacing.gap,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: <Widget>[
        // 方形「唱片」材质大图（与专辑网格同一材质）；封面上不压角标，光盘规格
        // 徽标挪到右侧格式徽章那一排。
        musicAlbumDetailCover(
          MusicCover(
            coverPath: album.coverPath,
            embeddedFromPath: embeddedCoverPath,
            size: kMusicAlbumDetailCoverSize,
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: tokens.spacing.gap * 0.5,
            children: <Widget>[
              Text(album.title, style: context.fushiType.headlineSmall),
              Text(
                <String>[
                  album.albumArtistCredit ?? t.music_artist_unknown,
                  if (album.releaseDate != null) album.releaseDate!,
                  t.music_tracks_count(count: tracks.length),
                ].join(' · '),
                style: context.fushiType.bodyMedium,
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (disc != null)
                    IgnorePointer(
                      child: MusicDiscBadge(
                        key: const ValueKey<String>('music-album-disc-badge'),
                        disc: disc,
                      ),
                    ),
                  for (final String b in fmt.badges) _Badge(text: b),
                  if (fmt.hiRes)
                    _Badge(text: t.music_hi_res_badge, strong: true),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: <Widget>[
                  FushiPressScale(
                    child: FushiFilledButton.icon(
                      key: const ValueKey<String>('music_album_play'),
                      onPressed: tracks.isEmpty
                          ? null
                          : () => unawaited(
                              engine.playQueue(
                                _items(),
                                context: MusicQueueContext.album,
                              ),
                            ),
                      icon: const FushiIcon(FushiIcons.play),
                      label: Text(t.music_play_all),
                    ),
                  ),
                  FushiPressScale(
                    child: FushiOutlinedButton.icon(
                      key: const ValueKey<String>('music_album_shuffle'),
                      onPressed: tracks.isEmpty
                          ? null
                          : () => unawaited(
                              engine.playQueue(
                                _items(),
                                context: MusicQueueContext.album,
                                shuffle: true,
                              ),
                            ),
                      icon: const FushiIcon(FushiIcons.repeat),
                      label: Text(t.music_shuffle_play),
                    ),
                  ),
                  if (disc != null) ...<Widget>[
                    FushiPressScale(
                      child: FushiOutlinedButton.icon(
                        key: const ValueKey<String>('music_disc_import'),
                        onPressed: _busy
                            ? null
                            : () => unawaited(
                                _runDisc(MusicDiscMenuAction.importChapters),
                              ),
                        icon: const FushiIcon(FushiIcons.toc),
                        label: Text(
                          musicDiscImportLabel(
                            disc,
                            hasTracks: tracks.isNotEmpty,
                          ),
                        ),
                      ),
                    ),
                    if (tracks.isNotEmpty &&
                        disc.kind != MusicDiscKind.cdda.wire)
                      FushiPressScale(
                        child: FushiOutlinedButton.icon(
                          key: const ValueKey<String>('music_disc_lookup'),
                          onPressed: _busy
                              ? null
                              : () => unawaited(
                                  _runDisc(MusicDiscMenuAction.lookup),
                                ),
                          icon: const FushiIcon(FushiIcons.search),
                          label: Text(t.music_disc_lookup),
                        ),
                      ),
                    FushiPressScale(
                      child: FushiOutlinedButton.icon(
                        key: const ValueKey<String>('music_disc_remove'),
                        onPressed: _busy
                            ? null
                            : () => unawaited(
                                _runDisc(MusicDiscMenuAction.remove),
                              ),
                        icon: const FushiIcon(FushiIcons.delete),
                        label: Text(t.music_disc_remove),
                      ),
                    ),
                  ],
                ],
              ),
              if (disc != null && tracks.isEmpty)
                Text(
                  t.music_disc_not_imported,
                  style: context.fushiType.bodySmall,
                ),
            ],
          ),
        ),
      ],
    );

    final List<Widget> children = <Widget>[
      header,
      for (final MapEntry<int?, List<MusicTrackRow>> disc
          in discs.entries) ...<Widget>[
        if (disc.key != null)
          FushiSectionTitle(t.music_disc_label(n: disc.key!)),
        _AlbumDiscList(
          tracks: disc.value,
          allTracks: tracks,
          albums: albumMap,
          album: album,
        ),
      ],
    ];

    return FushiPageScaffold(
      title: album.title,
      bottomNavigationBar: const MusicNowPlayingBar(),
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
                title: album.title,
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
      body: FushiEntranceScope(
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
      ),
    );
  }
}

/// 一碟的曲目。点一首 = 整张专辑为队列（album 语境），从这首开始。
class _AlbumDiscList extends ConsumerWidget {
  const _AlbumDiscList({
    required this.tracks,
    required this.allTracks,
    required this.albums,
    required this.album,
  });

  final List<MusicTrackRow> tracks;
  final List<MusicTrackRow> allTracks;
  final Map<String, MusicAlbumRow> albums;
  final MusicAlbumRow album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    return Column(
      children: <Widget>[
        for (int i = 0; i < tracks.length; i++)
          FushiPressScale(
            child: FushiGroupedListItem(
              key: ValueKey<String>('music-album-track-${tracks[i].trackUid}'),
              index: i,
              count: tracks.length,
              onTap: () => unawaited(
                engine.playQueue(
                  <MusicPlayItem>[
                    for (final MusicTrackRow t in allTracks)
                      musicPlayItemOf(t, album: album),
                  ],
                  startIndex: allTracks.indexOf(tracks[i]),
                  context: MusicQueueContext.album,
                ),
              ),
              child: FushiListItem(
                leading: SizedBox(
                  width: 28,
                  child: Text(
                    tracks[i].trackNo?.toString() ?? '',
                    textAlign: TextAlign.end,
                    style: context.fushiType.bodySmall,
                  ),
                ),
                title: Text(
                  tracks[i].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle:
                    tracks[i].artistCredit == null ||
                        tracks[i].artistCredit == album.albumArtistCredit
                    ? null
                    : Text(tracks[i].artistCredit!),
                trailing: Text(
                  formatMusicDuration(tracks[i].durationMs),
                  style: context.fushiType.bodySmall,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.strong = false});

  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: strong ? scheme.primaryContainer : scheme.secondaryContainer,
        borderRadius: FushiDesignTokens.of(context).radii.chipRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          text,
          style: context.fushiType.labelMedium.copyWith(
            color: strong
                ? scheme.onPrimaryContainer
                : scheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}
