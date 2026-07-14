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

    // ── TODO-1128: merge trailing single-image chapters into text chapter ──
    group('mergeImagePages (TODO-1128, restricted plan A)', () {
      test(
          'off by default: mergeImagePages omitted leaves image chapters '
          'on their own virtual pages', () {
        // text, img, img, text
        final EpubBook book = _makeBook(
          count: 4,
          imageOnly: <bool>[false, true, true, false],
        );
        final EpubSpreadMap map = EpubSpreadMap.build(
          book: book,
          spreadMode: 'off',
          spreadDirection: 'rtl',
        );
        // No merge → 4 independent virtual pages, no absorbed chapters.
        expect(map.length, 4);
        expect(map.mergedImagesForChapter(0), isEmpty);
        expect(map.isAbsorbedImageChapter(1), isFalse);
        expect(map.isAbsorbedImageChapter(2), isFalse);
      });

      test(
          'on: a text chapter absorbs the run of single-image chapters that '
          'PRECEDE it into the top of its own virtual page (TODO-1174)', () {
        // ch0 text, ch1 img, ch2 img, ch3 text
        final EpubBook book = _makeBook(
          count: 4,
          imageOnly: <bool>[false, true, true, false],
        );
        final EpubSpreadMap map = EpubSpreadMap.build(
          book: book,
          spreadMode: 'off',
          spreadDirection: 'rtl',
          mergeImagePages: true,
        );

        // ch1+ch2 are absorbed into ch3 (the *following* text); ch0 keeps its
        // own page. 4 chapters → 2 pages.
        expect(map.length, 2);
        expect(map.entryAt(0).chapterIndex, 0);
        expect(map.entryAt(0).hasMergedImages, isFalse);
        expect(map.entryAt(1).chapterIndex, 3);
        expect(map.entryAt(1).hasMergedImages, isTrue);
        expect(map.entryAt(1).mergedImageChapters, <int>[1, 2]);
        // Owning text index comes first; absorbed (smaller) image indices follow.
        expect(map.entryAt(1).chapterIndices, <int>[3, 1, 2]);

        // Reverse lookups the reader uses for injection / TOC hiding: the images
        // now belong to ch3, NOT ch0.
        expect(map.mergedImagesForChapter(3), <int>[1, 2]);
        expect(map.mergedImagesForChapter(0), isEmpty);
        expect(map.isAbsorbedImageChapter(1), isTrue);
        expect(map.isAbsorbedImageChapter(2), isTrue);
        expect(map.isAbsorbedImageChapter(0), isFalse);
        expect(map.isAbsorbedImageChapter(3), isFalse);
      });

      test(
          'charOffset ownership unchanged: every chapter still maps to a '
          'virtual page and text-chapter indices are never reassigned', () {
        final EpubBook book = _makeBook(
          count: 4,
          imageOnly: <bool>[false, true, true, false],
        );
        final EpubSpreadMap map = EpubSpreadMap.build(
          book: book,
          spreadMode: 'off',
          spreadDirection: 'rtl',
          mergeImagePages: true,
        );
        // Absorbed images resolve to the following text chapter's page (ch3 =
        // page 1); text chapters keep their own page. No index is renumbered.
        expect(map.virtualPageForChapter(0), 0);
        expect(map.virtualPageForChapter(1), 1);
        expect(map.virtualPageForChapter(2), 1);
        expect(map.virtualPageForChapter(3), 1);
      });

      test(
          'NEVER merges two text chapters: adjacent text chapters stay '
          'separate pages, no absorption', () {
        // All text — merge must be a total no-op.
        final EpubBook book = _makeBook(
          count: 4,
          imageOnly: <bool>[false, false, false, false],
        );
        final EpubSpreadMap map = EpubSpreadMap.build(
          book: book,
          spreadMode: 'off',
          spreadDirection: 'rtl',
          mergeImagePages: true,
        );
        expect(map.length, 4);
        for (int i = 0; i < 4; i++) {
          expect(map.entryAt(i).chapterIndex, i);
          expect(map.entryAt(i).hasMergedImages, isFalse);
          expect(map.isAbsorbedImageChapter(i), isFalse);
        }
      });

      test(
          'front-matter: a leading image-only chapter (cover / kuchi-e) is '
          'absorbed into the FOLLOWING chapter (TODO-1174 blind-spot fix)', () {
        // ch0 img (cover-like), ch1 text — the illustration joins ch1's opening
        // flow instead of dangling on its own page (old behaviour left it as a
        // standalone page; the flip folds it into the chapter it introduces).
        final EpubBook book = _makeBook(
          count: 2,
          imageOnly: <bool>[true, false],
        );
        final EpubSpreadMap map = EpubSpreadMap.build(
          book: book,
          spreadMode: 'off',
          spreadDirection: 'rtl',
          mergeImagePages: true,
        );
        expect(map.length, 1);
        expect(map.entryAt(0).chapterIndex, 1);
        expect(map.entryAt(0).mergedImageChapters, <int>[0]);
        expect(map.mergedImagesForChapter(1), <int>[0]);
        expect(map.isAbsorbedImageChapter(0), isTrue);
        expect(map.isAbsorbedImageChapter(1), isFalse);
        expect(map.virtualPageForChapter(0), 0);
        expect(map.virtualPageForChapter(1), 0);
      });

      test(
          'trailing images after the last text chapter keep their own pages '
          '(nothing follows to absorb them) (TODO-1174)', () {
        // ch0 text, ch1 img, ch2 img — images dangle after the last prose, so
        // with the flipped direction they cannot join any following chapter.
        final EpubBook book = _makeBook(
          count: 3,
          imageOnly: <bool>[false, true, true],
        );
        final EpubSpreadMap map = EpubSpreadMap.build(
          book: book,
          spreadMode: 'off',
          spreadDirection: 'rtl',
          mergeImagePages: true,
        );
        expect(map.length, 3);
        expect(map.entryAt(0).chapterIndex, 0);
        expect(map.entryAt(0).hasMergedImages, isFalse);
        expect(map.entryAt(1).chapterIndex, 1);
        expect(map.entryAt(2).chapterIndex, 2);
        expect(map.isAbsorbedImageChapter(1), isFalse);
        expect(map.isAbsorbedImageChapter(2), isFalse);
      });

      test(
          'spread pairing wins over merge: a spread pair is an opaque barrier '
          'that flushes a pending leading image run to its own page (TODO-1174)',
          () {
        // ch0 text, ch1 img, ch2 img, ch3 img — with OPF spread on ch2/ch3.
        // ch1 is a leading image awaiting a following text; before any text
        // arrives it hits the ch2+ch3 spread (an opaque barrier), so ch1 is
        // flushed to its own page rather than absorbed across the spread.
        final EpubBook book = _makeBook(
          count: 4,
          imageOnly: <bool>[false, true, true, true],
          spreadProps: <String?>[
            null,
            null,
            'page-spread-left',
            'page-spread-right',
          ],
        );
        final EpubSpreadMap map = EpubSpreadMap.build(
          book: book,
          spreadMode: 'auto',
          spreadDirection: 'rtl',
          mergeImagePages: true,
        );
        // Pages: [ch0 text], [ch1 img (flushed)], [ch2+ch3 spread].
        expect(map.length, 3);
        expect(map.entryAt(0).chapterIndex, 0);
        expect(map.entryAt(0).hasMergedImages, isFalse);
        expect(map.entryAt(1).chapterIndex, 1);
        expect(map.entryAt(1).isSpread, isFalse);
        expect(map.entryAt(1).hasMergedImages, isFalse,
            reason: 'spread barrier flushes the pending leading image run');
        expect(map.entryAt(2).isSpread, isTrue);
        expect(map.entryAt(2).chapterIndices, <int>[2, 3]);
        expect(map.isAbsorbedImageChapter(1), isFalse);
        expect(map.isAbsorbedImageChapter(2), isFalse);
        expect(map.isAbsorbedImageChapter(3), isFalse);
      });

      test(
          'BUG-817: OPF page-spread must NOT pair a reflowable text page with a '
          'fixed-layout illustration page (hybrid book), or the illustration is '
          'consumed by a bogus text|image spread and merge can never absorb it',
          () {
        // Real repro from 安達としまむら2 (電撃文庫 hybrid layout): reflowable
        // text chapters carry OPF page-spread-right, and the fixed-layout SVG
        // insert illustration that follows carries page-spread-left. The old
        // `_isSpreadPair` rule paired them on OPF metadata alone → the image was
        // swallowed into a nonsensical text|image spread, `isAbsorbedImageChapter`
        // stayed false, and "将插图页并入正文" silently did nothing (the picture
        // vanished: no standalone page, no inline injection). Pairing must require
        // BOTH pages be image-only, exactly like the rendition:spread rule.
        //   ch0 text(right), ch1 image(left), ch2 text — p-009/p-010/p-011.
        final EpubBook book = _makeBook(
          count: 3,
          imageOnly: <bool>[false, true, false],
          spreadProps: <String?>[
            'page-spread-right',
            'page-spread-left',
            null,
          ],
        );
        final EpubSpreadMap map = EpubSpreadMap.build(
          book: book,
          spreadMode: 'auto',
          spreadDirection: 'rtl',
          mergeImagePages: true,
        );
        // The text page is never spread-paired with the image.
        expect(map.entryAt(map.virtualPageForChapter(0)).isSpread, isFalse,
            reason: '文本章不得与插画章配成 spread');
        // The illustration is absorbed into the following text chapter's top.
        expect(map.isAbsorbedImageChapter(1), isTrue,
            reason: '插画应被 merge 吸收进后随正文，而非被 spread 消费');
        expect(map.mergedImagesForChapter(2), <int>[1]);
        // Pages collapse to [ch0 text], [ch2 text + inline img1].
        expect(map.length, 2);
        expect(map.entryAt(1).chapterIndex, 2);
      });

      test(
          'merge folds each leading image run into the next text chapter '
          '(TODO-1174)', () {
        // text, img, img, text, img, text
        final EpubBook book = _makeBook(
          count: 6,
          imageOnly: <bool>[false, true, true, false, true, false],
        );
        final EpubSpreadMap map = EpubSpreadMap.build(
          book: book,
          spreadMode: 'off',
          spreadDirection: 'rtl',
          mergeImagePages: true,
        );
        // Pages: [ch0], [ch3+img1+img2], [ch5+img4].
        expect(map.length, 3);
        expect(map.entryAt(0).chapterIndex, 0);
        expect(map.entryAt(0).hasMergedImages, isFalse);
        expect(map.entryAt(1).chapterIndex, 3);
        expect(map.entryAt(1).mergedImageChapters, <int>[1, 2]);
        expect(map.entryAt(2).chapterIndex, 5);
        expect(map.entryAt(2).mergedImageChapters, <int>[4]);
      });

      // ── TODO-1128 nav-guard: redirect + off-mode skip contract ──────────
      // These lock the exact map computation the reader's `_resolveNavChapter`
      // and unified page-turn use to dedupe absorbed image chapters (which
      // otherwise load their own single-image page AND get injected inline at
      // the host top = the same image twice).

      // Mirror of `_resolveNavChapter`: an absorbed image chapter resolves to
      // the text chapter whose virtual page owns its inline image; any other
      // chapter passes through unchanged.
      int resolveNavChapter(EpubSpreadMap map, int index) {
        if (!map.isAbsorbedImageChapter(index)) return index;
        return map.entryAt(map.virtualPageForChapter(index)).chapterIndex;
      }

      test(
          'redirect: every absorbed image chapter resolves to its host text '
          'chapter, and the host is never itself absorbed (idempotent)', () {
        // cover(img), text, img, img, text  → ch0 absorbed into ch1;
        // ch2,ch3 absorbed into ch4.
        final EpubBook book = _makeBook(
          count: 5,
          imageOnly: <bool>[true, false, true, true, false],
        );
        final EpubSpreadMap map = EpubSpreadMap.build(
          book: book,
          spreadMode: 'off',
          spreadDirection: 'rtl',
          mergeImagePages: true,
        );
        // ch0 → host ch1; ch2,ch3 → host ch4.
        expect(resolveNavChapter(map, 0), 1);
        expect(resolveNavChapter(map, 2), 4);
        expect(resolveNavChapter(map, 3), 4);
        // Text chapters pass through untouched.
        expect(resolveNavChapter(map, 1), 1);
        expect(resolveNavChapter(map, 4), 4);
        // Idempotent: resolving a host again is a no-op (host not absorbed).
        for (int c = 0; c < 5; c++) {
          final int host = resolveNavChapter(map, c);
          expect(map.isAbsorbedImageChapter(host), isFalse);
          expect(resolveNavChapter(map, host), host);
        }
      });

      test(
          'off mode + merge still absorbs: page-turn via virtual pages skips '
          'every absorbed image chapter (both directions)', () {
        // Same book as above, spreadMode == off (the mode that previously
        // bypassed the virtual-page map and loaded absorbed chapters raw).
        final EpubBook book = _makeBook(
          count: 5,
          imageOnly: <bool>[true, false, true, true, false],
        );
        final EpubSpreadMap map = EpubSpreadMap.build(
          book: book,
          spreadMode: 'off',
          spreadDirection: 'rtl',
          mergeImagePages: true,
        );
        // Merge runs regardless of spreadMode: absorbed chapters exist.
        expect(map.isAbsorbedImageChapter(0), isTrue);
        expect(map.isAbsorbedImageChapter(2), isTrue);
        expect(map.isAbsorbedImageChapter(3), isTrue);
        // Every virtual page hosts only a non-absorbed chapter → walking pages
        // (a page turn) can never land on an absorbed single-image chapter.
        for (int v = 0; v < map.length; v++) {
          expect(
              map.isAbsorbedImageChapter(map.entryAt(v).chapterIndex), isFalse,
              reason: 'virtual page $v must not be an absorbed image chapter');
        }
        // Forward from the host of ch0 (=ch1, virtual 0) goes straight to ch4's
        // page (virtual 1), never through the absorbed ch2/ch3 single pages.
        expect(map.virtualPageForChapter(1), 0);
        expect(map.virtualPageForChapter(4), 1);
        expect(map.entryAt(1).chapterIndex, 4);
        // Backward from ch4's page lands on ch1's page (skips absorbed run).
        expect(map.entryAt(0).chapterIndex, 1);
      });
    });
  });
}
