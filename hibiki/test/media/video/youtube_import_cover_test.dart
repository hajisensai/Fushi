import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/youtube_source_resolver.dart';
import 'package:hibiki/src/media/video/video_cover_extractor.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// TODO-1281：YouTube 导入时「视频名不对（恒 "watch"）+ 无封面」的守卫。
///
/// 覆盖两块可离线单测的纯逻辑 / IO 分支：
/// - [youtubeThumbnailUrl]：由 videoId 拼 hqdefault 缩略图 URL（导入封面源）；
/// - [downloadVideoCoverToPath]：把缩略图 URL 下载到指定路径（注入 MockClient，
///   不碰真网络 / path_provider），断言 2xx 写文件、非 2xx / 空体 / 非图片 / 非法 URL
///   返回 null，以及**覆盖写走统一收口**（原子 `.tmp`+rename，BUG-1394）。
///
/// 真实标题抓取（[resolveYoutubeMetadata]）依赖 youtube_explode + 真网络，属外部系统
/// 契约（守卫见 youtube_resolver_impl_symbols_test.dart），此处不联网测。
void main() {
  // 落盘走 MediaCoverService.applyCoverBytes → evictLocalCoverCache（需 PaintingBinding）。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('youtubeThumbnailUrl', () {
    test('builds hqdefault url from video id', () {
      expect(
        youtubeThumbnailUrl('dQw4w9WgXcQ'),
        'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
      );
    });

    test('uses hqdefault (always exists) not maxresdefault', () {
      // maxresdefault 对未上传高清源的视频会 404；hqdefault 恒存在。
      expect(youtubeThumbnailUrl('abc').contains('hqdefault'), isTrue);
      expect(youtubeThumbnailUrl('abc').contains('maxresdefault'), isFalse);
    });
  });

  group('downloadVideoCoverToPath', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('yt_cover_test_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('2xx with bytes writes the file and returns the path', () async {
      // JPEG 魔数：收口前先过 looksLikeImageBytes（错误页 HTML 不许当封面落盘）。
      final Uint8List bytes = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 4, 5]);
      final MockClient client = MockClient((http.Request req) async {
        expect(req.url.host, 'i.ytimg.com');
        return http.Response.bytes(bytes, 200);
      });
      final String outputPath = p.join(tmp.path, 'cover.jpg');
      final String? result = await downloadVideoCoverToPath(
        coverUrl: youtubeThumbnailUrl('vid123'),
        outputPath: outputPath,
        httpClient: client,
      );
      expect(result, outputPath);
      expect(File(outputPath).existsSync(), isTrue);
      expect(File(outputPath).readAsBytesSync(), bytes);
      expect(File('$outputPath.tmp').existsSync(), isFalse,
          reason: '收口的原子写不该留 .tmp');
    });

    test('content-type image/* 即便字节非图片魔数也放行（服务端权威）', () async {
      final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      final MockClient client = MockClient(
        (http.Request req) async => http.Response.bytes(
          bytes,
          200,
          headers: const <String, String>{'content-type': 'image/jpeg'},
        ),
      );
      final String outputPath = p.join(tmp.path, 'cover.jpg');
      expect(
        await downloadVideoCoverToPath(
          coverUrl: youtubeThumbnailUrl('vid123'),
          outputPath: outputPath,
          httpClient: client,
        ),
        outputPath,
      );
    });

    test('非图片响应（错误页 HTML）返回 null 且不落盘', () async {
      final MockClient client = MockClient(
        (http.Request req) async => http.Response(
          '<html>404 not found</html>',
          200,
          headers: const <String, String>{'content-type': 'text/html'},
        ),
      );
      final String outputPath = p.join(tmp.path, 'cover.jpg');
      expect(
        await downloadVideoCoverToPath(
          coverUrl: youtubeThumbnailUrl('vid123'),
          outputPath: outputPath,
          httpClient: client,
        ),
        isNull,
      );
      expect(File(outputPath).existsSync(), isFalse);
    });

    test('覆盖写同名文件：内容真被换掉、不留 .tmp（BUG-1118 形状）', () async {
      final String outputPath = p.join(tmp.path, 'cover.jpg');
      await File(outputPath).writeAsBytes(<int>[0x89, 0x50, 0x4E, 0x47, 0xAA]);
      final Uint8List fresh =
          Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xBE, 0xEF]);
      final MockClient client = MockClient(
        (http.Request req) async => http.Response.bytes(fresh, 200),
      );
      expect(
        await downloadVideoCoverToPath(
          coverUrl: youtubeThumbnailUrl('vid123'),
          outputPath: outputPath,
          httpClient: client,
        ),
        outputPath,
      );
      expect(File(outputPath).readAsBytesSync(), fresh);
      expect(File('$outputPath.tmp').existsSync(), isFalse);
    });

    test('non-2xx returns null and writes nothing', () async {
      final MockClient client =
          MockClient((http.Request req) async => http.Response('nope', 404));
      final String outputPath = p.join(tmp.path, 'cover.jpg');
      final String? result = await downloadVideoCoverToPath(
        coverUrl: 'https://i.ytimg.com/vi/x/hqdefault.jpg',
        outputPath: outputPath,
        httpClient: client,
      );
      expect(result, isNull);
      expect(File(outputPath).existsSync(), isFalse);
    });

    test('empty 2xx body returns null (no zero-byte cover)', () async {
      final MockClient client = MockClient(
          (http.Request req) async => http.Response.bytes(<int>[], 200));
      final String outputPath = p.join(tmp.path, 'cover.jpg');
      final String? result = await downloadVideoCoverToPath(
        coverUrl: 'https://i.ytimg.com/vi/x/hqdefault.jpg',
        outputPath: outputPath,
        httpClient: client,
      );
      expect(result, isNull);
      expect(File(outputPath).existsSync(), isFalse);
    });

    test('malformed url returns null without hitting the client', () async {
      bool hit = false;
      final MockClient client = MockClient((http.Request req) async {
        hit = true;
        return http.Response.bytes(<int>[9], 200);
      });
      final String? result = await downloadVideoCoverToPath(
        coverUrl: 'not a url',
        outputPath: p.join(tmp.path, 'cover.jpg'),
        httpClient: client,
      );
      expect(result, isNull);
      expect(hit, isFalse);
    });
  });
}
