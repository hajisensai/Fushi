/// YouTube 内置音源（反馈 0tRY-D2JgG）：在音乐页直接搜 YouTube、点歌即串流音频。
///
/// **原生实现**：搜索与取流都走仓库已有的 `youtube_explode_dart`（纯 Dart，视频模块 YouTube
/// 播放 / 音乐 MV 绑定同一份依赖与同一条多 client 兜底链，`youtube_source_resolver.dart`），
/// 不经插件运行时、不起 WebView、不抓网页。
///
/// 形态是一个 [MusicServerBrowser]（与 Apple Music catalog 同一条接入面）：统一搜索的来源 chip、
/// 曲目行、播放项构造、「来源」页的排序与显示开关都复用服务器来源那一套。YouTube 没有专辑 /
/// 艺人 / 歌单树，这些接口恒回空；推荐 / 浏览页不列它（app 侧 `musicServerHasBrowse`）。
///
/// 播放项路径是 `fushi-music-youtube://video/<videoId>`——与插件曲目同一思路的**只认身份的占位**：
/// googlevideo 直链几小时就过期，真正的地址在 mpv 后端打开这一首时才经
/// [resolveYoutubeAudioStream] 取，每次重开自然刷新。
///
/// 纯 Dart、不碰 Flutter（引擎纯度守卫）。
library;

import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';

/// YouTube 音源曲目播放路径的 scheme。
const String kYoutubeMusicScheme = 'fushi-music-youtube';

/// 浏览器的 [MusicServerBrowser.serverId]（来源排序 / 启停偏好里的 key 由 app 侧派生）。
const String kYoutubeMusicServerId = 'youtube';

final RegExp _videoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// YouTube 视频 id → 音乐播放路径（host 固定为 `video`：URI host 会被规范成小写，而 videoId
/// 区分大小写，所以 id 放在路径段里）。
String youtubeMusicTrackPath(String videoId) => Uri(
  scheme: kYoutubeMusicScheme,
  host: 'video',
  pathSegments: <String>[videoId],
).toString();

/// 音乐播放路径 → YouTube 视频 id；不是 YouTube 音源曲目返回 null。
String? youtubeMusicVideoIdFromPath(String path) {
  if (!path.startsWith('$kYoutubeMusicScheme://')) return null;
  final Uri? uri = Uri.tryParse(path);
  if (uri == null || uri.host != 'video' || uri.pathSegments.length != 1) {
    return null;
  }
  final String id = uri.pathSegments.single;
  return _videoIdPattern.hasMatch(id) ? id : null;
}

bool isYoutubeMusicTrackPath(String path) =>
    youtubeMusicVideoIdFromPath(path) != null;

/// 标题里描述「视频形态」的括注（`(Official Video)`、`【MV】`、`[Lyrics]` …）：去掉后歌词来源
/// 按「歌名 + 艺人」才查得到。只认带这些词的括注，`(feat. X)`、`(Remix)` 这类属于歌名本身的保留。
final RegExp _noiseBracket = RegExp(r'\s*[(\[【（]([^)\]】）]*)[)\]】）]');
final RegExp _noiseWord = RegExp(
  r'official|music\s*video|\bm\s*/?\s*v\b|\bpv\b|lyrics?|audio|video|'
  r'visuali[sz]er|\bhd\b|\b4k\b|full\s*ver|公式|歌詞|ミュージックビデオ|字幕',
  caseSensitive: false,
);
final RegExp _trailingNoise = RegExp(
  r'\s+(official\s+)?(music\s+)?(video|mv|m/v|pv|audio)\s*$',
  caseSensitive: false,
);
final RegExp _quotedTitle = RegExp(r'^(.+?)\s*[「『](.+?)[」』]');
final RegExp _dashSplit = RegExp(r'\s+[-–—]\s+');
final RegExp _topicSuffix = RegExp(r'\s+-\s+Topic$', caseSensitive: false);
final RegExp _channelSuffix = RegExp(
  r'(VEVO|\s+official(\s+channel)?)$',
  caseSensitive: false,
);

String _stripNoise(String s) {
  final String out = s
      .replaceAllMapped(
        _noiseBracket,
        (Match m) => _noiseWord.hasMatch(m.group(1)!) ? '' : m.group(0)!,
      )
      .replaceFirst(_trailingNoise, '')
      .trim();
  return out.isEmpty ? s.trim() : out;
}

