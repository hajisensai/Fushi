/// MV + 卡拉 OK 字幕页（音乐方案 §6.2 / §6.3 / §8.3 / §9.2）：一个带纹理的 mpv 实例
/// （media_kit `Video`）同时出画面、声音和 libass 字幕，三者同一时钟。画面三选一
/// （[MusicKaraokePicture]，指令计划见 `karaoke_stage_plan.dart`）：
///
/// - **MV**：绑定的 MV。音频源可选——**MV 原声**直接放 MV 自己的音轨；**曲库音轨**（「看 MV
///   听无损」）在同一个 mpv 实例里 `audio-add` 本地文件并选中、MV 自带音轨不出声，对齐靠
///   mpv 自己的 `audio-delay`：外挂音轨文件时刻 a（CUE 曲目里 = 曲目时刻 + 起点）要在 MV
///   时刻 `a − cueStart + offset` 播出，所以 `audio-delay = offset − cueStart`
///   （[musicMvAudioDelaySeconds]）。
/// - **画布**（无视频的曲目）：主文件就是曲目音频（CUE 曲目是 EDL 段），封面 / 纯色画布
///   以封面轨挂上。
/// - **CD+G**：主文件是曲目音频，同名 `.cdg` 以视频轨挂上，FFmpeg `cdgraphics` 解码。
///
/// 字幕叠加三选一（[MusicKaraokeOverlay]）：ASS 原样（libass 画进帧里，`sub-delay` 按
/// [musicKaraokeSubDelaySeconds] 对齐 MV 偏移与歌词偏移）/ 结构化逐字歌词
/// （`KaraokeLyricsView` 叠在画面下方）/ 关闭；默认按 Rust 的特效检测 + 设置项
/// （[musicKaraokeDefaultOverlay]）。
///
/// 画面是主时钟：MV 下歌词显示时刻 = MV 位置 − MV 偏移（[musicMvLyricPosition]）；画布 /
/// CD+G 下就是音频位置。MV 偏移来自绑定（声纹对齐求得），页内 ±100 ms 微调并写回绑定。
///
/// 进入时暂停音乐播放引擎（同一首歌不该两路同时出声）；画布 / CD+G 离开时把引擎拨到本页
/// 的位置（同一首）。
///
/// 在线 MV（插件音源的 `mvStream`）不走本页：[openMusicOnlineMvPage] 交给视频播放页
/// 播（iOS 不受限，D5）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_stage_plan.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/metadata/music_video_service.dart';
import 'package:fushi/src/media/music/music_local_video.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart'
    show musicEdlUri;
import 'package:fushi/src/media/music/plugin/music_online_mv_video_client.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart'
    show MusicPluginStreamUnavailable;
import 'package:fushi/src/media/music/server/interconnect_music_client.dart';
import 'package:fushi/src/media/music/server/youtube_music_gate.dart'
    show isYoutubeMusicSourceAvailable;
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/playback_route_marks.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart'
    show resolvePlatformHwdec, setMpvPropertiesInOrder;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock, formatFushiPlaybackTime;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show shellRedesignActive;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart'
    show musicBrowseScaffold;
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi_engine/sync/remote_music_dto.dart'
    show RemoteMusicVideoCandidate, RemoteMusicVideoCandidateSource;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_video_match.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi_music/fushi_music.dart'
    show AssRawScript, FushiLyricsAsync, LyricTimeline;
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

/// 卡拉 OK 字幕页要播的曲目（曲库行与播放队列项两种入口的公共部分）。
class MusicKaraokeTrack {
  const MusicKaraokeTrack({
    required this.trackUid,
    required this.path,
    required this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.cueStartMs,
    this.cueEndMs,
    this.coverPath,
  });

  factory MusicKaraokeTrack.fromRow(MusicTrackRow row, {String? coverPath}) =>
      MusicKaraokeTrack(
        trackUid: row.trackUid,
        path: row.path,
        title: row.title,
        artist: row.artistCredit,
        durationMs: row.durationMs,
        cueStartMs: row.cueStartMs,
        cueEndMs: row.cueEndMs,
        coverPath: coverPath,
      );

  factory MusicKaraokeTrack.fromPlayItem(MusicPlayItem item) =>
      MusicKaraokeTrack(
        trackUid: item.trackUid,
        path: item.path,
        title: item.title,
        artist: item.artist,
        album: item.album,
        durationMs: item.durationMs,
        cueStartMs: item.startMs,
        cueEndMs: item.endMs,
        coverPath: item.coverPath,
      );

  final String trackUid;
  final String path;
  final String title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final int? cueStartMs;
  final int? cueEndMs;
  final String? coverPath;

  bool get isCueTrack => cueStartMs != null;

  MusicLyricsTrackRef get lyricsRef => MusicLyricsTrackRef(
    trackUid: trackUid,
    path: path,
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
    cueStartMs: cueStartMs,
  );

  /// 画布 / CD+G 下主文件的 URL：普通文件给路径，CUE 曲目给 EDL 段（时间轴从 0 起，
  /// 与歌词 / 字幕的曲目时间一致）。
  String get audioUrl => cueStartMs == null
      ? path
      : musicEdlUri(path, startMs: cueStartMs!, endMs: cueEndMs);
}

/// MV 页里要放的画面：主视频地址、（YouTube 分离流时）MV 自己的音频流、请求头；远端画面带
/// [release]（离页时释放流票）。
typedef MusicKaraokeMvMedia = ({
  String video,
  String? mvAudio,
  Map<String, String> headers,
  Future<void> Function()? release,
});

