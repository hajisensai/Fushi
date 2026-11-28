import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/banner/banner_book_scan.dart';
import 'package:path/path.dart' as p;

/// 「横幅…」面板的「书中」候选：漫画横版页（manga.json 自带尺寸）、EPUB 卷首彩页
/// 与横版插图（只读文件头量尺寸），封面 / 行内小图 / 缺文件 / 越界的都不进。
void main() {
  /// 只有文件头的 PNG（探针只读 IHDR 里的宽高）。
  Uint8List pngHeader(int width, int height) {
    final ByteData data = ByteData(33);
    const List<int> sig = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (int i = 0; i < sig.length; i++) {
      data.setUint8(i, sig[i]);
    }
    data.setUint32(8, 13);
    const List<int> ihdr = <int>[0x49, 0x48, 0x44, 0x52];
    for (int i = 0; i < 4; i++) {
      data.setUint8(12 + i, ihdr[i]);
    }
    data.setUint32(16, width);
    data.setUint32(20, height);
    return data.buffer.asUint8List();
  }

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('banner_scan_'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('判据（纯函数）', () {
    test('比 16:9 窄才要裁；够宽 / 尺寸非法不裁', () {
      expect(bannerNeedsCrop(width: 1000, height: 1500), isTrue);
      expect(bannerNeedsCrop(width: 2800, height: 2000), isTrue, reason: '跨页');
      expect(bannerNeedsCrop(width: 1920, height: 1080), isFalse);
      expect(bannerNeedsCrop(width: 1900, height: 400), isFalse, reason: '横幅');
      expect(bannerNeedsCrop(width: 0, height: 0), isFalse);
    });

    test('漫画：只要横版页（≥1.2），尺寸缺失跳过，按上限截断', () {
      final List<({int width, int height})> pages = <({int width, int height})>[
        (width: 1000, height: 1500),
        (width: 2800, height: 2000),
        (width: 0, height: 0),
        (width: 1200, height: 1000),
        (width: 1100, height: 1000),
        (width: 3000, height: 1000),
      ];
      expect(selectWideMangaPages(pages), <int>[1, 3, 5]);
      expect(selectWideMangaPages(pages, limit: 2), <int>[1, 3]);
    });

    test('EPUB：封面 / 量不出 / 行内小图不要；前 N 张大图不论横竖，之后只要横版', () {
      final List<({bool cover, int? width, int? height})> images =
          <({bool cover, int? width, int? height})>[
            (cover: true, width: 1000, height: 1500),
            (cover: false, width: 120, height: 160),
            (cover: false, width: 1000, height: 1400),
            (cover: false, width: null, height: null),
            (cover: false, width: 2000, height: 1400),
            (cover: false, width: 800, height: 1200),
            (cover: false, width: 2400, height: 1600),
          ];
      expect(selectEpubBannerImages(images, frontPlates: 1), <int>[2, 4, 6]);
      expect(selectEpubBannerImages(images, frontPlates: 6), <int>[2, 4, 5, 6]);
      expect(selectEpubBannerImages(images, frontPlates: 6, limit: 2), <int>[
        2,
        4,
      ]);
    });
  });

  test('漫画卷：读 manga.json，横版页入选、缺文件的页跳过，页号 1 起', () {
    final Directory images = Directory(p.join(dir.path, 'images'))
      ..createSync();
    File(p.join(images.path, 'p1.jpg')).writeAsBytesSync(<int>[1]);
    File(p.join(images.path, 'p2.jpg')).writeAsBytesSync(<int>[1]);
    File(p.join(dir.path, 'manga.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'pages': <Map<String, Object?>>[
          <String, Object?>{
            'url': 'images/p1.jpg',
            'width': 1000,
            'height': 1500,
          },
          <String, Object?>{
            'url': 'images/p2.jpg',
            'width': 2800,
            'height': 2000,
          },
          <String, Object?>{
            'url': 'images/missing.jpg',
            'width': 3000,
            'height': 2000,
          },
          <String, Object?>{
            'url': '../escape.jpg',
            'width': 3000,
            'height': 2000,
          },
        ],
      }),
    );
    final List<BannerBookPick> picks = scanMangaBookForBanners((
      extractDir: dir.path,
      epubPath: 'manga.json',
    ));
    expect(picks, hasLength(1));
    expect(picks.single.ordinal, 2);
    expect(picks.single.isPage, isTrue);
    expect(picks.single.width, 2800);
    expect(p.basename(picks.single.path), 'p2.jpg');
  });

  test('EPUB：只读文件头量尺寸；重复引用只算一次，越界 / 缺文件跳过', () {
    final Directory oebps = Directory(p.join(dir.path, 'OEBPS', 'img'))
      ..createSync(recursive: true);
    void png(String name, int w, int h) =>
        File(p.join(oebps.path, name)).writeAsBytesSync(pngHeader(w, h));
    png('cover.png', 1000, 1500);
    png('plate1.png', 1000, 1400);
    png('spread.png', 2400, 1600);
    png('gaiji.png', 40, 40);
    final List<BannerBookPick> picks = scanEpubImagesForBanners((
      extractDir: dir.path,
      srcs: <String>[
        'OEBPS/img/cover.png',
        'OEBPS/img/cover.png',
        'OEBPS/img/plate1.png',
        'OEBPS/img/gaiji.png',
        'OEBPS/img/none.png',
        '../outside.png',
        'OEBPS/img/spread.png',
      ],
      cover: <bool>[true, false, false, false, false, false, false],
    ));
    expect(
      <String>[for (final BannerBookPick b in picks) p.basename(b.path)],
      <String>['plate1.png', 'spread.png'],
    );
    expect(picks.last.wide, isTrue);
    expect(picks.first.wide, isFalse);
    expect(picks.every((BannerBookPick b) => !b.isPage), isTrue);
  });
}
