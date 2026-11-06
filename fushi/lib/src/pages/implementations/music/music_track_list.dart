import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_resume.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart'
    show MusicFloatingBarHost;
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
/// 长按 / 行尾「详情」= 曲目详情页。有没听完的断点（点开会接着放的，`music_resume.dart`）
/// 的行：行尾显示剩余时间，副标题下一条细进度条。
class MusicTrackList extends ConsumerStatefulWidget {
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

  @override
  ConsumerState<MusicTrackList> createState() => _MusicTrackListState();
}

class _MusicTrackListState extends ConsumerState<MusicTrackList> {
  /// 这一列曲目的断点（一次按块查齐，不逐行查）。
  Map<String, MusicResumePointRow> _resume =
      const <String, MusicResumePointRow>{};
  MusicResumeMode _mode = MusicResumeMode.longTracks;
  int _loadGen = 0;
  late final MusicSession _session = ref.read(appProvider).musicSession;

  List<MusicTrackRow> get tracks => widget.tracks;

  @override
  void initState() {
    super.initState();
    _session.resumePointsRevision.addListener(_reloadResume);
    _reloadResume();
  }

  @override
  void didUpdateWidget(MusicTrackList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tracks, widget.tracks)) _reloadResume();
  }

  @override
  void dispose() {
    _session.resumePointsRevision.removeListener(_reloadResume);
    super.dispose();
  }

  void _reloadResume() => unawaited(_loadResume());

  Future<void> _loadResume() async {
    final AppModel app = ref.read(appProvider);
    if (!app.isDatabaseReady) return;
    final int gen = ++_loadGen;
    final Map<String, MusicResumePointRow> rows = await app.database
        .listMusicResumePoints(<String>[
          for (final MusicTrackRow t in widget.tracks) t.trackUid,
        ]);
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _resume = rows;
      _mode = app.isPreferencesReady
          ? app.musicResumeMode
          : MusicResumeMode.longTracks;
    });
  }

  List<MusicPlayItem> _items() => <MusicPlayItem>[
    for (final MusicTrackRow t in tracks)
      musicPlayItemOf(
        t,
        album: t.albumUid == null ? null : widget.albums[t.albumUid!],
      ),
  ];

  /// 点开会从哪接着放；null = 从头（不显示进度）。
  Duration? _resumeOf(MusicTrackRow track) {
    final MusicResumePointRow? row = _resume[track.trackUid];
    if (row == null) return null;
    return musicResumeDisplayStart(
      mode: _mode,
      savedPositionMs: row.positionMs,
      durationMs: track.durationMs ?? row.durationMs,
    );
  }

  @override
  Widget build(BuildContext buildContext) {
    final bool shrinkWrap = widget.shrinkWrap;
    final bool showTrackNumbers = widget.showTrackNumbers;
    final MusicQueueContext context = widget.context;
    final FushiDesignTokens tokens = FushiDesignTokens.of(buildContext);
    final MusicPlayerEngine engine = _session.engine;
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
          final Duration? resume = _resumeOf(track);
          final int? durationMs = track.durationMs;
          final Text subtitle = Text(
            <String>[
              track.artistCredit ?? t.music_artist_unknown,
              if (badge.isNotEmpty) badge,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
                subtitle: resume == null || durationMs == null
                    ? subtitle
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          subtitle,
                          const SizedBox(height: 4),
                          _MusicResumeBar(
                            key: ValueKey<String>(
                              'music-track-resume-${track.trackUid}',
                            ),
                            fraction: resume.inMilliseconds / durationMs,
                          ),
                        ],
                      ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      resume == null || durationMs == null
                          ? formatMusicDuration(durationMs)
                          : t.music_track_remaining(
                              time: formatMusicDuration(
                                durationMs - resume.inMilliseconds,
                              ),
                            ),
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
