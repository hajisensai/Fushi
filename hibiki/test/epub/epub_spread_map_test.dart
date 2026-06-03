import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_spread_map.dart';

EpubBook _makeBook({
  required int count,
  List<bool>? imageOnly,
  List<String?>? spreadProps,
  String? renditionSpread,
}) {
  return EpubBook(
    title: 'test',
    renditionSpread: renditionSpread,
    chapters: List<EpubChapter>.generate(count, (int i) {
      final bool isImage =
          imageOnly != null && i < imageOnly.length && imageOnly[i];
      return EpubChapter(
        id: 'ch$i',
        href: 'ch$i.xhtml',
        mediaType: 'application/xhtml+xml',
        html: isImage
            ? '<html><body><img src="img$i.png"/></body></html>'
            : '<html><body><p>Text chapter $i</p></body></html>',
        spineIndex: i,
        spreadProperty: spreadProps != null && i < spreadProps.length
            ? spreadProps[i]
            : null,
      );
    }),
  );
}

void main() {
  group('EpubSpreadMap', () {
    test('off mode produces identity map', () {
      final EpubBook book =
          _makeBook(count: 5, imageOnly: [true, true, true, true, true]);
      final EpubSpreadMap map = EpubSpreadMap.build(
        book: book,
        spreadMode: 'off',
        spreadDirection: 'rtl',
      );

      expect(map.length, 5);
      for (int i = 0; i < 5; i++) {
        expect(map.entryAt(i).chapterIndex, i);
        expect(map.entryAt(i).isSpread, false);
      }
    });

    test('on mode pairs adjacent image-only chapters, chapter 0 stays single',
        () {
      final EpubBook book = _makeBook(
        count: 6,
        imageOnly: [true, true, true, true, true, true],
      );
      final EpubSpreadMap map = EpubSpreadMap.build(
        book: book,
        spreadMode: 'on',
        spreadDirection: 'rtl',
      );

      // ch0 = single (cover), ch1+ch2 = spread, ch3+ch4 = spread, ch5 = single
      expect(map.length, 4);
      expect(map.entryAt(0).isSpread, false);
      expect(map.entryAt(0).chapterIndex, 0);
      expect(map.entryAt(1).isSpread, true);
      expect(map.entryAt(1).chapterIndex, 1);
      expect(map.entryAt(1).secondChapterIndex, 2);
      expect(map.entryAt(2).isSpread, true);
      expect(map.entryAt(2).chapterIndex, 3);
      expect(map.entryAt(2).secondChapterIndex, 4);
      expect(map.entryAt(3).isSpread, false);
      expect(map.entryAt(3).chapterIndex, 5);
    });

    test('on mode does not pair text chapters', () {
      final EpubBook book = _makeBook(
        count: 4,
        imageOnly: [true, false, true, true],
      );
      final EpubSpreadMap map = EpubSpreadMap.build(
        book: book,
        spreadMode: 'on',
        spreadDirection: 'rtl',
      );

      // ch0 = single (cover), ch1 = single (text), ch2+ch3 = spread
      expect(map.length, 3);
      expect(map.entryAt(0).isSpread, false);
      expect(map.entryAt(1).isSpread, false);
      expect(map.entryAt(2).isSpread, true);
    });

    test('auto mode pairs by OPF metadata', () {
      final EpubBook book = _makeBook(
        count: 4,
        imageOnly: [true, true, true, true],
        spreadProps: [null, 'page-spread-left', 'page-spread-right', null],
      );
      final EpubSpreadMap map = EpubSpreadMap.build(
        book: book,
        spreadMode: 'auto',
        spreadDirection: 'rtl',
      );

      // ch0 = single, ch1+ch2 = spread (OPF metadata), ch3 = single
      expect(map.length, 3);
      expect(map.entryAt(0).isSpread, false);
      expect(map.entryAt(1).isSpread, true);
      expect(map.entryAt(1).chapterIndex, 1);
      expect(map.entryAt(1).secondChapterIndex, 2);
      expect(map.entryAt(2).isSpread, false);
    });

    test('auto mode pairs by renditionSpread for image-only', () {
      final EpubBook book = _makeBook(
        count: 3,
        imageOnly: [true, true, true],
        renditionSpread: 'both',
      );
      final EpubSpreadMap map = EpubSpreadMap.build(
        book: book,
        spreadMode: 'auto',
        spreadDirection: 'rtl',
      );

      // ch0+ch1 paired (renditionSpread + both image-only), ch2 single
      expect(map.length, 2);
      expect(map.entryAt(0).isSpread, true);
      expect(map.entryAt(1).isSpread, false);
    });

    test('auto mode pairs by edge match results', () {
      final EpubBook book = _makeBook(
        count: 4,
        imageOnly: [true, true, true, true],
      );
      final EpubSpreadMap map = EpubSpreadMap.build(
        book: book,
        spreadMode: 'auto',
        spreadDirection: 'rtl',
        edgeMatchResults: {0: true, 2: false},
      );

      // ch0+ch1 = spread (edge match), ch2 = single, ch3 = single
      expect(map.length, 3);
      expect(map.entryAt(0).isSpread, true);
      expect(map.entryAt(1).isSpread, false);
      expect(map.entryAt(2).isSpread, false);
    });

    test('virtualPageForChapter round-trips correctly', () {
      final EpubBook book = _makeBook(
        count: 5,
        imageOnly: [true, true, true, true, true],
      );
      final EpubSpreadMap map = EpubSpreadMap.build(
        book: book,
        spreadMode: 'on',
        spreadDirection: 'rtl',
      );

      // ch0=single → v0, ch1+2=spread → v1, ch3+4=spread → v2
      expect(map.virtualPageForChapter(0), 0);
      expect(map.virtualPageForChapter(1), 1);
      expect(map.virtualPageForChapter(2), 1);
      expect(map.virtualPageForChapter(3), 2);
      expect(map.virtualPageForChapter(4), 2);
    });

    test('SpreadEntry.chapterIndices returns correct lists', () {
      const SpreadEntry single = SpreadEntry.single(chapterIndex: 3);
      expect(single.chapterIndices, [3]);
      expect(single.isSpread, false);

      const SpreadEntry spread = SpreadEntry.spread(
        chapterIndex: 4,
        secondChapterIndex: 5,
      );
      expect(spread.chapterIndices, [4, 5]);
      expect(spread.isSpread, true);
    });

    test(
        'flipping Spread Mode off→on rebuilds the page map on the SAME book '
        '(identity singles → paired/forceAll)', () {
      final EpubBook book = _makeBook(
        count: 6,
        imageOnly: <bool>[true, true, true, true, true, true],
      );

      final EpubSpreadMap off = EpubSpreadMap.build(
        book: book,
        spreadMode: 'off',
        spreadDirection: 'rtl',
      );
      expect(off.length, 6, reason: 'off 模式必须是 N 个单页 identity');
      for (int i = 0; i < 6; i++) {
        expect(off.entryAt(i).chapterIndex, i);
        expect(off.entryAt(i).isSpread, isFalse);
        expect(off.entryAt(i).secondChapterIndex, isNull);
        expect(off.virtualPageForChapter(i), i);
      }

      final EpubSpreadMap on = EpubSpreadMap.build(
        book: book,
        spreadMode: 'on',
        spreadDirection: 'rtl',
      );

      expect(on.length, 4, reason: 'on 模式应配对 → 页数应少于 off');
      expect(on.length, lessThan(off.length));

      expect(on.entryAt(0).isSpread, isFalse);
      expect(on.entryAt(0).chapterIndex, 0);

      expect(on.entryAt(1).isSpread, isTrue);
      expect(on.entryAt(1).chapterIndex, 1);
      expect(on.entryAt(1).secondChapterIndex, 2);
      expect(on.entryAt(1).chapterIndices, <int>[1, 2]);

      expect(on.entryAt(2).isSpread, isTrue);
      expect(on.entryAt(2).chapterIndex, 3);
      expect(on.entryAt(2).secondChapterIndex, 4);

      expect(on.entryAt(3).isSpread, isFalse);
      expect(on.entryAt(3).chapterIndex, 5);

      expect(off.virtualPageForChapter(4), 4);
      expect(on.virtualPageForChapter(4), 2);
      expect(on.virtualPageForChapter(4), isNot(off.virtualPageForChapter(4)));

      final bool offHasAnySpread = List<int>.generate(off.length, (int v) => v)
          .any((int v) => off.entryAt(v).isSpread);
      final bool onHasAnySpread = List<int>.generate(on.length, (int v) => v)
          .any((int v) => on.entryAt(v).isSpread);
      expect(offHasAnySpread, isFalse);
      expect(onHasAnySpread, isTrue);
    });
  });
}
