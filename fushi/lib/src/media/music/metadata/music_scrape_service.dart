/// 音乐刮削的 app 侧装配（音乐方案 §8.1）：曲库行 → [MusicTrackFacts] → 引擎识别器
/// （`packages/fushi_engine/lib/media/music/metadata/`）→ 落库（v133 刮削三表 + 专辑封面）。
///
/// - 声纹：统一 FFmpeg 解前 120 s 成 11025 Hz 单声道 s16（与 `fpcalc` 同一默认长度），
///   后台 isolate 里经 native/fushi_music 算声纹并编码成 AcoustID 查询串——只有这个串和
///   时长出本机；
/// - 出站：provider 全部经 `createAppHttpIoClient`（全应用代理装配）；
/// - 文件标签不动：显示列仍是标签镜像，刮到的值经「写回文件标签」显式落进文件
///   （[MusicTagWriteback]）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/media/links/theme_song/theme_song_detector.dart'
    show
        FfmpegThemeSongAudioDecoder,
        ThemeSongAudioDecoder,
        ThemeSongDecodeException;
import 'package:fushi/src/media/music/acoustid_secret.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_auxiliary_providers.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_resolver.dart';
import 'package:fushi_engine/media/music/metadata/music_versions.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

/// AcoustID key 的生效值：用户在设置里填的优先，没填用随包的应用 key
/// （[kBuiltinAcoustidApiKey]，CI 从仓库 secret 注入、入库是空占位）；两者都空 = 不可用。
String resolveMusicAcoustidApiKey(
  String userKey, {
  String builtinKey = kBuiltinAcoustidApiKey,
}) {
  final String user = userKey.trim();
  return user.isNotEmpty ? user : builtinKey.trim();
}

/// 这个包是否随带了 AcoustID 应用 key（设置页文案用）。
bool get musicAcoustidBuiltinKeyAvailable =>
    kBuiltinAcoustidApiKey.trim().isNotEmpty;

/// 刮削器版本：识别判据 / 落库形态变了就升，曲库「识别全部」会重刮旧版本的结论。
const int kMusicScraperVersion = 1;

/// AcoustID 默认取的声纹长度（与 `fpcalc -length` 默认值一致）。
const Duration kMusicAcoustidFingerprintLength = Duration(seconds: 120);

/// `music_scrape_meta.status` 值域。
abstract final class MusicScrapeStatus {
  static const String matched = 'matched';
  static const String unmatched = 'unmatched';
  static const String error = 'error';
}

/// 一次刮削调用的 provider 组。[sink] 收集原始响应（落快照表）。
typedef MusicScraperFactory =
    MusicMetadataScraper Function({
      required MusicRawResponseSink sink,
      required String acoustidApiKey,
      required bool vgmdbEnabled,
    });

/// 默认 provider 组：MusicBrainz 主源 + AcoustID（有 key 才可用）+ CAA + VGMdb（开关）。
MusicMetadataScraper defaultMusicScraper({
  required MusicRawResponseSink sink,
  required String acoustidApiKey,
  required bool vgmdbEnabled,
}) {
  final MusicBrainzProvider mb = MusicBrainzProvider(onRawResponse: sink);
  return MusicMetadataScraper(
    resolver: MusicMetadataResolver(
      musicBrainz: mb,
      acoustid: AcoustidProvider(apiKey: acoustidApiKey, onRawResponse: sink),
    ),
    covers: CoverArtArchiveProvider(onRawResponse: sink),
    vgmdb: VgmdbProvider(enabled: vgmdbEnabled, onRawResponse: sink),
  );
}

/// 曲目 → AcoustID 查询串 + 时长（秒）。算不出返回 null（解码失败）。
typedef MusicAcoustidFingerprinter =
    Future<({String fingerprint, int durationSec})?> Function(
      MusicTrackRow track,
    );

/// 默认声纹：统一 FFmpeg 解前 120 s → 后台 isolate 算声纹 + 编码。
MusicAcoustidFingerprinter defaultMusicAcoustidFingerprinter({
  ThemeSongAudioDecoder decoder = const FfmpegThemeSongAudioDecoder(),
}) => (MusicTrackRow track) async {
  final int? durationMs = track.durationMs;
  if (durationMs == null || durationMs <= 0) return null;
  final Directory dir = Directory(
    p.join(Directory.systemTemp.path, 'fushi_music_acoustid'),
  );
  if (!dir.existsSync()) await dir.create(recursive: true);
  final String raw = p.join(
    dir.path,
    'fp_${track.trackUid.hashCode.toUnsigned(32)}.s16le',
  );
  try {
    await decoder.decodeToRawPcm(
      input: track.path,
      output: raw,
      startMs: track.cueStartMs,
      durationMs: durationMs < kMusicAcoustidFingerprintLength.inMilliseconds
          ? durationMs
          : kMusicAcoustidFingerprintLength.inMilliseconds,
    );
    final String encoded = await Isolate.run(() {
      final AudioFingerprinter fp = AudioFingerprinter.instance;
      final Uint32List print = fp.computeRawPcmFile(raw);
      return fp.acoustidEncode(print);
    }, debugName: 'music-acoustid-fingerprint');
    if (encoded.isEmpty) return null;
    return (fingerprint: encoded, durationSec: (durationMs / 1000).round());
  } on ThemeSongDecodeException {
    return null;
  } finally {
    final File f = File(raw);
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } on FileSystemException {
        // 被占用留给系统临时目录清理；不影响结论。
      }
    }
  }
};

