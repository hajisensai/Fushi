import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_spread_model.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:path/path.dart' as p;

/// ERRATA C2：制卡卡图从**当前 spread 首页**经 firstPageOfSpread →
/// resolveMangaResource 解析（`_updateCurrentPageImagePath` 的组合），必须解析出
/// 非 null 真实路径、且翻页后重解析到新页。旧分支修过的坑：漏更新会让
/// coverPath 恒 null（卡片永远无图）。
void main() {
  group('制卡卡图解析（ERRATA C2）', () {
    late Directory imagesDir;

    setUp(() {
      imagesDir = Directory.systemTemp.createTempSync('manga_cover_');
      File(p.join(imagesDir.path, 'p001.jpg')).writeAsBytesSync(<int>[1]);
      File(p.join(imagesDir.path, 'p002.jpg')).writeAsBytesSync(<int>[2]);
    });

    tearDown(() {
      if (imagesDir.existsSync()) imagesDir.deleteSync(recursive: true);
    });

    MokuroPayload payload() => const MokuroPayload(images: <MokuroImage>[
          MokuroImage(
              url: 'p001.jpg', size: Size(1000, 1500), blocks: <MokuroBlock>[]),
          MokuroImage(
              url: 'p002.jpg', size: Size(1000, 1500), blocks: <MokuroBlock>[]),
        ]);

    String? coverFor(int currentSpread) {
      final List<MangaSpreadEntry> spreads = buildMangaSpreads(
        2,
        layout: MangaPageLayout.single,
        spreadOffset: 0,
      );
      final int page =
          MangaFushiPage.firstPageOfSpread(spreads, currentSpread);
      return MangaFushiPage.resolveMangaResource(
          imagesDir.path, payload().images[page].url);
    }

    test('当前 spread 解析到真实卡图路径（非 null）', () {
      final String? cover0 = coverFor(0);
      expect(cover0, isNotNull, reason: '开书时卡图必须解析到真实文件（非 null）');
      expect(File(cover0!).existsSync(), isTrue);
    });

    test('推进 spread 后重解析到下一页图', () {
      final String? cover0 = coverFor(0);
      final String? cover1 = coverFor(1);
      expect(cover0, isNotNull);
      expect(cover1, isNotNull);
      expect(cover0, isNot(cover1), reason: '翻页后卡图必须重解析到新页（不再恒 null/恒同一页）');
      expect(p.basename(cover1!), 'p002.jpg');
    });
  });

  group('ensureMangaCoverPng（Anki 媒体扩展名契约）', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('manga_cover_ext_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('带图片扩展名的路径原样返回（页图直通，不做无谓拷贝）', () async {
      final String jpg = p.join(dir.path, 'page.jpg');
      File(jpg).writeAsBytesSync(<int>[1]);
      expect(await ensureMangaCoverPng(jpg), jpg);
      final String png = p.join(dir.path, 'page.png');
      File(png).writeAsBytesSync(<int>[1]);
      expect(await ensureMangaCoverPng(png), png);
    });

    test('无扩展名（裁剪输出）拷贝成 .png 返回', () async {
      final String bare = p.join(dir.path, 'cropped');
      File(bare).writeAsBytesSync(<int>[9]);
      final String result = await ensureMangaCoverPng(bare);
      expect(p.extension(result), '.png',
          reason: 'Anki 后端用 split(".").last 推导媒体扩展名，'
              '无扩展名路径会把整条路径当扩展名');
      expect(File(result).existsSync(), isTrue);
    });
  });
}
