import 'package:html_unescape/html_unescape.dart';
import 'package:hibiki_audio/hibiki_audio.dart' show AudioCue;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

/// YouTube 解析结果：可播放流 URL + 字幕 cue + header + 标题。
class YoutubeResolvedSource {
  const YoutubeResolvedSource({
    required this.streamUrl,
    required this.title,
    required this.httpHeaders,
    required this.cues,
  });

  final String streamUrl;
  final String title;
  final Map<String, String> httpHeaders;
  final List<AudioCue> cues;
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

AudioCue _cue(String bookKey, int index, String text, int startMs, int endMs) => AudioCue()
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
    final String raw =
        _unescape.convert((m.group(3) ?? '').replaceAll(RegExp(r'<[^>]+>'), '')).trim();
    if (raw.isEmpty) continue;
    cues.add(_cue(bookKey, index, raw, (start * 1000).round(), ((start + dur) * 1000).round()));
    index++;
  }
  return cues;
}

/// IO：用 youtube_explode 解析可播放流 URL + 日文字幕（无则空）+ 标题。
///
/// 优先 muxed（音视频合一）流，保证 libmpv 单 URL 就有声画（muxed 限 ≤360p，是取「单 URL
/// 同时供播放+ffmpeg 制卡裁剪」简洁性的折中；日后可拆最高视频流 + 最高音频流经 libmpv
/// `--audio-file` 提清晰度，但制卡需两路源，故首版走 muxed）。
Future<YoutubeResolvedSource> resolveYoutubeSource(
  String url, {
  String preferSubtitleLang = 'ja',
}) async {
  final yt.YoutubeExplode client = yt.YoutubeExplode();
  try {
    final yt.Video video = await client.videos.get(url);
    final yt.StreamManifest manifest =
        await client.videos.streamsClient.getManifest(video.id);
    final yt.MuxedStreamInfo muxed = manifest.muxed.withHighestBitrate();
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
      streamUrl: muxed.url.toString(),
      title: video.title,
      httpHeaders: const <String, String>{'User-Agent': 'Mozilla/5.0'},
      cues: cues,
    );
  } finally {
    client.close();
  }
}