/// 一首刮完的结局（界面提示用）。
class MusicScrapeOutcome {
  const MusicScrapeOutcome({required this.status, this.result, this.error});

  final String status;
  final MusicScrapeResult? result;
  final Object? error;

  bool get matched => status == MusicScrapeStatus.matched;
}

/// 曲库批量刮削的统计。
class MusicLibraryScrapeReport {
  int total = 0;
  int matched = 0;
  int unmatched = 0;
  int failed = 0;
  final Map<String, int> byMethod = <String, int>{};

  @override
  String toString() =>
      'MusicLibraryScrapeReport(total: $total, matched: $matched, '
      'unmatched: $unmatched, failed: $failed, byMethod: $byMethod)';
}

/// 识别结论 → `music_scrape_meta` 行（纯函数，测试钉死）。
MusicScrapeMetaCompanion musicScrapeMetaOf({
  required String trackUid,
  required MusicScrapeResult result,
  required int scrapedAt,
}) {
  final MusicIdentification id = result.identification;
  final MusicRecording? r = result.recording;
  final MusicReleaseRef? rel = result.release;
  final MusicVersions? v = result.versions;
  final MusicWorkRecording? original = v?.original;
  final bool matched = id.matched && r != null;
  final List<String> warnings = <String>[
    ...result.warnings,
    if (id.acoustidSkippedReason != null)
      'acoustid: ${id.acoustidSkippedReason}',
  ];
  String? json(Object? o) => o == null ? null : jsonEncode(o);
  return MusicScrapeMetaCompanion.insert(
    trackUid: trackUid,
    status: matched ? MusicScrapeStatus.matched : MusicScrapeStatus.unmatched,
    method: Value<String?>(matched ? id.method?.wire : null),
    mbRecordingId: Value<String?>(matched ? r.mbRecordingId : null),
    mbReleaseId: Value<String?>(rel?.mbReleaseId),
    mbReleaseGroupId: Value<String?>(rel?.releaseGroupId),
    mbWorkId: Value<String?>(r?.works.firstOrNull?.mbWorkId),
    mbArtistId: Value<String?>(r?.artistCredit.firstOrNull?.mbArtistId),
    acoustid: Value<String?>(id.acoustid),
    confidence: Value<double?>(matched ? id.confidence : null),
    title: Value<String?>(r?.title),
    artistCredit: Value<String?>(
      (r?.artistCreditText.isNotEmpty ?? false) ? r!.artistCreditText : null,
    ),
    albumTitle: Value<String?>(rel?.title),
    albumArtistCredit: Value<String?>(
      rel == null || rel.artistCredit.isEmpty
          ? null
          : musicArtistCreditText(rel.artistCredit),
    ),
    releaseDate: Value<String?>(rel?.date ?? r?.firstReleaseDate),
    catalogNo: Value<String?>(rel?.catalogNumbers.firstOrNull),
    trackNo: Value<int?>(rel?.trackPosition),
    discNo: Value<int?>(rel?.discPosition),
    originalRecordingId: Value<String?>(original?.mbRecordingId),
    originalTitle: Value<String?>(original?.title),
    originalArtistCredit: Value<String?>(original?.artistCreditText),
    originalReleaseDate: Value<String?>(original?.firstReleaseDate),
    selfIsOriginal: Value<bool>(v?.selfIsOriginal ?? false),
    versionsJson: Value<String?>(
      v == null
          ? null
          : json(<Object?>[
              for (final MusicWorkRecording o in v.others)
                <String, Object?>{
                  'id': o.mbRecordingId,
                  'title': o.title,
                  'artist': o.artistCreditText,
                  'date': o.firstReleaseDate,
                  'attrs': o.attributes,
                },
            ]),
    ),
    musicVideosJson: Value<String?>(
      result.musicVideos.isEmpty
          ? null
          : json(<Object?>[
              for (final MusicVideoReference m in result.musicVideos)
                <String, Object?>{
                  'url': m.url,
                  'videoRecordingId': m.videoRecordingId,
                  'title': m.title,
                },
            ]),
    ),
    coverUrl: Value<String?>(result.cover?.displayUrl),
    vgmdbJson: Value<String?>(
      result.vgmdb == null
          ? null
          : json(<String, Object?>{
              'id': result.vgmdb!.id,
              'link': result.vgmdb!.link,
              'catalog': result.vgmdb!.catalog,
              'names': result.vgmdb!.names,
            }),
    ),
    candidatesJson: Value<String?>(
      matched || id.candidates.isEmpty
          ? null
          : json(<Object?>[
              for (final MusicRecordingCandidate c in id.candidates.take(10))
                <String, Object?>{
                  'id': c.recording.mbRecordingId,
                  'title': c.recording.title,
                  'artist': c.recording.artistCreditText,
                  'lengthMs': c.recording.durationMs,
                  'release': c.release?.title,
                  'date': c.release?.date ?? c.recording.firstReleaseDate,
                  'score': double.parse(c.score.toStringAsFixed(3)),
                },
            ]),
    ),
    warnings: Value<String?>(warnings.isEmpty ? null : warnings.join('\n')),
    scraperVersion: kMusicScraperVersion,
    scrapedAt: scrapedAt,
  );
}

