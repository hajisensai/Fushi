/// 作品图谱 L2（docs/specs/2026-10-24-cross-media-links.md §2）：把 `theme_song` 连接
/// 展开成「哪首歌 × 哪一集」的比对计划，以及读回按集缓存的比对结果。
///
/// 纯 Dart + Drift，不碰 FFmpeg / 原生库（那在 [ThemeSongDetector] 里），可直接单测。
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_local_files.dart';

/// 主题曲在一集里的角色。落库值是 `media_links.role`（`op` / `ed` / `insert` / `theme`）。
enum ThemeSongRole {
  op('op'),
  ed('ed'),
  insert('insert'),
  theme('theme');

  const ThemeSongRole(this.wire);

  final String wire;

  static ThemeSongRole? tryParse(String? raw) {
    final String? v = raw?.trim().toLowerCase();
    for (final ThemeSongRole r in ThemeSongRole.values) {
      if (r.wire == v) return r;
    }
    return null;
  }
}

/// 连接没写角色时按位置推断：起点在整集前半是 OP，否则 ED。整集时长未知时取起点
/// 是否在前 10 分钟（TV 动画一集 24 分钟上下，OP 通常在前 5 分钟内）。
ThemeSongRole inferThemeSongRole({
  required int startMs,
  required int? episodeDurationMs,
}) {
  if (episodeDurationMs != null && episodeDurationMs > 0) {
    return startMs * 2 < episodeDurationMs
        ? ThemeSongRole.op
        : ThemeSongRole.ed;
  }
  return startMs < 10 * 60 * 1000 ? ThemeSongRole.op : ThemeSongRole.ed;
}

/// 解析 `media_links.episode_range`（`1-12`、`1,3,5-7`、`13–24`）。NULL / 空 / 解析不了
/// → null（= 全部集）。集号从 1 起。
Set<int>? parseEpisodeRange(String? raw) {
  final String text = (raw ?? '').trim();
  if (text.isEmpty) return null;
  final Set<int> out = <int>{};
  for (final String part in text.split(RegExp(r'[,，、\s]+'))) {
    if (part.isEmpty) continue;
    final Match? range = RegExp(r'^(\d+)\s*[-–~〜～]\s*(\d+)$').firstMatch(part);
    if (range != null) {
      final int a = int.parse(range.group(1)!);
      final int b = int.parse(range.group(2)!);
      if (a < 1 || b < a || b - a > 5000) return null;
      for (int i = a; i <= b; i++) {
        out.add(i);
      }
      continue;
    }
    final int? single = int.tryParse(part);
    if (single == null || single < 1) return null;
    out.add(single);
  }
  return out.isEmpty ? null : out;
}

/// 集号列表 → 紧凑显示（`1–12`、`1–3, 5, 7–8`）。
String formatEpisodeNumbers(Iterable<int> numbers) {
  final List<int> sorted = numbers.toSet().toList()..sort();
  final List<String> parts = <String>[];
  int i = 0;
  while (i < sorted.length) {
    int j = i;
    while (j + 1 < sorted.length && sorted[j + 1] == sorted[j] + 1) {
      j++;
    }
    parts.add(j == i ? '${sorted[i]}' : '${sorted[i]}–${sorted[j]}');
    i = j + 1;
  }
  return parts.join(', ');
}

/// 一集视频（比对的 haystack）。
class ThemeSongEpisode {
  const ThemeSongEpisode({
    required this.bookUid,
    required this.episodeIndex,
    required this.episodeNumber,
    required this.path,
  });

  final String bookUid;

  /// 播放列表下标（单文件为 0），缓存键的一部分。
  final int episodeIndex;

  /// 在作品里的集号（从 1 起，按合集成员顺序 × 播放列表顺序展开）。
  final int episodeNumber;

  /// 本机绝对路径（BD 标题是 `.mpls`，DVD 是虚拟 title 路径——统一 FFmpeg 后端认得）。
  final String path;

  ThemeSongEpisodeKey get key => (bookUid: bookUid, episodeIndex: episodeIndex);
}

/// 一首候选歌（比对的 needle）。
class ThemeSongSong {
  const ThemeSongSong({
    required this.trackUid,
    required this.title,
    required this.path,
    this.cueStartMs,
    this.cueEndMs,
    this.durationMs,
  });

  factory ThemeSongSong.fromRow(MusicTrackRow row) => ThemeSongSong(
    trackUid: row.trackUid,
    title: row.title,
    path: row.path,
    cueStartMs: row.cueStartMs,
    cueEndMs: row.cueEndMs,
    durationMs: row.durationMs,
  );

  final String trackUid;
  final String title;
  final String path;

  /// CUE 虚拟曲目在整轨里的起止（毫秒）。
  final int? cueStartMs;
  final int? cueEndMs;
  final int? durationMs;
}

