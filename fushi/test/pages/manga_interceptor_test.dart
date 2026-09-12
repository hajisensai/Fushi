import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:path/path.dart' as p;

void main() {
  group('resolveMangaResource（穿越守卫）', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('manga_intercept_');
      final File img = File(p.join(root.path, 'vol1', 'p001.jpg'))
        ..createSync(recursive: true);
      img.writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('树内图片路径可解析（保留子目录结构）', () {
      final String? resolved = MangaFushiPage.resolveMangaResource(
        root.path,
        'vol1/p001.jpg',
      );
      expect(resolved, isNotNull);
      expect(File(resolved!).existsSync(), isTrue);
    });

    test('BUG-2484：裸路径不解码——含 % 的图名原样解析、不抛', () {
      File(p.join(root.path, 'vol1', '100%.jpg')).writeAsBytesSync(<int>[1]);
      final String? resolved = MangaFushiPage.resolveMangaResource(
        root.path,
        'vol1/100%.jpg',
      );
      expect(resolved, isNotNull);
      expect(p.basename(resolved!), '100%.jpg');
    });

    test('BUG-2484：形如 %41.jpg 的合法图名不被误解码成 A.jpg', () {
      File(p.join(root.path, 'vol1', '%41.jpg')).writeAsBytesSync(<int>[1]);
      File(p.join(root.path, 'vol1', 'A.jpg')).writeAsBytesSync(<int>[2]);
      final String? resolved = MangaFushiPage.resolveMangaResource(
        root.path,
        'vol1/%41.jpg',
      );
      expect(resolved, isNotNull);
      expect(p.basename(resolved!), '%41.jpg');
    });

    test('路径穿越被拒（../../ 越出 images 根）', () {
      final String? resolved = MangaFushiPage.resolveMangaResource(
        root.path,
        '../../../etc/passwd',
      );
      expect(resolved, isNull);
    });

    test('树内缺文件回 null', () {
      final String? resolved = MangaFushiPage.resolveMangaResource(
        root.path,
        'vol1/missing.jpg',
      );
      expect(resolved, isNull);
    });
  });

  group('resolveImageUrlToFile', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('manga_imgurl_');
      File(p.join(root.path, 'p001.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1]);
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('manga.local 图片 URL 解析到树内文件', () {
      final String? resolved = MangaFushiPage.resolveImageUrlToFile(
        root.path,
        'https://manga.local/img/p001.jpg',
      );
      expect(resolved, isNotNull);
      final String? customSchemeResolved = MangaFushiPage.resolveImageUrlToFile(
        root.path,
        'fushi-manga://manga.local/img/p001.jpg',
      );
      expect(customSchemeResolved, isNotNull);
    });

    test('percent-encoded 路径在 URL 边界解码（与 mangaImageUrl 编码对称）', () {
      final String? resolved = MangaFushiPage.resolveImageUrlToFile(
        root.path,
        'https://manga.local/img/p001%2Ejpg',
      );
      expect(resolved, isNotNull);
    });

    test('encoded 穿越被拒（%2E%2E%2F）', () {
      final String? resolved = MangaFushiPage.resolveImageUrlToFile(
        root.path,
        'https://manga.local/img/%2E%2E%2F%2E%2E%2Fsecret.txt',
      );
      expect(resolved, isNull);
    });

    test('BUG-2484：含 % 的图名经 mangaImageUrl 编码后能往返解析', () {
      File(p.join(root.path, 'vol 1', '100%.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1]);
      final String url = MangaFushiPage.mangaImageUrl('images/vol 1/100%.jpg');
      expect(url, 'https://manga.local/img/vol%201/100%25.jpg');
      final String? resolved = MangaFushiPage.resolveImageUrlToFile(
        root.path,
        url,
      );
      expect(resolved, isNotNull);
      expect(p.basename(resolved!), '100%.jpg');
    });

    test('BUG-2484：URL 编码非法回 null 而不是抛异常（两类异常都要接）', () {
      // `Uri.decodeComponent` 对非法输入抛两种**不同层级**的东西（实测）：
      //   percent 语法本身非法（`100%`/`%`/`%2`/`%GG`） -> ArgumentError（是 Error）
      //   语法合法但解出来不是合法 UTF-8（`%FF`/`%C3%28`） -> FormatException（是 Exception）
      // 起初只接了前者，`%FF` 这类照样掀翻拦截器——WebView 可以请求任意
      // manga.local URL，这条路径可达。也不能合并写成 `on Exception`：
      // ArgumentError 继承 Error 而非 Exception，那样会把前一半漏掉。
      for (final String bad in <String>[
        '100%.jpg', // ArgumentError
        '%.jpg', // ArgumentError
        '%2', // ArgumentError
        '%GG.jpg', // ArgumentError
        '%FF.jpg', // FormatException
        '%C3%28.jpg', // FormatException
      ]) {
        expect(
          MangaFushiPage.decodeMangaImagePath(bad),
          isNull,
          reason: '$bad 必须回 null 而不是抛出',
        );
      }
      // 走完整 URL 边界：`%FF` 能原样穿过 Uri.parse（不像孤立的 `%` 会被重编码成
      // `%25`），所以这一条真的会打到解码分支上。
      expect(
        MangaFushiPage.resolveImageUrlToFile(
          root.path,
          'https://manga.local/img/%FF.jpg',
        ),
        isNull,
      );
    });

    test('错误 host / 非 img 路径回 null', () {
      expect(
        MangaFushiPage.resolveImageUrlToFile(
          root.path,
          'https://fushi.local/img/p001.jpg',
        ),
        isNull,
      );
      expect(
        MangaFushiPage.resolveImageUrlToFile(
          root.path,
          'https://manga.local/other/p001.jpg',
        ),
        isNull,
      );
    });
  });

  test('漫画虚拟域与阅读器 fushi.local 互异（两拦截器绝不混叠）', () {
    expect(MangaFushiPage.kMangaHost, isNot('fushi.local'));
    expect(MangaFushiPage.kMangaHost, 'manga.local');
    expect(MangaFushiPage.kMangaResourceScheme, 'fushi-manga');
  });
}
