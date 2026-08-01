import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/metadata/credential_redaction.dart';
import 'package:hibiki/src/media/metadata/image_download.dart'
    show kCoverImageDownloadTimeout;
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart'
    show ScrapeNetworkException;
import 'package:hibiki/src/media/video/scraper/cover_downloader.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart'
    show videoCoverFileName;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:transparent_image/transparent_image.dart';

import '../../../helpers/cover_cache_test_helpers.dart';

/// 先返回响应头、再把 body stream 挂住，只有 abort trigger 才释放。
///
/// 这覆盖「Future.timeout 已向 UI 报错，但源响应流仍在后台下载」的旧缺陷。
final class _StreamAbortTrackingClient extends http.BaseClient {
  final Completer<void> abortObserved = Completer<void>();
  final List<StreamController<List<int>>> _openResponses =
      <StreamController<List<int>>>[];

  /// 实际发起的尝试次数。共享总预算下预算被吃光即停手，不再发起新尝试。
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCount++;
    final StreamController<List<int>> response = StreamController<List<int>>();
    _openResponses.add(response);
    if (request case http.Abortable(:final Future<void>? abortTrigger)
        when abortTrigger != null) {
      unawaited(
        abortTrigger.whenComplete(() {
          if (!abortObserved.isCompleted) abortObserved.complete();
          if (!response.isClosed) {
            response.addError(http.RequestAbortedException(request.url));
            unawaited(response.close());
          }
        }),
      );
    }
    return http.StreamedResponse(
      response.stream,
      200,
      headers: const <String, String>{'content-type': 'image/png'},
    );
  }

  @override
  void close() {
    for (final StreamController<List<int>> response in _openResponses) {
      if (!response.isClosed) unawaited(response.close());
    }
  }
}

/// 最小合法 PNG 魔数字节（89 50 4E 47 0D 0A 1A 0A + 少量填充）。
final List<int> _fakePng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
];

