import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_text_join.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 漫画 OCR 行尾断字（dehyphenation）。
///
/// OCR 行尾断词的典型形式，例如
/// `Under-` / `stands`、`HESITAT-` / `ING...`、`EVERY-` / `ONE'S`。
/// 判据只用 OCR 自带的行边界（不在字框几何上猜），所以这组用例直接钉住
/// 拼接结果与字格 utf16 偏移——偏一个字符就会点「n」选中隔壁字。
void main() {
  MokuroBlock blockOf(List<String> lines, {bool vertical = false}) =>
      MokuroBlock(
        rectangle: const MokuroRect.fromLTWH(0, 0, 600, 120),
        isVertical: vertical,
        fontSize: 10,
        zIndex: 0,
        lines: lines,
      );

  group('mangaJoinOcrText 断字', () {
    test('行尾连字符去掉并与下一行直接拼接', () {
      expect(mangaJoinOcrText(<String>['Under-', 'stands']), 'Understands');
      expect(mangaJoinOcrText(<String>['HESITAT-', 'ING...']), 'HESITATING...');
      expect(mangaJoinOcrText(<String>['SOME-', 'THING']), 'SOMETHING');
      expect(mangaJoinOcrText(<String>['EVENTU-', 'ALLY.']), 'EVENTUALLY.');
      expect(mangaJoinOcrText(<String>['EVERY-', "ONE'S"]), "EVERYONE'S");
      expect(
        mangaJoinOcrText(<String>['AND PAS-', 'SIONATE!']),
        'AND PASSIONATE!',
      );
    });

    test('连续三行断字逐段去掉连字符', () {
      expect(
        mangaJoinOcrText(<String>['INTER-', 'NATION-', 'AL!']),
        'INTERNATIONAL!',
      );
    });

    test('词内连字符（同一行）保持原样', () {
      expect(
        mangaJoinOcrText(<String>['a well-known', 'fact']),
        'a well-known fact',
      );
      expect(mangaJoinOcrText(<String>['well-known fact']), 'well-known fact');
    });

    test('非断词的行尾连字符不动：下一行不以字母开头', () {
      // 数字区间 / 破折号结尾 / 下一行以标点开头。
      expect(mangaJoinOcrText(<String>['1990-', '1995']), '1990-1995');
      expect(mangaJoinOcrText(<String>['wait-', '?']), 'wait-?');
    });

    test('日文行界仍无缝拼接', () {
      expect(mangaJoinOcrText(<String>['一行目', '二行目']), '一行目二行目');
    });

    test('破折号和非字母脚本字符不作为断词续接', () {
      expect(mangaJoinOcrText(<String>['wait–', 'please']), 'wait–please');
      expect(mangaJoinOcrText(<String>['wait—', 'please']), 'wait—please');
      expect(mangaJoinOcrText(<String>['1990-', '١٩٩٥']), '1990-١٩٩٥');
      expect(mangaJoinOcrText(<String>['word-', '字']), 'word-字');
      expect(mangaJoinOcrText(<String>['сло-', 'во']), 'слово');
      expect(mangaJoinOcrText(<String>['caf-', 'e\u0301']), 'cafe\u0301');
    });

    test('连接符家族：U+2010 / U+2011 同样去掉', () {
      expect(
        mangaJoinOcrText(<String>['Under\u2010', 'stands']),
        'Understands',
      );
      expect(
        mangaJoinOcrText(<String>['Under\u2011', 'stands']),
        'Understands',
      );
    });
  });

  group('mangaBlockTextLayout 偏移', () {
    test('空行的起点随断词行界一起调整', () {
      final MangaBlockTextLayout layout = mangaBlockTextLayout(
        blockOf(<String>['Under-', '', '', 'stands']),
      );
      expect(layout.text, 'Understands');
      expect(layout.lines.map((MangaBlockTextLine line) => line.start), <int>[
        0,
        5,
        5,
        5,
      ]);
      expect(layout.dehyphenatedBreaks, <int>{5});
    });

    test('多行断词、空行和多单元字素的偏移与拼句一致', () {
      for (final List<String> parts in <List<String>>[
        <String>['INTER-', 'NATION-', 'AL!'],
        <String>['😀 caf-', '', 'e\u0301', 'time'],
        <String>['', '-', '', 'a'],
        <String>['', 'Under-', 'stands', ''],
      ]) {
        final MangaBlockTextLayout layout = mangaBlockTextLayout(
          blockOf(parts),
        );
        expect(layout.text, mangaJoinOcrText(parts));
        for (final MangaBlockTextLine line in layout.lines) {
          expect(
            layout.text.substring(line.start, line.start + line.text.length),
            line.text,
          );
        }
      }
    });
    test('去连字符后的整串与每行起点自洽', () {
      final MangaBlockTextLayout layout = mangaBlockTextLayout(
        blockOf(<String>['Under-', 'stands', 'the tree']),
      );
      expect(layout.text, 'Understands the tree');
      // 逐行切片必须与有效行文本一致（字格区间建立在这个不变量上）。
      for (final MangaBlockTextLine line in layout.lines) {
        expect(
          layout.text.substring(line.start, line.start + line.text.length),
          line.text,
        );
      }
    });

    test('断字行的下一个行起点少一个字符', () {
      final MangaBlockTextLayout layout = mangaBlockTextLayout(
        blockOf(<String>['Under-', 'stands']),
      );
      expect(layout.lines[0].text, 'Under'); // 连字符被删
      expect(layout.lines[1].start, 5); // 不是 6
      expect(layout.text, 'Understands');
    });
  });

  group('字格 utf16 区间落在去连字符后的句子上', () {
    test('断词块每个字格的切片都与它自己的字符一致', () {
      final MokuroBlock block = blockOf(<String>['Under-', 'stands']);
      final List<MangaOcrTextRegion> regions = mangaEffectiveTextRegions(block);
      final String sentence = mangaBlockTextLayout(block).text;
      expect(sentence, 'Understands');
      expect(regions.length, 'Understands'.length);
      for (int i = 0; i < regions.length; i++) {
        final MangaOcrTextRegion region = regions[i];
        final String slice = sentence.substring(
          region.utf16Start,
          region.utf16End,
        );
        expect(slice, 'Understands'[i], reason: '字格 $i 应与有效文本同位');
      }
      // 点「stands」的 n：整串下标 8（Understand：U0 n1 d2 e3 r4 s5 t6 a7 n8）。
      final MangaOcrTextRegion n = regions[8];
      expect(sentence.substring(n.utf16Start, n.utf16End), 'n');
    });

    test('OCR 自带的旧 regions（按原始 sentence）不再匹配时回退几何重算', () {
      final MokuroBlock raw = blockOf(<String>['Under-', 'stands']);
      final String rawSentence = raw.lines.join();
      final MokuroBlock withStaleRegions = MokuroBlock(
        rectangle: raw.rectangle,
        isVertical: false,
        fontSize: 10,
        zIndex: 0,
        lines: raw.lines,
        regions: <MangaOcrTextRegion>[
          for (int i = 0; i < rawSentence.length; i++)
            if (rawSentence[i].trim().isNotEmpty)
              MangaOcrTextRegion(
                rectangle: MokuroRect.fromLTWH(i * 10.0, 0, 10, 10),
                utf16Start: i,
                utf16End: i + 1,
              ),
        ],
      );
      final List<MangaOcrTextRegion> regions = mangaEffectiveTextRegions(
        withStaleRegions,
      );
      final String sentence = mangaBlockTextLayout(withStaleRegions).text;
      expect(sentence, 'Understands');
      expect(regions.length, sentence.length);
      expect(
        sentence.substring(regions[8].utf16Start, regions[8].utf16End),
        'n',
      );
    });

    test('删连字符与补空格抵消长度变化时仍丢弃旧偏移', () {
      final MokuroBlock block = MokuroBlock(
        rectangle: const MokuroRect.fromLTWH(0, 0, 600, 120),
        isVertical: false,
        fontSize: 10,
        zIndex: 0,
        lines: const <String>['LET-', 'TER', 'the'],
        regions: <MangaOcrTextRegion>[
          for (int i = 0; i < 'LET-TERthe'.length; i++)
            MangaOcrTextRegion(
              rectangle: MokuroRect.fromLTWH(i * 10.0, 0, 10, 10),
              utf16Start: i,
              utf16End: i + 1,
            ),
        ],
      );
      final String sentence = mangaBlockTextLayout(block).text;
      expect(sentence, 'LETTER the');
      expect(sentence.length, block.lines.join().length);
      expect(
        mangaTextRegionsMatchSentence(block.regions!, sentence),
        isTrue,
        reason: '仅校验覆盖范围无法发现旧字符偏移',
      );
      final List<MangaOcrTextRegion> regions = mangaEffectiveTextRegions(block);
      expect(regions, hasLength(9));
      expect(
        regions.every(
          (MangaOcrTextRegion r) =>
              sentence.substring(r.utf16Start, r.utf16End).trim().isNotEmpty,
        ),
        isTrue,
      );
      expect(
        regions[3].rectangle.top,
        greaterThan(0),
        reason: '首个 T 必须在第二行，不能沿用第一行连字符的字框',
      );
    });

    test('overlay 的 data-utf16-start 与整串一致', () {
      final String html = mangaOcrBoxesHtml(
        MokuroImage(
          url: 'p.jpg',
          size: const MokuroSize(1000, 1000),
          blocks: <MokuroBlock>[
            blockOf(<String>['Under-', 'stands']),
          ],
        ),
      );
      expect(html, contains('data-utf16-start="5"'));
      // 「stands」的 s 从整串 5 开始（不是原始行拼接的 6）。
      expect(html, isNot(contains('data-utf16-start="11"')));
    });
  });
}
