import 'package:flutter_test/flutter_test.dart';
import 'package:characters/characters.dart';
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

  MokuroBlock withRegions(List<String> lines, {bool vertical = false}) {
    int offset = 0;
    final List<MangaOcrTextRegion> regions = <MangaOcrTextRegion>[];
    for (final String char in lines.join().characters) {
      final int end = offset + char.length;
      if (char.trim().isNotEmpty) {
        regions.add(
          MangaOcrTextRegion(
            rectangle: MokuroRect.fromLTWH(
              offset * 7.0,
              offset * 3.0,
              5 + offset * 1.0,
              12,
            ),
            utf16Start: offset,
            utf16End: end,
            rotation: 0.1,
          ),
        );
      }
      offset = end;
    }
    return MokuroBlock(
      rectangle: const MokuroRect.fromLTWH(0, 0, 600, 120),
      isVertical: vertical,
      fontSize: 10,
      zIndex: 0,
      lines: lines,
      regions: regions,
    );
  }

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

    test('断词连字符后的尾随空白一并删除，其它行的空白保留', () {
      for (final String hyphen in <String>['-', '\u2010', '\u2011']) {
        final List<String> parts = <String>[
          'Under$hyphen \t\u3000',
          '',
          'stands',
        ];
        final MangaBlockTextLayout layout = mangaBlockTextLayout(
          blockOf(parts),
        );
        expect(mangaJoinOcrText(parts), 'Understands');
        expect(layout.text, 'Understands');
        expect(layout.lines.map((MangaBlockTextLine line) => line.start), <int>[
          0,
          5,
          5,
        ]);
        expect(layout.lines.first.text, 'Under');
        expect(layout.dehyphenatedBreaks, <int>{5});
      }
      for (final List<String> parts in <List<String>>[
        <String>['日本語- ', '続き'],
        <String>['スーパー ', 'マーケット'],
        <String>['1990- ', '1995'],
        <String>['wait— ', 'please'],
        <String>['well-known ', 'fact'],
        <String>[' \t', 'hello'],
      ]) {
        expect(mangaJoinOcrText(parts), parts.join());
        expect(mangaBlockTextLayout(blockOf(parts)).text, parts.join());
      }
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

    test('日文长音符与中日韩行首不会误删连接符', () {
      for (final List<String> lines in <List<String>>[
        <String>['スーパー', 'マーケット'],
        <String>['カレー', 'ライス'],
        <String>['言葉-', '続き'],
        <String>['中文-', '续行'],
        <String>['한국어-', '다음'],
      ]) {
        final MokuroBlock block = blockOf(lines, vertical: true);
        expect(mangaJoinOcrText(lines), lines.join());
        final MangaBlockTextLayout layout = mangaBlockTextLayout(block);
        expect(layout.text, lines.join());
        expect(layout.dehyphenatedBreaks, isEmpty);
        expect(layout.lines[1].start, lines[0].length);
      }
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

    test('OCR 自带 regions 映射偏移并保留原始字框', () {
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
      expect(
        regions[5].rectangle,
        same(withStaleRegions.regions![6].rectangle),
      );
      expect(
        regions[8].rectangle,
        same(withStaleRegions.regions![9].rectangle),
      );
    });

    test('删连字符与补空格抵消长度变化时仍映射旧偏移', () {
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
        regions[3].rectangle,
        same(block.regions![4].rectangle),
        reason: '首个 T 保留自己的字框，不能沿用第一行连字符的字框',
      );
      expect(regions[6].utf16Start, 7);
      expect(regions[6].rectangle, same(block.regions![7].rectangle));
    });

    test('多次断词、尾随空白、空行和 Unicode 字素保留原字框与旋转', () {
      final MokuroBlock block = withRegions(<String>[
        '😀 INTER- \t',
        '',
        'NATION\u2010',
        'AL caf\u2011 ',
        'e\u0301',
        'time',
      ]);
      final String original = block.lines.join();
      final String text = mangaBlockTextLayout(block).text;
      expect(text, '😀 INTERNATIONAL cafe\u0301 time');
      final List<MangaOcrTextRegion> mapped = mangaEffectiveTextRegions(block);
      final List<MangaOcrTextRegion> retained = block.regions!
          .where(
            (MangaOcrTextRegion r) => !kMangaDehyphenationHyphens.contains(
              original.substring(r.utf16Start, r.utf16End),
            ),
          )
          .toList();
      expect(mapped, hasLength(retained.length));
      for (int i = 0; i < mapped.length; i++) {
        expect(mapped[i].rectangle, same(retained[i].rectangle));
        expect(mapped[i].rotation, retained[i].rotation);
        expect(
          text.substring(mapped[i].utf16Start, mapped[i].utf16End),
          original.substring(retained[i].utf16Start, retained[i].utf16End),
        );
      }
      expect(mangaTextRegionsMatchSentence(mapped, text), isTrue);
    });

    test('日语混排补空格只调整偏移，长音符和竖排字框不变', () {
      final MokuroBlock block = withRegions(<String>[
        'カレー…',
        '50mです',
      ], vertical: true);
      final List<MangaOcrTextRegion> mapped = mangaEffectiveTextRegions(block);
      expect(mangaBlockTextLayout(block).text, 'カレー… 50mです');
      expect(mapped, hasLength(block.regions!.length));
      for (int i = 0; i < mapped.length; i++) {
        expect(mapped[i].rectangle, same(block.regions![i].rectangle));
        expect(mapped[i].rotation, block.regions![i].rotation);
        expect(mapped[i].utf16Start, i < 4 ? i : i + 1);
      }
    });

    test('跨行复合区域保留几何，仅含被删后缀的区域消失', () {
      final MokuroBlock block = MokuroBlock(
        rectangle: const MokuroRect.fromLTWH(0, 0, 600, 120),
        isVertical: false,
        fontSize: 10,
        zIndex: 0,
        lines: const <String>['Under- ', 'stands'],
        regions: const <MangaOcrTextRegion>[
          MangaOcrTextRegion(
            rectangle: MokuroRect.fromLTWH(20, 30, 55, 18),
            utf16Start: 0,
            utf16End: 5,
          ),
          MangaOcrTextRegion(
            rectangle: MokuroRect.fromLTWH(75, 30, 4, 18),
            utf16Start: 5,
            utf16End: 7,
          ),
          MangaOcrTextRegion(
            rectangle: MokuroRect.fromLTWH(20, 60, 60, 18),
            utf16Start: 7,
            utf16End: 13,
          ),
        ],
      );
      final List<MangaOcrTextRegion> mapped = mangaEffectiveTextRegions(block);
      expect(mapped, hasLength(2));
      expect(mapped[0].rectangle, same(block.regions![0].rectangle));
      expect(mapped[1].rectangle, same(block.regions![2].rectangle));
      expect(mapped[1].utf16Start, 5);
      expect(mapped[1].utf16End, 11);
    });

    test('不完整或不在字素边界上的原始字框仍整块回退', () {
      for (final int start in <int>[-1, 1, 2]) {
        final MokuroBlock block = MokuroBlock(
          rectangle: const MokuroRect.fromLTWH(0, 0, 600, 120),
          isVertical: false,
          fontSize: 10,
          zIndex: 0,
          lines: const <String>['😀 Under-', 'stands'],
          regions: <MangaOcrTextRegion>[
            MangaOcrTextRegion(
              rectangle: const MokuroRect.fromLTWH(-500, -500, 1, 1),
              utf16Start: start,
              utf16End: 4,
            ),
          ],
        );
        final List<MangaOcrTextRegion> regions = mangaEffectiveTextRegions(
          block,
        );
        expect(
          mangaTextRegionsMatchSentence(
            regions,
            mangaBlockTextLayout(block).text,
          ),
          isTrue,
        );
        expect(
          regions.every((MangaOcrTextRegion r) => r.rectangle.left >= 0),
          isTrue,
        );
      }
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
