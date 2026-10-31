// BUG-3926：下载后缺字幕重试 / 刮削后补字幕按**库内刮削身份**搜字幕，刮削主源
// 是 TMDB 时身份里没有 AniList，Jimaku 按 TMDB 关联与 TMDB 长标题都搜不到条目，
// 字幕站明明有这一集也永远补不上；界面只报另一家来源的「超时」，把原因盖住。
//
// 钉三件事：
// 1. 合并规则（只补缺、冲突不合、TMDB 形态漂移不搬）；
// 2. 库内补字幕目标（重试 / 控制通道走的同一入口）带上产出该文件的下载任务确认的
//    AniList / MAL；
// 3. 零候选时逐来源说明原因，「没命中」不被别家的超时盖住。
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/library_video_subtitle_backfill.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/download_confirmed_identity.dart';
import 'package:fushi_engine/media/video/download/video_media_reference_codec.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

const String _path =
    'D:/video/凶乱令嬢ニア・リストン (2026)/Season 01/凶乱令嬢ニア・リストン (2026) - S01E04.mkv';

/// 实测用户库里的刮削结论：TMDB 主身份 + IMDb / TVDB，没有任何动画专库 id，
/// 标题是 TMDB 的长标题（中点是 U+2027）。
VideoMediaReference _scraped({int? anilistId}) => VideoMediaReference(
  providerId: 'tmdb',
  mediaId: '312850',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.tv,
  title: '凶乱令嬢ニア‧リストン 病弱令嬢に転生した神殺しの武人の華麗なる無双録',
  season: 1,
  episode: 4,
  tmdbId: 312850,
  imdbId: 'tt41296544',
  tvdbId: 473266,
  anilistId: anilistId,
  externalIds: <String, String>{
    'tmdb': '312850',
    'imdb': 'tt41296544',
    'tvdb': '473266',
    if (anilistId != null) 'anilist': '$anilistId',
  },
);

/// 订阅入队时确认的身份（AniList 主身份 + MAL 交叉引用）。
VideoMediaReference _confirmed({
  int anilistId = 206949,
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
  int? tmdbId,
}) => VideoMediaReference(
  providerId: 'anilist',
  mediaId: '$anilistId',
  mediaKind: kind,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: '凶乱令嬢ニア・リストン',
  aliases: const <String>[
    'Kyouran Reijou Nia Liston',
    'Nia Liston: The Merciless Maiden',
  ],
  year: 2026,
  anilistId: anilistId,
  tmdbId: tmdbId,
  externalIds: <String, String>{
    'anilist': '$anilistId',
    'mal': '63382',
    if (tmdbId != null) 'tmdb': '$tmdbId',
  },
);

