/// MV 匹配的纯判据（音乐方案 §8.3）：
///
/// 1. 本地：同目录 / 相邻 `MV` `PV` 目录里的视频按文件名（标题 + 艺人）预筛，**声纹对齐是
///    硬判据**（app 侧 `ThemeSongDetector.mvAlignment`，同时求出 MV 相对音频的偏移）；
/// 2. MusicBrainz 关系里的 `music video` 录音 → URL（识别器已取，存在刮削结论里）；
/// 3. YouTube 搜索：只取高置信结果（官方频道 / 「Official Video」类标题、时长相符），
///    **用户确认后**才绑定；
/// 4. 动画 OP / ED：视频库里声纹识别出的片头片尾区间（作品图谱 L2）。
library;

import 'package:fushi_engine/media/music/metadata/music_metadata_text.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show YoutubeSearchHit;

/// `music_videos.kind` 值域（v126 表注释同一组，冻结）。
abstract final class MusicVideoKind {
  static const String local = 'local';
  static const String youtube = 'youtube';
  static const String discChapter = 'disc_chapter';
  static const String animeEpisode = 'anime_episode';
}

/// 本地 MV 候选的视频扩展名。
const Set<String> kMusicVideoExtensions = <String>{
  'mkv',
  'mp4',
  'm4v',
  'webm',
  'mov',
  'avi',
  'ts',
  'm2ts',
  'mpg',
  'mpeg',
  'flv',
  'wmv',
};

/// 常见的 MV 目录名（大小写不敏感）：曲目同目录下、或上一级目录下。
const Set<String> kMusicVideoFolderNames = <String>{
  'mv',
  'pv',
  'mvs',
  'video',
  'videos',
  'music video',
  'music videos',
  '映像',
  '特典映像',
};

/// MV 标记词（文件名 / 视频标题里出现即加分）。
final RegExp _mvMarker = RegExp(
  r'(music\s*video|official\s*(music\s*)?video|\bmv\b|\bpv\b|ミュージックビデオ|'
  r'ミュージック・ビデオ|official\s*mv|full\s*mv)',
  caseSensitive: false,
);

/// 明显不是 MV 的（歌词视频 / 翻唱 / 现场 / 音源-only）。
final RegExp _notMv = RegExp(
  r'(lyric\s*video|lyrics|歌詞|歌ってみた|cover|カバー|翻唱|live\b|ライブ|'
  r'karaoke|カラオケ|instrumental|off\s*vocal|audio\s*only|\bshort\b|teaser|'
  r'予告|spot|cm\b|reaction|1\s*hour)',
  caseSensitive: false,
);

/// 本地文件名打分（0..1，0 = 不是候选）：去掉扩展名后的文件名必须包含（去版本注记的）
/// 标题；含艺人 +0.2，含 MV 标记 +0.15。
double scoreLocalMusicVideoName(
  String fileName, {
  required String title,
  String? artist,
}) {
  final int dot = fileName.lastIndexOf('.');
  final String stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final String n = normalizeMusicText(stem);
  final String t = normalizeMusicText(stripMusicTitleAnnotations(title));
  if (t.isEmpty || !n.contains(t)) return 0;
  double s = 0.6;
  final String? a = artist?.trim();
  if (a != null && a.isNotEmpty) {
    for (final String part in splitMusicArtists(a)) {
      if (part.isNotEmpty && n.contains(part)) {
        s += 0.2;
        break;
      }
    }
  }
  if (_mvMarker.hasMatch(stem)) s += 0.15;
  return s > 1 ? 1 : s;
}

/// 声纹对齐之后的接受门：置信度 ≥ 0.5 且命中段 ≥ 30 s（或覆盖整首的 60%）。
bool acceptMusicVideoAlignment({
  required double confidence,
  required Duration matched,
  required int? songDurationMs,
}) {
  if (confidence < 0.5) return false;
  if (matched >= const Duration(seconds: 30)) return true;
  final int? d = songDurationMs;
  return d != null && d > 0 && matched.inMilliseconds >= d * 0.6;
}

