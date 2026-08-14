import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:path/path.dart' as p;

/// 反向守卫：**词典 zip 不许在导入入口层被判成漫画**。
///
/// 载体分家把「这是什么」的判定从 `_importEpubOnly` 末尾提到了
/// `classifyImportCarrier`，两个对话框（书籍 / 漫画）都改从这里问。`4f9644db4` 的
/// 「词典包一票否决」判据本体（`index.json` + `*_bank_*.json` 同时在场 ⇒ 不是图片
/// 包，优先于「有图片就算漫画」）留在 `MangaArchiveImporter.looksLikeImageArchive`，
/// 分家没有改动它——但**没有任何测试钉住新入口层真的把这个判据接上了**。
///
/// 已有的 `test/media/drag_drop/dictionary_zip_not_manga_test.dart` 走的是拖放分类
/// 层（`classifyDroppedFiles`），`test/media/import/import_carrier_test.dart` 全程
/// 用假回调（`imageArchives.contains`）。两者都不覆盖「对话框入口 →
/// classifyImportCarrier → 真判据」这条新链路：只要有人把
/// `book_import_dialog.dart` / `manga_import_dialog.dart` 注入的实参从
/// `MangaModule.isImageArchive` 换成按扩展名的简化桩，现有套件**一条都不会红**，
/// 而一本自带插图的 Yomitan 词典包就会被静默导成只有插图的垃圾「漫画」。
///
/// 故这里用**真 zip + 真判据**（不打桩）跑新入口层，把那条链钉死。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hibiki_carrier_dict_');
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

  /// 用**生产实参**跑分类：`isImageArchive` 就是两个对话框注入的那一个。
  ImportCarrier classifyWithRealPredicate(String path) => classifyImportCarrier(
        path,
        isDirectory: (String p) => Directory(p).existsSync(),
        isImageArchive: MangaModule.isImageArchive,
        directoryHasPageImages: MangaModule.directoryHasPageImages,
        directoryCarrierFileCount: MangaModule.directoryCarrierFileCount,
      );

  test('自带插图的 Yomitan 词典 zip 不得被判成漫画载体', () {
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

    final ImportCarrier carrier = classifyWithRealPredicate(dictZip);

    expect(carrier.isManga, isFalse,
        reason: '词典包一票否决必须优先于「有图片就算漫画」：判成漫画 = 词典没被导入，'
            '还平白多出一本只有插图的垃圾漫画（4f9644db4 回归）');
    expect(carrier, ImportCarrier.epub,
        reason: '.zip 非图片包时落 epub 分支（与分家前 _importEpubOnly 的兜底一致）');
  });

  test('kanji_bank 形态的词典包同样被否决', () {
    final String dictZip = writeZip('kanji_dict.zip', <String, List<int>>{
      'index.json': utf8Bytes('{"title":"Kanji Dict","format":3}'),
      'kanji_bank_1.json': utf8Bytes('[["猫","","","",[],[]]]'),
      'img/stroke.png': onePixelPng(),
    });

    expect(classifyWithRealPredicate(dictZip).isManga, isFalse,
        reason: 'kanji_bank_ 也在 Yomitan 前缀集里，不能只认 term_bank_');
  });

  test('反向用例：真页图 zip 仍判为漫画（否决判据不得误伤漫画）', () {
    final String mangaZip = writeZip('scan.zip', <String, List<int>>{
      '001.png': onePixelPng(),
      '002.png': onePixelPng(),
      '003.png': onePixelPng(),
    });

    expect(classifyWithRealPredicate(mangaZip), ImportCarrier.mangaArchive,
        reason: '没有 index.json + bank 的纯页图包就是漫画——否决判据必须精确，'
            '否则「拖图包 zip 到书架仍要能导成漫画」这条红线会被误伤');
  });

  test('只有 index.json 而没有 bank 的 zip 不算词典（单有清单不足以否决）', () {
    final String zip = writeZip('has_index.zip', <String, List<int>>{
      'index.json': utf8Bytes('{"name":"whatever"}'),
      '001.png': onePixelPng(),
      '002.png': onePixelPng(),
    });

    expect(classifyWithRealPredicate(zip), ImportCarrier.mangaArchive,
        reason: '打包工具随手生成的清单也叫 index.json，bank 前缀才是 Yomitan 指纹；'
            '只认 index.json 会把普通图包误判成词典而拒绝导入');
  });
}