void main() {
  group('mergeDownloadConfirmedIdentity', () {
    test('TMDB 刮削身份补上下载确认的 AniList / MAL 与标题，库内身份不变', () {
      final VideoMediaReference merged = mergeDownloadConfirmedIdentity(
        _scraped(),
        _confirmed(),
      );

      expect(merged.anilistId, 206949);
      expect(merged.externalIds['mal'], '63382');
      expect(merged.tmdbId, 312850);
      expect(merged.imdbId, 'tt41296544');
      expect(merged.tvdbId, 473266);
      expect(merged.providerId, 'tmdb');
      expect(merged.title, _scraped().title);
      expect(merged.season, 1);
      expect(merged.episode, 4);
      expect(merged.discoveryCategory, VideoDiscoveryCategory.anime);
      expect(
        merged.aliases,
        containsAll(<String>['凶乱令嬢ニア・リストン', 'Kyouran Reijou Nia Liston']),
      );
    });

    test('同一命名空间 id 冲突 = 不是同一部作品 → 原样返回刮削身份', () {
      final VideoMediaReference scraped = _scraped(anilistId: 1);
      expect(
        identical(
          mergeDownloadConfirmedIdentity(scraped, _confirmed()),
          scraped,
        ),
        isTrue,
      );
    });

    test('形态漂移（电影身份配剧集文件）不搬 TMDB id，其余照补', () {
      final VideoMediaReference merged = mergeDownloadConfirmedIdentity(
        VideoMediaReference(
          providerId: 'tvdb',
          mediaId: '473266',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.tv,
          title: 'x',
          tvdbId: 473266,
          externalIds: const <String, String>{'tvdb': '473266'},
        ),
        _confirmed(kind: VideoMetadataMediaKind.movie, tmdbId: 999),
      );
      expect(merged.tmdbId, isNull);
      expect(merged.externalIds.containsKey('tmdb'), isFalse);
      expect(merged.anilistId, 206949);
    });
  });

  group('库内补字幕目标带上下载确认身份', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<VideoBookRow> seedLibrary() async {
      const String uid = 'video/凶乱令嬢ニア・リストン (2026) - S01E04';
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(bookUid: uid, title: uid, videoPath: _path),
      );
      final int workId = await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          mediaType: 'tv',
          title: _scraped().title,
          bookUid: const Value<String?>(uid),
          year: const Value<int?>(2026),
          updatedAt: 0,
        ),
      );
      await db.replaceVideoMetadataProviderIdentities(
        workId: workId,
        identities: <VideoMetadataProviderIdentitiesCompanion>[
          for (final (String provider, String id, bool primary)
              in <(String, String, bool)>[
                ('tmdb', '312850', true),
                ('imdb', 'tt41296544', false),
                ('tvdb', '473266', false),
              ])
            VideoMetadataProviderIdentitiesCompanion.insert(
              identityKey: 'work:$workId:$provider',
              workId: Value<int?>(workId),
              provider: provider,
              externalId: id,
              isPrimary: Value<bool>(primary),
              updatedAt: 0,
            ),
        ],
      );
      return (await db.getVideoBookByBookUid(uid))!;
    }

    Future<void> seedJob(String jobId, VideoMediaReference identity) async {
      await db.upsertVideoDownloadJob(
        VideoDownloadJobsCompanion.insert(
          jobId: jobId,
          resourceProvider: 'nyaa:nyaa.si',
          selectedResourceId: jobId,
          metadataProvider: Value<String?>(identity.providerId),
          externalId: Value<String?>(identity.mediaId),
          identityJson: Value<String?>(encodeVideoMediaReference(identity)),
          mediaKind: VideoMetadataMediaKind.tv.name,
          discoveryCategory: const Value<String?>('anime'),
          title: '凶乱令嬢ニア・リストン',
          season: const Value<int?>(1),
          backendKind: 'embedded',
          fingerprint: 'fp',
          lifecycle: const Value<String>(VideoDownloadJobLifecycle.completed),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await db.upsertVideoDownloadJobFile(
        VideoDownloadJobFilesCompanion.insert(
          jobId: jobId,
          backendFileIndex: const Value<int?>(0),
          originalRelativePath:
              '[SubsPlease] Kyouran Reijou Nia Liston - 04 (1080p) [1A604A90].mkv',
          currentRelativePath: 'S01E04.mkv',
          // 任务行记的是 Windows 反斜杠路径，库里是正斜杠：按规范化路径认。
          finalAbsolutePath: Value<String?>(_path.replaceAll('/', r'\')),
          kind: const Value<String>('video'),
          status: const Value<String>(VideoDownloadJobFileStatus.imported),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
    }

    test('TMDB 刮削的作品 + 订阅下载的文件 → 目标身份带 AniList 206949', () async {
      final VideoBookRow book = await seedLibrary();
      await seedJob('job-ep4', _confirmed());

      final SubtitleBackfillTarget target = (await libraryVideoSubtitleTarget(
        db,
        book,
      )).target!;

      expect(target.media.anilistId, 206949);
      expect(target.media.externalIds['mal'], '63382');
      expect(target.media.tmdbId, 312850);
      expect(target.media.episode, 4);
    });

    test('不是下载来的文件 → 身份照旧只有刮削结论', () async {
      final VideoBookRow book = await seedLibrary();

      final SubtitleBackfillTarget target = (await libraryVideoSubtitleTarget(
        db,
        book,
      )).target!;

      expect(target.media.anilistId, isNull);
      expect(target.media.tmdbId, 312850);
    });

    test('同一文件两条任务确认了互不相干的作品 → 不替它选', () async {
      final VideoBookRow book = await seedLibrary();
      await seedJob('job-a', _confirmed());
      await seedJob(
        'job-b',
        VideoMediaReference(
          providerId: 'anilist',
          mediaId: '1',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.anime,
          title: 'other',
          anilistId: 1,
          externalIds: const <String, String>{'anilist': '1', 'mal': '2'},
        ),
      );

      expect(await downloadConfirmedReferenceForVideoPath(db, _path), isNull);
      final SubtitleBackfillTarget target = (await libraryVideoSubtitleTarget(
        db,
        book,
      )).target!;
      expect(target.media.anilistId, isNull);
    });
  });

  test('零候选时逐来源说明：Jimaku 没命中不被别家的超时盖住', () async {
    final VideoSubtitleRegistry registry =
        VideoSubtitleRegistry(<VideoSubtitleProvider>[
          _Provider(
            'jimaku',
            () async => ProviderBatchResult<VideoSubtitleCandidate>.success(
              const <VideoSubtitleCandidate>[],
            ),
          ),
          _Provider('opensubtitles', () async => throw TimeoutException('t')),
        ]);

    final ProviderBatchResult<VideoSubtitleCandidate> result = await registry
        .search(VideoSubtitleSearchRequest(media: _scraped()));

    expect(result.items, isEmpty);
    expect(
      registry.describeEmptySearch(result),
      'jimaku: no match; opensubtitles: provider request timed out',
    );
  });
}

final class _Provider implements VideoSubtitleProvider {
  _Provider(this.id, this._search);

  @override
  final String id;
  final Future<ProviderBatchResult<VideoSubtitleCandidate>> Function() _search;

  @override
  int get priority => 0;

  @override
  bool get allowsFreeProbeDownload => false;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) => _search();

  @override
  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate) =>
      throw UnimplementedError();

  @override
  void close() {}
}
