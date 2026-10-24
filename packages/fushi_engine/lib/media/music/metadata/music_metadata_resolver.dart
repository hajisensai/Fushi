/// 音乐识别器（音乐方案 §8.1 识别顺序）：
///
/// 1. 文件标签里已有 MBID → 直接取（[MusicIdentificationMethod.mbidTag]）；
/// 2. 标签精确查（艺人 + 标题 + 专辑 + 时长）→ **唯一**严格命中才算（[tagSearch]）；
/// 3. AcoustID 声纹 → 高分且唯一的录音（[acoustid]）；与第 2 步的歧义候选取交集；
/// 4. 都不行 → 未识别，把候选交给用户手选（[manual]）。
///
/// 与视频识别链同一判据（BUG-2268 的教训）：只在**唯一精确命中**时终止，歧义一律交给下一
/// 步或人工，不「取第一个」。
///
/// 识别之后的补全（录音详情、发行选择、封面、原曲、MV 关系、VGMdb）在
/// [MusicMetadataScraper]。纯 Dart、不碰 Flutter / 数据库：provider 与声纹来源都是注入的。
library;

import 'dart:async';

import 'package:fushi_engine/media/music/metadata/music_auxiliary_providers.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_provider.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_text.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart';
import 'package:fushi_engine/media/music/metadata/music_versions.dart';

/// 识别器看到的一首曲目（来自 `music_tracks` + 专辑行）。
class MusicTrackFacts {
  const MusicTrackFacts({
    required this.trackUid,
    required this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.durationMs,
    this.trackNo,
    this.discNo,
    this.mbRecordingIdTag,
    this.mbReleaseIdTag,
    this.catalogNo,
  });

  final String trackUid;
  final String title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? durationMs;
  final int? trackNo;
  final int? discNo;

  /// 标签里的 `MUSICBRAINZ_TRACKID`（录音 id）。
  final String? mbRecordingIdTag;
  final String? mbReleaseIdTag;
  final String? catalogNo;
}

/// 本机算出的 AcoustID 查询串（fpcalc 同形）+ 整首时长（秒）。算不出来返回 null。
typedef MusicFingerprintSource =
    Future<({String fingerprint, int durationSec})?> Function();

/// 一个候选录音及其得分。
class MusicRecordingCandidate {
  const MusicRecordingCandidate({
    required this.recording,
    required this.score,
    required this.titleScore,
    required this.artistScore,
    required this.durationScore,
    required this.albumScore,
    this.release,
    this.acoustidScore,
  });

  final MusicRecording recording;

  /// 0..1 综合分。
  final double score;
  final double titleScore;
  final double artistScore;

  /// 时长：≤3 s 1.0、≤7 s 0.6、≤15 s 0.3、更多 = 硬拒（不进候选）；未知 0.5。
  final double durationScore;

  /// 专辑：某张发行名与标签专辑相等 1.0（同时曲序也对上 1.0+）、不等 0.4、标签没写 0.5。
  final double albumScore;

  /// 与标签专辑最相符的那张发行。
  final MusicReleaseRef? release;
  final double? acoustidScore;

  /// 「严格命中」：标题与艺人都对得上、时长在 7 s 内（时长未知时要求专辑对上）。
  bool get strict =>
      titleScore >= 0.8 &&
      artistScore >= 0.8 &&
      (durationScore >= 0.6 || (durationScore == 0.5 && albumScore >= 1));
}

/// 一次识别的结论。
class MusicIdentification {
  const MusicIdentification({
    this.method,
    this.recordingId,
    this.confidence = 0,
    this.candidates = const <MusicRecordingCandidate>[],
    this.acoustid,
    this.acoustidUsed = false,
    this.acoustidSkippedReason,
    this.notes = const <String>[],
  });

  /// null = 未识别。
  final MusicIdentificationMethod? method;
  final String? recordingId;
  final double confidence;

  /// 未识别 / 歧义时交给用户手选的候选（按分数降序）。
  final List<MusicRecordingCandidate> candidates;
  final String? acoustid;

  /// 这次识别真的问过 AcoustID。
  final bool acoustidUsed;

  /// 没问 AcoustID 的原因（没配 key / key 被拒 / 声纹算不出）。
  final String? acoustidSkippedReason;

  /// 诊断信息（日志 / 抽样报告用）。
  final List<String> notes;

