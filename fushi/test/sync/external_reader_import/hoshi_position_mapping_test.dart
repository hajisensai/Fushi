import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_backup_archive.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_position_mapping.dart';

const List<FushiChapterRef> _fushiChapters = <FushiChapterRef>[
  FushiChapterRef(href: 'OEBPS/Text/ch1.xhtml', characters: 80),
  FushiChapterRef(href: 'OEBPS/Text/ch2.xhtml', characters: 240),
];

/// Hoshi 视角：spine 里夹了一个 Fushi 会跳过的图片项，所以 ch2 的 spineIndex = 2。
const ExternalReaderBookInfo _sourceInfo = ExternalReaderBookInfo(
  characterCount: 300,
  chapters: <ExternalReaderChapterSpan>[
    ExternalReaderChapterSpan(
      manifestPath: 'Text/ch1.xhtml',
      spineIndex: 0,
      currentTotal: 0,
      chapterCount: 100,
    ),
    ExternalReaderChapterSpan(
      manifestPath: 'Text/ch2.xhtml',
      spineIndex: 2,
      currentTotal: 100,
      chapterCount: 200,
    ),
  ],
);

ExternalReaderBookmark _bookmark({
  int chapterIndex = 0,
  double progress = 0,
  int characterCount = 0,
}) => ExternalReaderBookmark(
  chapterIndex: chapterIndex,
  progress: progress,
  characterCount: characterCount,
  lastModifiedAt: null,
);

