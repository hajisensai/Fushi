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
import 'package:fushi/src/media/links/theme_song/theme_song_detector.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_video_match.dart';
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

/// 列出曲目附近可能是 MV 的视频文件（同目录、同目录下的 MV 目录、上一级的 MV 目录），
/// 按文件名分数降序。纯 IO，不解码。
List<({String path, double score})> listLocalMusicVideoFiles(
  MusicTrackRow track, {
  int limit = 5,
}) {
  final Directory home = File(track.path).parent;
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
  final List<({String path, double score})> out =
      <({String path, double score})>[];
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
      final double s = scoreLocalMusicVideoName(
        p.basename(e.path),
        title: track.title,
        artist: track.artistCredit,
      );
      if (s > 0) out.add((path: e.path, score: s));
    }
  }
  out.sort(
    (({String path, double score}) a, ({String path, double score}) b) =>
        b.score.compareTo(a.score),
  );
  return out.take(limit).toList();
}

class MusicVideoService {
  MusicVideoService({
    required this.database,
    ThemeSongDetector? detector,
    Future<List<YoutubeSearchHit>> Function(String query)? youtubeSearch,
    Future<String?> Function(String url)? youtubeAudioUrl,
    int Function()? clock,
  }) : _detector = detector,
       _youtubeSearch = youtubeSearch ?? searchYoutubeVideos,
       _youtubeAudioUrl = youtubeAudioUrl ?? _defaultYoutubeAudioUrl,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase database;
  final ThemeSongDetector? _detector;
  final Future<List<YoutubeSearchHit>> Function(String query) _youtubeSearch;
  final Future<String?> Function(String url) _youtubeAudioUrl;
  final int Function() _clock;

  ThemeSongDetector get _det => _detector ?? themeSongDetectorFor(database);

  static Future<String?> _defaultYoutubeAudioUrl(String url) async {
    final YoutubeResolvedSource s = await resolveYoutubeSource(
      url,
      withCaptions: false,
    );
    return s.audioStreamUrl ?? s.streamUrl;
  }

  /// 本地匹配：文件名预筛 → 逐个声纹对齐 → 过门的**自动绑定**（偏移 = 对齐偏移）。
  Future<List<MusicLocalVideoMatch>> matchLocal(String trackUid) async {
    final MusicTrackRow? track = await database.getMusicTrack(trackUid);
    if (track == null) return const <MusicLocalVideoMatch>[];
    final ThemeSongSong song = ThemeSongSong.fromRow(track);
    final List<MusicLocalVideoMatch> out = <MusicLocalVideoMatch>[];
    for (final ({String path, double score}) c in listLocalMusicVideoFiles(
      track,
    )) {
      final AudioFingerprintMatch? m = await _det.mvAlignment(
        audio: song,
        mvPath: c.path,
      );
      out.add(
        MusicLocalVideoMatch(path: c.path, nameScore: c.score, alignment: m),
      );
      if (m != null &&
          acceptMusicVideoAlignment(
            confidence: m.confidence,
            matched: m.haystackEnd - m.haystackStart,
            songDurationMs: track.durationMs,
          )) {
        await database.upsertMusicVideo(
          MusicVideosCompanion.insert(
            trackUid: trackUid,
            kind: MusicVideoKind.local,
            ref: c.path,
            offsetMs: Value<int>(m.offset.inMilliseconds),
            confidence: Value<double?>(m.confidence),
            updatedAt: _clock(),
          ),
        );
      }
    }
    return out;
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