  bool get matched => method != null && recordingId != null;
}

/// 时长打分（毫秒）。返回 null = 差太多，硬拒。
double? musicDurationScore(int? a, int? b) {
  if (a == null || b == null || a <= 0 || b <= 0) return 0.5;
  final int d = (a - b).abs();
  if (d <= 3000) return 1;
  if (d <= 7000) return 0.6;
  if (d <= 15000) return 0.3;
  return null;
}

/// 给一条录音按标签打分。时长差太多返回 null（不进候选）。
MusicRecordingCandidate? scoreMusicRecording(
  MusicTrackFacts facts,
  MusicRecording r, {
  double? acoustidScore,
}) {
  final double title = musicTitleSimilarity(facts.title, r.title);
  final String? tagArtist = (facts.artist?.trim().isNotEmpty ?? false)
      ? facts.artist
      : facts.albumArtist;
  final double artist = (tagArtist == null || tagArtist.trim().isEmpty)
      ? 0.5
      : musicArtistSimilarity(tagArtist, <String>[
          r.artistCreditText,
          for (final MusicArtistCredit c in r.artistCredit) c.name,
          for (final MusicArtistCredit c in r.artistCredit)
            if (c.sortName != null) c.sortName!,
        ]);
  final double? duration = musicDurationScore(facts.durationMs, r.durationMs);
  if (duration == null) return null;
  double album = 0.5;
  MusicReleaseRef? best;
  final String? tagAlbum = facts.album?.trim();
  if (tagAlbum != null && tagAlbum.isNotEmpty) {
    album = 0.4;
    for (final MusicReleaseRef rel in r.releases) {
      final double s = musicTitleSimilarity(tagAlbum, rel.title);
      if (s < 0.8) continue;
      final bool trackOk =
          facts.trackNo != null && rel.trackPosition == facts.trackNo;
      final double v = trackOk ? 1.1 : (s >= 1 ? 1.0 : 0.85);
      if (v > album) {
        album = v;
        best = rel;
      }
    }
  }
  best ??= _preferredRelease(r.releases);
  final double score =
      (title * 0.4 +
              artist * 0.3 +
              duration * 0.15 +
              (album > 1 ? 1 : album) * 0.15 +
              (album > 1 ? 0.05 : 0))
          .clamp(0, 1)
          .toDouble();
  return MusicRecordingCandidate(
    recording: r,
    score: score,
    titleScore: title,
    artistScore: artist,
    durationScore: duration,
    albumScore: album,
    release: best,
    acoustidScore: acoustidScore,
  );
}

/// 没有专辑线索时的发行偏好：官方 > 其它；专辑 > 单曲 > 其它；早的在前。
MusicReleaseRef? _preferredRelease(List<MusicReleaseRef> releases) {
  if (releases.isEmpty) return null;
  int rank(MusicReleaseRef r) =>
      (r.status == 'Official' ? 0 : 10) +
      switch (r.primaryType) {
        'Album' => 0,
        'Single' => 1,
        'EP' => 2,
        _ => 3,
      } +
      (r.secondaryTypes.contains('Compilation') ? 4 : 0);
  final List<MusicReleaseRef> sorted = <MusicReleaseRef>[...releases]
    ..sort((MusicReleaseRef a, MusicReleaseRef b) {
      final int c = rank(a).compareTo(rank(b));
      if (c != 0) return c;
      return musicDateSortKey(a.date).compareTo(musicDateSortKey(b.date));
    });
  return sorted.first;
}

/// 两条候选是不是「同一首的重复录音实体」：MusicBrainz 偶尔给同一份音频建了两条录音
/// （没合并），标题 / 艺人 / 时长（±2 s）都一样。这种不算歧义。
bool _sameSong(MusicRecordingCandidate a, MusicRecordingCandidate b) {
  if (normalizeMusicText(a.recording.title) !=
      normalizeMusicText(b.recording.title)) {
    return false;
  }
  if (normalizeMusicText(a.recording.artistCreditText) !=
      normalizeMusicText(b.recording.artistCreditText)) {
    return false;
  }
  final int? da = a.recording.durationMs;
  final int? db = b.recording.durationMs;
  return da != null && db != null && (da - db).abs() <= 2000;
}

