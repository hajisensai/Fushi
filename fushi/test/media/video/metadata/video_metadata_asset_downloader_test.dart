import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_asset_downloader.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('image downloader caps Retry-After before retrying', () async {
    int requests = 0;
    final List<Duration> delays = <Duration>[];
    final VideoMetadataAssetDownloader downloader =
        VideoMetadataAssetDownloader(
      client: MockClient((http.Request request) async {
        requests++;
        if (requests == 1) {
          return http.Response(
            'limited',
            429,
            headers: <String, String>{'retry-after': '3600'},
          );
        }
        return http.Response.bytes(
          _jpegBytes,
          200,
          headers: <String, String>{'content-type': 'image/jpeg'},
        );
      }),
      maxRetryDelay: const Duration(seconds: 4),
      sleep: (Duration duration) async => delays.add(duration),
    );

    final VideoMetadataDownloadedAsset asset =
        await downloader.download('https://images.example/cover.jpg');

    expect(asset.bytes, _jpegBytes);
    expect(asset.extension, '.jpg');
    expect(delays, <Duration>[const Duration(seconds: 4)]);
  });

  test('image downloader does not retry non-retryable responses', () async {
    int requests = 0;
    final VideoMetadataAssetDownloader downloader =
        VideoMetadataAssetDownloader(
      client: MockClient((http.Request request) async {
        requests++;
        return http.Response('forbidden', 403);
      }),
      sleep: (Duration duration) async {},
    );

    await expectLater(
      downloader.download('https://images.example/cover.jpg'),
      throwsA(
        isA<VideoMetadataNetworkException>().having(
          (VideoMetadataNetworkException error) => error.statusCode,
          'statusCode',
          403,
        ),
      ),
    );
    expect(requests, 1);
  });

  for (final ({
    String name,
    String contentType,
    List<int> bytes,
    String ext
  }) image
      in <({String name, String contentType, List<int> bytes, String ext})>[
    (
      name: 'JPEG',
      contentType: 'image/jpeg',
      bytes: _jpegBytes,
      ext: '.jpg',
    ),
    (
      name: 'PNG',
      contentType: 'image/png',
      bytes: _pngBytes,
      ext: '.png',
    ),
    (
      name: 'WebP',
      contentType: 'image/webp',
      bytes: _webpBytes,
      ext: '.webp',
    ),
    (
      name: 'GIF',
      contentType: 'image/gif',
      bytes: _gifBytes,
      ext: '.gif',
    ),
  ]) {
    test('image downloader accepts ${image.name} magic and derives extension',
        () async {
      final VideoMetadataAssetDownloader downloader =
          VideoMetadataAssetDownloader(
        client: MockClient((http.Request request) async => http.Response.bytes(
              image.bytes,
              200,
              headers: <String, String>{
                'content-type': '${image.contentType}; charset=binary',
              },
            )),
      );

      final VideoMetadataDownloadedAsset asset = await downloader.download(
        'https://images.example/deliberately-wrong.jpg',
      );

      expect(asset.extension, image.ext, reason: '扩展名必须来自实际 magic');
      expect(asset.contentType, image.contentType);
      expect(asset.bytes, image.bytes);
    });
  }

  for (final ({String name, String? contentType, List<int> bytes}) invalid
      in <({String name, String? contentType, List<int> bytes})>[
    (name: 'empty body', contentType: 'image/png', bytes: <int>[]),
    (
      name: 'HTML response',
      contentType: 'text/html',
      bytes: '<html>not found</html>'.codeUnits,
    ),
    (
      name: 'spoofed image Content-Type',
      contentType: 'image/jpeg',
      bytes: '<html>not an image</html>'.codeUnits,
    ),
    (name: 'missing Content-Type', contentType: null, bytes: _pngBytes),
  ]) {
    test('image downloader rejects ${invalid.name} without retrying', () async {
      int requests = 0;
      final VideoMetadataAssetDownloader downloader =
          VideoMetadataAssetDownloader(
        client: MockClient((http.Request request) async {
          requests++;
          return http.Response.bytes(
            invalid.bytes,
            200,
            headers: <String, String>{
              if (invalid.contentType != null)
                'content-type': invalid.contentType!,
            },
          );
        }),
        sleep: (Duration duration) async {},
      );

      await expectLater(
        downloader.download('https://images.example/cover.jpg'),
        throwsA(
          isA<VideoMetadataNetworkException>().having(
            (VideoMetadataNetworkException error) => error.statusCode,
            'statusCode',
            200,
          ),
        ),
      );
      expect(requests, 1, reason: '2xx 内容校验失败不是可重试服务端错误');
    });
  }
}

const List<int> _jpegBytes = <int>[0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10];
const List<int> _pngBytes = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
];
const List<int> _webpBytes = <int>[
  0x52,
  0x49,
  0x46,
  0x46,
  0x04,
  0x00,
  0x00,
  0x00,
  0x57,
  0x45,
  0x42,
  0x50,
];
const List<int> _gifBytes = <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61];
