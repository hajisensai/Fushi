import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

const String _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

Future<ImageInfo> _resolve(ImageProvider provider) async {
  final Completer<ImageInfo> loaded = Completer<ImageInfo>();
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo image, bool synchronousCall) {
      loaded.complete(image);
    },
    onError: (Object error, StackTrace? stack) {
      loaded.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  try {
    return await loaded.future;
  } finally {
    stream.removeListener(listener);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final HttpOverrides? originalOverrides = HttpOverrides.current;
  final String Function() originalProxy = appUserProxyReader;
  final String Function() originalMode = appUserProxyModeReader;
  late Directory temp;
  late HttpServer proxy;
  final List<Uri> requests = <Uri>[];
  final List<String?> referers = <String?>[];
  int status = 200;

  setUpAll(() async {
    HttpOverrides.global = null;
    temp = await Directory.systemTemp.createTemp('fushi-image-proxy-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => temp.path,
        );
    proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    proxy.listen((HttpRequest request) async {
      requests.add(request.uri);
      referers.add(request.headers.value('referer'));
      request.response.statusCode = status;
      request.response.headers.set('content-type', 'image/png');
      request.response.headers.set('cache-control', 'max-age=3600');
      request.response.headers.set('etag', 'fixture-v1');
      if (status == 200) request.response.add(base64Decode(_png));
      await request.response.close();
    });
    appUserProxyModeReader = () => kProxyModeManual;
    appUserProxyReader = () => '127.0.0.1:${proxy.port}';
  });
  setUp(() {
    requests.clear();
    referers.clear();
    status = 200;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDownAll(() async {
    await AppImageCacheManager().emptyCache();
    await AppImageCacheManager().dispose();
    await proxy.close(force: true);
    HttpOverrides.global = originalOverrides;
    appUserProxyReader = originalProxy;
    appUserProxyModeReader = originalMode;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await temp.delete(recursive: true);
  });

  test(
    'public image resolves through proxy with source headers and scale',
    () async {
      final ImageInfo image = await _resolve(
        const AppHttpImage(
          'http://image.invalid/direct.png',
          scale: 2,
          headers: <String, String>{'Referer': 'https://source.invalid/series'},
        ),
      );
      expect(image.image.width, 1);
      expect(image.scale, 2);
      expect(requests.single.host, 'image.invalid');
      expect(referers.single, 'https://source.invalid/series');
      image.dispose();
    },
  );

  test(
    'failed image is evicted and can load after connectivity recovers',
    () async {
      const AppHttpImage image = AppHttpImage(
        'http://image.invalid/recover.png',
      );
      status = 503;
      await expectLater(
        _resolve(image),
        throwsA(isA<NetworkImageLoadException>()),
      );
      await Future<void>.delayed(Duration.zero);
      status = 200;
      final ImageInfo result = await _resolve(image);
      expect(requests, hasLength(2));
      result.dispose();
    },
  );

  test(
    'disk cache uses proxy and reuses the explicit cache key across urls',
    () async {
      final AppCachedHttpImage image = AppCachedHttpImage(
        'http://image.invalid/cached.png',
        cacheKey: 'book-key',
        scale: 2,
        maxWidth: 32,
        maxHeight: 48,
        headers: const <String, String>{
          'Referer': 'https://source.invalid/book',
        },
      );
      expect(image.cacheManager, same(AppImageCacheManager()));
      expect(image.cacheManager, isA<ImageCacheManager>());
      expect(image.maxWidth, 32);
      expect(image.maxHeight, 48);
      final ImageInfo loaded = await _resolve(image);
      expect(loaded.scale, 2);
      loaded.dispose();
      final File cached = await AppImageCacheManager().getSingleFile(
        'http://image.invalid/changed-url.png',
        key: 'book-key',
      );
      expect(await cached.readAsBytes(), base64Decode(_png));
      expect(requests, hasLength(1));
      expect(referers.single, 'https://source.invalid/book');
    },
  );

  test(
    'cache file service preserves status and conditional cache metadata',
    () async {
      status = 304;
      final FileServiceResponse response = await AppImageFileService().get(
        'http://image.invalid/not-modified.png',
      );
      expect(response.statusCode, 304);
      expect(response.eTag, 'fixture-v1');
      expect(await response.content.toList(), isEmpty);
      expect(response.validTill.isAfter(DateTime.now()), isTrue);
    },
  );

  test(
    'header identity is independent of map order and prevents wrong-source reuse',
    () {
      const AppHttpImage first = AppHttpImage(
        'https://image.invalid/a',
        headers: <String, String>{'Referer': 'a', 'User-Agent': 'ua'},
      );
      const AppHttpImage reordered = AppHttpImage(
        'https://image.invalid/a',
        headers: <String, String>{'User-Agent': 'ua', 'Referer': 'a'},
      );
      expect(first, reordered);
      expect(first.hashCode, reordered.hashCode);
      expect(
        first,
        isNot(
          const AppHttpImage(
            'https://image.invalid/a',
            headers: <String, String>{'Referer': 'b', 'User-Agent': 'ua'},
          ),
        ),
      );
    },
  );
}
