// TODO-1000：字幕必须从 youtube_explode 的内部 VideoController（@internal）取 ANDROID_VR
// player response（见下方注释与 resolveYoutubeSource）。dart format 会把多行 import 的
// `show VideoController` 换行，令行内 `// ignore` 锚点失效，故用 file 级抑制。
// ignore_for_file: invalid_use_of_internal_member
import 'package:html_unescape/html_unescape.dart';
import 'package:hibiki_audio/hibiki_audio.dart' show AudioCue;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
// TODO-1000 根因：YouTube 已对 web 端 timedtext（字幕）URL 加 proof-of-origin
// 门槛，公开 API（closedCaptions.getManifest → web 观看页派生的 URL）实测**所有格式
// 都返回空体**，`.get()` 解析空 XML 抛 XmlParserException，进而**炸掉整个
// resolveYoutubeSource → 视频根本打不开（黑屏/报错）**。唯一仍可直取的是 ANDROID_VR
// innertube player response 内嵌的字幕 URL（移动端豁免该门槛）。公开 API 不暴露按
// client 取 player response 的入口，故此处必须触达内部符号；一旦 youtube_explode 升级
// 改了这些符号，守卫测试 test/media/video/youtube_resolver_impl_symbols_test.dart 会
// 大声失败。依赖锁定在 youtube_explode_dart 2.5.x。
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/videos/video_controller.dart'
    show VideoController;
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/pages/watch_page.dart'
    show WatchPage;
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/player/player_response.dart'
    show PlayerResponse, ClosedCaptionTrack;

/// YouTube 解析结果：可播放流 URL + 字幕 cue + header + 标题。
///
/// [streamUrl] 是最高清 **video-only** 流（可达 4K，非 muxed 的 360p 上限）；
/// [audioStreamUrl] 是最高码率 **audio-only** 流，播放时经 `AudioTrack.uri` 外挂、制卡时
/// 音频段从它裁。仅当该视频没有分离流（罕见）才回落 muxed（[audioStreamUrl] 为 null，
/// 画质 ≤360p——这是 YouTube 侧的限制，非本实现选择）。
class YoutubeResolvedSource {
  const YoutubeResolvedSource({
    required this.streamUrl,
    required this.audioStreamUrl,
    required this.miningVideoUrl,
    required this.title,
    required this.httpHeaders,
    required this.cues,
  });

  final String streamUrl;
  final String? audioStreamUrl;

  /// TODO-1000（BUG-528）：**制卡 GIF/帧专用**的低分辨率视频流 URL（muxed 360p 或最低
  /// 码率 video-only）。播放用的 [streamUrl] 可达 4K，让 ffmpeg 从它按时间戳裁 GIF 会
  /// 因下载/解码 4K 帧而超时（实测 120s timeout）；制卡封面只需 ~320px，故另取一条小流。
  /// 音频段仍从 [audioStreamUrl]（audio-only）裁。null → 回落 [streamUrl]。
  final String? miningVideoUrl;

  final String title;
  final Map<String, String> httpHeaders;
  final List<AudioCue> cues;

  /// 是否走了 muxed 兜底（无分离流，画质受限）。
  bool get isMuxedFallback => audioStreamUrl == null;
}

/// 纯函数：识别 YouTube URL（watch / youtu.be / shorts / nocookie）。
bool isYoutubeUrl(String url) {
  final Uri? u = Uri.tryParse(url.trim());
  if (u == null || !u.hasScheme) return false;
  final String host = u.host.toLowerCase();
  return host.endsWith('youtube.com') ||
      host == 'youtu.be' ||
      host.endsWith('youtube-nocookie.com');
}

final HtmlUnescape _unescape = HtmlUnescape();

AudioCue _cue(String bookKey, int index, String text, int startMs, int endMs) =>
    AudioCue()
      ..bookKey = bookKey
      ..chapterHref = 'youtube://$bookKey'
      ..sentenceIndex = index
      ..textFragmentId = 'yt-$index'
      ..text = text
      ..startMs = startMs
      ..endMs = endMs
      ..audioFileIndex = 0;

