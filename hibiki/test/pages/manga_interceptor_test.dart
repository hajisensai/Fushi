import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/manga_hibiki_page.dart';
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
      final String? resolved =
          MangaHibikiPage.resolveMangaResource(root.path, 'vol1/p001.jpg');
      expect(resolved, isNotNull);
      expect(File(resolved!).existsSync(), isTrue);
    });

    test('percent-encoded 路径解码后解析（与 mangaImageUrl 编码对称）', () {
      final String? resolved =
          MangaHibikiPage.resolveMangaResource(root.path, 'vol1/p001%2Ejpg');
      expect(resolved, isNotNull);
    });

    test('路径穿越被拒（../../ 越出 images 根）', () {
      final String? resolved = MangaHibikiPage.resolveMangaResource(
          root.path, '../../../etc/passwd');
      expect(resolved, isNull);
    });

    test('encoded 穿越同样被拒（%2E%2E%2F）', () {
      final String? resolved = MangaHibikiPage.resolveMangaResource(
          root.path, '%2E%2E%2F%2E%2E%2Fsecret.txt');
      expect(resolved, isNull);
    });

    test('树内缺文件回 null', () {
      final String? resolved =
          MangaHibikiPage.resolveMangaResource(root.path, 'vol1/missing.jpg');
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
      final String? resolved = MangaHibikiPage.resolveImageUrlToFile(
          root.path, 'https://manga.local/img/p001.jpg');
      expect(resolved, isNotNull);
    });

    test('错误 host / 非 img 路径回 null', () {
      expect(
        MangaHibikiPage.resolveImageUrlToFile(
            root.path, 'https://hoshi.local/img/p001.jpg'),
        isNull,
      );
      expect(
        MangaHibikiPage.resolveImageUrlToFile(
            root.path, 'https://manga.local/other/p001.jpg'),
        isNull,
      );
    });
  });

  test('漫画虚拟域与阅读器 hoshi.local 互异（两拦截器绝不混叠）', () {
    expect(MangaHibikiPage.kMangaHost, isNot('hoshi.local'));
    expect(MangaHibikiPage.kMangaHost, 'manga.local');
  });
}