/// 曲库行 + 专辑行 → 识别器输入。
MusicTrackFacts musicTrackFactsOf(
  MusicTrackRow t,
  MusicAlbumRow? album, {
  bool ignoreRecordingTag = false,
}) => MusicTrackFacts(
  trackUid: t.trackUid,
  title: t.title,
  artist: t.artistCredit,
  album: album?.title,
  albumArtist: album?.albumArtistCredit,
  durationMs: t.durationMs,
  trackNo: t.trackNo,
  discNo: t.discNo,
  mbRecordingIdTag: ignoreRecordingTag ? null : t.mbRecordingId,
  mbReleaseIdTag: album?.mbReleaseId,
  catalogNo: album?.catalogNo,
);

class MusicScrapeService {
  MusicScrapeService({
    required FushiDatabase? Function() database,
    required String Function() acoustidApiKey,
    required bool Function() vgmdbEnabled,
    MusicScraperFactory? scraperFactory,
    MusicAcoustidFingerprinter? fingerprinter,
    Future<Directory> Function()? coverDirectory,
    int Function()? clock,
  }) : _database = database,
       _acoustidApiKey = acoustidApiKey,
       _vgmdbEnabled = vgmdbEnabled,
       _scraperFactory = scraperFactory ?? defaultMusicScraper,
       _fingerprinter = fingerprinter ?? defaultMusicAcoustidFingerprinter(),
       _coverDirectory = coverDirectory ?? AppPaths.musicCoversDirectory,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase? Function() _database;
  final String Function() _acoustidApiKey;
  final bool Function() _vgmdbEnabled;
  final MusicScraperFactory _scraperFactory;
  final MusicAcoustidFingerprinter _fingerprinter;
  final Future<Directory> Function() _coverDirectory;
  final int Function() _clock;

  /// AcoustID 有没有配 key（设置页 / 曲目页说明用）。
  bool get acoustidConfigured => _acoustidApiKey().trim().isNotEmpty;

  Future<void> _tail = Future<void>.value();