/// 从严格候选里挑唯一的那条；挑不出返回 null（歧义）。
MusicRecordingCandidate? pickUniqueMusicCandidate(
  List<MusicRecordingCandidate> strict,
) {
  if (strict.isEmpty) return null;
  final List<MusicRecordingCandidate> sorted = <MusicRecordingCandidate>[
    ...strict,
  ]..sort((MusicRecordingCandidate a, MusicRecordingCandidate b) =>
        b.score.compareTo(a.score));
  if (sorted.length == 1) return sorted.single;
  final MusicRecordingCandidate top = sorted.first;
  // 专辑 + 曲序都对上的只有一条：就是它。
  final List<MusicRecordingCandidate> pinned = <MusicRecordingCandidate>[
    for (final MusicRecordingCandidate c in sorted)
      if (c.albumScore > 1) c,
  ];
  if (pinned.length == 1) return pinned.single;
  // 第二名明显落后。
  if (top.score - sorted[1].score >= 0.1) return top;
  // 并列的都是同一首的重复实体：取分最高 / 发行最早的那条。
  final List<MusicRecordingCandidate> tied = <MusicRecordingCandidate>[
    for (final MusicRecordingCandidate c in sorted)
      if (top.score - c.score < 0.1) c,
  ];
  if (tied.every((MusicRecordingCandidate c) => _sameSong(c, top))) {
    tied.sort(
      (MusicRecordingCandidate a, MusicRecordingCandidate b) =>
          musicDateSortKey(
            a.recording.firstReleaseDate,
          ).compareTo(musicDateSortKey(b.recording.firstReleaseDate)),
    );
    return tied.first;
  }
  return null;
}

class MusicMetadataResolver {
  MusicMetadataResolver({required this.musicBrainz, this.acoustid});

  final MusicRecordingProvider musicBrainz;
  final MusicFingerprintProvider? acoustid;

  /// AcoustID 结果低于这个分数不认（AcoustID 官方建议 0.5 起；我们要「高置信」）。
  static const double minAcoustidScore = 0.8;