/// MV 页放的那条 MV 绑定。本机绑定（[MusicKaraokeLocalBinding]）与互联 host 的绑定
/// （[MusicKaraokeHostBinding]，design-imusic-q7）各管自己的取流、「曲库音轨」地址与微调写回，
/// 页面里没有来源分支（互联共享音乐库设计 §6.3）。
abstract interface class MusicKaraokeMvBinding {
  /// MV 时间 = 音频时间 + offset。
  int get offsetMs;

  /// 取画面（YouTube 由本机自己的 YouTube 音源取）；放不了为 null。
  Future<MusicKaraokeMvMedia?> resolve(FushiDatabase db);

  /// 「曲库音轨」外挂进 MV 的音频地址（本机：文件路径；host：签一张音频流票）。
  Future<String> libraryAudio(MusicKaraokeTrack track);

  /// 页内 ±100 ms 微调写回（本机绑定 / host 上的绑定）。
  Future<void> setOffset(FushiDatabase db, int offsetMs);
}

/// YouTube MV 的画面（本机自己的 YouTube 音源取流）。
Future<MusicKaraokeMvMedia> _youtubeMv(String ref) async {
  final YoutubeResolvedSource s = await resolveYoutubeSource(
    ref,
    withCaptions: false,
  );
  return (
    video: s.streamUrl,
    mvAudio: s.audioStreamUrl,
    headers: s.httpHeaders,
    release: null,
  );
}

/// 本机曲目的 MV 绑定（`music_videos` 行）。
class MusicKaraokeLocalBinding implements MusicKaraokeMvBinding {
  const MusicKaraokeLocalBinding(this.row);

  final MusicVideoRow row;

  @override
  int get offsetMs => row.offsetMs;

  @override
  Future<MusicKaraokeMvMedia?> resolve(FushiDatabase db) async {
    switch (row.kind) {
      case MusicVideoKind.local:
      case MusicVideoKind.animeEpisode:
        final String? file = await resolveMusicVideoLocalFile(db, row);
        return file == null
            ? null
            : (
                video: file,
                mvAudio: null,
                headers: const <String, String>{},
                release: null,
              );
      case MusicVideoKind.youtube:
        return _youtubeMv(row.ref);
    }
    return null;
  }

  @override
  Future<String> libraryAudio(MusicKaraokeTrack track) async => track.path;

  @override
  Future<void> setOffset(FushiDatabase db, int offsetMs) =>
      MusicVideoService(database: db).setOffset(row, offsetMs);
}

/// 互联 host 曲目的 MV 绑定（design-imusic-q7）：本机文件 / 动画集经 host 签画面流票；YouTube 由本机
/// 自己的 YouTube 音源取（受本机合规门约束，iOS 不出这类绑定）；微调写回 host（按 updatedAt LWW）。
class MusicKaraokeHostBinding implements MusicKaraokeMvBinding {
  const MusicKaraokeHostBinding({
    required this.browser,
    required this.trackUid,
    required this.video,
  });

  final InterconnectMusicBrowser browser;
  final String trackUid;
  final MusicServerVideo video;

  @override
  int get offsetMs => video.offsetMs;

  @override
  Future<MusicKaraokeMvMedia?> resolve(FushiDatabase db) async {
    final String? youtube = video.youtubeRef;
    if (youtube != null) {
      return isYoutubeMusicSourceAvailable ? _youtubeMv(youtube) : null;
    }
    final MusicServerMediaLease lease = await browser.openVideo(video);
    return (
      video: lease.uri.toString(),
      mvAudio: null,
      headers: const <String, String>{},
      release: lease.release,
    );
  }

  /// 曲库音轨：向 host 签这首的音频流——原样音质、就是这一首（CUE 曲目由 host 无损截段），所以
  /// [musicHostKaraokeTrack] 不带 CUE 起点，`audio-delay` 就是绑定偏移。
  @override
  Future<String> libraryAudio(MusicKaraokeTrack track) async =>
      (await browser.openTrack(trackUid, forDownload: true)).url;

  @override
  Future<void> setOffset(FushiDatabase db, int offsetMs) =>
      browser.setVideoOffset(video, offsetMs);
}

/// 打开 MV 页。
Future<void> openMusicMvPage({
  required BuildContext context,
  required MusicTrackRow track,
  required MusicVideoRow binding,
}) => openMusicKaraokeMvPage(
  context: context,
  track: MusicKaraokeTrack.fromRow(track),
  binding: MusicKaraokeLocalBinding(binding),
);

/// 打开 MV 页（任意来源的绑定）。
Future<void> openMusicKaraokeMvPage({
  required BuildContext context,
  required MusicKaraokeTrack track,
  required MusicKaraokeMvBinding binding,
}) async {
  await Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => MusicKaraokeStagePage(
        track: track,
        picture: MusicKaraokePicture.mv,
        binding: binding,
      ),
    ),
  );
}

/// 在线 MV（插件音源的 `mvStream`）：不绑定曲库曲目，只给一个取流函数。进页时才取流
/// （地址有时效），失败时播放页失败态显示 [describeError] 的文字。
class MusicOnlineMv {
  const MusicOnlineMv({required this.resolve, this.describeError});

  /// 取流：播放地址与请求头（插件宿主已按网络授权核对过地址）。
  final Future<({String url, Map<String, String> headers})> Function() resolve;