  /// 串行：MusicBrainz 每 IP 1 req/s，并发刮多首只会在闸门上排队，还会把界面里
  /// 「正在识别」的状态搅乱。
  Future<T> _serial<T>(Future<T> Function() body) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await body());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// 识别一首并落库。[manualRecordingId] = 用户手选 / 手填的录音 MBID。
  Future<MusicScrapeOutcome> scrapeTrack(
    String trackUid, {
    String? manualRecordingId,
  }) => _serial(() => _scrapeTrack(trackUid, manualRecordingId));

  Future<MusicScrapeOutcome> _scrapeTrack(
    String trackUid,
    String? manualRecordingId,
  ) async {
    final FushiDatabase? db = _database();
    if (db == null) {
      return const MusicScrapeOutcome(status: MusicScrapeStatus.error);
    }
    final MusicTrackRow? track = await db.getMusicTrack(trackUid);
    if (track == null) {
      return const MusicScrapeOutcome(status: MusicScrapeStatus.error);
    }
    final String? albumUid = track.albumUid;
    final MusicAlbumRow? album = albumUid == null
        ? null
        : await db.getMusicAlbum(albumUid);
    final int now = _clock();
    final List<MusicMetadataRawSnapshotsCompanion> snapshots =
        <MusicMetadataRawSnapshotsCompanion>[];
    void sink({
      required MusicMetadataProviderKind provider,
      required String kind,
      required String externalId,
      required String rawJson,
    }) {
      snapshots.add(
        MusicMetadataRawSnapshotsCompanion.insert(
          provider: provider.wire,
          snapshotKind: kind,
          externalId: externalId,
          rawJson: rawJson,
          fetchedAt: now,
        ),
      );
    }

    final MusicMetadataScraper scraper = _scraperFactory(
      sink: sink,
      acoustidApiKey: _acoustidApiKey(),
      vgmdbEnabled: _vgmdbEnabled(),
    );
    final MusicScrapeResult result;
    try {
      // `music_tracks.mb_recording_id` 可能是上一次识别叠加上去的（不是文件标签）：重新
      // 识别时不能把它当「MBID 标签」直取，否则手选 / 搜到的结论永远自我确认。
      final MusicScrapeMetaRow? prev = await db.getMusicScrapeMeta(trackUid);
      final bool overlaid =
          prev != null &&
          prev.method != MusicIdentificationMethod.mbidTag.wire &&
          prev.mbRecordingId != null &&
          prev.mbRecordingId == track.mbRecordingId;
      result = await scraper.scrape(
        musicTrackFactsOf(track, album, ignoreRecordingTag: overlaid),
        manualRecordingId: manualRecordingId,
        fingerprint: () => _fingerprinter(track),
      );
    } on Exception catch (e) {
      scraper.close();
      // 资料源整体连不上（主源失败）：记一行 error，不覆盖已有的成功结论。
      final MusicScrapeMetaRow? prev = await db.getMusicScrapeMeta(trackUid);
      if (prev == null || prev.status != MusicScrapeStatus.matched) {
        await db.writeMusicScrapeResult(
          meta: MusicScrapeMetaCompanion.insert(
            trackUid: trackUid,
            status: MusicScrapeStatus.error,
            warnings: Value<String?>('$e'),
            scraperVersion: kMusicScraperVersion,
            scrapedAt: now,
          ),
        );
      }
      return MusicScrapeOutcome(status: MusicScrapeStatus.error, error: e);
    }
    scraper.close();
    final MusicScrapeMetaCompanion meta = musicScrapeMetaOf(
      trackUid: trackUid,
      result: result,
      scrapedAt: now,
    );
    await db.writeMusicScrapeResult(meta: meta, snapshots: snapshots);
    if (album != null && album.coverPath == null) {
      await _maybeDownloadCover(db, album, result);
    }
    return MusicScrapeOutcome(status: meta.status.value, result: result);
  }

  /// 专辑没有目录封面、封面没上锁、CAA 有正面图 → 下到 `<documents>/music_covers`。
  Future<void> _maybeDownloadCover(
    FushiDatabase db,
    MusicAlbumRow album,
    MusicScrapeResult result,
  ) async {
    final MusicCoverImage? cover = result.cover;
    final String? releaseId = result.release?.mbReleaseId;
    if (cover == null || releaseId == null) return;
    final Set<String> locks = await db.listMusicLockedFields(
      entityKind: 'album',
      entityUid: album.albumUid,
    );
    if (locks.contains('cover')) return;
    final CoverArtArchiveProvider caa = CoverArtArchiveProvider();
    try {
      final List<int> bytes = await caa.download(cover.displayUrl);
      if (bytes.isEmpty) return;
      final Directory dir = await _coverDirectory();
      if (!dir.existsSync()) await dir.create(recursive: true);
      final File file = File(p.join(dir.path, '$releaseId.jpg'));
      await file.writeAsBytes(bytes, flush: true);
      await db.setMusicAlbumScrapedCover(
        albumUid: album.albumUid,
        coverPath: file.path,
        updatedAt: _clock(),
      );
    } on Exception {
      // 封面下不来不影响识别结论；下次重刮再试（meta 里已记 coverUrl）。
      return;
    } finally {
      caa.close();
    }
  }

  /// 识别曲库里没有结论（或结论版本旧）的全部曲目。串行、遵守 1 req/s。
  Future<MusicLibraryScrapeReport> scrapeLibrary({
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final MusicLibraryScrapeReport report = MusicLibraryScrapeReport();
    final FushiDatabase? db = _database();
    if (db == null) return report;
    final List<MusicTrackRow> todo = await db.listMusicTracksNeedingScrape(
      olderThanVersion: kMusicScraperVersion,
    );
    report.total = todo.length;
    for (int i = 0; i < todo.length; i++) {
      if (cancelled?.call() ?? false) break;
      final MusicScrapeOutcome o = await scrapeTrack(todo[i].trackUid);
      switch (o.status) {
        case MusicScrapeStatus.matched:
          report.matched++;
          final String m = o.result?.identification.method?.wire ?? '?';
          report.byMethod[m] = (report.byMethod[m] ?? 0) + 1;
        case MusicScrapeStatus.unmatched:
          report.unmatched++;
        default:
          report.failed++;
      }
      onProgress?.call(i + 1, todo.length);
    }
    return report;
  }
}
