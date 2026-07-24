import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart'
    show ScrapeNetworkException;
import 'package:hibiki/src/media/video/scraper/poster_downloader.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart'
    show videoCoverFileName;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// 最小合法 PNG 魔数字节（89 50 4E 47 0D 0A 1A 0A + 少量填充）。
final List<int> _fakePng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
];

void main() {
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
    final String path = await PosterDownloader(client: client).downloadPoster(
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
    final String path = await PosterDownloader(client: client).downloadPoster(
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
      PosterDownloader(client: client).downloadPoster(
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
      PosterDownloader(client: client).downloadPoster(
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
    final String path = await PosterDownloader(client: client).downloadPoster(
      url: 'https://img/new',
      bookUid: 'uid4',
      coversDirectory: tempDir,
    );
    expect(path, finalPath);
    expect(File(path).readAsBytesSync(), _fakePng); // 已覆盖
  });
}
