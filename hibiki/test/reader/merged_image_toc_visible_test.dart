import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_spread_map.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/reader/ttu_toc_flatten.dart';

/// TODO-1333 回归：图片合并了以后章节列表没了。
///
/// 根因：`chrome.part.dart _buildTtuToc` 旧实现（TODO-1128）把「被吸收进后续文本章的
/// 单图片章」从目录里过滤掉。当一本书的目录项**全部/大量**指向会被合并吸收的图片页
/// （如一长串插图/图片页被一个尾部文本章整段吸收）时，压平结果变空 → 整个章节列表消失。
/// 修复把压平抽成纯函数 [flattenTtuTocEntries]，保留所有解析到的章、永不因合并隐藏，
/// 被吸收章的目录跳转交给导航层 `_resolveNavChapter` 重定向到宿主文本章。
EpubBook _makeBook({
  required int count,
  required List<bool> imageOnly,
}) {
  return EpubBook(
    title: 'test',
    chapters: List<EpubChapter>.generate(count, (int i) {
      final bool isImage = imageOnly[i];
      return EpubChapter(
        id: 'ch$i',
        href: 'ch$i.xhtml',
        mediaType: 'application/xhtml+xml',
        html: isImage
            ? '<html><body><img src="img$i.png"/></body></html>'
            : '<html><body><p>Text chapter $i with real prose paragraph.</p></body></html>',
        spineIndex: i,
      );
    }),
  );
}