  /// 取流失败时给用户看的文字（如插件说「需要会员」）；null 交给视频页按异常归类。
  final String Function(Object error)? describeError;
}

/// 打开在线 MV：在视频播放页里播（字幕查词 / 制卡 / 倍速 / 小窗等与其它在线视频一致），
/// 走视频源扩展同一条远端起播路径（[MusicOnlineMvVideoClient]，不进视频库）。进入时
/// 暂停音乐播放引擎（同一首歌不该两路同时出声）。
Future<void> openMusicOnlineMvPage({
  required BuildContext context,
  required String key,
  required String title,
  String? artist,
  String? coverUrl,
  required MusicOnlineMv source,
}) async {
  final AppModel app = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appProvider);
  unawaited(app.musicSession.engine.pause());
  final MusicOnlineMvVideoClient client = MusicOnlineMvVideoClient(
    resolve: source.resolve,
    describeError: source.describeError,
  );
  await Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => VideoFushiPage.neutralizedRemote(
        info: RemoteVideoInfo(
          id: '$kMusicOnlineMvVideoIdPrefix$key',
          title: musicOnlineMvVideoTitle(title, artist),
          coverUrl: coverUrl,
        ),
        repo: VideoBookRepository(app.database),
        client: client,
      ),
    ),
  );
}

/// MV 曲目（[isMusicWatchableVideoTrack]，曲库里的视频容器）在视频播放页里看：ASS 特效
/// 字幕、同名外挂字幕、暂停识别画面文字、查词制卡与视频库视频一致（拍板台 jeNKF9u0WJ）。
/// - 本地 MV：首次观看按 app 外打开视频同一入口登记进视频库并标「MV」
///   （[ensureMusicVideoInVideoLibrary]）；
/// - 网络音乐来源的 MV（拍板台 left3568）：起播期按来源取流（[resolveMusicStreamVideo]），
///   走在线 MV 同一条远端起播路径串流，不登记进视频库。
/// 进入时暂停音乐播放引擎（同一首歌不该两路同时出声）。视频模块关掉时不登记、只提示
/// ——否则 MV 会进一个用户看不见的库。
Future<void> openMusicTrackVideo({
  required BuildContext context,
  required MusicTrackRow track,
}) async {
  final AppModel app = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appProvider);
  if (!app.moduleVisibility.isEnabled(ModuleId.video)) {
    FushiToast.show(msg: t.module_disabled_hint, severity: ToastSeverity.info);
    return;
  }
  if (isMusicStreamVideoTrack(track)) {
    await openMusicOnlineMvPage(
      context: context,
      key: '$kMusicStreamVideoKeyPrefix${track.trackUid}',
      title: track.title,
      artist: track.artistCredit,
      source: MusicOnlineMv(
        resolve: () => resolveMusicStreamVideo(track),
        describeError: (Object e) => e is MusicPluginStreamUnavailable
            ? e.message
            : t.music_mv_open_failed,
      ),
    );
    return;
  }
  if (!await File(track.path).exists()) {
    FushiToast.show(msg: t.video_file_not_found, severity: ToastSeverity.error);
    return;
  }
  final String bookUid;
  try {
    bookUid = await ensureMusicVideoInVideoLibrary(app.database, track.path);
  } on Object catch (e, st) {
    ErrorLogService.instance.log('openMusicTrackVideo', e, st);
    FushiToast.show(msg: t.music_mv_open_failed, severity: ToastSeverity.error);
    return;
  }
  unawaited(app.musicSession.engine.pause());
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => VideoFushiPage.neutralized(
        bookUid: bookUid,
        repo: VideoBookRepository(app.database),
      ),
    ),
  );
}

/// 网络音乐来源 MV 在视频页里的播放身份前缀（接在 [kMusicOnlineMvVideoIdPrefix] 之后，
/// 断点 / 观看统计按曲目 uid 记，与插件在线 MV 分开）。
const String kMusicStreamVideoKeyPrefix = 'source:';

/// 打开无视频的卡拉 OK 字幕页：有同名 `.cdg` 时画面走 CD+G，否则封面 / 纯色画布。
Future<void> openMusicKaraokePage({
  required BuildContext context,
  required MusicKaraokeTrack track,
  String? cdgPath,
}) async {
  await Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => MusicKaraokeStagePage(
        track: track,
        picture: cdgPath == null
            ? MusicKaraokePicture.canvas
            : MusicKaraokePicture.cdg,
        cdgPath: cdgPath,
      ),
    ),
  );
}

/// 要播的东西：主视频 + （YouTube 分离流时）MV 自己的音频流。
class _MvSource {
  const _MvSource({
    required this.video,
    this.mvAudio,
    this.headers = const <String, String>{},
    this.release,
  });

  final String video;
  final String? mvAudio;
  final Map<String, String> headers;

  /// 远端画面的流票释放（离页时调）。
  final Future<void> Function()? release;
}

/// 歌词时钟：读播放器位置并换算到音频时间轴（画布 / CD+G 下偏移恒 0）。
class _StageLyricClock implements FushiPlaybackClock {
  _StageLyricClock(this._player, this._offsetMs);

  final Player _player;
  final int Function() _offsetMs;

  @override
  Duration get position =>
      musicMvLyricPosition(_player.state.position, _offsetMs());

  @override
  Duration get duration => _player.state.duration;
}

