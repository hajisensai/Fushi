import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/async_file_existence_cache.dart'
    show kPendingCoverImage;
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_image_provider.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi_core/fushi_core.dart' show VideoMetadataImageRow;
import 'package:fushi_engine/media/video/scraper/scraper_types.dart';
import 'package:material_ui/material_ui.dart';

/// 拍板 GLMHiavo0y（反馈 GLMHiavo0y）：选集页每集缩略图取图顺序
/// 「手动设置的封面 > 分集剧照（本地文件优先，其次远程 URL）> 自动截图」，
/// 剧照缺失或加载失败回落截图；剧照挑选与首页主卡同一份函数。
void main() {
  // 远程剧照 provider 会建磁盘图片缓存（path_provider 取目录）：钉到临时目录。
  setUpAll(() async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'fushi-episode-thumb-test-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => temp.path,
        );
  });

  group('videoEpisodeThumbCandidates', () {
    final ImageProvider cover = FileImage(File('cover.jpg'));
    final ImageProvider still = FileImage(File('still.jpg'));

    test('自动截图封面：剧照在前，截图垫后', () {
      expect(
        videoEpisodeThumbCandidates(
          cover: cover,
          coverIsUserChosen: false,
          still: still,
        ),
        <ImageProvider>[still, cover],
      );
    });

    test('手动封面：封面在前，剧照垫后', () {
      expect(
        videoEpisodeThumbCandidates(
          cover: cover,
          coverIsUserChosen: true,
          still: still,
        ),
        <ImageProvider>[cover, still],
      );
    });

    test('缺哪张就去掉哪张', () {
      expect(
        videoEpisodeThumbCandidates(
          cover: cover,
          coverIsUserChosen: false,
          still: null,
        ),
        <ImageProvider>[cover],
      );
      expect(
        videoEpisodeThumbCandidates(
          cover: null,
          coverIsUserChosen: true,
          still: still,
        ),
        <ImageProvider>[still],
      );
      expect(
        videoEpisodeThumbCandidates(
          cover: null,
          coverIsUserChosen: false,
          still: null,
        ),
        isEmpty,
      );
    });

    // 封面来源表在后台读（不挡详情页加载）：还没读到时，封面与剧照都有的集
    // 停在待定占位，不先闪成剧照再跳回手动封面；只有一张时顺序无关，直接给出。
    test('封面来源还没读到：两张都有时停在待定占位，只有一张时照给', () {
      expect(
        videoEpisodeThumbCandidates(
          cover: cover,
          coverIsUserChosen: null,
          still: still,
        ),
        <ImageProvider>[kPendingCoverImage],
      );
      expect(
        videoEpisodeThumbCandidates(
          cover: cover,
          coverIsUserChosen: null,
          still: null,
        ),
        <ImageProvider>[cover],
      );
      expect(
        videoEpisodeThumbCandidates(
          cover: null,
          coverIsUserChosen: null,
          still: still,
        ),
        <ImageProvider>[still],
      );
    });
  });

  group('CoverOrigin.isUserChosen', () {
    test('只有确定是用户挑的封面才排在剧照前', () {
      expect(
        <CoverOrigin, bool>{
          for (final CoverOrigin origin in CoverOrigin.values)
            origin: origin.isUserChosen,
        },
        <CoverOrigin, bool>{
          CoverOrigin.autoFrame: false,
          CoverOrigin.manual: true,
          CoverOrigin.scraped: false,
          CoverOrigin.autoScraped: false,
          CoverOrigin.cleanupPending: false,
          CoverOrigin.cleanupReplacement: true,
          CoverOrigin.userScraped: true,
          CoverOrigin.sidecar: true,
        },
      );
    });
  });

  group('videoFileEpisodeStillImage', () {
    VideoFileEpisodeStills episode(
      int episodeId,
      int episodeNumber, {
      String? localPath,
      String remoteUrl = '',
      String kind = 'thumb',
      int? runtimeMinutes,
    }) => VideoFileEpisodeStills(
      episodeId: episodeId,
      seasonNumber: 1,
      episodeNumber: episodeNumber,
      runtimeMinutes: runtimeMinutes,
      stills: <VideoMetadataImageRow>[
        VideoMetadataImageRow(
          id: episodeId * 10,
          episodeId: episodeId,
          provider: 'tmdb',
          kind: kind,
          position: 0,
          localPath: localPath,
          remoteUrl: remoteUrl,
          updatedAt: 0,
        ),
      ],
    );

    ImageProvider? pick(
      List<VideoFileEpisodeStills>? episodes, {
      Map<String, bool> exists = const <String, bool>{},
      int positionMs = 0,
    }) => videoFileEpisodeStillImage(
      episodes,
      positionMs: positionMs,
      localExists: (String? path) =>
          path == null || path.isEmpty ? false : exists[path],
    );

    test('本地剧照文件存在：用本地文件', () {
      final ImageProvider? image = pick(
        <VideoFileEpisodeStills>[
          episode(1, 7, localPath: 'D:/s/7.jpg', remoteUrl: 'https://r/7.jpg'),
        ],
        exists: const <String, bool>{'D:/s/7.jpg': true},
      );
      expect(image, isA<ResizeImage>());
      expect(
        (image! as ResizeImage).imageProvider,
        FileImage(File('D:/s/7.jpg')),
      );
    });

    test('本地文件不在：回落远程 URL', () {
      final ImageProvider? image = pick(
        <VideoFileEpisodeStills>[
          episode(1, 7, localPath: 'D:/s/7.jpg', remoteUrl: 'https://r/7.jpg'),
        ],
        exists: const <String, bool>{'D:/s/7.jpg': false},
      );
      expect(
        ((image! as ResizeImage).imageProvider as dynamic).url,
        'https://r/7.jpg',
      );
    });

    test('本地文件还在探测：停在待定占位，不先闪远程图', () {
      expect(
        pick(<VideoFileEpisodeStills>[
          episode(1, 7, localPath: 'D:/s/7.jpg', remoteUrl: 'https://r/7.jpg'),
        ]),
        same(kPendingCoverImage),
      );
    });

    test('没有分集资料 / 只有非剧照图 / 没有图源：null，由调用方回落截图', () {
      expect(pick(null), isNull);
      expect(
        pick(<VideoFileEpisodeStills>[
          episode(1, 7, kind: 'poster', remoteUrl: 'https://r/p.jpg'),
        ]),
        isNull,
      );
      expect(pick(<VideoFileEpisodeStills>[episode(1, 7)]), isNull);
    });

    test('一文件多集：按续播点挑那一集的剧照（与首页主卡同一套定位）', () {
      final List<VideoFileEpisodeStills> file = <VideoFileEpisodeStills>[
        episode(2, 8, remoteUrl: 'https://r/8.jpg', runtimeMinutes: 24),
        episode(1, 7, remoteUrl: 'https://r/7.jpg', runtimeMinutes: 24),
      ];
      String? urlAt(int positionMs) =>
          ((pick(file, positionMs: positionMs)! as ResizeImage).imageProvider
                      as dynamic)
                  .url
              as String?;
      expect(urlAt(0), 'https://r/7.jpg');
      expect(urlAt(30 * Duration.millisecondsPerMinute), 'https://r/8.jpg');
    });
  });

  group('collectionEpisodeThumb fallbacks', () {
    testWidgets('首选图加载失败：换回落图（剧照失败退回自动截图）', (WidgetTester tester) async {
      final ImageProvider broken = _BrokenImage();
      final ImageProvider fallback = _NeverLoadingImage();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => collectionEpisodeThumb(
                context,
                broken,
                fallbacks: <ImageProvider>[fallback],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final Iterable<ImageProvider> shown = tester
          .widgetList<Image>(find.byType(Image))
          .map((Image image) => image.image);
      expect(shown, contains(fallback));
      expect(shown, isNot(contains(broken)));
    });

    testWidgets('全部失败：退占位图标', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) =>
                  collectionEpisodeThumb(context, _BrokenImage()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsNothing);
    });
  });
}

/// 一加载就报错的图（模拟远程剧照 404 / 文件坏掉）。
class _BrokenImage extends ImageProvider<_BrokenImage> {
  @override
  Future<_BrokenImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_BrokenImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _BrokenImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    Future<ImageInfo>.error(StateError('broken still')),
  );
}

/// 永远不出帧的图（只用来确认它被挂上了）。
class _NeverLoadingImage extends ImageProvider<_NeverLoadingImage> {
  @override
  Future<_NeverLoadingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_NeverLoadingImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _NeverLoadingImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}
