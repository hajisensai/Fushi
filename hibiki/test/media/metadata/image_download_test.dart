import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/metadata/image_download.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// 挂住响应头，直到生产请求的 [http.Abortable.abortTrigger] 真正触发。
///
/// 旧实现只在外层 `Future.timeout`，发进来的普通 Request 没有 abort trigger，
/// 因而这条假传输会继续存活；这正是本回归要杀掉的路径。
final class _RequestAbortTrackingClient extends http.BaseClient {
  final Completer<void> abortObserved = Completer<void>();
  final Completer<http.StreamedResponse> _unabortableRequest =
      Completer<http.StreamedResponse>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request case http.Abortable(:final Future<void>? abortTrigger)
        when abortTrigger != null) {
      await abortTrigger;
      if (!abortObserved.isCompleted) abortObserved.complete();
      throw http.RequestAbortedException(request.url);
    }
    return _unabortableRequest.future;
  }

  @override
  void close() {
    if (!_unabortableRequest.isCompleted) {
      _unabortableRequest.complete(
        http.StreamedResponse(const Stream<List<int>>.empty(), 499),
      );
    }
  }
}

void main() {
  test('原图下载截止时间为 100 秒', () {
    expect(kCoverImageDownloadTimeout, const Duration(seconds: 100));
  });

  group('looksLikeImageBytes', () {
    test('Content-Type image/* 直接判是', () {
      expect(looksLikeImageBytes(const <int>[], 'image/jpeg'), isTrue);
      expect(looksLikeImageBytes(const <int>[], 'IMAGE/PNG'), isTrue);
    });

    test('字节魔数：JPEG/PNG/GIF/WebP', () {
      expect(looksLikeImageBytes(const <int>[0xFF, 0xD8, 0xFF, 0x00], null),
          isTrue); // JPEG
      expect(looksLikeImageBytes(const <int>[0x89, 0x50, 0x4E, 0x47], null),
          isTrue); // PNG
      expect(looksLikeImageBytes(const <int>[0x47, 0x49, 0x46, 0x38], null),
          isTrue); // GIF
      expect(
        looksLikeImageBytes(
            <int>[...utf8.encode('RIFF'), 0, 0, 0, 0, ...utf8.encode('WEBP')],
            null),
        isTrue,
      );
    });

    test('非图片（html 错误页）判否', () {
      expect(
        looksLikeImageBytes(utf8.encode('<html>oops</html>'), 'text/html'),
        isFalse,
      );
      expect(looksLikeImageBytes(const <int>[1, 2], null), isFalse);
    });
  });

  group('downloadImageToTempFile', () {
    late Directory tempDir;
    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('hibiki_img_download_test');
    });
    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('成功：写出图片文件、内容为响应字节', () async {
      final List<int> png = <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4];
      final MockClient client = MockClient(
        (http.Request req) async => http.Response.bytes(png, 200,
            headers: <String, String>{'content-type': 'image/png'}),
      );
      final File file = await downloadImageToTempFile(
        'https://example.invalid/cover.png',
        client: client,
        tempDir: tempDir,
      );
      expect(await file.exists(), isTrue);
      expect(p.isWithin(tempDir.path, file.path), isTrue);
      expect(await file.readAsBytes(), png);
    });

    test('显式较长截止时间允许慢响应，仍保存原响应字节', () async {
      final List<int> png = <int>[0x89, 0x50, 0x4E, 0x47, 9, 8, 7, 6];
      final MockClient client = MockClient((http.Request req) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return http.Response.bytes(
          png,
          200,
          headers: <String, String>{'content-type': 'image/png'},
        );
      });

      final File file = await downloadImageToTempFile(
        'https://example.invalid/slow-cover.png',
        client: client,
        tempDir: tempDir,
        timeout: const Duration(milliseconds: 100),
      );

      expect(await file.readAsBytes(), png);
    });

    test('书籍默认100秒绑定会取消底层请求，且不落半成品', () {
      fakeAsync((FakeAsync async) {
        final _RequestAbortTrackingClient client =
            _RequestAbortTrackingClient();
        Object? error;

        unawaited(
          downloadImageToTempFile(
            'https://example.invalid/never-responds',
            client: client,
            tempDir: tempDir,
          ).then<void>(
            (_) {},
            onError: (Object value, StackTrace stackTrace) {
              error = value;
            },
          ),
        );
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 99));
        async.flushMicrotasks();
        expect(error, isNull, reason: '书籍路径不得悄然退回30秒');

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(
          error,
          isA<ImageDownloadException>().having(
            (ImageDownloadException value) => value.message,
            'message',
            'image download timed out',
          ),
        );
        expect(client.abortObserved.isCompleted, isTrue);
        expect(tempDir.listSync(), isEmpty);

        client.close();
        async.flushMicrotasks();
      });
    });

    test('非图片响应 → 抛 ImageDownloadException，不落文件', () async {
      final MockClient client = MockClient((http.Request req) async =>
          http.Response('<html/>', 200,
              headers: <String, String>{'content-type': 'text/html'}));
      await expectLater(
        downloadImageToTempFile('https://example.invalid/x',
            client: client, tempDir: tempDir),
        throwsA(isA<ImageDownloadException>()),
      );
      expect(tempDir.listSync(), isEmpty);
    });

    test('404 → 抛 ImageDownloadException(statusCode=404)', () async {
      final MockClient client =
          MockClient((http.Request req) async => http.Response('x', 404));
      await expectLater(
        downloadImageToTempFile('https://example.invalid/x',
            client: client, tempDir: tempDir),
        throwsA(isA<ImageDownloadException>().having(
            (ImageDownloadException e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });
}
