import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi_audio/fushi_audio.dart' show SrtBook;

import '../helpers/source_guard.dart';

/// PR #1697 审查阻断 2：纯字幕书（bookKey 空）不摆「同时删除统计数据」、执行时也
/// 不删它的统计。
///
/// 根因：纯字幕书的 legacy `reading_statistics` / book 类查词制卡计数与
/// `(title, 'book')` 墓碑只能按 title 定位（`deleteReadingStatisticsForTitle`），
/// 勾上就会把**同名 EPUB** 的统计一并删掉、还立墓碑压死它以后的同步。判据只有一条
/// （[ReaderFushiSource.srtBookOffersStatisticsDeletion]），三个删除入口（书架单删 /
/// 批删 / 合集连删）必须都走它，且不得再绕过 deleteBook 按 uid 直删统计。
///
/// flutter test 的 cwd 是 `fushi` 包根。
SrtBook _srt({required String bookKey}) => SrtBook()
  ..uid = 'srtbook_1'
  ..title = 'Same Title'
  ..srtPath = '/x.srt'
  ..importedAt = 0
  ..bookKey = bookKey;

void main() {
  test('判据：只有配对了 EPUB 的字幕书（bookKey 非空）提供统计删除', () {
    expect(
      ReaderFushiSource.srtBookOffersStatisticsDeletion(_srt(bookKey: '')),
      isFalse,
    );
    expect(
      ReaderFushiSource.srtBookOffersStatisticsDeletion(_srt(bookKey: 'bk')),
      isTrue,
    );
  });

  group('书架删除入口的源码守卫', () {
    final String books = maskComments(
      File(
        'lib/src/pages/implementations/reader_history/books.part.dart',
      ).readAsStringSync(),
    );
    final String page = maskComments(
      File(
        'lib/src/pages/implementations/reader_fushi_history_page.dart',
      ).readAsStringSync(),
    );

    test('不再绕过 deleteBook 按字幕书 uid 直删统计（会连坐同名 EPUB）', () {
      expect(books, isNot(contains('deleteBookStatistics(')));
      expect(page, isNot(contains('deleteBookStatistics(')));
    });

    test('单删字幕书：统计勾选受判据门控', () {
      final int start = books.indexOf('Future<void> _confirmDeleteSrtBook(');
      expect(start, isNonNegative);
      final String body = books.substring(
        start,
        books.indexOf('\n  }\n', start),
      );
      expect(
        compactCode(body),
        contains(
          compactCode(
            'statisticsSubtitle: '
            'ReaderFushiSource.srtBookOffersStatisticsDeletion(book) '
            '? _statisticsSubtitle : null',
          ),
        ),
      );
    });

    test('批删：全是纯字幕书时不摆勾选（按判据扫选中集）', () {
      expect(
        compactCode(books),
        contains(
          compactCode(
            'statisticsSubtitle: anyStatisticsTarget ? _statisticsSubtitle : null',
          ),
        ),
      );
      final int start = books.indexOf(
        'Future<bool> _selectionHasStatisticsTarget(',
      );
      expect(start, isNonNegative);
      final String body = books.substring(
        start,
        books.indexOf('\n  }\n', start),
      );
      expect(body, contains('srtBookOffersStatisticsDeletion('));
    });
  });
}