/// 一条 `theme_song` 连接展开后的比对计划。
class ThemeSongPlan {
  const ThemeSongPlan({
    required this.link,
    required this.role,
    required this.songs,
    required this.episodes,
  });

  final MediaLinkRow link;

  /// 连接上写的角色；null = 按位置推断（[inferThemeSongRole]）。
  final ThemeSongRole? role;

  /// 专辑连接展开成该专辑全部曲目（每集取命中最好的一首）；曲目连接就一首。
  final List<ThemeSongSong> songs;

  /// 适用的集（已按 `episode_range` 过滤）。
  final List<ThemeSongEpisode> episodes;
}

/// 专辑里只有时长 ≤ 它的曲目参与比对：OP / ED 的完整版也极少超过 8 分钟，再长的是
/// 组曲 / 广播剧，只会白白拖慢比对。
const int kThemeSongMaxTrackMs = 8 * 60 * 1000;

/// 一行视频展开成集：有播放列表按列表各项，否则就是 `videoPath` 一个文件。只留本机
/// 绝对路径（远端流 / 网页源没有可解码的本地音轨）。
List<({int index, String path})> themeSongFilesOf(VideoBookRow row) {
  final List<String> playlist = playlistEntryPaths(row.playlistJson);
  final List<String> paths = playlist.isEmpty
      ? <String>[row.videoPath]
      : playlist;
  return <({int index, String path})>[
    for (int i = 0; i < paths.length; i++)
      if (isLocalVideoFilePath(paths[i])) (index: i, path: paths[i]),
  ];
}

/// 视频端点 → 按作品顺序展开的全部集。合集按成员顺序（`sort_index`），每个成员再按
/// 播放列表展开；集号连续递增（远端成员、非本地路径的集跳过但仍占号——集号要与用户
/// 在合集详情页看到的顺序一致）。
Future<List<ThemeSongEpisode>> expandThemeSongEpisodes(
  FushiDatabase db,
  MediaLinkEndpoint video,
) async {
  final List<String> bookUids = <String>[];
  switch (video.kind) {
    case MediaLinkKind.videoCollection:
      final int? id = collectionIdOfTagEntryKey(video.key);
      if (id == null) return const <ThemeSongEpisode>[];
      for (final MediaCollectionItemRow item in await db.getCollectionItems(
        id,
      )) {
        if (item.mediaType == MediaKind.video.dbValue) {
          bookUids.add(item.entryKey);
        }
      }
    case MediaLinkKind.videoEpisode:
      bookUids.add(video.key);
    case MediaLinkKind.book ||
        MediaLinkKind.game ||
        MediaLinkKind.musicAlbum ||
        MediaLinkKind.musicTrack ||
        MediaLinkKind.audiobook:
      return const <ThemeSongEpisode>[];
  }
  final List<ThemeSongEpisode> out = <ThemeSongEpisode>[];
  int number = 0;
  for (final String uid in bookUids) {
    final VideoBookRow? row = await db.getVideoBookByBookUid(uid);
    if (row == null) {
      number++;
      continue;
    }
    final List<String> playlist = playlistEntryPaths(row.playlistJson);
    final int slots = playlist.isEmpty ? 1 : playlist.length;
    final Map<int, String> local = <int, String>{
      for (final ({int index, String path}) f in themeSongFilesOf(row))
        f.index: f.path,
    };
    for (int i = 0; i < slots; i++) {
      number++;
      final String? path = local[i];
      if (path == null) continue;
      out.add(
        ThemeSongEpisode(
          bookUid: uid,
          episodeIndex: i,
          episodeNumber: number,
          path: path,
        ),
      );
    }
  }
  return out;
}

/// 音乐端点 → 参与比对的曲目。
Future<List<ThemeSongSong>> expandThemeSongSongs(
  FushiDatabase db,
  MediaLinkEndpoint music,
) async {
  switch (music.kind) {
    case MediaLinkKind.musicTrack:
      final MusicTrackRow? row = await db.getMusicTrack(music.key);
      if (row == null || row.deletedAt != null) {
        return const <ThemeSongSong>[];
      }
      return <ThemeSongSong>[ThemeSongSong.fromRow(row)];
    case MediaLinkKind.musicAlbum:
      return <ThemeSongSong>[
        for (final MusicTrackRow row in await db.listMusicTracks(
          albumUid: music.key,
        ))
          if (row.deletedAt == null &&
              (row.durationMs ?? 0) <= kThemeSongMaxTrackMs)
            ThemeSongSong.fromRow(row),
      ];
    case MediaLinkKind.videoCollection ||
        MediaLinkKind.videoEpisode ||
        MediaLinkKind.book ||
        MediaLinkKind.game ||
        MediaLinkKind.audiobook:
      return const <ThemeSongSong>[];
  }
}

