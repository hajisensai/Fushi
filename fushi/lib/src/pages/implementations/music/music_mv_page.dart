/// MV 播放页（音乐方案 §8.3）：带纹理的 mpv 实例（media_kit `Video`），音频源可选——
///
/// - **MV 原声**：直接放 MV 自己的音轨；
/// - **曲库音轨**（「看 MV 听无损」）：同一个 mpv 实例里 `audio-add` 本地文件并选中它、
///   MV 自带音轨不出声；对齐靠 mpv 自己的 `audio-delay`，不在 Dart 里追帧：
///   外挂音轨文件时刻 a（CUE 曲目里 = 曲目时刻 + 起点）要在 MV 时刻 `a − cueStart + offset`
///   播出，所以 `audio-delay = offset − cueStart`（[musicMvAudioDelaySeconds]）。
///
/// 两种音频源下画面都是主时钟：歌词显示时刻 = MV 位置 − 偏移（[musicMvLyricPosition]）。
/// 偏移来自绑定（声纹对齐求得），页内 ±100 ms 微调并写回绑定。
///
/// 进入时暂停音乐播放引擎（同一首歌不该两路同时出声）。iOS 在线 MV 不受限（D5）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/metadata/music_video_service.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart'
    show resolvePlatformHwdec;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_video_match.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';
import 'package:fushi_music/fushi_music.dart' show LyricTimeline;
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// MV 页的音频源。
enum MusicMvAudioSource { mv, library }

/// 外挂曲库音轨的 mpv `audio-delay`（秒，纯函数，测试钉死符号）。
double musicMvAudioDelaySeconds({required int offsetMs, int? cueStartMs}) =>
    (offsetMs - (cueStartMs ?? 0)) / 1000;

/// MV 位置 → 歌词时刻（纯函数）：歌词时间轴是音频时间，MV 时间 = 音频时间 + 偏移。
Duration musicMvLyricPosition(Duration mvPosition, int offsetMs) {
  final Duration p = mvPosition - Duration(milliseconds: offsetMs);
  return p.isNegative ? Duration.zero : p;
}

/// 打开 MV 页。
Future<void> openMusicMvPage({
  required BuildContext context,
  required MusicTrackRow track,
  required MusicVideoRow binding,
}) async {
  await Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => MusicMvPage(track: track, binding: binding),
    ),
  );
}

/// 要播的东西：主视频 + （YouTube 分离流时）MV 自己的音频流。
class _MvSource {
  const _MvSource({
    required this.video,
    this.mvAudio,
    this.headers = const <String, String>{},
  });

  final String video;
  final String? mvAudio;
  final Map<String, String> headers;
}

/// 歌词时钟：读播放器位置并换算到音频时间轴。
class _MvLyricClock implements FushiPlaybackClock {
  _MvLyricClock(this._player, this._offsetMs);

  final Player _player;
  final int Function() _offsetMs;

  @override
  Duration get position =>
      musicMvLyricPosition(_player.state.position, _offsetMs());

  @override
  Duration get duration => _player.state.duration;
}

class MusicMvPage extends ConsumerStatefulWidget {
  const MusicMvPage({super.key, required this.track, required this.binding});

  final MusicTrackRow track;
  final MusicVideoRow binding;

  @override
  ConsumerState<MusicMvPage> createState() => _MusicMvPageState();
}

