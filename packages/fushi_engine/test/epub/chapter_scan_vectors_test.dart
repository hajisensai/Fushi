// EPUB 章节 DOM 派生量（纯文本 / 读音轨 / 学习字数 / 锚点偏移 / 纯图片章 / 图片引用 /
// 插图索引 / 全书搜索文本）的回归：期望值全部由删除前的 Dart 实现（`package:html`
// 0.15.6 建树 + Dart 遍历）生成，现实现（`ffc_parse_epub_chapter`，Rust 里的
// `package:html` 逐行移植）必须逐字相同——学习统计、阅读位置、有声书 cue 偏移都建在
// 这些数上。生成方式见 chapter_scan_vectors/chapter_scan_vectors.dart。
import 'dart:io';

import 'package:fushi_engine/epub/epub_book.dart';
import 'package:test/test.dart';

import 'chapter_scan_vectors/chapter_scan_vectors.dart';

String _fixture(String name) {
  final List<String> candidates = <String>[
    'test/epub/chapter_scan_vectors/$name',
    'packages/fushi_engine/test/epub/chapter_scan_vectors/$name',
  ];
  for (final String path in candidates) {
    final File f = File(path);
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('fixture $name not found from ${Directory.current.path}');
}

void main() {
  group('chapter scan vectors (old package:html implementation)', () {
    final List<String> edgeCases = splitCorpus(_fixture('edge_cases.html.txt'));

    test('hand-written edge cases: full dump', () {
      expect(edgeCases, hasLength(234));
      expect(
        chapterScanVectorDump(edgeCases),
        _fixture('edge_cases.scan.expected.txt'),
      );
    });

    test('hand-written edge cases: search text', () {
      expect(
        chapterSearchVectorDump(edgeCases),
        _fixture('edge_cases.search.expected.txt'),
      );
    });

    // 3 个种子 × 3000 章的标签汤 + 真书常见片段；只入库整份转储的 SHA-256。
    const Map<int, (String, String)> fuzzDigests = <int, (String, String)>{
      1: (
        'c80b79ef6cc278f3f89d3c35657f3eba32ee5bee597a51915ad2137961fe422b',
        '29daa45314471b2cbd8674f44b3b899710c6c3428b47fa79e4f703edb075c420',
      ),
      2: (
        '91e4f3748f497761d6d8165efcf19960d73fd3c6747e89e9616da3e837a4b1a7',
        '97f539eb874c51603e4bd286cfa0a625d99c4071c696c35be9234e4913a0d0fc',
      ),
      3: (
        '2ae8170dc3477cef1a96c165b29f6509bfcfd835387b1557388e39410370f950',
        'cb072e9c441da5c65b623a28a7cba6ca0848fec956e4fec0422ff20f76fd773a',
      ),
    };
    for (final MapEntry<int, (String, String)> e in fuzzDigests.entries) {
      test('fixed-seed corpus ${e.key}', () {
        final List<String> docs = chapterScanFuzzCorpus(e.key, 3000);
        expect(vectorDigest(chapterScanVectorDump(docs)), e.value.$1);
        expect(vectorDigest(chapterSearchVectorDump(docs)), e.value.$2);
      });
    }
  });

  test('chapters the old parser threw on still throw; images skips them', () {
    // package:html 的数字字符引用走 int.parse，超出 64 位就抛 FormatException。
    const List<String> throwing = <String>[
      '<p>&#99999999999999999999;</p>',
      '<p>&#x8000000000000000;</p>',
      '<p title="&#99999999999999999999;">x</p>',
    ];
    final EpubBook book = EpubBook(
      title: 't',
      chapters: <EpubChapter>[
        for (int i = 0; i < throwing.length; i++)
          EpubChapter(
            id: 'c$i',
            href: 'OEBPS/c$i.xhtml',
            mediaType: 'application/xhtml+xml',
            html: throwing[i],
          ),
        EpubChapter(
          id: 'ok',
          href: 'OEBPS/ok.xhtml',
          mediaType: 'application/xhtml+xml',
          html: '<body><p>本文<img src="a.jpg"/></p></body>',
        ),
      ],
    );
    for (int i = 0; i < throwing.length; i++) {
      expect(() => book.chapterPlainText(i), throwsFormatException);
      expect(() => book.chapterCharacterCount(i), throwsFormatException);
      expect(() => book.chapterSearchText(i), throwsFormatException);
    }
    expect(book.chapterPlainText(3), '本文');
    expect(
      <String>[for (final EpubImageRef r in book.images) r.src],
      <String>['OEBPS/a.jpg'],
    );
  });
}
