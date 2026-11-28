import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show youtubeThumbnailFallbackUrl;

/// BUG-2450：磁盘缓存图片的文件服务层对 5xx / 连接错误退避重试。走真实 loopback HttpServer（`HttpOverrides` 置空，与
/// app_http_image_proxy_test 同款装配）。BUG-5614：404 时按回退地址再取一次。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const String png =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';
  final HttpOverrides? originalOverrides = HttpOverrides.current;
  late Directory temp;
  late HttpServer server;
  final List<int> statuses = <int>[];
  final List<String> paths = <String>[];
  int requests = 0;

  setUpAll(() async {
    HttpOverrides.global = null;
    temp = await Directory.systemTemp.createTemp('fushi-image-retry-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => temp.path,
        );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      requests++;
      paths.add(request.uri.path);
      final int status = statuses.isEmpty ? 200 : statuses.removeAt(0);
      request.response.statusCode = status;
      request.response.headers.set('content-type', 'image/png');
      request.response.headers.set('cache-control', 'no-store');
      if (status == 200) request.response.add(base64Decode(png));
      await request.response.close();
    });
  });

  tearDownAll(() async {
    // 与 app_http_image_proxy_test 同款收尾：先让单例缓存管理器放开它打开的
    // 缓存文件，否则 Windows 上临时目录删不掉（errno 32）。
    await AppImageCacheManager().emptyCache();
    await AppImageCacheManager().dispose();
    await server.close(force: true);
    HttpOverrides.global = originalOverrides;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // 缓存文件句柄晚释放时留一个临时目录，不算测试失败。
    }
  });

  setUp(() {
    requests = 0;
    statuses.clear();
    paths.clear();
    PaintingBinding.instance.imageCache.clear();
  });

  String url(String name) =>
      'http://${server.address.host}:${server.port}/$name.png';

  test('文件服务层：503 后按退避重试，第二次 200 成功', () async {
    final List<Duration> waits = <Duration>[];
    final AppImageFileService service = AppImageFileService(
      retryBackoff: const <Duration>[Duration(milliseconds: 5)],
      retryWait: (Duration delay) async => waits.add(delay),
    );
    statuses.addAll(<int>[503, 200]);
    final FileServiceResponse response = await service.get(url('flaky'));
    expect(response.statusCode, 200);
    expect(await response.content.toList(), isNotEmpty);
    expect(requests, 2);
    expect(waits, <Duration>[const Duration(milliseconds: 5)]);
  });

  test('文件服务层：梯度耗尽后以 CacheManager 同款状态码异常抛出', () async {
    final AppImageFileService service = AppImageFileService(
      retryBackoff: const <Duration>[Duration(milliseconds: 5)],
      retryWait: (Duration delay) async {},
    );
    statuses.addAll(<int>[503, 503]);
    await expectLater(
      service.get(url('down')),
      throwsA(
        isA<HttpExceptionWithStatus>().having(
          (HttpExceptionWithStatus e) => e.statusCode,
          'status',
          503,
        ),
      ),
    );
    expect(requests, 2);
  });

  test('文件服务层：404 不重试，照旧把响应交给 CacheManager', () async {
    final AppImageFileService service = AppImageFileService(
      retryBackoff: const <Duration>[Duration(milliseconds: 5)],
      retryWait: (Duration delay) async => fail('404 不该退避'),
    );
    statuses.add(404);
    final FileServiceResponse response = await service.get(url('missing'));
    expect(response.statusCode, 404);
    expect(requests, 1);
  });

  test('BUG-5614：404 且有回退地址时改取回退地址（YouTube maxres → mqdefault）', () async {
    final AppImageFileService service = AppImageFileService(
      retryBackoff: const <Duration>[Duration(milliseconds: 5)],
      retryWait: (Duration delay) async => fail('404 不该退避'),
      fallbackUrlOf: (String u) =>
          u == url('maxresdefault') ? url('mqdefault') : null,
    );
    statuses.addAll(<int>[404, 200]);
    final FileServiceResponse response = await service.get(
      url('maxresdefault'),
    );
    expect(response.statusCode, 200);
    expect(await response.content.toList(), isNotEmpty);
    expect(paths, <String>['/maxresdefault.png', '/mqdefault.png']);
  });

  test('BUG-5614：回退地址也 404 时照旧交出 404，不无限回退', () async {
    final AppImageFileService service = AppImageFileService(
      retryBackoff: const <Duration>[Duration(milliseconds: 5)],
      retryWait: (Duration delay) async => fail('404 不该退避'),
      fallbackUrlOf: (String u) =>
          u == url('maxresdefault') ? url('mqdefault') : null,
    );
    statuses.addAll(<int>[404, 404]);
    final FileServiceResponse response = await service.get(
      url('maxresdefault'),
    );
    expect(response.statusCode, 404);
    expect(requests, 2);
  });

  test('BUG-5614：200 不走回退；生产回退规则是 YouTube 缩略图回退', () async {
    final AppImageFileService service = AppImageFileService(
      fallbackUrlOf: (String u) => fail('200 不该查回退'),
    );
    final FileServiceResponse response = await service.get(url('ok'));
    expect(response.statusCode, 200);
    expect(requests, 1);
    expect(AppImageFileService().fallbackUrlOf, youtubeThumbnailFallbackUrl);
  });
}