/// 画布 / ASS 的落盘目录（系统临时目录，按内容哈希命名、可随时清）。
Directory _stageCacheDir() {
  final Directory d = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}fushi_karaoke',
  );
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

Future<String> _writeCached(List<int> content, String ext) async {
  final String path = musicKaraokeCacheFile(
    _stageCacheDir().path,
    content,
    ext,
  );
  final File f = File(path);
  if (!f.existsSync()) await f.writeAsBytes(content, flush: true);
  return path;
}

/// 画布 PNG：封面（可选）按 contain 居中在纯色底上，比例取 ASS 的 PlayRes。
Future<String> _canvasFor({
  required String? coverPath,
  required AssRawScript? ass,
}) async {
  final ({int width, int height}) size = musicKaraokeCanvasSize(
    playResX: ass?.playResX,
    playResY: ass?.playResY,
  );
  Uint8List? cover;
  if (coverPath != null) {
    try {
      cover = await File(coverPath).readAsBytes();
    } on FileSystemException {
      cover = null;
    }
  }
  final Uint8List png = await Isolate.run(
    () => renderMusicKaraokeCanvasPng(
      width: size.width,
      height: size.height,
      coverBytes: cover,
    ),
  );
  return _writeCached(png, 'png');
}

/// 舞台页叠在画面下部的结构化逐字歌词：「模糊非当前行」偏好在这里订阅
/// （`ref.watch` + `select`），页面开着时经 AI 操作 / 其他窗口改了也即时生效。
class MusicKaraokeStageLyrics extends ConsumerWidget {
  const MusicKaraokeStageLyrics({
    super.key,
    required this.timeline,
    required this.clock,
    required this.playing,
    required this.offsetMs,
    this.onSeek,
  });

  final LyricTimeline timeline;
  final FushiPlaybackClock clock;
  final bool playing;
  final int offsetMs;
  final ValueChanged<int>? onSeek;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool blurInactive = ref.watch(
      appProvider.select((AppModel m) => m.musicLyricsBlurInactive),
    );
    final bool showTranslation = ref.watch(
      appProvider.select((AppModel m) => m.musicLyricsShowTranslation),
    );
    final bool showRomanization = ref.watch(
      appProvider.select((AppModel m) => m.musicLyricsShowRomanization),
    );
    final bool showRuby = ref.watch(
      appProvider.select((AppModel m) => m.musicLyricsShowRuby),
    );
    return KaraokeLyricsView(
      timeline: timeline,
      clock: clock,
      playing: playing,
      offsetMs: offsetMs,
      onSeek: onSeek,
      appearance: KaraokeLyricsAppearance(
        blurInactive: blurInactive,
        showTranslation: showTranslation,
        showRomanization: showRomanization,
        showRuby: showRuby,
      ),
    );
  }
}

class MusicKaraokeStagePage extends ConsumerStatefulWidget {
  const MusicKaraokeStagePage({
    super.key,
    required this.track,
    required this.picture,
    this.binding,
    this.cdgPath,
  }) : assert(picture != MusicKaraokePicture.mv || binding != null),
       assert(picture != MusicKaraokePicture.cdg || cdgPath != null);

  final MusicKaraokeTrack track;
  final MusicKaraokePicture picture;

  /// [MusicKaraokePicture.mv] 时的 MV 绑定。
  final MusicKaraokeMvBinding? binding;

  /// [MusicKaraokePicture.cdg] 时的 `.cdg` 路径。
  final String? cdgPath;

  @override
  ConsumerState<MusicKaraokeStagePage> createState() =>
      _MusicKaraokeStagePageState();
}

class _MusicKaraokeStagePageState extends ConsumerState<MusicKaraokeStagePage> {
  // libass: true —— media_kit 默认把 sub-ass / sub-visibility 关掉，原样渲染要它们。
  late final Player _player = Player(
    configuration: const PlayerConfiguration(libass: true),
  );
  late final VideoController _controller = VideoController(
    _player,
    configuration: VideoControllerConfiguration(
      hwdec: resolvePlatformHwdec('auto-safe'),
    ),
  );
  late int _offsetMs = widget.binding?.offsetMs ?? 0;
  MusicMvAudioSource _audio = MusicMvAudioSource.mv;
  _MvSource? _source;
  MusicLyricsResolution? _lyrics;
  String? _assPath;
  MusicKaraokeOverlay _overlay = MusicKaraokeOverlay.off;
  bool _failed = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  AppModel get _app => ref.read(appProvider);
  bool get _isMv => widget.picture == MusicKaraokePicture.mv;
  int get _mvOffsetMs => _isMv ? _offsetMs : 0;
  int get _lyricsOffsetMs => _lyrics?.timeline.offsetMs ?? 0;
  NativePlayer? get _native => _player.platform is NativePlayer
      ? _player.platform! as NativePlayer
      : null;

  @override
  void initState() {
    super.initState();
    _subs
      ..add(
        _player.stream.playing.listen((bool p) {
          if (mounted) setState(() => _playing = p);
        }),
      )
      ..add(
        _player.stream.position.listen((Duration p) {
          if (mounted) setState(() => _position = p);
        }),
      )
      ..add(
        _player.stream.duration.listen((Duration d) {
          if (mounted) setState(() => _duration = d);
        }),
      );
    unawaited(_start());
  }

