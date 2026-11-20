/// #3722 video-18 / video-s3-13：刮削作品图（TMDB 默认原图）解码必须封顶。
///
/// 修前作品详情页本地图是裸 `FileImage`、远程图是裸 `AppCachedHttpImage`，库页
/// 剧照 / 作品图的远程回落也是裸 `AppCachedHttpImage`：一张 4K 背景整帧解进
/// ImageCache 约 33MB。这里既量真实解码尺寸（本地文件分支），也在真实页面
/// （远端作品资料页）上断言 hero 拿到的 provider 带解码上限。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/video/cover_ui/video_poster_detail_hero.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_image_provider.dart';
import 'package:fushi/src/pages/implementations/video_work_detail_page.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteVideoWorkMetadataFetch;
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:material_ui/material_ui.dart';

VideoMetadataImageRow _row({
  required String kind,
  String remoteUrl = '',
  String? localPath,
  int position = 0,
}) => VideoMetadataImageRow(
  id: position + 1,
  workId: 1,
  kind: kind,
  provider: 'tmdb',
  remoteUrl: remoteUrl,
  localPath: localPath,
  position: position,
  updatedAt: 0,
);

/// 写一张 [width]×[height] 的 PNG（真实字节，供真实解码）。
Future<File> _writePng(Directory dir, int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366CC),
  );
  final ui.Image image = await recorder.endRecording().toImage(width, height);
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final File file = File('${dir.path}/${width}x$height.png');
  await file.writeAsBytes(png!.buffer.asUint8List());
  return file;
}

/// 真实走一遍 provider 的解码，返回解出来的位图宽。
Future<int> _decodedWidth(ImageProvider provider) async {
  final ImageInfo info = await _firstFrame(
    provider.resolve(ImageConfiguration.empty),
  );
  final int width = info.image.width;
  info.dispose();
  return width;
}

Future<ImageInfo> _firstFrame(ImageStream stream) {
  final Completer<ImageInfo> done = Completer<ImageInfo>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool _) {
      stream.removeListener(listener);
      done.complete(info);
    },
    onError: (Object error, StackTrace? st) {
      stream.removeListener(listener);
      done.completeError(error, st);
    },
  );
  stream.addListener(listener);
  return done.future;
}

class _FakeMetadata implements RemoteVideoWorkMetadataFetch {
  _FakeMetadata(this.work);
  final VideoMetadataWork work;

  @override
  Future<VideoMetadataWork?> remoteVideoWorkMetadata(String id) async => work;
}

