import 'dart:io';

import 'package:fushi/src/reader/reader_chapter_path_index.dart';
import 'package:test/test.dart';

import '../helpers/source_guard.dart';

/// 路线图 m1 / novel-17e：拦截器的「路径 → 章号」反查走按书建一次的表，结果与旧的
/// 「从第 0 章起逐章算路径、命中即返回」逐个一致；章节表换了（网文追加章节）或解包目录
/// 变了才重建。
void main() {
  String? pathOf(List<String?> paths, int i) => paths[i];

  int linear(List<String?> paths, String target) {
    for (int i = 0; i < paths.length; i++) {
      if (paths[i] == target) return i;
    }
    return -1;
  }

  test('lookups match the old linear scan, first occurrence wins', () {
    final List<String?> paths = <String?>[
      '/b/Text/0.xhtml',
      null, // 越界 / 逃逸出解包目录的章：旧实现返回 null，永不命中
      '/b/Text/2.xhtml',
      '/b/Text/0.xhtml', // 同一文档在书脊里出现两次：取第一个
      '/b/Text/4.xhtml',
    ];
    final ReaderChapterPathIndex index = ReaderChapterPathIndex.build(
      source: paths,
      count: paths.length,
      dir: '/b',
      pathOf: (int i) => pathOf(paths, i),
    );
    for (final String target in <String>[
      '/b/Text/0.xhtml',
      '/b/Text/2.xhtml',
      '/b/Text/4.xhtml',
      '/b/Text/9.xhtml',
      '',
    ]) {
      expect(index.indexOf(target), linear(paths, target), reason: target);
    }
  });

  test('builds the table once: one path computation per chapter', () {
    int calls = 0;
    final List<String> paths = <String>[
      for (int i = 0; i < 3000; i++) '/b/Text/$i.xhtml',
    ];
    final ReaderChapterPathIndex index = ReaderChapterPathIndex.build(
      source: paths,
      count: paths.length,
      dir: '/b',
      pathOf: (int i) {
        calls++;
        return paths[i];
      },
    );
    for (int i = 0; i < paths.length; i += 7) {
      expect(index.indexOf(paths[i]), i);
    }
    expect(calls, paths.length);
  });

  test('the interceptor looks chapters up through the table, not a scan', () {
    final String source = maskComments(
      File(
        'lib/src/pages/implementations/reader_fushi/webview.part.dart',
      ).readAsStringSync(),
    );
    final int start = source.indexOf(
      'int _chapterIndexForFilePath(String filePath) {',
    );
    expect(start, isNonNegative);
    final String body = source.substring(start, source.indexOf('\n  }', start));
    expect(body, contains('ReaderChapterPathIndex.build('));
    expect(body, contains('index.indexOf(filePath)'));
    expect(body, isNot(contains('_chapterFilePath(i) ==')));
  });

  test('describes only the same chapter list, length and extract dir', () {
    final List<String> chapters = <String>['a', 'b'];
    final ReaderChapterPathIndex index = ReaderChapterPathIndex.build(
      source: chapters,
      count: 2,
      dir: '/b',
      pathOf: (int i) => chapters[i],
    );
    expect(index.describes(source: chapters, count: 2, dir: '/b'), isTrue);
    // 网文追加章节时 EpubBook 换一份新列表（内容相同也是新对象）。
    expect(
      index.describes(source: List<String>.of(chapters), count: 2, dir: '/b'),
      isFalse,
    );
    expect(index.describes(source: chapters, count: 3, dir: '/b'), isFalse);
    expect(index.describes(source: chapters, count: 2, dir: '/c'), isFalse);
  });
}