/// 纯函数：YouTube timedtext（srv1/legacy）XML → List<AudioCue>。start/dur 秒 → 毫秒。
List<AudioCue> parseYoutubeTimedTextToCues({
  required String content,
  required String bookKey,
}) {
  final List<AudioCue> cues = <AudioCue>[];
  final RegExp re = RegExp(
    r'<text start="([\d.]+)"(?: dur="([\d.]+)")?[^>]*>(.*?)</text>',
    dotAll: true,
  );
  int index = 0;
  for (final RegExpMatch m in re.allMatches(content)) {
    final double start = double.tryParse(m.group(1) ?? '') ?? 0;
    final double dur = double.tryParse(m.group(2) ?? '') ?? 0;
    final String raw = _unescape
        .convert((m.group(3) ?? '').replaceAll(RegExp(r'<[^>]+>'), ''))
        .trim();
    if (raw.isEmpty) continue;
    cues.add(_cue(bookKey, index, raw, (start * 1000).round(),
        ((start + dur) * 1000).round()));
    index++;
  }
  return cues;
}

/// IO：用 youtube_explode 解析可播放流 URL + 日文字幕（无则空）+ 标题。
///
/// 流用 **ANDROID_VR** client 取：它签发的直链无需签名解密、且 libmpv/ffmpeg 用普通
/// 浏览器 UA 即可拉取（默认 android/ios client 签发的直链实测被 403），取**最高清
/// video-only + 最高码率 audio-only** 分离流（可达 4K），播放时视频流经 libmpv、音频流经
/// `AudioTrack.uri` 外挂；制卡时 GIF/帧从视频流、音频段从音频流各自 ffmpeg 裁。仅当该视频
/// 无分离流才回落 muxed（≤360p，YouTube 侧限制）。字幕见 [_resolveYoutubeCaptions]。
Future<YoutubeResolvedSource> resolveYoutubeSource(
  String url, {
  String preferSubtitleLang = 'ja',
}) async {
  final yt.YoutubeExplode client = yt.YoutubeExplode();
  try {
    final yt.Video video = await client.videos.get(url);
    final yt.StreamManifest manifest =
        await client.videos.streamsClient.getManifest(
      video.id,
      ytClients: <yt.YoutubeApiClient>[yt.YoutubeApiClient.androidVr],
    );
    // 优先「video-only（≤1080p 里最高清）+ 最高码率 audio-only」分离流；两者齐备才用，
    // 否则回落 muxed（YouTube 把 muxed 限 ≤360p，故仅作最后兜底）。
    String streamUrl;
    String? audioStreamUrl;
    if (manifest.videoOnly.isNotEmpty && manifest.audioOnly.isNotEmpty) {
      streamUrl = _pickPlaybackVideoUrl(manifest);
      audioStreamUrl = manifest.audioOnly.withHighestBitrate().url.toString();
    } else {
      streamUrl = manifest.muxed.withHighestBitrate().url.toString();
      audioStreamUrl = null;
    }
    // 制卡 GIF/帧的低分辨率源：muxed（360p，含音视频、抽 GIF 快）优先，否则最低码率
    // video-only（都远小于 4K 播放流，避免网络抽取超时）。见 [YoutubeResolvedSource.miningVideoUrl]。
    final String? miningVideoUrl = _pickMiningVideoUrl(manifest);
    final String bookKey = 'yt:${video.id.value}';
    final List<AudioCue> cues = await _resolveYoutubeCaptions(
      video.id,
      bookKey: bookKey,
      preferSubtitleLang: preferSubtitleLang,
    );

    return YoutubeResolvedSource(
      streamUrl: streamUrl,
      audioStreamUrl: audioStreamUrl,
      miningVideoUrl: miningVideoUrl,
      title: video.title,
      httpHeaders: const <String, String>{'User-Agent': 'Mozilla/5.0'},
      cues: cues,
    );
  } finally {
    client.close();
  }
}