  Future<_MvSource?> _resolveMv() async {
    final MusicKaraokeMvMedia? m = await widget.binding!.resolve(_app.database);
    if (m == null) return null;
    return _MvSource(
      video: m.video,
      mvAudio: m.mvAudio,
      headers: m.headers,
      release: m.release,
    );
  }

  /// 「曲库音轨」外挂的音频地址（host 曲目要签票，只签一次）。
  Future<String>? _libraryAudio;

  Future<void> _start() async {
    final Duration enginePosition = _app.musicSession.engine.position;
    final bool sameTrackInEngine =
        _app.musicSession.engine.current?.trackUid == widget.track.trackUid;
    unawaited(_app.musicSession.engine.pause());

    // 歌词与 ASS 原文先就位：画布比例取 ASS 的 PlayRes，默认叠加看特效检测。
    MusicLyricsResolution? lyrics;
    try {
      lyrics = await _app.musicLyrics.resolve(widget.track.lyricsRef);
    } on Object catch (e, st) {
      // 在线歌词查不到不影响画面与 ASS（本地来源已先于在线返回）。
      ErrorLogService.instance.log('MusicKaraokeStage.lyrics', e, st);
    }
    AssRawScript? ass;
    final Uint8List? rawAss = lyrics?.rawAss;
    if (rawAss != null) {
      ass = await FushiLyricsAsync.assRaw(rawAss);
    }
    _MvSource? src;
    try {
      src = switch (widget.picture) {
        MusicKaraokePicture.mv => await _resolveMv(),
        MusicKaraokePicture.canvas ||
        MusicKaraokePicture.cdg => _MvSource(video: widget.track.audioUrl),
      };
    } on Exception {
      src = null;
    }
    String? assPath;
    String? canvasPath;
    if (src != null) {
      if (ass != null) {
        assPath = await _writeCached(utf8.encode(ass.text), 'ass');
      }
      if (widget.picture == MusicKaraokePicture.canvas) {
        canvasPath = await _canvasFor(
          coverPath: widget.track.coverPath,
          ass: ass,
        );
      }
    }
    if (!mounted) return;
    if (src == null) {
      setState(() => _failed = true);
      FushiToast.show(
        msg: _isMv ? t.music_mv_open_failed : t.music_karaoke_open_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    final LyricTimeline? timeline = lyrics?.timeline;
    setState(() {
      _lyrics = lyrics;
      _source = src;
      _assPath = assPath;
      _overlay = musicKaraokeDefaultOverlay(
        hasRawAss: assPath != null,
        hasEffects: timeline?.hasEffects ?? false,
        hasTimeline: timeline?.isSynced ?? false,
        preference: _app.musicKaraokeAssRender,
        picture: widget.picture,
      );
    });
    await _openWith(
      MusicMvAudioSource.mv,
      canvasPath: canvasPath,
      startAt: !_isMv && sameTrackInEngine ? enginePosition : Duration.zero,
    );
  }

  /// 按音频源（重新）打开。位置保留。
  Future<void> _openWith(
    MusicMvAudioSource audio, {
    String? canvasPath,
    Duration startAt = Duration.zero,
  }) async {
    final _MvSource? src = _source;
    if (src == null) return;
    final Duration resumeAt = _player.state.position > Duration.zero
        ? _player.state.position
        : startAt;
    final NativePlayer? native = _native;
    if (native != null) {
      // 全仓 mpv 属性批量下发的唯一实现：逐条保序，被拒的单条留痕后跳过（BUG-4911）。
      await setMpvPropertiesInOrder(_player, <String, String>{
        ...musicKaraokeSubtitleProperties(
          visible: _overlay == MusicKaraokeOverlay.original,
        ),
        if (widget.picture == MusicKaraokePicture.cdg)
          ...musicKaraokeCdgProperties(),
      });
    }
    await _player.open(Media(src.video, httpHeaders: src.headers), play: false);
    if (native != null) {
      final String? external = _isMv
          ? (audio == MusicMvAudioSource.library
                ? await (_libraryAudio ??= widget.binding!.libraryAudio(
                    widget.track,
                  ))
                : src.mvAudio)
          : null;
      // 外挂轨要在 seek / play 之前加（与视频页外挂音轨同一时序，见
      // video_player_controller.dart 的外挂音轨注释）。
      if (external != null) {
        await native.command(<String>['audio-add', external, 'select']);
      }
      if (_isMv) {
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
      if (canvasPath != null) {
        await native.command(musicKaraokeCanvasCommand(canvasPath));
      }
      final String? cdg = widget.cdgPath;
      if (widget.picture == MusicKaraokePicture.cdg && cdg != null) {
        await native.command(musicKaraokeCdgCommand(cdg));
      }
      final String? assPath = _assPath;
      if (assPath != null) {
        await native.command(musicKaraokeAssCommand(assPath));
        await _applySubDelay();
      }
    }
    if (resumeAt > Duration.zero) await _player.seek(resumeAt);
    await _player.play();
    if (mounted) setState(() => _audio = audio);
  }

  Future<void> _applySubDelay() async {
    if (_assPath == null) return;
    await _native?.setProperty(
      'sub-delay',
      musicKaraokeSubDelaySeconds(
        mvOffsetMs: _mvOffsetMs,
        lyricsOffsetMs: _lyricsOffsetMs,
      ).toStringAsFixed(3),
    );
  }

  Future<void> _setOverlay(MusicKaraokeOverlay overlay) async {
    setState(() => _overlay = overlay);
    await _native?.setProperty(
      'sub-visibility',
      overlay == MusicKaraokeOverlay.original ? 'yes' : 'no',
    );
  }

  Future<void> _nudge(int deltaMs) async {
    final MusicKaraokeMvBinding? binding = widget.binding;
    if (binding == null) return;
    setState(() => _offsetMs += deltaMs);
    await binding.setOffset(_app.database, _offsetMs);
    if (_audio == MusicMvAudioSource.library) {
      await _native?.setProperty(
        'audio-delay',
        musicMvAudioDelaySeconds(
          offsetMs: _offsetMs,
          cueStartMs: widget.track.cueStartMs,
        ).toStringAsFixed(3),
      );
    }
    await _applySubDelay();
  }

  /// 把本页路由登记成「播放页」：底下的浏览页据此让网页别跟着播（BUG-4084）。
  final PlaybackRouteMark _playbackRouteMark = PlaybackRouteMark();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playbackRouteMark.attach(ModalRoute.of(context));
  }

  @override
  void dispose() {
    _playbackRouteMark.dispose();
    for (final StreamSubscription<Object?> s in _subs) {
      unawaited(s.cancel());
    }
    // 画布 / CD+G 放的就是这首歌：把引擎拨到这里的位置，回到歌词页接着唱。
    if (!_isMv) {
      final AppModel app = _app;
      if (app.musicSession.engine.current?.trackUid == widget.track.trackUid &&
          _position > Duration.zero) {
        unawaited(app.musicSession.engine.seek(_position));
      }
    }
    unawaited(_source?.release?.call());
    unawaited(_player.dispose());
    super.dispose();
  }

  String _overlayLabel(MusicKaraokeOverlay o) => switch (o) {
    MusicKaraokeOverlay.original => t.music_karaoke_overlay_original,
    MusicKaraokeOverlay.structured => t.music_karaoke_overlay_structured,
    MusicKaraokeOverlay.off => t.music_karaoke_overlay_off,
  };

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState navigator = Navigator.of(context);
    final LyricTimeline? lyrics = _lyrics?.timeline;
    final List<MusicKaraokeOverlay> overlays = musicKaraokeAvailableOverlays(
      hasRawAss: _assPath != null,
      hasTimeline: lyrics?.isSynced ?? false,
    );
    final bool showStructured =
        _overlay == MusicKaraokeOverlay.structured && lyrics != null;
    final List<FushiToolbarItem> controls = <FushiToolbarItem>[
      FushiToolbarItem(
        icon: _playing ? FushiIcons.pause : FushiIcons.play,
        label: _playing ? t.pause : t.play,
        onPressed: () => unawaited(_player.playOrPause()),
      ),
      if (_isMv) ...<FushiToolbarItem>[
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
    ];
    // 重设计外壳（墨水屏除外）：页头大字——曲名 + 平铺的裸图标控制；墨水屏照旧
    // 悬浮顶栏。
    final bool masthead = shellRedesignActive(context);
    return FushiPageScaffold(
      masthead: true,
      title: widget.track.title,
      actions: masthead
          ? <Widget>[
              for (final FushiToolbarItem item in controls)
                FushiIconButtonControl(
                  icon: FushiIcon(item.icon),
                  tooltip: item.label,
                  onPressed: item.onPressed,
                ),
            ]
          : const <Widget>[],
      header: masthead
          ? null
          : Padding(
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
                actions: <List<FushiToolbarItem>>[controls],
              ),
            ),
      body: _failed
          ? Center(
              child: Text(
                _isMv ? t.music_mv_open_failed : t.music_karaoke_open_failed,
              ),
            )
          : FushiEntranceScope(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_isMv)
                    FushiStaggeredEntrance(
                      index: 0,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: tokens.spacing.page,
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child:
                                  adaptiveSegmentedButton<MusicMvAudioSource>(
                                    context: context,
                                    segments:
                                        <ButtonSegment<MusicMvAudioSource>>[
                                          ButtonSegment<MusicMvAudioSource>(
                                            value: MusicMvAudioSource.mv,
                                            label: Text(t.music_mv_audio_mv),
                                          ),
                                          ButtonSegment<MusicMvAudioSource>(
                                            value: MusicMvAudioSource.library,
                                            label: Text(
                                              t.music_mv_audio_library,
                                            ),
                                          ),
                                        ],
                                    selected: <MusicMvAudioSource>{_audio},
                                    onSelectionChanged:
                                        (Set<MusicMvAudioSource> s) =>
                                            unawaited(_openWith(s.first)),
                                  ),
                            ),
                            SizedBox(width: tokens.spacing.gap),
                            Text(t.music_mv_offset_value(ms: _offsetMs)),
                          ],
                        ),
                      ),
                    ),
                  if (overlays.length > 1)
                    FushiStaggeredEntrance(
                      index: 1,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          tokens.spacing.page,
                          tokens.spacing.gap,
                          tokens.spacing.page,
                          0,
                        ),
                        child: adaptiveSegmentedButton<MusicKaraokeOverlay>(
                          context: context,
                          segments: <ButtonSegment<MusicKaraokeOverlay>>[
                            for (final MusicKaraokeOverlay o in overlays)
                              ButtonSegment<MusicKaraokeOverlay>(
                                value: o,
                                label: Text(_overlayLabel(o)),
                              ),
                          ],
                          selected: <MusicKaraokeOverlay>{_overlay},
                          onSelectionChanged: (Set<MusicKaraokeOverlay> s) =>
                              unawaited(_setOverlay(s.first)),
                        ),
                      ),
                    ),
                  SizedBox(height: tokens.spacing.gap),
                  Expanded(
                    child: FushiStaggeredEntrance(
                      index: 2,
                      child: ColoredBox(
                        color: Colors.black,
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            Video(
                              controller: _controller,
                              controls: NoVideoControls,
                              // 字幕由 libass 画进帧里（原样渲染），不要 media_kit 再叠
                              // 一层纯文本字幕。
                              subtitleViewConfiguration:
                                  const SubtitleViewConfiguration(
                                    visible: false,
                                  ),
                              pauseUponEnteringBackgroundMode: true,
                              resumeUponEnteringForegroundMode: true,
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: AnimatedSwitcher(
                                duration: fushiMotionDuration(
                                  context,
                                  FushiMotion.medium,
                                ),
                                child: showStructured
                                    ? _buildStructured(lyrics)
                                    : const SizedBox.shrink(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _buildProgress(context, tokens),
                ],
              ),
            ),
    );
  }

  /// 结构化逐字歌词叠在画面下部（底部压暗保证可读）。
  Widget _buildStructured(LyricTimeline lyrics) {
    return SizedBox(
      key: const ValueKey<String>('music_karaoke_structured'),
      height: 220,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0x00000000), Color(0xB0000000)],
          ),
        ),
        child: MusicKaraokeStageLyrics(
          timeline: lyrics,
          clock: _StageLyricClock(_player, () => _mvOffsetMs),
          playing: _playing,
          offsetMs: _lyricsOffsetMs,
          onSeek: (int ms) =>
              unawaited(_player.seek(Duration(milliseconds: ms + _mvOffsetMs))),
        ),
      ),
    );
  }

  Widget _buildProgress(BuildContext context, FushiDesignTokens tokens) {
    final double max = _duration.inMilliseconds.toDouble();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          Text(formatFushiPlaybackTime(_position)),
          Expanded(
            child: FushiSlider(
              value: _position.inMilliseconds.toDouble().clamp(
                0,
                max <= 0 ? 1 : max,
              ),
              max: max <= 0 ? 1 : max,
              onChanged: max <= 0
                  ? null
                  : (double v) => unawaited(
                      _player.seek(Duration(milliseconds: v.round())),
                    ),
            ),
          ),
          Text(formatFushiPlaybackTime(_duration)),
        ],
      ),
    );
  }
}