void main() {
  group('normalizeChapterHref', () {
    test('decodes, strips fragments and leading slashes', () {
      expect(
        normalizeChapterHref('/OEBPS/Text/%E7%AB%A0.xhtml#p3'),
        'OEBPS/Text/章.xhtml',
      );
      expect(
        normalizeChapterHref(r'OEBPS\Text\ch1.xhtml?x=1'),
        'OEBPS/Text/ch1.xhtml',
      );
      expect(
        normalizeChapterHref('OEBPS/Text/../Text/./ch1.xhtml'),
        'OEBPS/Text/ch1.xhtml',
      );
      expect(normalizeChapterHref('bad%zzpath.xhtml'), 'bad%zzpath.xhtml');
      expect(normalizeChapterHref('  '), '');
    });
  });

  group('matchFushiChapterIndex', () {
    test('matches an OPF-relative manifest path by path-segment suffix', () {
      expect(matchFushiChapterIndex('Text/ch2.xhtml', _fushiChapters), 1);
      expect(matchFushiChapterIndex('OEBPS/Text/ch1.xhtml', _fushiChapters), 0);
      expect(matchFushiChapterIndex('text/CH2.xhtml', _fushiChapters), 1);
    });

    test('does not match on a partial segment', () {
      expect(matchFushiChapterIndex('h2.xhtml', _fushiChapters), isNull);
    });

    test('gives up on ambiguous candidates instead of guessing', () {
      const List<FushiChapterRef> twins = <FushiChapterRef>[
        FushiChapterRef(href: 'a/index.xhtml', characters: 1),
        FushiChapterRef(href: 'b/index.xhtml', characters: 1),
      ];
      expect(matchFushiChapterIndex('index.xhtml', twins), isNull);
      expect(matchFushiChapterIndex('b/index.xhtml', twins), 1);
    });
  });

  group('mapExternalReaderBookmark', () {
    test('maps via manifest path even when spine indices disagree', () {
      final ExternalReaderMappedPosition? mapped = mapExternalReaderBookmark(
        bookmark: _bookmark(
          chapterIndex: 2,
          progress: 0.9,
          characterCount: 150,
        ),
        bookInfo: _sourceInfo,
        chapters: _fushiChapters,
      );
      expect(mapped, isNotNull);
      expect(mapped!.method, ExternalReaderPositionMethod.chapterHref);
      expect(mapped.sectionIndex, 1);
      // 章内比例按字符偏移算：(150 − 100) / 200，而不是滚动比例 0.9。
      expect(mapped.normCharOffset, 2500);
      expect(mapped.completed, isFalse);
    });

    test('falls back to progress when the char offset is outside the span', () {
      final ExternalReaderMappedPosition mapped = mapExternalReaderBookmark(
        bookmark: _bookmark(
          chapterIndex: 0,
          progress: 0.4,
          characterCount: 9999,
        ),
        bookInfo: _sourceInfo,
        chapters: _fushiChapters,
      )!;
      expect(mapped.sectionIndex, 0);
      expect(mapped.normCharOffset, 4000);
    });

    test('finds the chapter by char range when spineIndex is missing', () {
      const ExternalReaderBookInfo legacy = ExternalReaderBookInfo(
        characterCount: 300,
        chapters: <ExternalReaderChapterSpan>[
          ExternalReaderChapterSpan(
            manifestPath: 'Text/ch1.xhtml',
            spineIndex: null,
            currentTotal: 0,
            chapterCount: 100,
          ),
          ExternalReaderChapterSpan(
            manifestPath: 'Text/ch2.xhtml',
            spineIndex: null,
            currentTotal: 100,
            chapterCount: 200,
          ),
        ],
      );
      final ExternalReaderMappedPosition mapped = mapExternalReaderBookmark(
        bookmark: _bookmark(chapterIndex: 9, characterCount: 250),
        bookInfo: legacy,
        chapters: _fushiChapters,
      )!;
      expect(mapped.sectionIndex, 1);
      expect(mapped.normCharOffset, 7500);
    });

    test('uses the whole-book ratio when chapters cannot be matched', () {
      const ExternalReaderBookInfo foreign = ExternalReaderBookInfo(
        characterCount: 400,
        chapters: <ExternalReaderChapterSpan>[
          ExternalReaderChapterSpan(
            manifestPath: 'elsewhere/p1.html',
            spineIndex: 0,
            currentTotal: 0,
            chapterCount: 400,
          ),
        ],
      );
      final ExternalReaderMappedPosition mapped = mapExternalReaderBookmark(
        bookmark: _bookmark(characterCount: 200),
        bookInfo: foreign,
        chapters: _fushiChapters,
      )!;
      expect(mapped.method, ExternalReaderPositionMethod.bookRatio);
      // 50% × Fushi 总字数 320 = 160 → 第 1 章（80 之后）第 80/240 字。
      expect(mapped.sectionIndex, 1);
      expect(mapped.normCharOffset, 3333);
    });

    test('trusts the spine index only without bookinfo', () {
      final ExternalReaderMappedPosition mapped = mapExternalReaderBookmark(
        bookmark: _bookmark(chapterIndex: 1, progress: 0.5),
        bookInfo: null,
        chapters: _fushiChapters,
      )!;
      expect(mapped.method, ExternalReaderPositionMethod.spineIndex);
      expect(mapped.sectionIndex, 1);
      expect(mapped.normCharOffset, 5000);
      expect(
        mapExternalReaderBookmark(
          bookmark: _bookmark(chapterIndex: 5),
          bookInfo: null,
          chapters: _fushiChapters,
        ),
        isNull,
      );
    });

    test('flags the end of the last chapter as completed', () {
      // Hoshi「标记已读」写的书签：最大 spineIndex + 全书字数 + progress 1。
      final ExternalReaderMappedPosition mapped = mapExternalReaderBookmark(
        bookmark: _bookmark(chapterIndex: 2, progress: 1, characterCount: 300),
        bookInfo: _sourceInfo,
        chapters: _fushiChapters,
      )!;
      expect(mapped.sectionIndex, 1);
      expect(mapped.normCharOffset, 10000);
      expect(mapped.completed, isTrue);
      // 同一判据（≥ 9990）：还差几十字不算读完。
      expect(
        mapExternalReaderBookmark(
          bookmark: _bookmark(chapterIndex: 2, characterCount: 290),
          bookInfo: _sourceInfo,
          chapters: _fushiChapters,
        )!.completed,
        isFalse,
      );
    });

    test('正文读完、尾部后记 / 奥付没翻也算读完（BUG-2870）', () {
      // 用户库里《無職転生》13 的形状：正文 15 章读到末尾，后面挂着 180 字后记 +
      // 312 字奥付 + 0 字纯图页。书签停在正文最后一章 100%（全书 99.6%）。
      final List<FushiChapterRef> chapters = <FushiChapterRef>[
        for (int i = 0; i < 15; i++)
          FushiChapterRef(href: 'item/xhtml/p$i.xhtml', characters: 8500),
        const FushiChapterRef(href: 'item/xhtml/after.xhtml', characters: 180),
        const FushiChapterRef(
          href: 'item/xhtml/okuduke.xhtml',
          characters: 312,
        ),
        const FushiChapterRef(href: 'item/xhtml/ad.xhtml', characters: 0),
      ];
      const int body = 15 * 8500;
      const int total = body + 180 + 312;
      ExternalReaderMappedPosition at(int characterCount) =>
          mapExternalReaderBookmark(
            bookmark: _bookmark(characterCount: characterCount),
            bookInfo: const ExternalReaderBookInfo(
              characterCount: total,
              chapters: <ExternalReaderChapterSpan>[],
            ),
            chapters: chapters,
          )!;
      final ExternalReaderMappedPosition end = at(body);
      expect(end.sectionIndex, lessThan(chapters.length - 1));
      expect(end.completed, isTrue);
      // 差一整章（全书 ~93%）不算读完。
      expect(at(body - 8500).completed, isFalse);
      // 全书 0 字（纯图）没有比例可言：只认末章末尾。
      expect(
        mapExternalReaderBookmark(
          bookmark: _bookmark(chapterIndex: 0, progress: 1),
          bookInfo: null,
          chapters: const <FushiChapterRef>[
            FushiChapterRef(href: 'a.xhtml', characters: 0),
            FushiChapterRef(href: 'b.xhtml', characters: 0),
          ],
        )!.completed,
        isFalse,
      );
    });

    test('books without chapters (manga) get no position', () {
      expect(
        mapExternalReaderBookmark(
          bookmark: _bookmark(),
          bookInfo: _sourceInfo,
          chapters: const <FushiChapterRef>[],
        ),
        isNull,
      );
      expect(parseFushiChapterRefs('[]'), isEmpty);
      expect(parseFushiChapterRefs('not json'), isEmpty);
    });
  });
}
