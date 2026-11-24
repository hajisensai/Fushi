// YouTube 播放列表的条目枚举（拍板台 zGXhhMAglH：从播放列表进入播放时，播放器选集面板
// 列出整份播放列表）。纯 Dart、不碰 Flutter：分页由 youtube_explode 的
// `playlists.getVideos` 按需翻页，调用方按自己的节奏消费 [youtubePlaylistEntries]。
import 'dart:async';

import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show createYoutubeHttpClient;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

/// 播放列表里的一条视频（只有面板与落书要的字段）。
class YoutubePlaylistEntry {
  const YoutubePlaylistEntry({
    required this.videoId,
    required this.title,
    this.author = '',
    this.durationMs,
  });

  /// 11 位视频 id。
  final String videoId;
  final String title;
  final String author;

  /// 时长（列表页给得出时）；null = 未知（直播 / 首映）。
  final int? durationMs;

  @override
  bool operator ==(Object other) =>
      other is YoutubePlaylistEntry &&
      other.videoId == videoId &&
      other.title == title &&
      other.author == author &&
      other.durationMs == durationMs;

  @override
  int get hashCode => Object.hash(videoId, title, author, durationMs);
}

/// 播放列表 id 的形状：YouTube 的列表 id 长短不一（`PL…` 34 位、`OLAK5uy_…`、`RD…` 混合、
/// `UU…` 频道上传），字符集只有 `[A-Za-z0-9_-]`，至少 2 位（与 youtube_explode
/// `PlaylistId.validatePlaylistId` 同口径）。
final RegExp _kPlaylistIdShape = RegExp(r'^[A-Za-z0-9_-]{2,}$');

/// [raw] 是不是一个形状合法的播放列表 id。
bool isYoutubePlaylistId(String raw) => _kPlaylistIdShape.hasMatch(raw);

/// 按播放列表顺序逐条产出 [playlistId] 的视频（去重、跳过已删除 / 私享的占位条目）。
///
/// 惰性分页：消费方停止监听即不再翻下一页；[maxEntries] 是硬上限（超长的频道上传列表
/// 不会把整个频道拉下来）。网络 / 解析失败照常以流错误抛出，由调用方决定怎么呈现。
Stream<YoutubePlaylistEntry> youtubePlaylistEntries(
  String playlistId, {
  int maxEntries = 1000,
}) async* {
  final yt.YoutubeExplode client = yt.YoutubeExplode(createYoutubeHttpClient());
  try {
    int count = 0;
    await for (final yt.Video video in client.playlists.getVideos(playlistId)) {
      final String title = video.title.trim();
      if (title.isEmpty) continue;
      yield YoutubePlaylistEntry(
        videoId: video.id.value,
        title: title,
        author: video.author,
        durationMs: video.duration?.inMilliseconds,
      );
      count++;
      if (count >= maxEntries) break;
    }
  } finally {
    client.close();
  }
}