/// 纯函数：YouTube 视频标题 + 频道名 → 曲目的（歌名，艺人）。歌词来源按这两项查词。
///
/// - YouTube Music 自动生成的「<艺人> - Topic」频道：标题就是歌名，艺人取频道名去掉后缀；
/// - `艺人「歌名」…` / `艺人『歌名』…`（日文 MV 的惯用写法）：括号里是歌名；
/// - `艺人 - 歌名 (Official Video)`：按第一个两侧带空格的破折号拆；
/// - 都不像：整条标题（去掉视频形态括注）当歌名，艺人取频道名。
({String title, String? artist}) youtubeMusicTitleArtist(
  String title,
  String channel,
) {
  final String ch = channel.trim();
  final bool topic = _topicSuffix.hasMatch(ch);
  final String channelArtist = topic
      ? ch.replaceFirst(_topicSuffix, '').trim()
      : ch.replaceFirst(_channelSuffix, '').trim();
  final String? fallbackArtist = channelArtist.isEmpty ? null : channelArtist;
  if (topic) return (title: _stripNoise(title), artist: fallbackArtist);
  final RegExpMatch? quoted = _quotedTitle.firstMatch(title);
  if (quoted != null) {
    final String artist = _stripNoise(quoted.group(1)!);
    return (
      title: quoted.group(2)!.trim(),
      artist: artist.isEmpty ? fallbackArtist : artist,
    );
  }
  final String cleaned = _stripNoise(title);
  final List<String> parts = cleaned.split(_dashSplit);
  if (parts.length >= 2 && parts.first.trim().isNotEmpty) {
    final String song = parts.sublist(1).join(' - ').trim();
    if (song.isNotEmpty) return (title: song, artist: parts.first.trim());
  }
  return (title: cleaned, artist: fallbackArtist);
}

/// 搜索函数（缺省 [searchYoutubeVideos]，测试注入替身）。
typedef YoutubeMusicSearch =
    Future<List<YoutubeSearchHit>> Function(String query, {int limit});

/// YouTube 内置音源的浏览器：只有曲目搜索。
class YoutubeMusicClient implements MusicServerBrowser {
  YoutubeMusicClient({required this.displayName, YoutubeMusicSearch? search})
    : _search = search ?? searchYoutubeVideos;

  final YoutubeMusicSearch _search;

  @override
  final String displayName;

  @override
  MusicServerKind get kind => MusicServerKind.youtube;

  @override
  String get serverId => kYoutubeMusicServerId;

  @override
  Future<MusicServerSearchResult> search(String query, {int limit = 30}) async {
    if (query.trim().isEmpty) return const MusicServerSearchResult();
    final List<YoutubeSearchHit> hits = await _search(query, limit: limit);
    return MusicServerSearchResult(
      tracks: <MusicServerTrack>[
        for (final YoutubeSearchHit h in hits)
          // 直播 / 首播没有时长，也不是一首歌。
          if (h.duration != null && h.duration! > Duration.zero)
            youtubeMusicTrackOf(h),
      ],
    );
  }

  @override
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps}) =>
      MusicServerStream(
        uri: Uri.parse(youtubeMusicTrackPath(track.id)),
        transcoded: false,
      );

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) =>
      coverRef == null || !_videoIdPattern.hasMatch(coverRef)
      ? null
      : Uri.parse(youtubeThumbnailUrl(coverRef));

  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async =>
      const MusicServerPage<MusicServerAlbum>(items: <MusicServerAlbum>[]);

  @override
  Future<List<MusicServerTrack>> albumTracks(String albumId) async =>
      const <MusicServerTrack>[];

  @override
  Future<List<MusicServerArtist>> listArtists() async =>
      const <MusicServerArtist>[];

  @override
  Future<List<MusicServerAlbum>> artistAlbums(String artistId) async =>
      const <MusicServerAlbum>[];

  @override
  Future<MusicServerPage<MusicServerPlaylist>> listPlaylists({
    int offset = 0,
    int limit = kMusicServerPageSize,
  }) async => const MusicServerPage<MusicServerPlaylist>(
    items: <MusicServerPlaylist>[],
  );

  @override
  Future<List<MusicServerTrack>> playlistTracks(String playlistId) async =>
      const <MusicServerTrack>[];

  @override
  void close() {}
}

/// 一条 YouTube 搜索结果 → 服务器曲目（id = videoId，封面引用 = videoId）。
MusicServerTrack youtubeMusicTrackOf(YoutubeSearchHit hit) {
  final ({String title, String? artist}) ta = youtubeMusicTitleArtist(
    hit.title,
    hit.channelName,
  );
  return MusicServerTrack(
    id: hit.videoId,
    title: ta.title,
    artist: ta.artist,
    durationMs: hit.duration?.inMilliseconds,
    coverRef: hit.videoId,
  );
}
