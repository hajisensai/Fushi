import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/banner/banner_picker_sheet.dart';
import 'package:fushi/src/media/banner/video_banner_sources.dart';
import 'package:fushi/src/media/video/cover_ui/video_series_meta.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/media_image_user_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:path/path.dart' as p;

/// 视频作品「横幅…」：在线 = 已存的全部刮削背景 + TMDB 现拉的背景（去重）；片中 =
/// 盘上的分集画面（只留横版）；写入走 `media_images` 用户口径（v184 来源锁）；读侧
/// 系列色块里用户选的那张压过刮削背景。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cache;
  setUpAll(() async {
    // 远程候选的预览是 AppCachedHttpImage，构造即起磁盘缓存管理器，要 path_provider 应答。
    cache = await Directory.systemTemp.createTemp('video_banner_cache_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => cache.path,
        );
  });
  tearDownAll(() => cache.delete(recursive: true));

  late FushiDatabase db;
  late Directory dir;
  late int collectionId;
  late int workId;

  /// 只有文件头的 PNG（探针只读 IHDR 里的宽高）。
  Uint8List pngHeader(int width, int height) {
    final ByteData data = ByteData(33);
    const List<int> sig = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (int i = 0; i < sig.length; i++) {
      data.setUint8(i, sig[i]);
    }
    data.setUint32(8, 13);
    const List<int> ihdr = <int>[0x49, 0x48, 0x44, 0x52];
    for (int i = 0; i < 4; i++) {
      data.setUint8(12 + i, ihdr[i]);
    }
    data.setUint32(16, width);
    data.setUint32(20, height);
    return data.buffer.asUint8List();
  }

  String png(String name, int w, int h) {
    final File f = File(p.join(dir.path, name))
      ..writeAsBytesSync(pngHeader(w, h));
    return f.path;
  }

  // 最小 GIF（写侧判据只查 "GIF8" 头）。
  File gif(String name) => File(p.join(dir.path, name))
    ..writeAsBytesSync(<int>[
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0, 0, 0x3B, //
    ]);

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('video_banner_');
    collectionId = await db.createMediaCollection('Show');
    workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Show',
        updatedAt: 1,
      ),
    );
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  VideoMetadataImagesCompanion workImage(
    String kind,
    int position,
    String url, {
    String? localPath,
    int? width,
    int? height,
    String? language,
  }) => VideoMetadataImagesCompanion.insert(
    workId: Value<int?>(workId),
    provider: 'tmdb',
    kind: kind,
    position: Value<int>(position),
    remoteUrl: url,
    localPath: Value<String?>(localPath),
    width: Value<int?>(width),
    height: Value<int?>(height),
    language: Value<String?>(language),
    updatedAt: 1,
  );

  Future<void> addTmdbIdentity() => db.replaceVideoMetadataProviderIdentities(
    workId: workId,
    identities: <VideoMetadataProviderIdentitiesCompanion>[
      VideoMetadataProviderIdentitiesCompanion.insert(
        identityKey: 'work:$workId:tmdb',
        workId: Value<int?>(workId),
        provider: 'tmdb',
        externalId: '1399',
        isPrimary: const Value<bool>(true),
        updatedAt: 1,
      ),
    ],
  );

  MediaImageOwner owner() => MediaImageOwner.collection(collectionId);

  group('在线候选', () {
    test('已存的全部 backdrop（本地优先、远程兜底）+ 附加图组刮削图 + TMDB 现拉，按地址去重', () async {
      final String local0 = png('b0.png', 1920, 1080);
      await db.replaceVideoMetadataImages(
        workId: workId,
        images: <VideoMetadataImagesCompanion>[
          workImage(
            'backdrop',
            0,
            'https://image.tmdb.test/b0.jpg',
            localPath: local0,
            width: 1920,
            height: 1080,
          ),
          workImage('backdrop', 1, 'https://image.tmdb.test/b1.jpg'),
          workImage('logo', 0, 'https://image.tmdb.test/logo.png'),
        ],
      );
      final String media = png('m.png', 1920, 1080);
      await db
          .replaceMediaImagesForCollection(collectionId, <MediaImagesCompanion>[
            MediaImagesCompanion.insert(
              collectionId: Value<int?>(collectionId),
              kind: MediaImageKind.backdrop.dbValue,
              path: local0,
              sourceUrl: const Value<String?>('https://image.tmdb.test/b0.jpg'),
            ),
            MediaImagesCompanion.insert(
              collectionId: Value<int?>(collectionId),
              kind: MediaImageKind.backdrop.dbValue,
              position: const Value<int>(1),
              path: media,
              sourceUrl: const Value<String?>('https://image.tmdb.test/m.jpg'),
            ),
          ]);
      await addTmdbIdentity();
      final List<VideoMetadataLookup> fetched = <VideoMetadataLookup>[];
      final List<BannerCandidate> out = await loadVideoBannerOnlineCandidates(
        db: db,
        owner: owner(),
        fetchWork: (VideoMetadataLookup lookup) async {
          fetched.add(lookup);
          return _work(<VideoMetadataImage>[
            _backdrop('https://image.tmdb.test/b1.jpg'),
            _backdrop('https://image.tmdb.test/live.jpg'),
            _backdrop('https://image.tmdb.test/season.jpg', season: 1),
          ]);
        },
      );
      expect(fetched.single.provider, VideoMetadataProviderKind.tmdb);
      expect(fetched.single.externalId, '1399');
      expect(fetched.single.mediaKind, VideoMetadataMediaKind.tv);
      expect(
        <String?>[for (final BannerCandidate c in out) c.sourceUrl],
        <String?>[
          'https://image.tmdb.test/b0.jpg',
          'https://image.tmdb.test/b1.jpg',
          'https://image.tmdb.test/m.jpg',
          'https://image.tmdb.test/live.jpg',
        ],
      );
      expect(out.first.width, 1920);
      expect(await out.first.resolve(), isA<File>());
      expect((await out.first.resolve()).path, local0);
    });

    test('TMDB 现拉失败不挡已存的；什么都没有时抛出', () async {
      await addTmdbIdentity();
      Future<VideoMetadataWork?> failing(VideoMetadataLookup _) async =>
          throw Exception('tmdb 503');
      await expectLater(
        loadVideoBannerOnlineCandidates(
          db: db,
          owner: owner(),
          fetchWork: failing,
        ),
        throwsException,
      );
      await db.replaceVideoMetadataImages(
        workId: workId,
        images: <VideoMetadataImagesCompanion>[
          workImage('backdrop', 0, 'https://image.tmdb.test/b0.jpg'),
        ],
      );
      final List<BannerCandidate> out = await loadVideoBannerOnlineCandidates(
        db: db,
        owner: owner(),
        fetchWork: failing,
      );
      expect(out.single.sourceUrl, 'https://image.tmdb.test/b0.jpg');
    });

    test('没有 TMDB 身份不现拉（AniDB / MAL 只给海报）', () async {
      bool called = false;
      await loadVideoBannerOnlineCandidates(
        db: db,
        owner: owner(),
        fetchWork: (VideoMetadataLookup _) async {
          called = true;
          return null;
        },
      );
      expect(called, isFalse);
    });
  });

  test('片中：分集剧照 / 帧缩略图 / title_card，只留横版的', () async {
    final String wide = png('frame.png', 1280, 720);
    final String portrait = png('poster.png', 600, 900);
    final String still = png('still.png', 1920, 1080);
    final String card = png('card.png', 1600, 900);
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('ep1'),
        title: const Value<String>('Episode 1'),
        videoPath: const Value<String>('/v/ep1.mkv'),
        coverPath: Value<String?>(wide),
      ),
    );
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('ep2'),
        title: const Value<String>('Episode 2'),
        videoPath: const Value<String>('/v/ep2.mkv'),
        coverPath: Value<String?>(portrait),
      ),
    );
    await db.addToCollection(collectionId, MediaKind.video, 'ep1');
    await db.addToCollection(collectionId, MediaKind.video, 'ep2');
    final int seasonId = await db.upsertVideoMetadataSeason(
      VideoMetadataSeasonsCompanion.insert(
        workId: workId,
        seasonNumber: 1,
        updatedAt: 1,
      ),
    );
    final int episodeId = await db.upsertVideoMetadataEpisode(
      VideoMetadataEpisodesCompanion.insert(
        seasonId: seasonId,
        bookUid: const Value<String?>('ep2'),
        episodeNumber: 2,
        updatedAt: 1,
      ),
    );
    await db.replaceVideoMetadataImages(
      episodeId: episodeId,
      images: <VideoMetadataImagesCompanion>[
        VideoMetadataImagesCompanion.insert(
          episodeId: Value<int?>(episodeId),
          provider: 'tmdb',
          kind: 'thumb',
          remoteUrl: 'https://image.tmdb.test/still.jpg',
          localPath: Value<String?>(still),
          updatedAt: 1,
        ),
      ],
    );
    await db.replaceMediaImagesForBook('ep1', <MediaImagesCompanion>[
      MediaImagesCompanion.insert(
        bookUid: const Value<String?>('ep1'),
        kind: MediaImageKind.titleCard.dbValue,
        path: card,
      ),
    ]);
    final List<BannerCandidate> out = await loadVideoBannerFromWork(
      db: db,
      owner: owner(),
    );
    expect(
      <String>[for (final BannerCandidate c in out) (await c.resolve()).path],
      <String>[card, wide, still],
    );
    expect(out.first.label, 'Episode 1');
    expect(out.last.label, 'Episode 2');
    expect(out.last.width, 1920);
  });

  group('面板装配', () {
    late MediaImageUserStore store;
    setUp(() {
      store = MediaImageUserStore(
        db,
        collectionsDirectory: Directory(p.join(dir.path, 'collections')),
        videosDirectory: Directory(p.join(dir.path, 'videos')),
      );
    });

    test('当前是刮削背景：显示它但不出「移除」；选一张后上锁、重刮不覆盖', () async {
      final String scraped = png('scraped.png', 1920, 1080);
      await db
          .replaceMediaImagesForCollection(collectionId, <MediaImagesCompanion>[
            MediaImagesCompanion.insert(
              collectionId: Value<int?>(collectionId),
              kind: MediaImageKind.backdrop.dbValue,
              path: scraped,
              sourceUrl: const Value<String?>('https://image.tmdb.test/s.jpg'),
            ),
          ]);
      BannerPickerTarget target = await loadVideoBannerPickerTarget(
        db: db,
        owner: owner(),
        onlineEnabled: false,
        store: store,
      );
      expect(target.current, isNotNull);
      expect(target.currentUserChosen, isFalse);
      expect(target.clear, isNull);
      expect(target.loadOnline, isNull, reason: '在线服务关着不出在线分段');
      expect(target.sources, <BannerPickerSource>[
        BannerPickerSource.fromWork,
        BannerPickerSource.fileOrLink,
      ]);
      expect(target.fromWorkLabel, t.media_banner_source_from_video);

      await target.apply(
        gif('pick.gif'),
        sourceUrl: 'https://image.tmdb.test/pick.jpg',
      );
      final MediaImageRow picked = (await db.getMediaImagesForCollection(
        collectionId,
      )).single;
      expect(picked.userChosen, isTrue);

      target = await loadVideoBannerPickerTarget(
        db: db,
        owner: owner(),
        onlineEnabled: true,
        store: store,
      );
      expect(target.currentUserChosen, isTrue);
      expect(target.clear, isNotNull);
      expect(target.loadOnline, isNotNull);

      await target.clear!();
      expect(await db.getMediaImagesForCollection(collectionId), isEmpty);
    });
  });

  test('系列色块：用户选的那张压过无字刮削背景，不论它有没有字', () {
    final VideoMetadataImageRow textless = VideoMetadataImageRow(
      id: 1,
      workId: 1,
      provider: 'tmdb',
      kind: 'backdrop',
      position: 0,
      remoteUrl: 'https://image.tmdb.test/textless.jpg',
      localPath: '/scraped/textless.jpg',
      updatedAt: 1,
    );
    final VideoMetadataImageRow texted = VideoMetadataImageRow(
      id: 2,
      workId: 1,
      provider: 'tmdb',
      kind: 'backdrop',
      position: 1,
      language: 'ja',
      remoteUrl: 'https://image.tmdb.test/texted.jpg',
      updatedAt: 1,
    );
    final VideoSeriesMetaPlan plan = videoSeriesMetaPlan((
      work: VideoMetadataWorkRow(
        id: 1,
        collectionId: 1,
        mediaType: 'tv',
        title: 'Show',
        updatedAt: 1,
        episodeGroupId: null,
      ),
      mediaImages: const <MediaImageRow>[
        MediaImageRow(
          id: 1,
          collectionId: 1,
          kind: 'backdrop',
          position: 0,
          path: '/scraped/media.jpg',
          userChosen: false,
        ),
        MediaImageRow(
          id: 2,
          collectionId: 1,
          kind: 'backdrop',
          position: 1,
          path: '/user/pick.jpg',
          sourceUrl: 'https://image.tmdb.test/texted.jpg',
          userChosen: true,
        ),
      ],
      workImages: <VideoMetadataImageRow>[textless, texted],
      scrape: null,
    ));
    expect(plan.userBackdrop.mediaPaths, <String>['/user/pick.jpg']);
    expect(plan.userBackdropHasText, isTrue);
    expect(plan.textlessBackdrop.mediaPaths, <String>['/scraped/media.jpg']);
  });
}

VideoMetadataWork _work(List<VideoMetadataImage> images) => VideoMetadataWork(
  provider: VideoMetadataProviderKind.tmdb,
  kind: VideoMetadataMediaKind.tv,
  title: 'Show',
  images: images,
);

VideoMetadataImage _backdrop(String url, {int? season}) => VideoMetadataImage(
  kind: VideoMetadataImageKind.backdrop,
  url: url,
  provider: VideoMetadataProviderKind.tmdb,
  seasonNumber: season,
);