// 互联 host 曲目的 MV 页（design-imusic-q7 / q9）：列出 host 上这首的 MV 绑定，点一条在 MV 页
// （卡拉 OK 舞台）里看——本机文件 / 动画集经 host 签画面流票，YouTube 由本机自己的 YouTube 音源取
// （iOS 不出这类绑定）；页内 ±100 ms 微调写回 host。host 接受远程匹配时（能力位 `videoMatch`）还能
// 「请 host 重新找本机 MV / 从动画找 / 在线搜索 / 解绑」：匹配只在 host 上对 host 文件跑，客户端
// 不为远端曲目解码。
//
// 布局与本机曲目详情的 MV 一节同一套（分组列表 + 一排按钮），外壳用音乐浏览页的脚手架。

/// 这台设备上能显示的 host MV 绑定：YouTube 类只在本机 YouTube 音源可用时出（iOS 不出）。
List<MusicServerVideo> musicHostVisibleVideos(
  List<MusicServerVideo> videos, {
  required bool youtubeAvailable,
}) => <MusicServerVideo>[
  for (final MusicServerVideo v in videos)
    if (v.youtubeRef == null || youtubeAvailable) v,
];

/// MV 页要的曲目信息（host 曲目：路径是播放占位，歌词经 host 歌词层取；音频由 host 截好这一首，
/// 所以不带 CUE 起点）。
MusicKaraokeTrack musicHostKaraokeTrack(
  InterconnectMusicBrowser browser,
  MusicServerTrack track,
) => MusicKaraokeTrack(
  trackUid: track.id,
  path: fushiHostMusicTrackPath(browser.serverId, track.id),
  title: track.title,
  artist: track.artist,
  album: track.album,
  durationMs: track.durationMs,
  coverPath: track.coverRef == null
      ? null
      : fushiHostMusicCoverPath(browser.serverId, track.coverRef!),
);

