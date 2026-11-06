import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/web/web_comic_scan.dart';

void main() {
  final Uri page = Uri.parse('https://site.example/comic/1/chapter/2');

  test('相对 URL 按 pageUrl 解析、按绝对地址去重保序、去掉 fragment', () {
    final WebComicScanResult? result = normalizeWebComicScan(<String, Object?>{
      'pageUrl': page.toString(),
      'title': '  第2话  ',
      'images': <Object?>[
        <String, Object?>{'url': '/img/001.jpg', 'w': 800, 'h': 1200},
        <String, Object?>{'url': 'https://site.example/img/001.jpg#x'},
        <String, Object?>{'url': '../../img/002.jpg', 'w': 800, 'h': 1200},
        'https://cdn.example/003.webp',
      ],
    }, fallbackPageUrl: page);
    expect(result, isNotNull);
    expect(result!.title, '第2话');
    expect(result.images.map((WebComicScannedImage i) => i.url), <String>[
      'https://site.example/img/001.jpg',
      'https://site.example/comic/img/002.jpg',
      'https://cdn.example/003.webp',
    ]);
  });

  test('报了原图尺寸且长边低于阈值的丢掉；没报尺寸的保留', () {
    final WebComicScanResult result = normalizeWebComicScan(<String, Object?>{
      'images': <Object?>[
        <String, Object?>{'url': 'a.png', 'w': 64, 'h': 64},
        <String, Object?>{'url': 'b.png', 'w': 300, 'h': 499},
        <String, Object?>{'url': 'c.png', 'w': 300, 'h': 500},
        <String, Object?>{'url': 'd.png'},
        <String, Object?>{'url': 'e.png', 'w': 0, 'h': 0},
      ],
    }, fallbackPageUrl: page)!;
    expect(
      result.images.map((WebComicScannedImage i) => i.url.split('/').last),
      <String>['c.png', 'd.png', 'e.png'],
    );
  });

  test('data: / blob: / javascript: 取不回字节，一律丢掉', () {
    final WebComicScanResult result = normalizeWebComicScan(<String, Object?>{
      'images': <Object?>[
        'data:image/png;base64,AAAA',
        'blob:https://site.example/uuid',
        'javascript:void(0)',
        'ok.jpg',
      ],
    }, fallbackPageUrl: page)!;
    expect(
      result.images.single.url,
      'https://site.example/comic/1/chapter/ok.jpg',
    );
  });

  test('上下章链接解析成绝对地址；指回本页的链接丢掉', () {
    final WebComicScanResult result = normalizeWebComicScan(<String, Object?>{
      'pageUrl': page.toString(),
      'images': <Object?>[],
      'nextChapterUrl': '/comic/1/chapter/3',
      'prevChapterUrl': '$page#top',
    }, fallbackPageUrl: page)!;
    expect(
      result.nextChapterUrl.toString(),
      'https://site.example/comic/1/chapter/3',
    );
    expect(result.prevChapterUrl, isNull);
    expect(result.isEmpty, isTrue);
  });

  test('不是 map 返回 null；pageUrl 不是 http(s) 时用兜底地址', () {
    expect(normalizeWebComicScan('x', fallbackPageUrl: page), isNull);
    final WebComicScanResult result = normalizeWebComicScan(<String, Object?>{
      'pageUrl': 'about:blank',
      'images': <Object?>[],
    }, fallbackPageUrl: page)!;
    expect(result.pageUrl, page);
    expect(result.title, 'site.example');
  });

  test('脚本报的 pageUrl 换了主机时不采信，退回 WebView 自己的地址', () {
    final WebComicScanResult result = normalizeWebComicScan(<String, Object?>{
      'pageUrl': 'https://victim.example/account',
      'images': <Object?>[
        <String, Object?>{'url': 'img/1.jpg'},
      ],
    }, fallbackPageUrl: page)!;
    expect(result.pageUrl, page);
    expect(
      result.images.single.url,
      'https://site.example/comic/1/chapter/img/1.jpg',
    );
  });
}