bool _isVideoKind(MediaLinkKind? k) =>
    k == MediaLinkKind.videoCollection || k == MediaLinkKind.videoEpisode;

bool _isMusicKind(MediaLinkKind? k) =>
    k == MediaLinkKind.musicTrack || k == MediaLinkKind.musicAlbum;

/// 一条连接是不是「音乐 → 视频」的已确认主题曲连接（建议态 / 墓碑不参与识别：
/// 推断结果未经确认不能当事实去改播放行为）。返回 (音乐端, 视频端)。
({MediaLinkEndpoint music, MediaLinkEndpoint video})? themeSongEndpointsOf(
  MediaLinkRow row,
) {
  if (MediaLinkRelation.tryParse(row.relation) != MediaLinkRelation.themeSong) {
    return null;
  }
  if (mediaLinkStateOf(row) != MediaLinkState.confirmed) return null;
  final MediaLinkKind? from = MediaLinkKind.tryParse(row.fromKind);
  final MediaLinkKind? to = MediaLinkKind.tryParse(row.toKind);
  if (_isMusicKind(from) && _isVideoKind(to)) {
    return (
      music: (kind: from!, key: row.fromKey),
      video: (kind: to!, key: row.toKey),
    );
  }
  // 方向写反了（视频 → 音乐）也认：关系是 theme_song 时两端身份不会混淆。
  if (_isVideoKind(from) && _isMusicKind(to)) {
    return (
      music: (kind: to!, key: row.toKey),
      video: (kind: from!, key: row.fromKey),
    );
  }
  return null;
}

/// 全部已确认的主题曲连接 → 比对计划。[onlyBookUid] 给了时只保留含这部视频的计划，
/// 且计划里只剩这部视频的集（视频页按集优先识别用）。
Future<List<ThemeSongPlan>> loadThemeSongPlans(
  FushiDatabase db, {
  String? onlyBookUid,
  String? onlyTrackUid,
}) async {
  final List<ThemeSongPlan> plans = <ThemeSongPlan>[];
  for (final MediaLinkRow row in await db.allMediaLinks()) {
    final ({MediaLinkEndpoint music, MediaLinkEndpoint video})? ends =
        themeSongEndpointsOf(row);
    if (ends == null) continue;
    List<ThemeSongSong> songs = await expandThemeSongSongs(db, ends.music);
    if (onlyTrackUid != null) {
      songs = <ThemeSongSong>[
        for (final ThemeSongSong s in songs)
          if (s.trackUid == onlyTrackUid) s,
      ];
    }
    if (songs.isEmpty) continue;
    final Set<int>? range = parseEpisodeRange(row.episodeRange);
    final List<ThemeSongEpisode> episodes = <ThemeSongEpisode>[
      for (final ThemeSongEpisode e in await expandThemeSongEpisodes(
        db,
        ends.video,
      ))
        if ((range == null || range.contains(e.episodeNumber)) &&
            (onlyBookUid == null || e.bookUid == onlyBookUid))
          e,
    ];
    if (episodes.isEmpty) continue;
    plans.add(
      ThemeSongPlan(
        link: row,
        role: ThemeSongRole.tryParse(row.role),
        songs: songs,
        episodes: episodes,
      ),
    );
  }
  return plans;
}

/// 视频页用：这一集里识别出的一段主题曲。
class ThemeSongSpan {
  const ThemeSongSpan({
    required this.trackUid,
    required this.title,
    required this.role,
    required this.startMs,
    required this.endMs,
    required this.confidence,
  });

  final String trackUid;
  final String title;
  final ThemeSongRole role;
  final int startMs;
  final int endMs;
  final double confidence;

  bool contains(int positionMs) => positionMs >= startMs && positionMs < endMs;
}