/// [provider] 是「[AppCachedHttpImage] 外套只缩不放的 [ResizeImage]」，宽为 [width]。
void _expectCappedRemote(ImageProvider? provider, String url, int width) {
  expect(provider, isA<ResizeImage>());
  final ResizeImage resized = provider! as ResizeImage;
  expect(resized.width, width);
  expect(resized.height, isNull);
  expect(resized.allowUpscaling, isFalse);
  expect(resized.imageProvider, isA<AppCachedHttpImage>());
  expect((resized.imageProvider as AppCachedHttpImage).url, url);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUpAll(() async {
    // AppCachedHttpImage 构造即起磁盘缓存管理器，要 path_provider 应答。
    temp = await Directory.systemTemp.createTemp('metadata-image-cache-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => temp.path,
        );
  });
  tearDownAll(() => temp.delete(recursive: true));

  test('decode width per kind: backdrop 1280, logo 640, the rest 720', () {
    expect(videoMetadataImageDecodeWidth('backdrop'), 1280);
    expect(videoMetadataImageDecodeWidth('logo'), 640);
    for (final String kind in <String>[
      'poster',
      'cover',
      'thumb',
      'landscape',
    ]) {
      expect(videoMetadataImageDecodeWidth(kind), kLocalCoverDecodePixelWidth);
    }
    expect(
      videoMetadataImageKindDecodeWidth(VideoMetadataImageKind.backdrop),
      kMetadataBackdropDecodePixelWidth,
    );
  });

  testWidgets('existing local poster decodes at most 720 px wide, not native', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Directory dir = await Directory.systemTemp.createTemp('meta-img-');
      addTearDown(() => dir.delete(recursive: true));
      final File poster = await _writePng(dir, 2000, 3000);
      final File backdrop = await _writePng(dir, 3840, 216);
      final List<VideoMetadataImageRow> rows = <VideoMetadataImageRow>[
        _row(kind: 'poster', localPath: poster.path, remoteUrl: 'https://p'),
        _row(
          kind: 'backdrop',
          localPath: backdrop.path,
          remoteUrl: 'https://b',
          position: 1,
        ),
      ];
      bool exists(String path) => true;
      final ImageProvider posterImage = videoMetadataRowImage(
        rows,
        'poster',
        localExists: exists,
      )!;
      final ImageProvider backdropImage = videoMetadataRowImage(
        rows,
        'backdrop',
        localExists: exists,
      )!;
      expect(await _decodedWidth(posterImage), 720);
      expect(await _decodedWidth(backdropImage), 1280);
    });
  });

  // 刮削图落成 sidecar（`fanart.<ext>` / `logo.<ext>`），重刮换身份是同路径覆盖写，
  // 写后经 evictLocalCoverCache 驱逐（BUG-2737）。修前详情页用裸 FileImage，驱逐
  // 能清到；改成背景 1280 / logo 640 的宽度键后，驱逐必须把这些宽度也清掉，否则
  // 详情页重刮后仍画旧图。
  testWidgets('same-path overwrite evicts the 1280 / 640 detail-page decodes', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'meta-evict-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final File backdrop = await _writePng(dir, 1600, 900);
      final File logo = await _writePng(dir, 800, 300);
      final List<VideoMetadataImageRow> rows = <VideoMetadataImageRow>[
        _row(kind: 'backdrop', localPath: backdrop.path),
        _row(kind: 'logo', localPath: logo.path, position: 1),
      ];
      final ImageCache cache = PaintingBinding.instance.imageCache;
      for (final (String kind, File file) in <(String, File)>[
        ('backdrop', backdrop),
        ('logo', logo),
      ]) {
        final ImageProvider image = videoMetadataRowImage(
          rows,
          kind,
          localExists: (String _) => true,
        )!;
        await _decodedWidth(image);
        final Object key = await image.obtainKey(ImageConfiguration.empty);
        expect(cache.containsKey(key), isTrue, reason: kind);

        await evictLocalCoverCache(file.path);
        expect(cache.containsKey(key), isFalse, reason: kind);
      }
    });
  });

  test('missing local file falls back to a capped remote image', () {
    final ImageProvider? image = videoMetadataRowImage(
      <VideoMetadataImageRow>[
        _row(
          kind: 'backdrop',
          localPath: '/gone/backdrop.jpg',
          remoteUrl: 'https://image.tmdb.org/t/p/original/b.jpg',
        ),
      ],
      'backdrop',
      localExists: (String path) => false,
    );
    _expectCappedRemote(
      image,
      'https://image.tmdb.org/t/p/original/b.jpg',
      kMetadataBackdropDecodePixelWidth,
    );
  });

  test('no row of that kind yields null', () {
    expect(
      videoMetadataRowImage(
        <VideoMetadataImageRow>[_row(kind: 'logo', remoteUrl: 'https://l')],
        'poster',
        localExists: (String path) => true,
      ),
      isNull,
    );
  });

  testWidgets('remote work detail page hands the hero capped TMDB images', (
    WidgetTester tester,
  ) async {
    const String cover = 'https://image.tmdb.org/t/p/original/cover.jpg';
    const String backdrop = 'https://image.tmdb.org/t/p/original/back.jpg';
    final VideoMetadataWork work = VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.movie,
      title: 'Work',
      images: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: cover,
          provider: VideoMetadataProviderKind.tmdb,
        ),
        VideoMetadataImage(
          kind: VideoMetadataImageKind.backdrop,
          url: backdrop,
          provider: VideoMetadataProviderKind.tmdb,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteVideoWorkDetailPage(
          info: const RemoteVideoInfo(id: 'v1', title: 'Work'),
          metadata: _FakeMetadata(work),
          onPlay: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final List<Widget> heroes = tester
        .widgetList(
          find.byWidgetPredicate(
            (Widget w) =>
                w is VideoPosterDetailHero || w is CollectionDetailHero,
          ),
        )
        .toList();
    expect(heroes, isNotEmpty);
    for (final Widget hero in heroes) {
      final (
        ImageProvider? heroCover,
        ImageProvider? heroBackdrop,
      ) = switch (hero) {
        VideoPosterDetailHero h => (h.cover, h.backdrop),
        CollectionDetailHero h => (h.cover, h.backdrop),
        _ => (null, null),
      };
      _expectCappedRemote(heroCover, cover, kLocalCoverDecodePixelWidth);
      _expectCappedRemote(
        heroBackdrop,
        backdrop,
        kMetadataBackdropDecodePixelWidth,
      );
    }
    // 测试环境的 HttpClient 一律 400：图片加载失败与本用例无关，清掉再退出；
    // 拆树后再推一段时间，让入场动效 / 缓存管理器的定时器走完。
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
    while (tester.takeException() != null) {}
  });
}
