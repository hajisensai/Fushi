import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart';
import 'package:fushi/src/pages/implementations/music/music_track_detail_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

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

/// 曲目列表（歌曲分区 / 艺人 / 专辑碟内）：点一首 = 以该列表为队列从这首开始播；
/// 长按 / 行尾「详情」= 曲目详情页。
class MusicTrackList extends ConsumerWidget {
  const MusicTrackList({
    super.key,
    required this.tracks,
    required this.albums,
    required this.context,
    this.shrinkWrap = false,
    this.showTrackNumbers = false,
  });

  final List<MusicTrackRow> tracks;
  final Map<String, MusicAlbumRow> albums;

  /// 队列语境（决定 ReplayGain 模式）。
  final MusicQueueContext context;
  final bool shrinkWrap;
  final bool showTrackNumbers;

  List<MusicPlayItem> _items() => <MusicPlayItem>[
    for (final MusicTrackRow t in tracks)
      musicPlayItemOf(
        t,
        album: t.albumUid == null ? null : albums[t.albumUid!],
      ),
  ];

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(buildContext);
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    return FushiEntranceScope(
      child: ListView.builder(
        shrinkWrap: shrinkWrap,
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
        itemCount: tracks.length,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext c, int i) {
          final MusicTrackRow track = tracks[i];
          final String badge = musicFormatBadge(
            codec: track.codec,
            isLossless: track.isLossless,
            sampleRate: track.sampleRate,
            bitDepth: track.bitDepth,
            bitrateKbps: track.bitrate,
          );
          return FushiPressScale(
            child: FushiGroupedListItem(
              key: ValueKey<String>('music-track-${track.trackUid}'),
              index: i,
              count: tracks.length,
              onTap: () => unawaited(
                engine.playQueue(_items(), startIndex: i, context: context),
              ),
              onLongPress: () => openMusicTrackDetail(c, track.trackUid),
              child: FushiListItem(
                leading: showTrackNumbers
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
                subtitle: Text(
                  <String>[
                    track.artistCredit ?? t.music_artist_unknown,
                    if (badge.isNotEmpty) badge,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      formatMusicDuration(track.durationMs),
                      style: c.fushiType.bodySmall,
                    ),
                    FushiIconButton(
                      key: ValueKey<String>(
                        'music-track-detail-${track.trackUid}',
                      ),
                      icon: FushiIcons.info,
                      tooltip: t.music_track_detail,
                      onTap: () => openMusicTrackDetail(c, track.trackUid),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
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
    return FushiPageScaffold(
      title: title,
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
    );
  }
}