/// 读这一集的缓存结果（只回命中的、且仍有已确认连接支撑的），按起点排序。同一
/// 计划（专辑展开的多首）在同一集只留置信度最高的一首。
Future<List<ThemeSongSpan>> loadThemeSongSpansForEpisode(
  FushiDatabase db, {
  required String bookUid,
  required int episodeIndex,
  int? episodeDurationMs,
}) async {
  final List<ThemeSongPlan> plans = await loadThemeSongPlans(
    db,
    onlyBookUid: bookUid,
  );
  if (plans.isEmpty) return const <ThemeSongSpan>[];
  final Map<String, VideoThemeSongSpanRow> rows =
      <String, VideoThemeSongSpanRow>{
        for (final VideoThemeSongSpanRow r in await db.themeSongSpansForEpisode(
          (bookUid: bookUid, episodeIndex: episodeIndex),
        ))
          if (r.startMs != null) r.trackUid: r,
      };
  final List<ThemeSongSpan> out = <ThemeSongSpan>[];
  final Set<String> seenTracks = <String>{};
  for (final ThemeSongPlan plan in plans) {
    if (!plan.episodes.any(
      (ThemeSongEpisode e) => e.episodeIndex == episodeIndex,
    )) {
      continue;
    }
    VideoThemeSongSpanRow? best;
    ThemeSongSong? bestSong;
    for (final ThemeSongSong song in plan.songs) {
      final VideoThemeSongSpanRow? r = rows[song.trackUid];
      if (r == null) continue;
      if (best == null || (r.confidence ?? 0) > (best.confidence ?? 0)) {
        best = r;
        bestSong = song;
      }
    }
    if (best == null || bestSong == null) continue;
    if (!seenTracks.add(bestSong.trackUid)) continue;
    out.add(
      ThemeSongSpan(
        trackUid: bestSong.trackUid,
        title: bestSong.title,
        role:
            plan.role ??
            inferThemeSongRole(
              startMs: best.startMs!,
              episodeDurationMs: episodeDurationMs,
            ),
        startMs: best.startMs!,
        endMs: best.endMs!,
        confidence: best.confidence ?? 0,
      ),
    );
  }
  out.sort(
    (ThemeSongSpan a, ThemeSongSpan b) => a.startMs.compareTo(b.startMs),
  );
  return out;
}

/// 音乐侧「出现在」的一项：哪部视频的哪几集、什么角色，以及每集的起点（点了跳过去）。
class ThemeSongAppearance {
  const ThemeSongAppearance({
    required this.videoTitle,
    required this.role,
    required this.episodes,
  });

  final String videoTitle;

  /// 连接上写的角色；null = 没写（界面不标 OP / ED）。
  final ThemeSongRole? role;

  /// 命中的集，按集号排序。
  final List<({ThemeSongEpisode episode, int startMs})> episodes;

  String get episodeLabel => formatEpisodeNumbers(
    episodes.map(
      (({ThemeSongEpisode episode, int startMs}) e) => e.episode.episodeNumber,
    ),
  );
}

/// 一首歌出现在哪些视频的哪几集（只看缓存里命中的集）。
Future<List<ThemeSongAppearance>> loadThemeSongAppearances(
  FushiDatabase db,
  String trackUid,
) async {
  final List<VideoThemeSongSpanRow> hits = await db.themeSongSpansForTrack(
    trackUid,
  );
  if (hits.isEmpty) return const <ThemeSongAppearance>[];
  final Map<String, int> startByKey = <String, int>{
    for (final VideoThemeSongSpanRow r in hits)
      '${r.bookUid}\u0000${r.episodeIndex}': r.startMs!,
  };
  final List<ThemeSongAppearance> out = <ThemeSongAppearance>[];
  for (final ThemeSongPlan plan in await loadThemeSongPlans(
    db,
    onlyTrackUid: trackUid,
  )) {
    final List<({ThemeSongEpisode episode, int startMs})> episodes =
        <({ThemeSongEpisode episode, int startMs})>[
          for (final ThemeSongEpisode e in plan.episodes)
            if (startByKey['${e.bookUid}\u0000${e.episodeIndex}']
                case final int start)
              (episode: e, startMs: start),
        ];
    if (episodes.isEmpty) continue;
    final ({MediaLinkEndpoint music, MediaLinkEndpoint video}) ends =
        themeSongEndpointsOf(plan.link)!;
    out.add(
      ThemeSongAppearance(
        videoTitle: await _videoTitleOf(db, ends.video),
        role: plan.role,
        episodes: episodes,
      ),
    );
  }
  return out;
}

Future<String> _videoTitleOf(FushiDatabase db, MediaLinkEndpoint video) async {
  if (video.kind == MediaLinkKind.videoCollection) {
    final int? id = collectionIdOfTagEntryKey(video.key);
    final MediaCollectionRow? c = id == null
        ? null
        : await db.getMediaCollectionById(id);
    if (c != null) return c.name;
  }
  if (video.kind == MediaLinkKind.videoEpisode) {
    final VideoBookRow? row = await db.getVideoBookByBookUid(video.key);
    if (row != null) return row.title;
  }
  return video.key;
}

/// 测试 / 调试用：把一批计划压成可比较的结构。
String debugDescribeThemeSongPlans(List<ThemeSongPlan> plans) =>
    jsonEncode(<Object?>[
      for (final ThemeSongPlan p in plans)
        <String, Object?>{
          'role': p.role?.wire,
          'songs': <String>[for (final ThemeSongSong s in p.songs) s.trackUid],
          'episodes': <String>[
            for (final ThemeSongEpisode e in p.episodes)
              '${e.episodeNumber}:${e.bookUid}#${e.episodeIndex}',
          ],
        },
    ]);
