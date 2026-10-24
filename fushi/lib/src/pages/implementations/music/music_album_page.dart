/// 专辑页（设计 §11.2）：大封面、碟片分组、格式徽章（`FLAC 24/96` / `DSD64` / `Hi-Res`）、
/// 整碟播放（album ReplayGain）与随机播放（track ReplayGain）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
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

class MusicAlbumPage extends ConsumerWidget {
  const MusicAlbumPage({
    super.key,
    required this.album,
    required this.tracks,
    this.embeddedCoverPath,
  });

  final MusicAlbumRow album;

  /// 已按碟号 / 轨号排好的曲目。
  final List<MusicTrackRow> tracks;
  final String? embeddedCoverPath;

  List<MusicPlayItem> _items() => <MusicPlayItem>[
    for (final MusicTrackRow t in tracks) musicPlayItemOf(t, album: album),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool apple = isGlassDesign(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    final ({List<String> badges, bool hiRes}) fmt = musicAlbumBadges(tracks);
    final Map<int?, List<MusicTrackRow>> discs = groupTracksByDisc(tracks);
    final Map<String, MusicAlbumRow> albumMap = <String, MusicAlbumRow>{
      album.albumUid: album,
    };

    final Widget header = Wrap(
      spacing: tokens.spacing.section,
      runSpacing: tokens.spacing.gap,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: <Widget>[
        MusicCover(
          coverPath: album.coverPath,
          embeddedFromPath: embeddedCoverPath,
          size: 200,
          borderRadius: 16,
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
                children: <Widget>[
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
                ],
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
        color: strong ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          text,
          style: context.fushiType.labelMedium.copyWith(
            color: strong ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
