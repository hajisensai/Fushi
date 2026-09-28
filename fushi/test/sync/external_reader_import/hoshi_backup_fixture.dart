import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 测试夹具：按 Hoshi Reader iOS / Android 真实源码的落盘结构拼 `.hoshi` 备份。
///
/// 结构依据（Manhhao/Hoshi-Reader develop `Core/BookStorage.swift`、
/// `Models/Book.swift`、`Models/Statistics.swift`；HuangAntimony/Hoshi-Reader-Android
/// `epub/BookStorage.kt`、`epub/ReadingStatistics.kt`、
/// `features/backup/HoshiBackupRepository.kt`）：zip 根就是 `Books/` 的内容，每书
/// 一个目录，已删书的统计在 `statistics_archive/<folder>/`。

/// 一本两章的最小 EPUB：OPF 在 `OEBPS/`，章节在 `OEBPS/Text/`——Fushi 章节 href
/// 相对解压根（`OEBPS/Text/ch1.xhtml`），Hoshi 的 manifest 路径相对 OPF
/// （`Text/ch1.xhtml`），映射要靠后缀匹配对上。中间夹一个非 HTML 的 spine 项：
/// Fushi 解析 spine 时会跳过它，所以 Hoshi 的 spine 下标 2 对应 Fushi 的第 1 章。
Uint8List fixtureEpub(String title) {
  final Archive archive = Archive();
  void add(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
  add('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
  </metadata>
  <manifest>
    <item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="img" href="Images/cover.png" media-type="image/png"/>
    <item id="ch2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="img"/>
    <itemref idref="ch2"/>
  </spine>
</package>
''');
  add('OEBPS/Text/ch1.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>1</title></head>
  <body><p>吾輩は猫である。名前はまだ無い。</p></body>
</html>
''');
  add('OEBPS/Images/cover.png', 'not really a png');
  add('OEBPS/Text/ch2.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>2</title></head>
  <body><p>どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。</p></body>
</html>
''');
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// Hoshi 的 bookinfo：键是相对 OPF 的 manifest 路径。图片项不在 chapterInfo 里
/// （Hoshi 读不出文本的 spine 项不计），但 spineIndex 仍按 spine 原始下标。
Map<String, Object?> fixtureBookInfo() => <String, Object?>{
  'characterCount': 300,
  'chapterInfo': <String, Object?>{
    'Text/ch1.xhtml': <String, Object?>{
      'spineIndex': 0,
      'currentTotal': 0,
      'chapterCount': 100,
    },
    'Text/ch2.xhtml': <String, Object?>{
      'spineIndex': 2,
      'currentTotal': 100,
      'chapterCount': 200,
    },
  },
};

/// unix 毫秒 → Hoshi 的 Apple 纪元秒。
double appleSeconds(int unixMs) => unixMs / 1000 - 978307200;

/// 把 {zip 内路径: 内容（String / List<int> / JSON 可编码对象）} 写成 zip 文件。
File writeHoshiBackup(String path, Map<String, Object> entries) {
  final Archive archive = Archive();
  for (final MapEntry<String, Object> e in entries.entries) {
    final Object value = e.value;
    final List<int> bytes = switch (value) {
      final List<int> raw => raw,
      final String text => utf8.encode(text),
      _ => utf8.encode(jsonEncode(value)),
    };
    archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return File(path)..writeAsBytesSync(ZipEncoder().encode(archive)!);
}
