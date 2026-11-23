/// MV 匹配与绑定（音乐方案 §8.3）的 app 侧编排。判据在引擎
/// `packages/fushi_engine/lib/media/music/metadata/music_video_match.dart`，声纹对齐在
/// [ThemeSongDetector.mvAlignment]（native/fushi_music，后台 isolate）。
///
/// 绑定落 `music_videos`（v130）：`offset_ms` = MV 时间 − 音频时间（MV 模式下歌词与本地
/// 无损音轨都按它对准）。本地声纹命中自动绑定（硬判据）；YouTube / MusicBrainz 关系 /
/// 动画集只给候选，用户确认后才写（`is_user_bound = true`）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show immutable;
import 'package:fushi/src/media/links/theme_song/theme_song_detector.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_video_match.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

/// 一个待用户确认的在线 / 动画 MV 候选。
class MusicVideoCandidate {
  const MusicVideoCandidate({
    required this.kind,
    required this.ref,
    required this.title,
    this.subtitle,
    this.offsetMs = 0,
    this.confidence,
  });

  final String kind;
  final String ref;
  final String title;
  final String? subtitle;
  final int offsetMs;
  final double? confidence;
}

/// 本地匹配的一条结果。
class MusicLocalVideoMatch {
  const MusicLocalVideoMatch({
    required this.path,
    required this.nameScore,
    this.alignment,
  });

  final String path;
  final double nameScore;

  /// 声纹没对上 / 解码失败为 null。
  final AudioFingerprintMatch? alignment;
}

/// 一个候选视频文件与它此刻的版本（大小 + 修改时刻）：对齐记录按版本认，文件换了要重对。
@immutable
class MusicVideoFileStamp {
  const MusicVideoFileStamp({
    required this.path,
    required this.size,
    required this.mtimeMs,
  });

  final String path;
  final int size;
  final int mtimeMs;

  @override
  bool operator ==(Object other) =>
      other is MusicVideoFileStamp &&
      other.path == path &&
      other.size == size &&
      other.mtimeMs == mtimeMs;

  @override
  int get hashCode => Object.hash(path, size, mtimeMs);
}

/// 一个曲目目录附近的 MV 候选文件（[collectMusicVideoFilesNear] 的产物）。
@immutable
class MusicVideoNearbyFiles {
  const MusicVideoNearbyFiles({
    this.videos = const <MusicVideoFileStamp>[],
    this.discStreams = const <MusicVideoFileStamp>[],
  });

  /// 同目录、同目录下的 MV 目录、上一级的 MV 目录里的视频（按文件名给每首歌打分再筛）。
  final List<MusicVideoFileStamp> videos;

  /// 附近蓝光盘里的流（文件名不带歌名，不按名字筛，见 [listDiscMusicVideoStreams]）。
  final List<MusicVideoFileStamp> discStreams;

  bool get isEmpty => videos.isEmpty && discStreams.isEmpty;
}

MusicVideoFileStamp? _stampOf(File f) {
  try {
    final FileStat s = f.statSync();
    if (s.type != FileSystemEntityType.file) return null;
    return MusicVideoFileStamp(
      path: f.path,
      size: s.size,
      mtimeMs: s.modified.millisecondsSinceEpoch,
    );
  } on FileSystemException {
    return null;
  }
}

