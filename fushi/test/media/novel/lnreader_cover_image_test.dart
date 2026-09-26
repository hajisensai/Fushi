import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_source_browse_page.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';

/// BUG-2693：LNReader 源作品列表封面大量加载失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cache;
  setUpAll(() async {
    // AppCachedHttpImage 构造即起磁盘缓存管理器，要 path_provider 应答。
    cache = await Directory.systemTemp.createTemp('lnreader-cover-cache-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => cache.path,
        );
  });
  tearDownAll(() => cache.delete(recursive: true));

  group('lnReaderCoverImage', () {
    const String site = 'https://novel.example/books/';

    test('相对 / 协议相对地址按插件站点补全，绝对地址原样', () {
      final AppCachedHttpImage relative =
          lnReaderCoverImage('/img/1.jpg', site: site)! as AppCachedHttpImage;
      expect(relative.url, 'https://novel.example/img/1.jpg');
      final AppCachedHttpImage protocolRelative =
          lnReaderCoverImage('//cdn.example/2.png', site: site)!
              as AppCachedHttpImage;
      expect(protocolRelative.url, 'https://cdn.example/2.png');
      final AppCachedHttpImage absolute =
          lnReaderCoverImage('http://img.example/3.webp', site: site)!
              as AppCachedHttpImage;
      expect(absolute.url, 'http://img.example/3.webp');
    });

    test('请求带浏览器 UA + 站点 Referer，插件头按名字不分大小写覆盖', () {
      final AppCachedHttpImage image =
          lnReaderCoverImage(
                'https://img.example/c.jpg',
                site: site,
                pluginHeaders: const <String, String>{
                  'referer': 'https://other.example/',
                },
              )!
              as AppCachedHttpImage;
      final Map<String, String> headers = image.headers!;
      expect(headers['User-Agent'], LnReaderFetchBridge.defaultUserAgent);
      expect(headers.keys.where((String k) => k.toLowerCase() == 'referer'), [
        'referer',
      ]);
      expect(headers['referer'], 'https://other.example/');
    });

    test('data: 内联图直接解码；占位图 / 空 / 本机 / 非 http 一律不发请求', () {
      expect(
        lnReaderCoverImage('data:image/png;base64,iVBORw0KGgo=', site: site),
        isA<MemoryImage>(),
      );
      for (final String? url in <String?>[
        null,
        '',
        'https://github.com/lnreader/lnreader-plugins/blob/master/public/static/coverNotAvailable.webp?raw=true',
        'http://127.0.0.1:8080/x.png',
        'http://localhost/x.png',
        'ftp://files.example/x.png',
        'data:text/html;base64,PGh0bWw+',
      ]) {
        expect(lnReaderCoverImage(url, site: site), isNull, reason: '$url');
      }
    });
  });

  group('lnReaderImageHeaders', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lnreader_cover_headers');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('Cloudflare 放行 cookie 按图片地址补上；插件自带 Cookie 时不覆盖', () async {
      final MangaCookieJar jar = MangaCookieJar(
        File('${dir.path}/cookies.json'),
      );
      await jar.replaceForHost('img.example', <MangaCookie>[
        const MangaCookie(
          name: 'cf_clearance',
          value: 'token',
          domain: 'img.example',
          path: '/',
        ),
      ]);
      final LnReaderCloudflare cloudflare = LnReaderCloudflare(jar);
      final Uri uri = Uri.parse('https://img.example/c.jpg');
      expect(
        lnReaderImageHeaders(uri: uri, cloudflare: cloudflare)['Cookie'],
        'cf_clearance=token',
      );
      expect(
        lnReaderImageHeaders(
          uri: Uri.parse('https://elsewhere.example/c.jpg'),
          cloudflare: cloudflare,
        ).containsKey('Cookie'),
        isFalse,
      );
      final Map<String, String> own = lnReaderImageHeaders(
        uri: uri,
        pluginHeaders: const <String, String>{'cookie': 'a=b'},
        cloudflare: cloudflare,
      );
      expect(own['cookie'], 'a=b');
      expect(own.containsKey('Cookie'), isFalse);
    });
  });

  test('仓库索引里的相对图标路径按索引地址解析', () {
    final LnReaderRepoPlugin plugin =
        LnReaderRepoPlugin.tryParse(<String, Object?>{
          'id': 'x',
          'name': 'X',
          'url': 'https://repo.example/x.js',
          'version': '1.0.0',
          'iconUrl': 'icons/x.png',
        }, storeUrl: 'https://repo.example/dist/plugins.min.json')!;
    expect(plugin.iconUrl, 'https://repo.example/dist/icons/x.png');
    final LnReaderRepoPlugin absolute =
        LnReaderRepoPlugin.tryParse(<String, Object?>{
          'id': 'y',
          'name': 'Y',
          'url': 'https://repo.example/y.js',
          'version': '1.0.0',
          'iconUrl': 'https://cdn.example/y.png',
        }, storeUrl: 'https://repo.example/dist/plugins.min.json')!;
    expect(absolute.iconUrl, 'https://cdn.example/y.png');
  });
}