void main() {
  // downloadCover 落盘后走 evictLocalCoverCache（需要 PaintingBinding）。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('视频封面复用 100 秒原图下载截止时间', () {
    final CoverDownloader downloader = CoverDownloader(
      client: MockClient(
        (http.Request request) async => http.Response('', 200),
      ),
    );
    expect(downloader.timeout, kCoverImageDownloadTimeout);
    expect(downloader.timeout, const Duration(seconds: 100));
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('poster_dl_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('PNG 字节 → 落地文件名符合约定、内容一致、返回绝对路径', () async {
    final MockClient client = MockClient((http.Request req) async {
      return http.Response.bytes(
        _fakePng,
        200,
        headers: const <String, String>{'content-type': 'image/png'},
      );
    });
    const String bookUid = 'video/playlist/鬼滅';
    final String path = await CoverDownloader(client: client).downloadCover(
      url: 'https://img/poster.png',
      bookUid: bookUid,
      coversDirectory: tempDir,
    );

    // 文件名沿用 videoCoverFileName 约定（斜杠归一为 _，扩展名 .jpg）。
    final String expectedName = videoCoverFileName(bookUid);
    expect(p.basename(path), expectedName);
    expect(p.basename(path), 'video_playlist_鬼滅.jpg');
    expect(File(path).existsSync(), isTrue);
    expect(File(path).readAsBytesSync(), _fakePng);
    // 无残留 .tmp。
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('content-type=image/ 缺失但字节魔数是图片 → 仍接受', () async {
    final MockClient client = MockClient((http.Request req) async {
      // 无 content-type 头，靠魔数嗅探。
      return http.Response.bytes(_fakePng, 200);
    });
    final String path = await CoverDownloader(client: client).downloadCover(
      url: 'https://img/x',
      bookUid: 'uid1',
      coversDirectory: tempDir,
    );
    expect(File(path).existsSync(), isTrue);
  });

  test('content-type=text/html 且非图片字节 → 拒绝、不落地、不留 .tmp', () async {
    final MockClient client = MockClient((http.Request req) async {
      return http.Response(
        '<html>error</html>',
        200,
        headers: const <String, String>{'content-type': 'text/html'},
      );
    });
    const String bookUid = 'uid2';
    await expectLater(
      CoverDownloader(client: client).downloadCover(
        url: 'https://img/notimage',
        bookUid: bookUid,
        coversDirectory: tempDir,
      ),
      throwsA(isA<ScrapeNetworkException>()),
    );
    final String finalPath = p.join(tempDir.path, videoCoverFileName(bookUid));
    expect(File(finalPath).existsSync(), isFalse);
    expect(File('$finalPath.tmp').existsSync(), isFalse);
  });

  test('404 响应 → 抛 ScrapeNetworkException，不留任何文件', () async {
    final MockClient client =
        MockClient((http.Request req) async => http.Response('nf', 404));
    const String bookUid = 'uid3';
    await expectLater(
      CoverDownloader(client: client).downloadCover(
        url: 'https://img/404',
        bookUid: bookUid,
        coversDirectory: tempDir,
      ),
      throwsA(
        isA<ScrapeNetworkException>().having(
            (ScrapeNetworkException e) => e.statusCode, 'statusCode', 404),
      ),
    );
    final String finalPath = p.join(tempDir.path, videoCoverFileName(bookUid));
    expect(File(finalPath).existsSync(), isFalse);
    expect(File('$finalPath.tmp').existsSync(), isFalse);
  });

  test('传输异常在构造侧脱敏候选海报 URL 凭据', () async {
    const String secret = 'SECRET_POSTER_TOKEN_456';
    final MockClient client = MockClient((http.Request req) async {
      throw http.ClientException('connection reset', req.url);
    });

    try {
      await CoverDownloader(client: client).downloadCover(
        url: 'https://img.example/poster?size=original&api_key=$secret',
        bookUid: 'uid-secret',
        coversDirectory: tempDir,
      );
      fail('should throw');
    } on ScrapeNetworkException catch (error) {
      final String detail = error.toString();
      expect(detail, contains('size=original'));
      expect(detail, contains('api_key=$kRedactedPlaceholder'));
      expect(detail, isNot(contains(secret)));
    }
  });

  test(
    '超过截止时间会取消底层响应流，不覆盖旧封面且不留 .tmp',
    () async {
      const String bookUid = 'uid_timeout';
      final String finalPath =
          p.join(tempDir.path, videoCoverFileName(bookUid));
      const List<int> oldCover = <int>[0xFF, 0xD8, 0xFF, 0x01];
      await File(finalPath).writeAsBytes(oldCover);
      final _StreamAbortTrackingClient client = _StreamAbortTrackingClient();

      await expectLater(
        CoverDownloader(
          client: client,
          timeout: const Duration(milliseconds: 5),
          // 传输重试（BUG-1272）对超时同样重放；这里只去掉真实退避等待，
          // 判据（abort 已触发 / 旧封面不动 / 无 .tmp）不变。
          retrySleep: (Duration _) async {},
        ).downloadCover(
          url: 'https://img/slow',
          bookUid: bookUid,
          coversDirectory: tempDir,
        ),
        throwsA(
          isA<ScrapeNetworkException>().having(
            (ScrapeNetworkException error) => error.message,
            'message',
            'Poster download timed out',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.abortObserved.isCompleted, isTrue);
      expect(File(finalPath).readAsBytesSync(), oldCover);
      expect(File('$finalPath.tmp').existsSync(), isFalse);
      client.close();
    },
    timeout: const Timeout(Duration(seconds: 2)),
  );

  test(
    '总截止跨重试共享：预算被首次尝试吃光后不再发起新尝试，在飞传输仍被真正 abort',
    () async {
      const String bookUid = 'uid_shared_budget';
      final String finalPath =
          p.join(tempDir.path, videoCoverFileName(bookUid));
      const List<int> oldCover = <int>[0xFF, 0xD8, 0xFF, 0x03];
      await File(finalPath).writeAsBytes(oldCover);

      const Duration budget = Duration(milliseconds: 200);
      final _StreamAbortTrackingClient client = _StreamAbortTrackingClient();
      final Stopwatch elapsed = Stopwatch()..start();

      await expectLater(
        CoverDownloader(
          client: client,
          timeout: budget,
          maxAttempts: 3,
          // 去掉真实退避等待；判据只看尝试次数 / 总耗时 / abort，与退避无关。
          retrySleep: (Duration _) async {},
        ).downloadCover(
          url: 'https://img/hang',
          bookUid: bookUid,
          coversDirectory: tempDir,
        ),
        throwsA(
          isA<ScrapeNetworkException>().having(
            (ScrapeNetworkException error) => error.message,
            'message',
            'Poster download timed out',
          ),
        ),
      );
      elapsed.stop();

      // 旧口径「每次尝试各自计时」会发 3 次请求、总耗时 3×budget；
      // 共享总预算下预算被首次尝试吃光，第 2、3 次尝试不得发起。
      expect(client.sendCount, 1, reason: '预算用尽后不得再发起新的尝试');
      expect(
        elapsed.elapsed,
        lessThan(const Duration(milliseconds: 500)),
        reason: '3 次重试合计不得超过总预算（旧口径要 3×200ms）',
      );

      await Future<void>.delayed(Duration.zero);
      expect(
        client.abortObserved.isCompleted,
        isTrue,
        reason: '总截止到点必须真正中止底层响应流，而非只让等待层放弃（BUG-1248）',
      );
      expect(File(finalPath).readAsBytesSync(), oldCover);
      expect(File('$finalPath.tmp').existsSync(), isFalse);
      client.close();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test('退避期间预算耗尽 → 剩余重试次数用不满，不再发起新尝试', () async {
    int sends = 0;
    final MockClient client = MockClient((http.Request req) async {
      sends++;
      throw const SocketException('connection reset');
    });

    await expectLater(
      CoverDownloader(
        client: client,
        timeout: const Duration(milliseconds: 250),
        maxAttempts: 3,
        // 每次退避吃掉 150ms 共享预算：第二次退避结束时总预算已耗尽。
        retrySleep: (Duration _) =>
            Future<void>.delayed(const Duration(milliseconds: 150)),
      ).downloadCover(
        url: 'https://img/flaky',
        bookUid: 'uid_budget_exhausted',
        coversDirectory: tempDir,
      ),
      throwsA(isA<ScrapeNetworkException>()),
    );

    // 预期恰好 2 次（第 3 次退避后预算已过期）；放宽成 <3 只为躲开慢机上的
    // 定时器抖动——被钉死的性质是「不再把 maxAttempts 用满」。
    expect(
      sends,
      allOf(greaterThanOrEqualTo(1), lessThan(3)),
      reason: '共享预算耗尽后不得继续重试（旧口径会把 3 次用满）',
    );
  });

  test('底层 IO 失败不覆盖旧封面且不留 .tmp', () async {
    const String bookUid = 'uid_io_error';
    final String finalPath = p.join(tempDir.path, videoCoverFileName(bookUid));
    const List<int> oldCover = <int>[0xFF, 0xD8, 0xFF, 0x02];
    await File(finalPath).writeAsBytes(oldCover);
    final MockClient client = MockClient(
      (http.Request req) async =>
          throw const SocketException('connection reset'),
    );

    await expectLater(
      CoverDownloader(
        client: client,
        retrySleep: (Duration _) async {},
      ).downloadCover(
        url: 'https://img/io-error',
        bookUid: bookUid,
        coversDirectory: tempDir,
      ),
      throwsA(isA<ScrapeNetworkException>()),
    );
    expect(File(finalPath).readAsBytesSync(), oldCover);
    expect(File('$finalPath.tmp').existsSync(), isFalse);
  });

  test('覆盖旧封面：同 uid 二次下载直接替换内容', () async {
    final String finalPath = p.join(tempDir.path, videoCoverFileName('uid4'));
    await File(finalPath).writeAsBytes(<int>[0, 0, 0, 0]); // 旧封面

    final MockClient client = MockClient((http.Request req) async {
      return http.Response.bytes(
        _fakePng,
        200,
        headers: const <String, String>{'content-type': 'image/jpeg'},
      );
    });
    final String path = await CoverDownloader(client: client).downloadCover(
      url: 'https://img/new',
      bookUid: 'uid4',
      coversDirectory: tempDir,
    );
    expect(path, finalPath);
    expect(File(path).readAsBytesSync(), _fakePng); // 已覆盖
  });

  test('二次下载覆盖同路径后双键驱逐旧解码缓存（BUG-1118）', () async {
    // kTransparentImage 是真实可解码 PNG（_fakePng 只有魔数、解不了码）。
    final MockClient client = MockClient((http.Request req) async {
      return http.Response.bytes(
        kTransparentImage,
        200,
        headers: const <String, String>{'content-type': 'image/png'},
      );
    });
    final CoverDownloader downloader = CoverDownloader(client: client);

    final String path = await downloader.downloadCover(
      url: 'https://img/first.png',
      bookUid: 'uid_evict',
      coversDirectory: tempDir,
    );
    // 模拟卡片渲染：两个键都解码进缓存。
    await populateBothCoverKeys(path);

    // 二次下载覆盖同一路径 → 双键必须被驱逐，否则 UI 重建仍显示旧封面。
    final String again = await downloader.downloadCover(
      url: 'https://img/second.png',
      bookUid: 'uid_evict',
      coversDirectory: tempDir,
    );
    expect(again, path, reason: '同 uid 恒落同一路径（覆盖写）');
    await expectBothCoverKeysEvicted(path);
  });
}