  Future<MusicIdentification> identify(
    MusicTrackFacts facts, {
    MusicFingerprintSource? fingerprint,
  }) async {
    final List<String> notes = <String>[];

    // 1. MBID 标签。
    final String? tagged = normalizeMusicBrainzId(facts.mbRecordingIdTag);
    if (tagged != null) {
      final MusicRecording? r = await musicBrainz.fetchRecording(tagged);
      if (r != null) {
        return MusicIdentification(
          method: MusicIdentificationMethod.mbidTag,
          recordingId: r.mbRecordingId,
          confidence: 1,
          notes: <String>['mbid tag'],
        );
      }
      notes.add('mbid tag $tagged not found on MusicBrainz');
    }

    // 2. 标签精确查。
    final List<MusicRecordingCandidate> searched = <MusicRecordingCandidate>[];
    if (facts.title.trim().isNotEmpty) {
      final List<MusicRecording> found = await musicBrainz.searchRecordings(
        MusicRecordingSearchQuery(
          title: stripMusicTitleAnnotations(facts.title),
          artist: (facts.artist?.trim().isNotEmpty ?? false)
              ? facts.artist
              : facts.albumArtist,
          album: facts.album,
          durationMs: facts.durationMs,
        ),
      );
      for (final MusicRecording r in found) {
        final MusicRecordingCandidate? c = scoreMusicRecording(facts, r);
        if (c != null) searched.add(c);
      }
      searched.sort((MusicRecordingCandidate a, MusicRecordingCandidate b) =>
          b.score.compareTo(a.score));
      final List<MusicRecordingCandidate> strict = <MusicRecordingCandidate>[
        for (final MusicRecordingCandidate c in searched)
          if (c.strict) c,
      ];
      final MusicRecordingCandidate? unique = pickUniqueMusicCandidate(strict);
      notes.add('tag search: ${found.length} results, ${strict.length} strict');
      if (unique != null) {
        return MusicIdentification(
          method: MusicIdentificationMethod.tagSearch,
          recordingId: unique.recording.mbRecordingId,
          confidence: unique.score,
          candidates: searched,
          notes: notes,
        );
      }
    }

    // 3. AcoustID。
    final MusicFingerprintProvider? fp = acoustid;
    String? skipped;
    if (fp == null || !fp.isAvailable) {
      skipped = fp?.unavailableReason ?? 'AcoustID not configured';
    } else if (fingerprint == null) {
      skipped = 'no fingerprint source';
    } else {
      final ({String fingerprint, int durationSec})? print = await fingerprint();
      if (print == null) {
        skipped = 'fingerprint could not be computed';
      } else {
        List<AcoustidResult> results;
        try {
          results = await fp.lookup(
            fingerprint: print.fingerprint,
            durationSec: print.durationSec,
          );
        } on AcoustidKeyRejected catch (e) {
          return MusicIdentification(
            candidates: searched,
            acoustidSkippedReason: 'AcoustID key rejected: ${e.message}',
            notes: notes,
          );
        }
        final List<AcoustidResult> good = <AcoustidResult>[
          for (final AcoustidResult r in results)
            if (r.score >= minAcoustidScore && r.recordingIds.isNotEmpty) r,
        ];
        notes.add('acoustid: ${results.length} results, ${good.length} good');
        if (good.isNotEmpty) {
          final AcoustidResult best = good.first;
          final Set<String> ids = best.recordingIds.toSet();
          // 与标签候选取交集：声纹簇常挂着同一首的多条录音（原版 / 重制 / 合辑重复实体），
          // 标签能把它收窄到一条。
          final List<MusicRecordingCandidate> both = <MusicRecordingCandidate>[
            for (final MusicRecordingCandidate c in searched)
              if (ids.contains(c.recording.mbRecordingId)) c,
          ];
          String? chosen;
          if (both.length == 1) {
            chosen = both.single.recording.mbRecordingId;
          } else if (both.length > 1) {
            chosen = pickUniqueMusicCandidate(both)?.recording.mbRecordingId;
          } else if (ids.length == 1) {
            chosen = ids.single;
          } else {
            // 簇里多条录音、标签又帮不上：逐条查详情按标签打分，严格且唯一才认。
            final List<MusicRecordingCandidate> scored =
                <MusicRecordingCandidate>[];
            for (final String id in ids.take(5)) {
              final MusicRecording? r = await musicBrainz.fetchRecording(id);
              if (r == null) continue;
              final MusicRecordingCandidate? c = scoreMusicRecording(
                facts,
                r,
                acoustidScore: best.score,
              );
              if (c != null) scored.add(c);
            }
            chosen = pickUniqueMusicCandidate(<MusicRecordingCandidate>[
              for (final MusicRecordingCandidate c in scored)
                if (c.titleScore >= 0.8) c,
            ])?.recording.mbRecordingId;
            searched.addAll(scored);
          }
          if (chosen != null) {
            return MusicIdentification(
              method: MusicIdentificationMethod.acoustid,
              recordingId: chosen,
              confidence: best.score,
              candidates: searched,
              acoustid: best.acoustid,
              acoustidUsed: true,
              notes: notes,
            );
          }
          return MusicIdentification(
            candidates: searched,
            acoustid: best.acoustid,
            acoustidUsed: true,
            notes: notes,
          );
        }
        return MusicIdentification(
          candidates: searched,
          acoustidUsed: true,
          notes: notes,
        );
      }
    }
    return MusicIdentification(
      candidates: searched,
      acoustidSkippedReason: skipped,
      notes: notes,
    );
  }
}

/// 一首识别 + 补全后的全部结论。
class MusicScrapeResult {
  const MusicScrapeResult({
    required this.identification,
    this.recording,
    this.release,
    this.cover,
    this.work,
    this.versions,
    this.vgmdb,
    this.musicVideos = const <MusicVideoReference>[],
    this.warnings = const <String>[],
  });

  final MusicIdentification identification;
  final MusicRecording? recording;

  /// 选中的发行（专辑页 / 封面 / 目录编号的来源）。
  final MusicReleaseRef? release;
  final MusicCoverImage? cover;
  final MusicWork? work;
  final MusicVersions? versions;
  final VgmdbAlbum? vgmdb;

  /// MusicBrainz 关系给出的 MV（视频录音的 URL 关系）。
  final List<MusicVideoReference> musicVideos;

  /// 补全阶段的非致命失败（某个源连不上）：识别结论照常落库。
  final List<String> warnings;
}

/// 一条在线 MV 线索（来自 MusicBrainz `music video` 关系）。
class MusicVideoReference {
  const MusicVideoReference({
    required this.url,
    required this.videoRecordingId,
    this.title,
  });

  final String url;
  final String videoRecordingId;
  final String? title;
}