/// YouTube 结果的置信度（0..1）与「高置信」判定。
class YoutubeMusicVideoScore {
  const YoutubeMusicVideoScore({
    required this.hit,
    required this.confidence,
    required this.highConfidence,
  });

  final YoutubeSearchHit hit;
  final double confidence;

  /// 只有它为 true 的才拿给用户确认。
  final bool highConfidence;
}

/// 给一条 YouTube 结果打分。高置信 = 标题含歌名 + 频道是艺人本人（或艺人官方 / VEVO /
/// 唱片公司 Official）或标题有 MV 标记 + 时长相符 + 不是歌词视频 / 翻唱 / Live。
/// 自动生成的「- Topic」频道是音源而不是 MV，一律不算。
YoutubeMusicVideoScore scoreYoutubeMusicVideo(
  YoutubeSearchHit hit, {
  required String title,
  String? artist,
  int? songDurationMs,
  bool songIsCover = false,
}) {
  final String songTitle = normalizeMusicText(
    stripMusicTitleAnnotations(title),
  );
  final String videoTitle = normalizeMusicText(hit.title);
  final bool titleOk = songTitle.isNotEmpty && videoTitle.contains(songTitle);
  final String channel = hit.channelName.trim();
  final bool topic = channel.toLowerCase().endsWith('- topic');
  double channelScore = 0;
  final String? a = artist?.trim();
  if (a != null && a.isNotEmpty) {
    final String nc = normalizeMusicText(channel);
    for (final String part in splitMusicArtists(a)) {
      if (part.isEmpty) continue;
      if (nc == part ||
          nc == '${part}official' ||
          nc == '${part}vevo' ||
          nc == 'official$part') {
        channelScore = 1;
        break;
      }
      if (nc.contains(part) && channelScore < 0.7) {
        channelScore = 0.7;
      }
    }
  }
  final bool marker = _mvMarker.hasMatch(hit.title);
  final bool excluded = !songIsCover && _notMv.hasMatch(hit.title);
  bool durationOk = true;
  final Duration? d = hit.duration;
  final int? song = songDurationMs;
  if (d != null && song != null && song > 0) {
    final int v = d.inMilliseconds;
    // MV 常带前奏剧情 / 片尾：允许比音源短 15 s、长 4 分钟。
    durationOk = v >= song - 15000 && v <= song + 240000;
  }
  double confidence = 0;
  if (titleOk) confidence += 0.4;
  confidence += channelScore * 0.35;
  if (marker) confidence += 0.15;
  if (durationOk) confidence += 0.1;
  if (excluded || topic) confidence *= 0.3;
  final bool high =
      titleOk &&
      !excluded &&
      !topic &&
      durationOk &&
      (channelScore >= 1 || (channelScore >= 0.7 && marker));
  return YoutubeMusicVideoScore(
    hit: hit,
    confidence: confidence > 1 ? 1 : confidence,
    highConfidence: high,
  );
}

/// YouTube 搜索词：`艺人 歌名 MV`（艺人缺时只用歌名）。
String youtubeMusicVideoQuery({required String title, String? artist}) {
  final String t = stripMusicTitleAnnotations(title);
  final String? a = artist?.trim();
  return (a == null || a.isEmpty) ? '$t MV' : '$a $t MV';
}

/// `music_videos.ref` 的动画集引用：`<bookUid>#<episodeIndex>`。
String animeEpisodeMusicVideoRef(String bookUid, int episodeIndex) =>
    '$bookUid#$episodeIndex';

/// [animeEpisodeMusicVideoRef] 的逆；格式不对返回 null。
({String bookUid, int episodeIndex})? parseAnimeEpisodeMusicVideoRef(
  String ref,
) {
  final int hash = ref.lastIndexOf('#');
  if (hash <= 0) return null;
  final int? index = int.tryParse(ref.substring(hash + 1));
  if (index == null || index < 0) return null;
  return (bookUid: ref.substring(0, hash), episodeIndex: index);
}
