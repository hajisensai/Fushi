// HBK-AUDIT-040：按需追章后刷新 chaptersJson 只重数改过 / 新增的章，其余章的字数
// 沿用旧表，不再逐章重读整本正文（连续追 N 章累计 O(N²) 章读）。
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String _containerXml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>';

String _opf(int chapters) {
  final StringBuffer manifest = StringBuffer();
  final StringBuffer spine = StringBuffer();
  for (int i = 1; i <= chapters; i++) {
    manifest.write(
      '<item id="c$i" href="chapter-$i.xhtml" '
      'media-type="application/xhtml+xml"/>',
    );
    spine.write('<itemref idref="c$i"/>');
  }
  return '<?xml version="1.0" encoding="UTF-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>t</dc:title></metadata>'
      '<manifest>$manifest</manifest><spine>$spine</spine></package>';
}

String _chapter(String body) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title></head>'
    '<body><p>$body</p></body></html>';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('epub_reindex_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void writeBook(List<String> bodies) {
    File(p.join(dir.path, 'META-INF', 'container.xml'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(_containerXml);
    File(p.join(dir.path, 'OEBPS', 'content.opf'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(_opf(bodies.length));
    for (int i = 0; i < bodies.length; i++) {
      File(
        p.join(dir.path, 'OEBPS', 'chapter-${i + 1}.xhtml'),
      ).writeAsStringSync(_chapter(bodies[i]));
    }
  }

  List<Map<String, Object?>> entries(String json) =>
      (jsonDecode(json) as List<Object?>).cast<Map<String, Object?>>();

  test('只重数改过的章与新增的章，其余沿用旧表；结果与整本重解析一致', () async {
    writeBook(<String>['あいう', 'かきくけ', '待']);
    final String before = (await EpubImporter.reparseExtractedBook(
      dir.path,
    )).chaptersJson;
    expect(
      entries(before).map((Map<String, Object?> e) => e['characters']),
      <int>[3, 4, 1],
    );

    // 第 3 章（占位）换成正文、末尾续挂新占位；第 1 章的文件被偷偷改大——它不在
    // changedHrefs 里，沿用旧字数说明没有重读它的正文。
    writeBook(<String>['あいうえおかきくけこ', 'かきくけ', 'さしすせそ', '待']);
    final ({int chapterCount, String chaptersJson, String? coverPath})
    reindexed = await EpubImporter.reindexExtractedBook(
      extractDir: dir.path,
      previousChaptersJson: before,
      changedHrefs: <String>{p.join('OEBPS', 'chapter-3.xhtml')},
    );
    expect(reindexed.chapterCount, 4);
    final List<Map<String, Object?>> got = entries(reindexed.chaptersJson);
    expect(got.map((Map<String, Object?> e) => e['characters']), <int>[
      3, // 沿用（文件已变成 10 字，证明没重读）
      4,
      5, // 改过：重数
      1, // 新增：旧表没有，数
    ]);
    expect(got.map((Map<String, Object?> e) => e['charCaliber']).toSet(), <int>{
      kChapterCharCountCaliber,
    });

    // 除沿用的第 1 章外，与整本重解析逐项相同（id / href / mediaType 仍以 OPF 为准）。
    final List<Map<String, Object?>> full = entries(
      (await EpubImporter.reparseExtractedBook(dir.path)).chaptersJson,
    );
    expect(full[0]['characters'], 10);
    expect(got.sublist(1), full.sublist(1));
    expect(got[0]..remove('characters'), full[0]..remove('characters'));
  });

  test('旧表口径版本不对 / 缺字数 / 形状坏了的章一律重数', () async {
    writeBook(<String>['あいう', 'かきくけ']);
    final String stale = jsonEncode(<Object?>[
      <String, Object?>{
        'href': 'OEBPS/chapter-1.xhtml',
        'characters': 99,
        'charCaliber': kChapterCharCountCaliber - 1,
      },
      <String, Object?>{'href': 'OEBPS/chapter-2.xhtml'},
    ]);
    final List<Map<String, Object?>> got = entries(
      (await EpubImporter.reindexExtractedBook(
        extractDir: dir.path,
        previousChaptersJson: stale,
        changedHrefs: const <String>{},
      )).chaptersJson,
    );
    expect(got.map((Map<String, Object?> e) => e['characters']), <int>[3, 4]);

    final List<Map<String, Object?>> broken = entries(
      (await EpubImporter.reindexExtractedBook(
        extractDir: dir.path,
        previousChaptersJson: 'not json',
        changedHrefs: const <String>{},
      )).chaptersJson,
    );
    expect(broken.map((Map<String, Object?> e) => e['characters']), <int>[
      3,
      4,
    ]);
  });
}