/// 选播放用 video-only 流：优先「≤1080p 里最高清」。4K progressive 流（video-only 无
/// 自适应码率）网络下持续缓冲 → 黑屏加载（用户 TODO-1000 原报障），1080p 对阅读器窗口足够
/// 且流畅。全部 >1080p（罕见）时退最低清（宁流畅勿卡死）。
String _pickPlaybackVideoUrl(yt.StreamManifest manifest) {
  final List<yt.VideoOnlyStreamInfo> all = manifest.videoOnly.toList();
  final List<yt.VideoOnlyStreamInfo> capped = all
      .where((yt.VideoOnlyStreamInfo s) => s.videoResolution.height <= 1080)
      .toList();
  if (capped.isNotEmpty) {
    capped.sort((yt.VideoOnlyStreamInfo a, yt.VideoOnlyStreamInfo b) =>
        b.videoResolution.compareTo(a.videoResolution));
    return capped.first.url.toString();
  }
  all.sort((yt.VideoOnlyStreamInfo a, yt.VideoOnlyStreamInfo b) =>
      a.videoResolution.compareTo(b.videoResolution));
  return all.first.url.toString();
}

/// 选制卡 GIF/帧的低分辨率视频源：优先 muxed（360p，抽 GIF 实测 ~1.4s），否则最低码率
/// video-only（144p 级，实测 ~1.3s）。都远小于 4K 播放流，避免 ffmpeg 网络抽取超时。
/// 无任何流时返回 null（引擎回落到播放流→当前解码帧截图）。
String? _pickMiningVideoUrl(yt.StreamManifest manifest) {
  if (manifest.muxed.isNotEmpty) {
    return manifest.muxed.withHighestBitrate().url.toString();
  }
  if (manifest.videoOnly.isNotEmpty) {
    final List<yt.VideoOnlyStreamInfo> sorted = manifest.videoOnly.toList()
      ..sort((yt.VideoOnlyStreamInfo a, yt.VideoOnlyStreamInfo b) =>
          a.bitrate.compareTo(b.bitrate));
    return sorted.first.url.toString();
  }
  return null;
}

/// IO：从 ANDROID_VR innertube player response 取字幕轨（公开 API 的 web 字幕 URL 已失效，
/// 见文件头注释）。best-effort：任何失败都返回空 cue，**绝不让字幕失败阻断视频播放**。
Future<List<AudioCue>> _resolveYoutubeCaptions(
  yt.VideoId id, {
  required String bookKey,
  required String preferSubtitleLang,
}) async {
  final yt.YoutubeHttpClient http = yt.YoutubeHttpClient();
  try {
    final WatchPage watchPage = await WatchPage.get(http, id.value);
    final PlayerResponse response = await VideoController(http)
        .getPlayerResponse(id, yt.YoutubeApiClient.androidVr,
            watchPage: watchPage);
    final List<ClosedCaptionTrack> tracks = response.closedCaptionTrack;
    if (tracks.isEmpty) return const <AudioCue>[];
    ClosedCaptionTrack? chosen;
    for (final ClosedCaptionTrack t in tracks) {
      if (t.languageCode.startsWith(preferSubtitleLang)) {
        chosen = t;
        break;
      }
    }
    chosen ??= tracks.first;
    // 强制 fmt=srv1（= parseYoutubeTimedTextToCues 认得的 <text start=.. dur=..> XML）。
    final Uri raw = Uri.parse(chosen.url);
    final String captionUrl = raw.replace(queryParameters: <String, String>{
      ...raw.queryParameters,
      'fmt': 'srv1',
    }).toString();
    final String body = await http.getString(captionUrl);
    return parseYoutubeTimedTextToCues(content: body, bookKey: bookKey);
  } catch (_) {
    // 字幕是可选增强：其失败绝不能冒泡到 resolveYoutubeSource 阻断播放。
    return const <AudioCue>[];
  } finally {
    http.close();
  }
}