class _MusicMvPageState extends ConsumerState<MusicMvPage> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(
    _player,
    configuration: VideoControllerConfiguration(
      hwdec: resolvePlatformHwdec('auto-safe'),
    ),
  );
  late int _offsetMs = widget.binding.offsetMs;
  MusicMvAudioSource _audio = MusicMvAudioSource.mv;
  _MvSource? _source;
  LyricTimeline? _lyrics;
  bool _failed = false;
  bool _playing = false;
  StreamSubscription<bool>? _playingSub;

  AppModel get _app => ref.read(appProvider);
  NativePlayer? get _native => _player.platform is NativePlayer
      ? _player.platform! as NativePlayer
      : null;

  @override
  void initState() {
    super.initState();
    _playingSub = _player.stream.playing.listen((bool p) {
      if (mounted) setState(() => _playing = p);
    });
    unawaited(_start());
  }

  Future<_MvSource?> _resolve() async {
    final MusicVideoRow b = widget.binding;
    switch (b.kind) {
      case MusicVideoKind.local:
        return _MvSource(video: b.ref);
      case MusicVideoKind.youtube:
        final YoutubeResolvedSource s = await resolveYoutubeSource(
          b.ref,
          withCaptions: false,
        );
        return _MvSource(
          video: s.streamUrl,
          mvAudio: s.audioStreamUrl,
          headers: s.httpHeaders,
        );
      case MusicVideoKind.animeEpisode:
        final ({String bookUid, int episodeIndex})? ref =
            parseAnimeEpisodeMusicVideoRef(b.ref);
        if (ref == null) return null;
        final VideoBookRow? row = await VideoBookRepository(
          _app.database,
        ).getByBookUid(ref.bookUid);
        if (row == null) return null;
        for (final ({int index, String path}) f in themeSongFilesOf(row)) {
          if (f.index == ref.episodeIndex) return _MvSource(video: f.path);
        }
        return null;
    }
    return null;
  }

  Future<void> _start() async {
    unawaited(_app.musicSession.engine.pause());
    final MusicTrackRow track = widget.track;
    unawaited(
      _app.musicLyrics
          .resolve(
            MusicLyricsTrackRef(
              trackUid: track.trackUid,
              path: track.path,
              title: track.title,
              artist: track.artistCredit,
              durationMs: track.durationMs,
              cueStartMs: track.cueStartMs,
            ),
          )
          .then((MusicLyricsResolution? r) {
            if (mounted) setState(() => _lyrics = r?.timeline);
          }),
    );
    _MvSource? src;
    try {
      src = await _resolve();
    } on Exception {
      src = null;
    }
    if (!mounted) return;
    if (src == null) {
      setState(() => _failed = true);
      FushiToast.show(
        msg: t.music_mv_open_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    _source = src;
    await _openWith(MusicMvAudioSource.mv);
  }

  /// 按音频源（重新）打开。位置保留。
  Future<void> _openWith(MusicMvAudioSource audio) async {
    final _MvSource? src = _source;
    if (src == null) return;
    final Duration resumeAt = _player.state.position;
    await _player.open(Media(src.video, httpHeaders: src.headers), play: false);
    final NativePlayer? native = _native;
    final String? external = audio == MusicMvAudioSource.library
        ? widget.track.path
        : src.mvAudio;
    if (native != null && external != null) {
      // 外挂音轨要在 seek / play 之前加（与视频页外挂音轨同一时序，见
      // video_player_controller.dart 的外挂音轨注释）。
      await native.command(<String>['audio-add', external, 'select']);
      await native.setProperty(
        'audio-delay',
        audio == MusicMvAudioSource.library
            ? musicMvAudioDelaySeconds(
                offsetMs: _offsetMs,
                cueStartMs: widget.track.cueStartMs,
              ).toStringAsFixed(3)
            : '0',
      );
    }
    if (resumeAt > Duration.zero) await _player.seek(resumeAt);
    await _player.play();
    if (mounted) setState(() => _audio = audio);
  }

  Future<void> _nudge(int deltaMs) async {
    setState(() => _offsetMs += deltaMs);
    await MusicVideoService(
      database: _app.database,
    ).setOffset(widget.binding, _offsetMs);
    if (_audio == MusicMvAudioSource.library) {
      await _native?.setProperty(
        'audio-delay',
        musicMvAudioDelaySeconds(
          offsetMs: _offsetMs,
          cueStartMs: widget.track.cueStartMs,
        ).toStringAsFixed(3),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_playingSub?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState navigator = Navigator.of(context);
    final LyricTimeline? lyrics = _lyrics;
    return FushiPageScaffold(
      title: widget.track.title,
      header: Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap,
          tokens.spacing.page,
          tokens.spacing.gap,
        ),
        child: FushiFloatingTopBar(
          title: widget.track.title,
          adaptiveOverflow: true,
          leading: <FushiToolbarItem>[
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
          ],
          actions: <List<FushiToolbarItem>>[
            <FushiToolbarItem>[
              FushiToolbarItem(
                icon: _playing ? FushiIcons.pause : FushiIcons.play,
                label: _playing ? t.pause : t.play,
                onPressed: () => unawaited(_player.playOrPause()),
              ),
              FushiToolbarItem(
                icon: FushiIcons.remove,
                label: t.music_mv_offset_earlier,
                onPressed: () => unawaited(_nudge(-100)),
              ),
              FushiToolbarItem(
                icon: FushiIcons.add,
                label: t.music_mv_offset_later,
                onPressed: () => unawaited(_nudge(100)),
              ),
            ],
          ],
        ),
      ),
      body: _failed
          ? Center(child: Text(t.music_mv_open_failed))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.page,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: adaptiveSegmentedButton<MusicMvAudioSource>(
                          context: context,
                          segments: <ButtonSegment<MusicMvAudioSource>>[
                            ButtonSegment<MusicMvAudioSource>(
                              value: MusicMvAudioSource.mv,
                              label: Text(t.music_mv_audio_mv),
                            ),
                            ButtonSegment<MusicMvAudioSource>(
                              value: MusicMvAudioSource.library,
                              label: Text(t.music_mv_audio_library),
                            ),
                          ],
                          selected: <MusicMvAudioSource>{_audio},
                          onSelectionChanged: (Set<MusicMvAudioSource> s) =>
                              unawaited(_openWith(s.first)),
                        ),
                      ),
                      SizedBox(width: tokens.spacing.gap),
                      Text(t.music_mv_offset_value(ms: _offsetMs)),
                    ],
                  ),
                ),
                SizedBox(height: tokens.spacing.gap),
                Expanded(
                  flex: 3,
                  child: ColoredBox(
                    color: Colors.black,
                    child: Video(
                      controller: _controller,
                      controls: NoVideoControls,
                      pauseUponEnteringBackgroundMode: true,
                      resumeUponEnteringForegroundMode: true,
                    ),
                  ),
                ),
                if (lyrics != null)
                  Expanded(
                    flex: 2,
                    child: KaraokeLyricsView(
                      timeline: lyrics,
                      clock: _MvLyricClock(_player, () => _offsetMs),
                      playing: _playing,
                      onSeek: (int ms) => unawaited(
                        _player.seek(Duration(milliseconds: ms + _offsetMs)),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