/// 识别 + 补全编排。补全阶段每个源各自吞**网络类**失败成 warning（识别结论不因封面
/// 下不来作废）；编程错误照常抛。
class MusicMetadataScraper {
  MusicMetadataScraper({
    required this.resolver,
    this.covers,
    this.vgmdb,
    this.maxMusicVideoLookups = 3,
  });

  final MusicMetadataResolver resolver;
  final MusicCoverProvider? covers;
  final MusicAlbumCatalogProvider? vgmdb;
  final int maxMusicVideoLookups;

  /// 识别一首；[manualRecordingId] 给了就跳过识别（用户手选）。
  Future<MusicScrapeResult> scrape(
    MusicTrackFacts facts, {
    MusicFingerprintSource? fingerprint,
    String? manualRecordingId,
  }) async {
    final MusicIdentification id;
    final String? manual = normalizeMusicBrainzId(manualRecordingId);
    if (manual != null) {
      id = MusicIdentification(
        method: MusicIdentificationMethod.manual,
        recordingId: manual,
        confidence: 1,
      );
    } else {
      id = await resolver.identify(facts, fingerprint: fingerprint);
    }
    if (!id.matched) return MusicScrapeResult(identification: id);

    final List<String> warnings = <String>[];
    final MusicRecording? recording = await resolver.musicBrainz
        .fetchRecording(id.recordingId!);
    if (recording == null) {
      return MusicScrapeResult(
        identification: id,
        warnings: <String>['recording ${id.recordingId} not found'],
      );
    }
    final MusicReleaseRef? release =
        scoreMusicRecording(facts, recording)?.release ??
        _preferredRelease(recording.releases);

    MusicCoverImage? cover;
    final MusicCoverProvider? coverProvider = covers;
    if (release != null && coverProvider != null && coverProvider.isAvailable) {
      try {
        final List<MusicCoverImage> images = await coverProvider
            .fetchReleaseCovers(release.mbReleaseId);
        cover = images.where((MusicCoverImage i) => i.front).firstOrNull;
      } on Exception catch (e) {
        warnings.add('cover art: $e');
      }
    }

    MusicWork? work;
    MusicVersions? versions;
    final MusicWorkLink? workLink = recording.works.firstOrNull;
    if (workLink != null) {
      try {
        work = await resolver.musicBrainz.fetchWork(workLink.mbWorkId);
        if (work != null) {
          versions = resolveMusicVersions(work, recording.mbRecordingId);
        }
      } on Exception catch (e) {
        warnings.add('work: $e');
      }
    }

    final List<MusicVideoReference> videos = <MusicVideoReference>[];
    for (final String vid in recording.musicVideoRecordingIds.take(
      maxMusicVideoLookups,
    )) {
      try {
        final MusicRecording? v = await resolver.musicBrainz.fetchRecording(
          vid,
        );
        if (v == null) continue;
        for (final MusicUrlRelation u in v.urls) {
          if (isOnlineMusicVideoUrl(u.url)) {
            videos.add(
              MusicVideoReference(
                url: u.url,
                videoRecordingId: vid,
                title: v.title,
              ),
            );
          }
        }
      } on Exception catch (e) {
        warnings.add('music video $vid: $e');
      }
    }

    VgmdbAlbum? vgm;
    final MusicAlbumCatalogProvider? vgmProvider = vgmdb;
    final String? catalog =
        (facts.catalogNo?.trim().isNotEmpty ?? false)
        ? facts.catalogNo
        : release?.catalogNumbers.firstOrNull;
    if (vgmProvider != null && vgmProvider.isAvailable && catalog != null) {
      try {
        vgm = await vgmProvider.findAlbumByCatalog(catalog);
      } on Exception catch (e) {
        warnings.add('vgmdb: $e');
      }
    }

    return MusicScrapeResult(
      identification: id,
      recording: recording,
      release: release,
      cover: cover,
      work: work,
      versions: versions,
      vgmdb: vgm,
      musicVideos: videos,
      warnings: warnings,
    );
  }
}

/// 在线 MV 链接（目前只认 YouTube：五端都能解析播放，D5）。
bool isOnlineMusicVideoUrl(String url) {
  final Uri? u = Uri.tryParse(url);
  final String host = u?.host.toLowerCase() ?? '';
  return host == 'youtu.be' ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com');
}
