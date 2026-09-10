import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_locked_fields.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_core/fushi_core.dart';

/// v99 字段锁：编解码前向兼容 + `apply()` 里「被锁字段一律保留旧值，其余照常更新」。
void main() {
  group('parseLockedFields / encodeLockedFields', () {
    test('NULL / 空串 / 全空白 = 无锁', () {
      expect(parseLockedFields(null), isEmpty);
      expect(parseLockedFields(''), isEmpty);
      expect(parseLockedFields('  ,  , '), isEmpty);
    });

    test('未知值静默忽略，认识的照收（前向兼容：新版本的锁在旧版本只是不生效）', () {
      expect(
        parseLockedFields('title, someFutureField ,overview,,TITLE'),
        <VideoMetadataLockableField>{
          VideoMetadataLockableField.title,
          VideoMetadataLockableField.overview,
        },
        reason: '大小写不同的 TITLE 不是合法 wire 值，不认',
      );
    });

    test('编码按枚举声明序，空集合编成 NULL（唯一的「无锁」形态）', () {
      expect(encodeLockedFields(<VideoMetadataLockableField>{}), isNull);
      expect(
        encodeLockedFields(<VideoMetadataLockableField>{
          VideoMetadataLockableField.cover,
          VideoMetadataLockableField.title,
          VideoMetadataLockableField.genres,
        }),
        'title,genres,cover',
      );
    });

    test('编解码往返稳定', () {
      const Set<VideoMetadataLockableField> fields =
          <VideoMetadataLockableField>{
        VideoMetadataLockableField.originalTitle,
        VideoMetadataLockableField.tagline,
        VideoMetadataLockableField.rating,
        VideoMetadataLockableField.backdrop,
      };
      expect(parseLockedFields(encodeLockedFields(fields)), fields);
    });
  });

  group('apply() 尊重字段锁', () {
    late FushiDatabase database;
    late VideoMetadataDatabaseStore store;
    late VideoSourceScrapeWork localWork;

    setUp(() async {
      database = FushiDatabase.forTesting(NativeDatabase.memory());
      store = VideoMetadataDatabaseStore(database);
      final int sourceId = await database.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Movies',
          mediaKind: 'video',
          rootPath: 'D:/Movies',
          createdAt: 1,
        ),
      );
      await database.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: const Value<String>('movie-1'),
          title: const Value<String>('Example Movie'),
          videoPath: const Value<String>('D:/Movies/Example Movie (2025).mkv'),
          sourceId: Value<int?>(sourceId),
        ),
      );
      final SourceLibraryRow source =
          (await database.getMediaSourceById(sourceId))!;
      final VideoBookRow book =
          (await database.getVideoBookByBookUid('movie-1'))!;
      localWork = VideoSourceScrapeWork(
        source: source,
        title: book.title,
        members: <VideoBookRow>[book],
      );
    });

    tearDown(() => database.close());

    VideoMetadataWork build({
      required String title,
      String? plot,
      String? tagline,
      String? originalTitle,
      double? rating,
      List<String> genres = const <String>[],
      List<String> studios = const <String>[],
      List<VideoMetadataImage> images = const <VideoMetadataImage>[],
    }) =>
        VideoMetadataWork(
          provider: VideoMetadataProviderKind.tmdb,
          kind: VideoMetadataMediaKind.movie,
          title: title,
          originalTitle: originalTitle,
          plot: plot,
          tagline: tagline,
          rating: rating,
          genres: genres,
          studios: studios,
          images: images,
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'tmdb', value: '42'),
          ],
        );

    test('锁住的标量保留旧值，没锁的照常被新刮结果更新', () async {
      final PersistedVideoMetadata first = await store.apply(
        localWork,
        build(
          title: '旧标题',
          plot: '旧简介',
          tagline: '旧标语',
          originalTitle: '旧原名',
          rating: 7.5,
        ),
      );
      await database.setVideoMetadataWorkLockedFields(
        first.workId,
        encodeLockedFields(<VideoMetadataLockableField>{
          VideoMetadataLockableField.overview,
          VideoMetadataLockableField.rating,
        }),
      );

      await store.apply(
        localWork,
        build(
          title: '新标题',
          plot: '新简介',
          tagline: '新标语',
          originalTitle: '新原名',
          rating: 9.9,
        ),
      );

      final VideoMetadataWorkRow row =
          (await database.getVideoMetadataWorkById(first.workId))!;
      expect(row.overview, '旧简介', reason: 'overview 被锁 = 刮到了也不写');
      expect(row.rating, 7.5, reason: 'rating 被锁');
      expect(row.title, '新标题', reason: '没锁的字段照常更新');
      expect(row.tagline, '新标语');
      expect(row.originalTitle, '新原名');
      expect(row.lockedFields, 'overview,rating',
          reason: 'locked_fields 列本身不因刮削被清空');
    });

    test('锁 genres 保留整组词，studios 没锁照常整体替换', () async {
      final PersistedVideoMetadata first = await store.apply(
        localWork,
        build(
          title: 'Example Movie',
          genres: const <String>['Drama', 'Romance'],
          studios: const <String>['Old Studio'],
        ),
      );
      await database.setVideoMetadataWorkLockedFields(
        first.workId,
        encodeLockedFields(
            <VideoMetadataLockableField>{VideoMetadataLockableField.genres}),
      );

      await store.apply(
        localWork,
        build(
          title: 'Example Movie',
          genres: const <String>['Horror'],
          studios: const <String>['New Studio'],
        ),
      );

      final List<VideoMetadataTermRow> terms =
          await database.getVideoMetadataTermsForWork(first.workId);
      expect(
        terms
            .where((VideoMetadataTermRow row) => row.kind == 'genre')
            .map((VideoMetadataTermRow row) => row.name)
            .toSet(),
        <String>{'Drama', 'Romance'},
        reason: 'genres 被锁 = 整组保留',
      );
      expect(
        terms
            .where((VideoMetadataTermRow row) => row.kind == 'studio')
            .map((VideoMetadataTermRow row) => row.name),
        <String>['New Studio'],
      );
    });

    test('锁 cover 时旧封面（含已下载的本地路径）不被换掉，backdrop 照常换', () async {
      const VideoMetadataImage oldCover = VideoMetadataImage(
        kind: VideoMetadataImageKind.cover,
        url: 'https://image.example/old-poster.jpg',
        provider: VideoMetadataProviderKind.tmdb,
      );
      const VideoMetadataImage oldBackdrop = VideoMetadataImage(
        kind: VideoMetadataImageKind.backdrop,
        url: 'https://image.example/old-backdrop.jpg',
        provider: VideoMetadataProviderKind.tmdb,
      );
      final PersistedVideoMetadata first = await store.apply(
        localWork,
        build(
          title: 'Example Movie',
          images: const <VideoMetadataImage>[oldCover, oldBackdrop],
        ),
      );
      await store.updateCanonicalImagePaths(
        persisted: first,
        metadata: build(
          title: 'Example Movie',
          images: const <VideoMetadataImage>[oldCover, oldBackdrop],
        ),
        localPathByRemoteUrl: const <String, String>{
          'https://image.example/old-poster.jpg': 'D:/Movies/old-poster.jpg',
        },
      );
      await database.setVideoMetadataWorkLockedFields(
        first.workId,
        encodeLockedFields(
            <VideoMetadataLockableField>{VideoMetadataLockableField.cover}),
      );

      final VideoMetadataWork rescraped = build(
        title: 'Example Movie',
        images: const <VideoMetadataImage>[
          VideoMetadataImage(
            kind: VideoMetadataImageKind.cover,
            url: 'https://image.example/new-poster.jpg',
            provider: VideoMetadataProviderKind.tmdb,
          ),
          VideoMetadataImage(
            kind: VideoMetadataImageKind.backdrop,
            url: 'https://image.example/new-backdrop.jpg',
            provider: VideoMetadataProviderKind.tmdb,
          ),
        ],
      );
      final PersistedVideoMetadata second =
          await store.apply(localWork, rescraped);
      // 第二步（下载落盘后重写图行）同样必须守住锁，否则第一步保住的封面白保。
      await store.updateCanonicalImagePaths(
        persisted: second,
        metadata: rescraped,
        localPathByRemoteUrl: const <String, String>{},
      );

      final List<VideoMetadataImageRow> images =
          await database.getVideoMetadataImages(workId: second.workId);
      final VideoMetadataImageRow cover = images
          .singleWhere((VideoMetadataImageRow row) => row.kind == 'cover');
      expect(cover.remoteUrl, 'https://image.example/old-poster.jpg');
      expect(cover.localPath, 'D:/Movies/old-poster.jpg',
          reason: '已下载的本地封面不能被重刮清掉');
      expect(
        images
            .singleWhere((VideoMetadataImageRow row) => row.kind == 'backdrop')
            .remoteUrl,
        'https://image.example/new-backdrop.jpg',
        reason: 'backdrop 没锁，照常换',
      );
    });

    test('无锁时行为与引入字段锁前完全一致', () async {
      final PersistedVideoMetadata first =
          await store.apply(localWork, build(title: '旧标题', plot: '旧简介'));
      expect((await database.getVideoMetadataWorkById(first.workId))!.title,
          '旧标题');

      await store.apply(localWork, build(title: '新标题', plot: '新简介'));
      final VideoMetadataWorkRow row =
          (await database.getVideoMetadataWorkById(first.workId))!;
      expect(row.title, '新标题');
      expect(row.overview, '新简介');
      expect(row.lockedFields, isNull);
    });
  });
}
