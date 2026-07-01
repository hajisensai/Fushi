import 'package:html_unescape/html_unescape.dart';
import 'package:hibiki_audio/hibiki_audio.dart' show AudioCue;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

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
    required this.title,
    required this.httpHeaders,
    required this.cues,
  });

  final String streamUrl;
  final String? audioStreamUrl;
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

/// 纯函数：YouTube timedtext XML → List<AudioCue>。start/dur 秒 → 毫秒。
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
/// 取**最高清 video-only + 最高码率 audio-only** 分离流（可达 4K），播放时视频流经 libmpv、
/// 音频流经 `AudioTrack.uri` 外挂；制卡时 GIF/帧从视频流、音频段从音频流各自 ffmpeg 裁。
/// 仅当该视频无分离流才回落 muxed（≤360p，YouTube 侧限制）。
Future<YoutubeResolvedSource> resolveYoutubeSource(
  String url, {
  String preferSubtitleLang = 'ja',
}) async {
  final yt.YoutubeExplode client = yt.YoutubeExplode();
  try {
    final yt.Video video = await client.videos.get(url);
    final yt.StreamManifest manifest =
        await client.videos.streamsClient.getManifest(video.id);
    // 优先「最高清 video-only + 最高码率 audio-only」分离流（可达 4K）；两者齐备才用，
    // 否则回落 muxed（YouTube 把 muxed 限 ≤360p，故仅作最后兜底）。
    String streamUrl;
    String? audioStreamUrl;
    if (manifest.videoOnly.isNotEmpty && manifest.audioOnly.isNotEmpty) {
      streamUrl = manifest.videoOnly.withHighestBitrate().url.toString();
      audioStreamUrl = manifest.audioOnly.withHighestBitrate().url.toString();
    } else {
      streamUrl = manifest.muxed.withHighestBitrate().url.toString();
      audioStreamUrl = null;
    }
    final String bookKey = 'yt:${video.id.value}';

    final List<AudioCue> cues = <AudioCue>[];
    final yt.ClosedCaptionManifest cc =
        await client.videos.closedCaptions.getManifest(video.id);
    yt.ClosedCaptionTrackInfo? track;
    for (final yt.ClosedCaptionTrackInfo t in cc.tracks) {
      if (t.language.code.startsWith(preferSubtitleLang)) {
        track = t;
        break;
      }
    }
    track ??= cc.tracks.isNotEmpty ? cc.tracks.first : null;
    if (track != null) {
      final yt.ClosedCaptionTrack captions =
          await client.videos.closedCaptions.get(track);
      int i = 0;
      for (final yt.ClosedCaption c in captions.captions) {
        if (c.text.trim().isEmpty) continue;
        cues.add(_cue(
          bookKey,
          i,
          c.text.trim(),
          c.offset.inMilliseconds,
          (c.offset + c.duration).inMilliseconds,
        ));
        i++;
      }
    }

    return YoutubeResolvedSource(
      streamUrl: streamUrl,
      audioStreamUrl: audioStreamUrl,
      title: video.title,
      httpHeaders: const <String, String>{'User-Agent': 'Mozilla/5.0'},
      cues: cues,
    );
  } finally {
    client.close();
  }
}
