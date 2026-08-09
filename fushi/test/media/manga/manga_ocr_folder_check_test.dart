import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_dialog.dart';
import 'package:fushi/src/media/manga/manga_storage.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:path/path.dart' as p;

/// [checkOcrFolder] 的判定口径：**已入库书目录**（含 manga.json）看页表，
/// **裸图片文件夹**看文件。
///
/// BUG-1434：mokuro.moe 下载的卷导入后页图落在 `images/<卷名>/001.jpg`
/// （destRel 保留了 CBZ 顶层的 `<卷名>/` 目录），而旧判定只扫「目录直属文件 +
/// 一层子目录」，第三层的页图看不见 → 一本能正常阅读、且站点已附带完整 OCR
/// 的书，被 OCR 向导判成「此文件夹中没有找到图片」并禁用运行。
void main() {
  const MokuroBlock block = MokuroBlock(
    rectangle: Rect.fromLTRB(0, 0, 10, 10),
    isVertical: true,
    fontSize: 12,
    zIndex: 0,
    lines: <String>['テスト'],
  );

  MokuroImage page(String url,
          {List<MokuroBlock> blocks = const <MokuroBlock>[]}) =>
      MokuroImage(url: url, size: const Size(100, 140), blocks: blocks);

  /// 造一个已入库书目录：`manga.json` + 按每页 destRel 落的空页图文件
  /// （判定只看路径/扩展名，不解码像素）。
  Directory bookDir(String prefix, List<MokuroImage> pages, {String? rawJson}) {
    final Directory dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File(p.join(dir.path, MangaStorage.kMangaJsonFileName)).writeAsStringSync(
      rawJson ?? jsonEncode(mangaPayloadToJson(MokuroPayload(images: pages))),
    );
    for (final MokuroImage image in pages) {
      File(p.joinAll(<String>[dir.path, ...image.url.split('/')]))
          .createSync(recursive: true);
    }
    return dir;
  }

  Directory plainDir(String prefix) {
    final Directory dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  group('已入库书目录（manga.json 为准）', () {
    test('mokuro.moe 卷：页图在 images/<卷名>/ 且每页有 OCR → alreadyOcred', () {
      final Directory dir = bookDir('manga_check_mokuro_', <MokuroImage>[
        page('images/あつまれ！ふしぎ研究部 第01巻/001.jpg', blocks: <MokuroBlock>[block]),
        page('images/あつまれ！ふしぎ研究部 第01巻/002.jpg', blocks: <MokuroBlock>[block]),
      ]);

      final MangaOcrFolderStatus status = checkOcrFolder(dir.path);
      expect(status, MangaOcrFolderStatus.alreadyOcred);
      expect(status, isNot(MangaOcrFolderStatus.noImages),
          reason: 'BUG-1434：用户看到的正是「此文件夹中没有找到图片」');
    });

    test('有页缺 OCR 块 → valid（可补齐）', () {
      final Directory dir = bookDir('manga_check_partial_', <MokuroImage>[
        page('images/vol1/001.jpg', blocks: <MokuroBlock>[block]),
        page('images/vol1/002.jpg'),
      ]);
      expect(checkOcrFolder(dir.path), MangaOcrFolderStatus.valid);
    });

    test('一页都没 OCR → valid', () {
      final Directory dir = bookDir('manga_check_none_', <MokuroImage>[
        page('images/001.jpg'),
      ]);
      expect(checkOcrFolder(dir.path), MangaOcrFolderStatus.valid);
    });

    test('页表为空 → noImages', () {
      final Directory dir = bookDir('manga_check_empty_', <MokuroImage>[]);
      expect(checkOcrFolder(dir.path), MangaOcrFolderStatus.noImages);
    });

    test('manga.json 损坏 → 退回文件扫描，深层页图仍算 valid', () {
      final Directory dir = bookDir(
        'manga_check_broken_',
        const <MokuroImage>[],
        rawJson: '{ this is not json',
      );
      File(p.join(dir.path, 'images', 'vol1', '001.jpg'))
          .createSync(recursive: true);
      expect(checkOcrFolder(dir.path), MangaOcrFolderStatus.valid,
          reason: '「元数据坏了」不等于「没有图片」');
    });
  });

  group('裸图片文件夹', () {
    test('含 .mokuro → hasMokuro（应走普通导入）', () {
      final Directory dir = plainDir('manga_check_hasmokuro_');
      File(p.join(dir.path, 'vol.mokuro')).writeAsStringSync('{}');
      File(p.join(dir.path, '001.jpg')).createSync();
      expect(checkOcrFolder(dir.path), MangaOcrFolderStatus.hasMokuro);
    });

    test('只有深层子目录里有图 → valid（与 OCR 引擎枚举同口径）', () {
      final Directory dir = plainDir('manga_check_deep_');
      File(p.join(dir.path, 'vol1', 'ch1', '001.jpg'))
          .createSync(recursive: true);
      expect(checkOcrFolder(dir.path), MangaOcrFolderStatus.valid);
    });

    test('只有非图片文件 → noImages', () {
      final Directory dir = plainDir('manga_check_noimg_');
      File(p.join(dir.path, 'readme.txt')).writeAsStringSync('x');
      expect(checkOcrFolder(dir.path), MangaOcrFolderStatus.noImages);
    });

    test('目录不存在 → notFound', () {
      expect(
        checkOcrFolder(p.join(Directory.systemTemp.path, 'no_such_dir_zzz')),
        MangaOcrFolderStatus.notFound,
      );
    });
  });
}
