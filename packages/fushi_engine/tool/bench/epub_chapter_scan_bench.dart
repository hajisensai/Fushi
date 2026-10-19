// EPUB 章节 DOM 派生量的耗时分解（BUG-3433）：对一批已解压的 EPUB 目录逐书跑
// 纯文本 / 学习字数 / 插图索引 / 锚点偏移，按项累计毫秒。`parse` 一列是仍留在
// Dart 侧的 `EpubBook.parseChapterHtml`（package:html）建树耗时，作对照。
//
//   dart run tool/bench/epub_chapter_scan_bench.dart <dirs.txt>
//
// <dirs.txt> 每行一个已解压 EPUB 目录。原生库按 `FUSHI_COMPUTE_LIB` 定位。
import 'dart:io';

import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/stats/study_char_count.dart';

int ms(Stopwatch s) => s.elapsedMilliseconds;

void main(List<String> args) {
  final List<String> dirs = File(
    args[0],
  ).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
  int tParse = 0, tCount = 0, tTextCount = 0, tImages = 0, tPlain = 0;
  int tAnchor = 0;
  int totalChars = 0, totalUnits = 0, chapters = 0, books = 0;
  for (final String dir in dirs) {
    final EpubBook book;
    try {
      book = EpubParser.parseFromExtracted(dir);
    } catch (e) {
      stderr.writeln('skip $dir: $e');
      continue;
    }
    books++;
    int units = 0;
    for (final c in book.chapters) {
      units += c.html.length;
    }
    totalUnits += units;
    chapters += book.chapters.length;
    final sw = Stopwatch()..start();
    for (final c in book.chapters) {
      EpubBook.parseChapterHtml(c.html);
    }
    final int p = ms(sw);
    sw
      ..reset()
      ..start();
    final List<String> plains = [
      for (int i = 0; i < book.chapters.length; i++) book.chapterPlainText(i),
    ];
    final int pl = ms(sw);
    sw
      ..reset()
      ..start();
    int chars = 0;
    for (final t in plains) {
      chars += countStudyChars(t);
    }
    final int tc = ms(sw);
    sw
      ..reset()
      ..start();
    int chars2 = 0;
    for (int i = 0; i < book.chapters.length; i++) {
      chars2 += book.chapterCharacterCount(i);
    }
    final int cc = ms(sw);
    sw
      ..reset()
      ..start();
    final imgs = book.images;
    final int im = ms(sw);
    sw
      ..reset()
      ..start();
    for (int i = 0; i < book.chapters.length; i++) {
      book.chapterAnchorCharOffsets(i, const ['__none__']);
    }
    final int an = ms(sw);
    tParse += p;
    tPlain += pl;
    tTextCount += tc;
    tCount += cc;
    tImages += im;
    tAnchor += an;
    totalChars += chars;
    final String name = dir
        .split(RegExp(r'[\\/]'))
        .where((s) => s.isNotEmpty)
        .last;
    stdout.writeln(
      '$name\tch=${book.chapters.length}\tutf16=$units\tchars=$chars/$chars2\timgs=${imgs.length}\tparse=$p\tplain=$pl\tcountOnText=$tc\tcharCount=$cc\timages=$im\tanchorWalk=$an',
    );
  }
  stdout.writeln(
    'TOTAL books=$books chapters=$chapters htmlUtf16=$totalUnits chars=$totalChars parse=$tParse plain=$tPlain countOnText=$tTextCount charCount=$tCount images=$tImages anchorWalk=$tAnchor',
  );
}