void main() {
  group('TODO-1333 flattenTtuTocEntries keeps every chapter', () {
    test('flat TOC flattens in order, resolving each href to its chapter index',
        () {
      final List<EpubTocItem> toc = <EpubTocItem>[
        EpubTocItem(label: 'p1', href: 'ch0.xhtml'),
        EpubTocItem(label: 'p2', href: 'ch1.xhtml'),
        EpubTocItem(label: 'p3', href: 'ch2.xhtml'),
      ];
      final Map<String, int> hrefToIndex = <String, int>{
        'ch0.xhtml': 0,
        'ch1.xhtml': 1,
        'ch2.xhtml': 2,
      };
      final List<TtuTocEntry> entries =
          flattenTtuTocEntries(toc, (String? h) => hrefToIndex[h] ?? -1);
      expect(entries.map((TtuTocEntry e) => e.index).toList(), <int>[0, 1, 2]);
      expect(entries.map((TtuTocEntry e) => e.label).toList(),
          <String>['p1', 'p2', 'p3']);
    });

    test('nested children are walked and carry the parent label', () {
      final List<EpubTocItem> toc = <EpubTocItem>[
        EpubTocItem(label: 'Part 1', href: 'ch0.xhtml', children: <EpubTocItem>[
          EpubTocItem(label: 'Sub A', href: 'ch1.xhtml'),
          EpubTocItem(label: 'Sub B', href: 'ch2.xhtml'),
        ]),
      ];
      final Map<String, int> hrefToIndex = <String, int>{
        'ch0.xhtml': 0,
        'ch1.xhtml': 1,
        'ch2.xhtml': 2,
      };
      final List<TtuTocEntry> entries =
          flattenTtuTocEntries(toc, (String? h) => hrefToIndex[h] ?? -1);
      expect(entries.length, 3);
      expect(entries[0].parent, isNull);
      expect(entries[1].parent, 'Part 1');
      expect(entries[2].parent, 'Part 1');
    });

    test('unresolvable hrefs are skipped without dropping their siblings', () {
      final List<EpubTocItem> toc = <EpubTocItem>[
        EpubTocItem(label: 'good', href: 'ch0.xhtml'),
        EpubTocItem(label: 'dangling', href: 'missing.xhtml'),
        EpubTocItem(label: 'good2', href: 'ch1.xhtml'),
      ];
      final Map<String, int> hrefToIndex = <String, int>{
        'ch0.xhtml': 0,
        'ch1.xhtml': 1,
      };
      final List<TtuTocEntry> entries =
          flattenTtuTocEntries(toc, (String? h) => hrefToIndex[h] ?? -1);
      expect(entries.map((TtuTocEntry e) => e.label).toList(),
          <String>['good', 'good2']);
    });

    test(
        'a TOC whose entries all point to merge-absorbed image chapters stays '
        'non-empty (the reported bug)', () {
      // 3 illustration/image pages followed by a single trailing text chapter
      // (奥付/colophon). With image-merge on, the whole leading image run folds
      // into the trailing text chapter, so ch0..ch2 are absorbed image chapters.
      final EpubBook book = _makeBook(
        count: 4,
        imageOnly: <bool>[true, true, true, false],
      );
      final EpubSpreadMap map = EpubSpreadMap.build(
        book: book,
        spreadMode: 'off',
        spreadDirection: 'ltr',
        mergeImagePages: true,
      );
      // Preconditions: the three image pages really are absorbed (this is what
      // the old TOC filter keyed off to hide them).
      expect(map.isAbsorbedImageChapter(0), isTrue);
      expect(map.isAbsorbedImageChapter(1), isTrue);
      expect(map.isAbsorbedImageChapter(2), isTrue);
      expect(map.isAbsorbedImageChapter(3), isFalse);

      // The book's TOC lists exactly those three image pages (what the user sees
      // as the chapter list). The flatten must keep all of them.
      final List<EpubTocItem> toc = <EpubTocItem>[
        EpubTocItem(label: 'p1', href: 'ch0.xhtml'),
        EpubTocItem(label: 'p2', href: 'ch1.xhtml'),
        EpubTocItem(label: 'p3', href: 'ch2.xhtml'),
      ];
      final Map<String, int> hrefToIndex = <String, int>{
        'ch0.xhtml': 0,
        'ch1.xhtml': 1,
        'ch2.xhtml': 2,
      };
      final List<TtuTocEntry> entries =
          flattenTtuTocEntries(toc, (String? h) => hrefToIndex[h] ?? -1);
      expect(entries, isNotEmpty, reason: '图片合并后章节列表不得被清空（TODO-1333）');
      expect(entries.map((TtuTocEntry e) => e.index).toList(), <int>[0, 1, 2]);
    });
  });

  group('TODO-1333 source-scan guard: TOC flatten never hides absorbed images',
      () {
    final File chrome = File(
      'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
    );
    final File flatten = File('lib/src/reader/ttu_toc_flatten.dart');

    test('_buildTtuToc delegates to the un-filtered pure flattener', () {
      final String src = chrome.readAsStringSync();
      expect(src.contains('flattenTtuTocEntries('), isTrue,
          reason: '_buildTtuToc 必须调用纯函数 flattenTtuTocEntries 压平目录');
      // The old private hide-filter must be gone.
      expect(src.contains('void _flattenTocToTtu('), isFalse,
          reason: '旧的会隐藏被吸收章的 _flattenTocToTtu 必须删除');
    });

    test('the TOC flatten path does not gate entries on image absorption', () {
      // Neither the pure flattener nor the reader TOC builder may key TOC
      // visibility off isAbsorbedImageChapter — that is exactly what emptied the
      // chapter list. Absorbed-chapter nav is handled by _resolveNavChapter.
      expect(flatten.readAsStringSync().contains('isAbsorbedImageChapter('),
          isFalse,
          reason: '纯压平函数不得再按 isAbsorbedImageChapter 隐藏目录项');
      final String src = chrome.readAsStringSync();
      final int start = src.indexOf('List<TtuTocEntry> _buildTtuToc()');
      expect(start, greaterThanOrEqualTo(0));
      final int end = src.indexOf('_reloadWithCurrentSettings', start);
      expect(end, greaterThan(start));
      final String buildToc = src.substring(start, end);
      expect(buildToc.contains('isAbsorbedImageChapter('), isFalse,
          reason: '_buildTtuToc 区间不得再按 isAbsorbedImageChapter 隐藏目录项');
    });
  });
}