/// 收集曲目目录 [homeDir] 附近的 MV 候选文件（带版本）。纯同步 IO、不解码，可在后台
/// isolate 里跑（后台匹配按目录一次收齐，同目录的歌共用一份）。
MusicVideoNearbyFiles collectMusicVideoFilesNear(
  String homeDir, {
  int minDiscBytes = kMusicDiscVideoStreamMinBytes,
  int maxDiscBytes = kMusicDiscVideoStreamMaxBytes,
}) {
  final Directory home = Directory(homeDir);
  if (!home.existsSync()) return const MusicVideoNearbyFiles();
  final List<Directory> dirs = <Directory>[home];
  void addMvChildren(Directory d) {
    if (!d.existsSync()) return;
    try {
      for (final FileSystemEntity e in d.listSync(followLinks: false)) {
        if (e is Directory &&
            kMusicVideoFolderNames.contains(p.basename(e.path).toLowerCase())) {
          dirs.add(e);
        }
      }
    } on FileSystemException {
      return;
    }
  }

  addMvChildren(home);
  if (home.parent.path != home.path) addMvChildren(home.parent);
  final List<MusicVideoFileStamp> videos = <MusicVideoFileStamp>[];
  final Set<String> seen = <String>{};
  for (final Directory d in dirs) {
    List<FileSystemEntity> entries;
    try {
      entries = d.listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    for (final FileSystemEntity e in entries) {
      if (e is! File) continue;
      final String ext = p
          .extension(e.path)
          .replaceFirst('.', '')
          .toLowerCase();
      if (!kMusicVideoExtensions.contains(ext)) continue;
      if (!seen.add(p.normalize(e.path))) continue;
      final MusicVideoFileStamp? s = _stampOf(e);
      if (s != null) videos.add(s);
    }
  }
  return MusicVideoNearbyFiles(
    videos: videos,
    discStreams: _discStreamStamps(
      home,
      seen: seen,
      minBytes: minDiscBytes,
      maxBytes: maxDiscBytes,
    ),
  );
}

/// 一首歌在 [near] 里的候选：文件名打分 > 0 的视频按分数降序取前 [limit] 个，后面接
/// 全部蓝光流（分数记 0，交给声纹判）。纯函数。
List<({MusicVideoFileStamp file, double score})> musicVideoCandidatesFor(
  MusicVideoNearbyFiles near, {
  required String title,
  String? artist,
  int limit = 5,
}) {
  final List<({MusicVideoFileStamp file, double score})> named =
      <({MusicVideoFileStamp file, double score})>[
        for (final MusicVideoFileStamp f in near.videos)
          (
            file: f,
            score: scoreLocalMusicVideoName(
              p.basename(f.path),
              title: title,
              artist: artist,
            ),
          ),
      ]..removeWhere(
        (({MusicVideoFileStamp file, double score}) c) => c.score <= 0,
      );
  named.sort(
    (
      ({MusicVideoFileStamp file, double score}) a,
      ({MusicVideoFileStamp file, double score}) b,
    ) => b.score.compareTo(a.score),
  );
  return <({MusicVideoFileStamp file, double score})>[
    ...named.take(limit),
    for (final MusicVideoFileStamp s in near.discStreams) (file: s, score: 0),
  ];
}

/// 列出曲目附近可能是 MV 的视频文件（同目录、同目录下的 MV 目录、上一级的 MV 目录），
/// 按文件名分数降序；后面再接附近蓝光盘里的流（[listDiscMusicVideoStreams]）。纯 IO，不解码。
List<({String path, double score})> listLocalMusicVideoFiles(
  MusicTrackRow track, {
  int limit = 5,
}) => <({String path, double score})>[
  for (final ({MusicVideoFileStamp file, double score}) c
      in musicVideoCandidatesFor(
        collectMusicVideoFilesNear(File(track.path).parent.path),
        title: track.title,
        artist: track.artistCredit,
        limit: limit,
      ))
    (path: c.file.path, score: c.score),
];

/// 蓝光流文件小于这个大小的不当 MV 候选（菜单背景、片头 logo、静帧）。
const int kMusicDiscVideoStreamMinBytes = 20 * 1024 * 1024;

/// 蓝光流文件大于这个大小的不当 MV 候选（整场演唱会 / 正片：整段解码对齐太慢，
/// 这类盘走「章节导入为曲目」）。约 25 分钟的 35 Mbps 流。
const int kMusicDiscVideoStreamMaxBytes = 6 * 1024 * 1024 * 1024;

/// 一张盘最多取几条流去对齐（按大小降序）。
const int kMusicDiscVideoStreamLimit = 12;

/// 曲目附近蓝光盘里可能是 MV 的流（`BDMV/STREAM/*.m2ts`）：盘根可以是曲目目录本身、
/// 它的子目录（`专辑/BD/BDMV`）、上一级目录或上一级的子目录（`专辑/CD/` 与 `专辑/BD/` 并列）。
/// 按大小过滤（[minBytes]–[maxBytes]，默认 [kMusicDiscVideoStreamMinBytes]–
/// [kMusicDiscVideoStreamMaxBytes]）、每张盘按大小降序取前 [kMusicDiscVideoStreamLimit] 条。
/// [seen] 里已有的路径跳过并登记。纯 IO，不解码。
List<String> listDiscMusicVideoStreams(
  Directory home, {
  Set<String>? seen,
  int minBytes = kMusicDiscVideoStreamMinBytes,
  int maxBytes = kMusicDiscVideoStreamMaxBytes,
}) => <String>[
  for (final MusicVideoFileStamp s in _discStreamStamps(
    home,
    seen: seen,
    minBytes: minBytes,
    maxBytes: maxBytes,
  ))
    s.path,
];

List<MusicVideoFileStamp> _discStreamStamps(
  Directory home, {
  Set<String>? seen,
  required int minBytes,
  required int maxBytes,
}) {
  final Set<String> visited = seen ?? <String>{};
  final List<Directory> roots = <Directory>[home];
  void addChildren(Directory d) {
    try {
      for (final FileSystemEntity e in d.listSync(followLinks: false)) {
        if (e is Directory) roots.add(e);
      }
    } on FileSystemException {
      return;
    }
  }

  addChildren(home);
  final Directory parent = home.parent;
  if (parent.path != home.path) {
    roots.add(parent);
    addChildren(parent);
  }
  final List<MusicVideoFileStamp> out = <MusicVideoFileStamp>[];
  final Set<String> seenRoots = <String>{};
  for (final Directory root in roots) {
    if (!seenRoots.add(p.normalize(root.path))) continue;
    final Directory stream = Directory(p.join(root.path, 'BDMV', 'STREAM'));
    if (!stream.existsSync()) continue;
    final List<MusicVideoFileStamp> files = <MusicVideoFileStamp>[];
    try {
      for (final FileSystemEntity e in stream.listSync(followLinks: false)) {
        if (e is! File) continue;
        if (p.extension(e.path).toLowerCase() != '.m2ts') continue;
        final MusicVideoFileStamp? s = _stampOf(e);
        if (s == null || s.size < minBytes || s.size > maxBytes) continue;
        files.add(s);
      }
    } on FileSystemException {
      continue;
    }
    files.sort(
      (MusicVideoFileStamp a, MusicVideoFileStamp b) =>
          b.size.compareTo(a.size),
    );
    for (final MusicVideoFileStamp f in files.take(
      kMusicDiscVideoStreamLimit,
    )) {
      if (visited.add(p.normalize(f.path))) out.add(f);
    }
  }
  return out;
}

/// MV 绑定对应的**本机视频文件**（背景播放 / 本地对齐用）：本地 MV 是绑定里的路径，
/// 动画集按视频库行解析到那一集的文件。YouTube 等网络 MV、文件已不在的返回 null。
Future<String?> resolveMusicVideoLocalFile(
  FushiDatabase db,
  MusicVideoRow row,
) async {
  switch (row.kind) {
    case MusicVideoKind.local:
      return await File(row.ref).exists() ? row.ref : null;
    case MusicVideoKind.animeEpisode:
      final ({String bookUid, int episodeIndex})? ref =
          parseAnimeEpisodeMusicVideoRef(row.ref);
      if (ref == null) return null;
      final VideoBookRow? book = await VideoBookRepository(
        db,
      ).getByBookUid(ref.bookUid);
      if (book == null) return null;
      for (final ({int index, String path}) f in themeSongFilesOf(book)) {
        if (f.index == ref.episodeIndex) {
          return await File(f.path).exists() ? f.path : null;
        }
      }
      return null;
  }
  return null;
}

class MusicVideoService {
  MusicVideoService({
    required this.database,
    ThemeSongDetector? detector,
    Future<List<YoutubeSearchHit>> Function(String query)? youtubeSearch,
    Future<String?> Function(String url)? youtubeAudioUrl,
    int Function()? clock,
    MusicVideoNearbyFiles Function(String dir)? nearby,
  }) : _detector = detector,
       _nearby = nearby ?? collectMusicVideoFilesNear,
       _youtubeSearch = youtubeSearch ?? searchYoutubeVideos,
       _youtubeAudioUrl = youtubeAudioUrl ?? _defaultYoutubeAudioUrl,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase database;
  final ThemeSongDetector? _detector;
  final Future<List<YoutubeSearchHit>> Function(String query) _youtubeSearch;
  final Future<String?> Function(String url) _youtubeAudioUrl;
  final int Function() _clock;

  /// 收集一个曲目目录附近的候选（真 app = [collectMusicVideoFilesNear]；测试注入替身）。
  final MusicVideoNearbyFiles Function(String dir) _nearby;

  ThemeSongDetector get _det => _detector ?? themeSongDetectorFor(database);

  static Future<String?> _defaultYoutubeAudioUrl(String url) async {
    final YoutubeResolvedSource s = await resolveYoutubeSource(
      url,
      withCaptions: false,
    );
    return s.audioStreamUrl ?? s.streamUrl;
  }

  /// 本地匹配（曲目详情「找本地 MV」）：文件名预筛 + 附近蓝光流 → 逐个声纹对齐 → 过门的
  /// **自动绑定**（偏移 = 对齐偏移）。手动触发不看「已对齐过」记录，全部重对（视频声纹
  /// 有落库缓存，没换过的文件不重解码）；对过的照样记下，后台匹配不再重复。
  Future<List<MusicLocalVideoMatch>> matchLocal(String trackUid) async {
    final MusicTrackRow? track = await database.getMusicTrack(trackUid);
    if (track == null) return const <MusicLocalVideoMatch>[];
    final List<MusicLocalVideoMatch> out = <MusicLocalVideoMatch>[];
    for (final ({MusicVideoFileStamp file, double score}) c
        in musicVideoCandidatesFor(
          _nearby(File(track.path).parent.path),
          title: track.title,
          artist: track.artistCredit,
        )) {
      final ({AudioFingerprintMatch? match, bool bound}) r = await alignLocal(
        track,
        c.file,
      );
      out.add(
        MusicLocalVideoMatch(
          path: c.file.path,
          nameScore: c.score,
          alignment: r.match,
        ),
      );
    }
    return out;
  }

  /// 曲目 [track] 与本机视频 [video] 做一次声纹对齐：过门就绑定（`is_user_bound` 不动），
  /// 无论对没对上都记一条「已对齐过」（按视频版本）。返回对齐结果与是否绑定了。
  Future<({AudioFingerprintMatch? match, bool bound})> alignLocal(
    MusicTrackRow track,
    MusicVideoFileStamp video,
  ) async {
    final AudioFingerprintMatch? m = await _det.mvAlignment(
      audio: ThemeSongSong.fromRow(track),
      mvPath: video.path,
    );
    final bool accept =
        m != null &&
        acceptMusicVideoAlignment(
          confidence: m.confidence,
          matched: m.haystackEnd - m.haystackStart,
          songDurationMs: track.durationMs,
        );
    if (accept) {
      await database.upsertMusicVideo(
        MusicVideosCompanion.insert(
          trackUid: track.trackUid,
          kind: MusicVideoKind.local,
          ref: video.path,
          offsetMs: Value<int>(m.offset.inMilliseconds),
          confidence: Value<double?>(m.confidence),
          updatedAt: _clock(),
        ),
      );
    }
    await database.putMusicVideoMatchCheck(
      trackUid: track.trackUid,
      videoPath: video.path,
      fileSizeBytes: video.size,
      fileModifiedAt: video.mtimeMs,
      checkedAt: _clock(),
    );
    return (match: m, bound: accept);
  }

  /// 在线候选：MusicBrainz `music video` 关系（刮削结论里存的）+ YouTube 高置信搜索结果。
  Future<List<MusicVideoCandidate>> onlineCandidates(String trackUid) async {
    final MusicTrackRow? track = await database.getMusicTrack(trackUid);
    if (track == null) return const <MusicVideoCandidate>[];
    final MusicScrapeMetaRow? meta = await database.getMusicScrapeMeta(
      trackUid,
    );
    final List<MusicVideoCandidate> out = <MusicVideoCandidate>[];
    final Set<String> seen = <String>{};
    final String? relJson = meta?.musicVideosJson;
    if (relJson != null) {
      for (final Object? e in jsonDecode(relJson) as List<Object?>) {
        if (e is! Map<String, Object?>) continue;
        final Object? url = e['url'];
        if (url is! String) continue;
        final String? id = youtubeVideoIdOrNull(url);
        if (id == null || !seen.add(id)) continue;
        out.add(
          MusicVideoCandidate(
            kind: MusicVideoKind.youtube,
            ref: 'https://www.youtube.com/watch?v=$id',
            title: e['title'] is String ? e['title']! as String : track.title,
            subtitle: 'MusicBrainz',
            confidence: 0.95,
          ),
        );
      }
    }
    final String title = meta?.title ?? track.title;
    final String? artist = meta?.artistCredit ?? track.artistCredit;
    final List<YoutubeSearchHit> hits = await _youtubeSearch(
      youtubeMusicVideoQuery(title: title, artist: artist),
    );
    final bool isCover =
        meta != null &&
        meta.selfIsOriginal == false &&
        meta.originalRecordingId != null &&
        meta.originalRecordingId != meta.mbRecordingId;
    for (final YoutubeSearchHit h in hits) {
      final YoutubeMusicVideoScore s = scoreYoutubeMusicVideo(
        h,
        title: title,
        artist: artist,
        songDurationMs: track.durationMs,
        songIsCover: isCover,
      );
      if (!s.highConfidence || !seen.add(h.videoId)) continue;
      out.add(
        MusicVideoCandidate(
          kind: MusicVideoKind.youtube,
          ref: h.url,
          title: h.title,
          subtitle: h.channelName,
          confidence: s.confidence,
        ),
      );
    }
    return out;
  }

  /// 动画 OP / ED 候选：作品图谱声纹识别出的每集出现位置（MV 时间 = 集时间，偏移 =
  /// 该集里歌的起点）。片名带 NCOP / NCED / ノンクレジット 的集排前（无字幕版优先）。
  Future<List<MusicVideoCandidate>> animeCandidates(String trackUid) async {
    final List<ThemeSongAppearance> list = await loadThemeSongAppearances(
      database,
      trackUid,
    );
    final List<MusicVideoCandidate> out = <MusicVideoCandidate>[];
    final RegExp creditless = RegExp(
      r'(nc\s*op|nc\s*ed|ncop|nced|creditless|ノンクレジット|clean\s*(opening|ending))',
      caseSensitive: false,
    );
    for (final ThemeSongAppearance a in list) {
      for (final ({ThemeSongEpisode episode, int startMs}) e in a.episodes) {
        out.add(
          MusicVideoCandidate(
            kind: MusicVideoKind.animeEpisode,
            ref: animeEpisodeMusicVideoRef(
              e.episode.bookUid,
              e.episode.episodeIndex,
            ),
            title: a.videoTitle,
            subtitle: '#${e.episode.episodeNumber}',
            offsetMs: e.startMs,
          ),
        );
      }
    }
    int rank(MusicVideoCandidate c) =>
        creditless.hasMatch('${c.title} ${p.basename(c.ref)}') ? 0 : 1;
    out.sort(
      (MusicVideoCandidate a, MusicVideoCandidate b) => rank(a) - rank(b),
    );
    return out;
  }

  /// 用户确认绑定一个候选。YouTube 会尝试取音频流做一次声纹对齐求偏移；取不到就按
  /// 候选自带的偏移（0）绑定，界面上可以 ±100 ms 微调。返回绑定后的行。
  Future<MusicVideoRow?> bind(
    String trackUid,
    MusicVideoCandidate c, {
    bool alignOnline = true,
  }) async {
    int offset = c.offsetMs;
    double? confidence = c.confidence;
    if (c.kind == MusicVideoKind.youtube && alignOnline) {
      final MusicTrackRow? track = await database.getMusicTrack(trackUid);
      if (track != null) {
        String? audio;
        try {
          audio = await _youtubeAudioUrl(c.ref);
        } on Exception {
          audio = null;
        }
        if (audio != null) {
          final AudioFingerprintMatch? m = await _det.mvAlignment(
            audio: ThemeSongSong.fromRow(track),
            mvPath: audio,
          );
          if (m != null) {
            offset = m.offset.inMilliseconds;
            confidence = m.confidence;
          }
        }
      }
    }
    await database.upsertMusicVideo(
      MusicVideosCompanion.insert(
        trackUid: trackUid,
        kind: c.kind,
        ref: c.ref,
        offsetMs: Value<int>(offset),
        confidence: Value<double?>(confidence),
        isUserBound: const Value<bool>(true),
        updatedAt: _clock(),
      ),
    );
    for (final MusicVideoRow r in await database.listMusicVideos(trackUid)) {
      if (r.kind == c.kind && r.ref == c.ref) return r;
    }
    return null;
  }

  /// 微调偏移（MV 页 ±100 ms）。
  Future<void> setOffset(MusicVideoRow row, int offsetMs) =>
      database.upsertMusicVideo(
        MusicVideosCompanion.insert(
          trackUid: row.trackUid,
          kind: row.kind,
          ref: row.ref,
          offsetMs: Value<int>(offsetMs),
          confidence: Value<double?>(row.confidence),
          isUserBound: const Value<bool>(true),
          updatedAt: _clock(),
        ),
      );
}

/// 显示用：MV 绑定的一句话来源（本地文件名 / YouTube / 动画集）。
String musicVideoRefLabel(MusicVideoRow row) => switch (row.kind) {
  MusicVideoKind.local => p.basename(row.ref),
  MusicVideoKind.youtube => youtubeVideoIdOrNull(row.ref) ?? row.ref,
  _ => row.ref,
};
