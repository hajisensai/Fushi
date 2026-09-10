import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';

/// 互联漫画源的 host 端点（`/api/library/manga/**`）。
///
/// 用真 [FushiSyncServer] + 真 HTTP + 真文件，而不是直接调 service：这批端点的价值
/// 全在「路由 / 鉴权 / 能力协商 / 404 分型 / Range 下发」这几层上，绕开它们测等于什么
/// 都没测。
class _MangaHost extends Fake
    implements FushiLibraryHostService, MangaLibraryHost {
  _MangaHost(this.manifest, this.pageFiles);

  final RemoteMangaManifest manifest;
  final List<File> pageFiles;

  @override
  Future<RemoteMangaManifest> mangaManifest(String bookKey) async {
    if (bookKey.contains('..') || bookKey.contains('/')) {
      throw ArgumentError('unsafe book key');
    }
    if (bookKey != manifest.bookKey) {
      throw StateError('manga book not found: $bookKey');
    }
    return manifest;
  }

  @override
  Future<File> mangaPageFile(String bookKey, int index) async {
    if (bookKey != manifest.bookKey) {
      throw StateError('manga book not found: $bookKey');
    }
    if (index < 0 || index >= pageFiles.length) {
      throw StateError('manga page out of range: $bookKey#$index');
    }
    return pageFiles[index];
  }
}

/// 只实现主接口、**不**实现 [MangaLibraryHost] 的 host：老版本 / 精简 host 的形状。
class _NoMangaHost extends Fake implements FushiLibraryHostService {}

void main() {
  const String token = 'tkn-manga';
  const List<int> pngBytes = <int>[0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4, 5, 6];

  late Directory tmp;
  late FushiSyncServer server;
  late String base;

  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  Future<HttpClientResponse> get(
    String path, {
    bool authorize = true,
    String? range,
  }) async {
    final HttpClient client = HttpClient();
    final HttpClientRequest req = await client.getUrl(Uri.parse('$base$path'));
    if (authorize) req.headers.set('authorization', authHeader());
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final HttpClientResponse res = await req.close();
    client.close();
    return res;
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hbk_manga_srv');
    final List<File> pages = <File>[
      for (int i = 0; i < 3; i++)
        File('${tmp.path}/p$i.png')..writeAsBytesSync(<int>[...pngBytes, i]),
    ];
    server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: _MangaHost(
        RemoteMangaManifest(
          bookKey: 'vol1',
          title: 'よつばと！1',
          readingMode: 'spread',
          pages: const <RemoteMangaPageInfo>[
            RemoteMangaPageInfo(
              index: 0,
              name: 'p001.png',
              width: 1200,
              height: 1700,
            ),
            RemoteMangaPageInfo(index: 1, name: 'p002.png'),
            RemoteMangaPageInfo(index: 2, name: 'sub/p003.png'),
          ],
        ),
        pages,
      ),
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.stop();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  test('能力位随 MangaLibraryHost 一起出现', () async {
    final HttpClientResponse res = await get('/api/capabilities');
    expect(res.statusCode, 200);
    final Map<String, Object?> json =
        (jsonDecode(await res.transform(utf8.decoder).join()) as Map)
            .cast<String, Object?>();
    final Map<String, Object?> live =
        (json['liveLibrary']! as Map).cast<String, Object?>();
    expect(live['manga'], isTrue);
  });

  test('页表带页序、尺寸与阅读模式', () async {
    final HttpClientResponse res =
        await get('/api/library/manga/vol1/manifest');
    expect(res.statusCode, 200);
    final RemoteMangaManifest manifest = RemoteMangaManifest.fromJson(
      (jsonDecode(await res.transform(utf8.decoder).join()) as Map)
          .cast<String, Object?>(),
    );
    expect(manifest.bookKey, 'vol1');
    expect(manifest.title, 'よつばと！1');
    expect(manifest.readingMode, 'spread');
    expect(manifest.pages.length, 3);
    expect(manifest.pages.first.width, 1200);
    expect(manifest.pages.first.height, 1700);
    // 尺寸缺失编成 0（wire 上不写键），client 侧据此回落真实字节尺寸。
    expect(manifest.pages[1].width, 0);
    // 子目录结构原样保留——两页同名不同目录不能塌成一个。
    expect(manifest.pages[2].name, 'sub/p003.png');
  });

  test('按页取图返回该页字节', () async {
    final HttpClientResponse res = await get('/api/library/manga/vol1/pages/1');
    expect(res.statusCode, 200);
    final List<int> bytes = <int>[
      await for (final List<int> chunk in res) ...chunk,
    ];
    expect(bytes, <int>[...pngBytes, 1]);
  });

  test('页图支持 Range（阅读器可断点续取大页图）', () async {
    final HttpClientResponse res = await get(
      '/api/library/manga/vol1/pages/0',
      range: 'bytes=0-3',
    );
    expect(res.statusCode, 206);
    expect(res.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    final List<int> bytes = <int>[
      await for (final List<int> chunk in res) ...chunk,
    ];
    expect(bytes, pngBytes.sublist(0, 4));
  });

  test('越界页 / 不存在的书都是 404，不是 500', () async {
    expect((await get('/api/library/manga/vol1/pages/99')).statusCode, 404);
    expect((await get('/api/library/manga/nope/manifest')).statusCode, 404);
  });

  test('未鉴权一律 401——漫画页图没有视频 stream 那种 token 豁免', () async {
    expect(
      (await get('/api/library/manga/vol1/manifest', authorize: false))
          .statusCode,
      401,
    );
    expect(
      (await get('/api/library/manga/vol1/pages/0', authorize: false))
          .statusCode,
      401,
    );
  });

  test('写方法一律 405（本域只读）', () async {
    final HttpClient client = HttpClient();
    final HttpClientRequest req = await client.deleteUrl(
      Uri.parse('$base/api/library/manga/vol1/manifest'),
    );
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 405);
    await res.drain<void>();
    client.close();
  });

  test('穿越形状的 bookKey 进不了 service', () async {
    // `..` 会被路由前缀切分成别的形状，这里断言的是「无论怎么切，都不是 2xx」。
    expect(
      (await get('/api/library/manga/..%2F..%2Fetc/manifest')).statusCode,
      isNot(inInclusiveRange(200, 299)),
    );
  });

  group('不提供漫画能力的 host', () {
    late FushiSyncServer bare;
    late String bareBase;

    setUp(() async {
      bare = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_manga_bare').path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: _NoMangaHost(),
      );
      await bare.start();
      bareBase = 'http://127.0.0.1:${bare.port}';
    });

    tearDown(() async => bare.stop());

    Future<HttpClientResponse> bareGet(String path) async {
      final HttpClient client = HttpClient();
      final HttpClientRequest req = await client.getUrl(
        Uri.parse('$bareBase$path'),
      );
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      client.close();
      return res;
    }

    test('能力位为 false 且端点 404（新 client 据此提示对端版本过低）', () async {
      final HttpClientResponse caps = await bareGet('/api/capabilities');
      final Map<String, Object?> json =
          (jsonDecode(await caps.transform(utf8.decoder).join()) as Map)
              .cast<String, Object?>();
      expect(
        ((json['liveLibrary']! as Map).cast<String, Object?>())['manga'],
        isFalse,
      );
      expect(
          (await bareGet('/api/library/manga/vol1/manifest')).statusCode, 404);
    });
  });
}