/// 打开 host 曲目的 MV 页。
Future<void> openMusicHostMvPage({
  required BuildContext context,
  required InterconnectMusicBrowser browser,
  required MusicServerTrack track,
}) => Navigator.of(context).push<void>(
  adaptivePageRoute<void>(
    context: context,
    builder: (_) => MusicHostMvPage(browser: browser, track: track),
  ),
);

class MusicHostMvPage extends StatefulWidget {
  const MusicHostMvPage({
    super.key,
    required this.browser,
    required this.track,
    this.youtubeAvailable,
  });

  final InterconnectMusicBrowser browser;
  final MusicServerTrack track;

  /// 测试注入；缺省问本机 YouTube 合规门。
  final bool? youtubeAvailable;

  @override
  State<MusicHostMvPage> createState() => _MusicHostMvPageState();
}

class _MusicHostMvPageState extends State<MusicHostMvPage> {
  late Future<List<MusicServerVideo>> _videos = _load();
  bool _busy = false;

  bool get _youtube => widget.youtubeAvailable ?? isYoutubeMusicSourceAvailable;

  Future<List<MusicServerVideo>> _load() async => musicHostVisibleVideos(
    await widget.browser.videosFor(widget.track.id),
    youtubeAvailable: _youtube,
  );

  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } on Object catch (e) {
      FushiToast.show(
        msg: t.music_action_failed(error: '$e'),
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _videos = _load();
        });
      }
    }
  }

  Future<void> _rematch() => _run(() async {
    final int bound = await widget.browser.rematchVideos(widget.track.id);
    if (bound == 0) FushiToast.show(msg: t.music_mv_none_found);
  });

  Future<void> _pick(String source) => _run(() async {
    final List<RemoteMusicVideoCandidate> list = await widget.browser
        .videoCandidates(widget.track.id, source);
    if (!mounted) return;
    final List<RemoteMusicVideoCandidate> shown = <RemoteMusicVideoCandidate>[
      for (final RemoteMusicVideoCandidate c in list)
        if (c.kind != MusicVideoKind.youtube || _youtube) c,
    ];
    if (shown.isEmpty) {
      FushiToast.show(msg: t.music_mv_none_found);
      return;
    }
    final RemoteMusicVideoCandidate? c =
        await showFushiChoiceDialog<RemoteMusicVideoCandidate>(
          context: context,
          title: t.music_mv_candidates_title,
          icon: FushiIcons.video,
          options: <FushiChoiceOption<RemoteMusicVideoCandidate>>[
            for (final RemoteMusicVideoCandidate c in shown)
              FushiChoiceOption<RemoteMusicVideoCandidate>(
                value: c,
                label: c.title,
                subtitle: c.subtitle,
              ),
          ],
        );
    if (c != null) await widget.browser.bindVideo(widget.track.id, c);
  });

  Future<void> _unbind(MusicServerVideo v) =>
      _run(() => widget.browser.unbindVideo(widget.track.id, v));

  Future<void> _open(MusicServerVideo v) => openMusicKaraokeMvPage(
    context: context,
    track: musicHostKaraokeTrack(widget.browser, widget.track),
    binding: MusicKaraokeHostBinding(
      browser: widget.browser,
      trackUid: widget.track.id,
      video: v,
    ),
  );

  @override
  Widget build(BuildContext context) => musicBrowseScaffold(
    context,
    title: widget.track.title,
    body: (BuildContext context) => FutureBuilder<List<MusicServerVideo>>(
      future: _videos,
      builder: (BuildContext context, AsyncSnapshot<List<MusicServerVideo>> s) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final List<MusicServerVideo> rows =
            s.data ?? const <MusicServerVideo>[];
        final bool canMatch = widget.browser.canMatchVideos;
        final List<Widget> children = <Widget>[
          FushiSectionTitle(t.music_mv_section),
          if (s.connectionState == ConnectionState.done && rows.isEmpty)
            Text(t.music_mv_none_found),
          for (int i = 0; i < rows.length; i++)
            FushiPressScale(
              key: ValueKey<String>('music-host-mv-${rows[i].id}'),
              child: FushiGroupedListItem(
                index: i,
                count: rows.length,
                onTap: () => unawaited(_open(rows[i])),
                child: FushiListItem(
                  leading: const FushiListLeadingIcon(FushiIcons.video),
                  title: Text(
                    rows[i].label ?? rows[i].id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(t.music_mv_offset_value(ms: rows[i].offsetMs)),
                  trailing: canMatch
                      ? FushiIconButton(
                          tooltip: t.music_mv_unbind,
                          icon: FushiIcons.close,
                          enabled: !_busy,
                          onTap: () => unawaited(_unbind(rows[i])),
                        )
                      : null,
                ),
              ),
            ),
          if (canMatch)
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                FushiPressScale(
                  child: FushiOutlinedButton.icon(
                    key: const ValueKey<String>('music_host_mv_rematch'),
                    onPressed: _busy ? null : () => unawaited(_rematch()),
                    icon: const FushiIcon(FushiIcons.folder),
                    label: Text(
                      _busy ? t.music_mv_searching : t.music_mv_find_local,
                    ),
                  ),
                ),
                if (_youtube)
                  FushiPressScale(
                    child: FushiOutlinedButton.icon(
                      key: const ValueKey<String>('music_host_mv_online'),
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _pick(RemoteMusicVideoCandidateSource.online),
                            ),
                      icon: const FushiIcon(FushiIcons.search),
                      label: Text(t.music_mv_search_online),
                    ),
                  ),
                FushiPressScale(
                  child: FushiOutlinedButton.icon(
                    key: const ValueKey<String>('music_host_mv_anime'),
                    onPressed: _busy
                        ? null
                        : () => unawaited(
                            _pick(RemoteMusicVideoCandidateSource.anime),
                          ),
                    icon: const FushiIcon(FushiIcons.tv),
                    label: Text(t.music_mv_from_anime),
                  ),
                ),
              ],
            ),
        ];
        return FushiEntranceScope(
          child: ListView.separated(
            padding: withBottomSafeInset(
              context,
              EdgeInsets.fromLTRB(
                tokens.spacing.page,
                MediaQuery.paddingOf(context).top + tokens.spacing.gap,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
            ),
            itemCount: children.length,
            separatorBuilder: (_, int _) =>
                SizedBox(height: tokens.spacing.gap),
            itemBuilder: fushiStaggeredItemBuilder(
              (BuildContext context, int i) => children[i],
            ),
          ),
        );
      },
    ),
  );
}
