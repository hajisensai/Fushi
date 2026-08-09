import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/drop_decision.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:path/path.dart' as p;

/// 反向守卫：**词典 zip 不许被当漫画导**。
///
/// 拖放分类层给 `.zip` 加了内容判据（`isImageArchive`）之后，`.zip` 不再无条件
/// 归词典包——判据说是图片包就归 mangas。判据本身必须扛得住真实的 Yomitan 词典
/// 包：Yomitan 格式允许词典**自带图片**（structured-content 的 `image` 节点，本仓
/// `YomichanFormat.processDefinition` 就处理 `case 'image'`），这类词典包解开后
/// 同时含 `index.json` / `term_bank_*.json` 和 `.png`。
///
/// 这里用**真 zip 文件 + 真判据**（`MangaModule.isImageArchive`，即
/// `MangaArchiveImporter.looksLikeImageArchive`）跑，不打桩：桩只能证明接线对，
/// 证明不了判据对。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hibiki_dict_zip_guard_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// 在 [tempDir] 下写一个真 zip，[entries] 是 `包内路径 -> 内容字节`。
  String writeZip(String name, Map<String, List<int>> entries) {
    final Archive archive = Archive();
    entries.forEach((String path, List<int> bytes) {
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    });
    final List<int>? encoded = ZipEncoder().encode(archive);
    expect(encoded, isNotNull, reason: 'zip 编码失败，测试前提不成立');
    final String path = p.join(tempDir.path, name);
    File(path).writeAsBytesSync(encoded!);
    return path;
  }

  /// 最小 PNG（1x1，真字节）——词典自带插图就长这样。
  List<int> onePixelPng() => <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
      ];

  List<int> utf8Bytes(String text) => utf8.encode(text);

  group('拖放分类 — 词典 zip 不许被当漫画', () {
    test('自带插图的 Yomitan 词典 zip 仍归 dictionaries，不归 mangas', () {
      final String dictZip = writeZip('yomitan_dict.zip', <String, List<int>>{
        'index.json': utf8Bytes(
          '{"title":"Test Dict","format":3,"revision":"1"}',
        ),
        'term_bank_1.json': utf8Bytes(
          '[["猫","ねこ","n","",0,[{"type":"structured-content",'
          '"content":{"tag":"img","path":"img/neko.png"}}],1,""]]',
        ),
        'tag_bank_1.json': utf8Bytes('[["n","partOfSpeech",0,"noun",0]]'),
        'img/neko.png': onePixelPng(),
      });

      final DroppedFiles files = classifyDroppedFiles(
        <String>[dictZip],
        isImageArchive: MangaModule.isImageArchive,
      );

      expect(
        files.mangas,
        isEmpty,
        reason: '词典包被当漫画导 = 用户拖词典进书架，导出一本乱码「漫画」',
      );
      expect(files.dictionaries, <String>[dictZip]);
      expect(
        decideDropIntent(
          surface: DropSurface.books,
          files: files,
          cardHit: false,
        ),
        isNot(DropIntent.importNewManga),
      );
    });

    test('无插图的 Yomitan 词典 zip 归 dictionaries', () {
      final String dictZip = writeZip('plain_dict.zip', <String, List<int>>{
        'index.json': utf8Bytes('{"title":"Plain","format":3,"revision":"1"}'),
        'term_bank_1.json': utf8Bytes('[["犬","いぬ","n","",0,["dog"],1,""]]'),
      });

      final DroppedFiles files = classifyDroppedFiles(
        <String>[dictZip],
        isImageArchive: MangaModule.isImageArchive,
      );

      expect(files.mangas, isEmpty);
      expect(files.dictionaries, <String>[dictZip]);
    });

    test('只有 kanji_bank 的汉字词典 zip（带笔顺图）仍归 dictionaries', () {
      final String dictZip = writeZip('kanji_dict.zip', <String, List<int>>{
        'index.json': utf8Bytes('{"title":"Kanji","format":3,"revision":"1"}'),
        'kanji_bank_1.json': utf8Bytes('[["猫","ビョウ","ねこ","",["cat"],{}]]'),
        'stroke/neko.png': onePixelPng(),
      });

      final DroppedFiles files = classifyDroppedFiles(
        <String>[dictZip],
        isImageArchive: MangaModule.isImageArchive,
      );

      expect(files.mangas, isEmpty, reason: 'term_bank 不是唯一的 bank 形态');
      expect(files.dictionaries, <String>[dictZip]);
    });

    test('页图 zip 只是恰好带了 index.json（无 bank）仍归 mangas', () {
      // 反向误判防线：打包工具随手生成的清单也可能叫 index.json，光凭它否决会
      // 把真漫画包挡在门外。bank 前缀才是 Yomitan 独有的结构指纹，缺 bank 即
      // 不算词典包。
      final String mangaZip = writeZip('vol2.zip', <String, List<int>>{
        'index.json': utf8Bytes('{"pages":3,"packer":"some-comic-tool"}'),
        '001.png': onePixelPng(),
        '002.png': onePixelPng(),
      });

      final DroppedFiles files = classifyDroppedFiles(
        <String>[mangaZip],
        isImageArchive: MangaModule.isImageArchive,
      );

      expect(files.mangas, <String>[mangaZip]);
      expect(files.dictionaries, isEmpty);
    });

    test('纯页图 zip（真漫画包）归 mangas', () {
      final String mangaZip = writeZip('vol1.zip', <String, List<int>>{
        '001.png': onePixelPng(),
        '002.png': onePixelPng(),
        '003.png': onePixelPng(),
      });

      final DroppedFiles files = classifyDroppedFiles(
        <String>[mangaZip],
        isImageArchive: MangaModule.isImageArchive,
      );

      expect(files.mangas, <String>[mangaZip]);
      expect(files.dictionaries, isEmpty);
    });
  });
}
