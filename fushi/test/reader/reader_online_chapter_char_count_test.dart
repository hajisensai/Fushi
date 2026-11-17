import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show absoluteCharOffsetOf, charCountsWithLoadedOnlineChapter;

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// BUG-4791：在线小说书 / 网页小说书按需取回一章正文后，阅读器内存里那一章的
/// 字数必须从占位页的换成正文的——否则章内偏移被夹在占位文案长度以内（整章只
/// 入账那几个字），进度也按占位页算。
///
/// 加载器一侧「把新字数交回来」由 `test/media/novel/lnreader_online_book_test.dart`
/// 与 `test/media/novel/web/web_novel_library_test.dart` 钉住；这里钉阅读器一侧：
/// 换表的纯函数、换表后偏移不再被夹，以及页面把它接在了拦截层确认取章的那一刻。
void main() {
  List<int> cumulativeOf(List<int> counts) {
    final List<int> cumulative = <int>[];
    int sum = 0;
    for (final int count in counts) {
      cumulative.add(sum);
      sum += count;
    }
    return cumulative;
  }

  group('charCountsWithLoadedOnlineChapter', () {
    test('只换取回的那一章，返回新表、不改原表', () {
      final List<int> placeholder = <int>[12, 12, 12];
      final List<int>? updated = charCountsWithLoadedOnlineChapter(
        placeholder,
        1,
        4800,
      );
      expect(updated, <int>[12, 4800, 12]);
      expect(placeholder, <int>[12, 12, 12]);
    });

    test('字数未知 / 章号越界 / 数值没变：返回 null（不动统计坐标系）', () {
      final List<int> counts = <int>[12, 4800, 12];
      expect(charCountsWithLoadedOnlineChapter(counts, 1, null), isNull);
      expect(charCountsWithLoadedOnlineChapter(counts, 1, -1), isNull);
      expect(charCountsWithLoadedOnlineChapter(counts, 3, 100), isNull);
      expect(charCountsWithLoadedOnlineChapter(counts, -1, 100), isNull);
      expect(charCountsWithLoadedOnlineChapter(counts, 1, 4800), isNull);
      expect(charCountsWithLoadedOnlineChapter(<int>[], 0, 100), isNull);
    });

    test('换表前章内偏移被夹在占位页字数以内（读多少都只入账那几个字），'
        '换表后按正文走、后面的章整体平移', () {
      // 占位页 12 个字；第 2 章正文实际 4800 字，读到章内 [1500, 2100)。
      final List<int> before = <int>[12, 12, 12];
      int absolute(List<int> counts, int chapter, int offset) =>
          absoluteCharOffsetOf(
            chapterCumulativeChars: cumulativeOf(counts),
            chapterCharCounts: counts,
            chapter: chapter,
            charOffset: offset,
          );
      expect(
        absolute(before, 1, 2100) - absolute(before, 1, 1500),
        0,
        reason: '起止都被夹到章末，单元为空、不入账（BUG-4791 的漏计）',
      );

      final List<int> after = charCountsWithLoadedOnlineChapter(
        before,
        1,
        4800,
      )!;
      expect(absolute(after, 1, 2100) - absolute(after, 1, 1500), 600);
      // 第 3 章的章首从 24 平移到 4812：旧并集所在的坐标系已失效，所以换表必须
      // 伴随账本 reset（见下面的接线守卫）。
      expect(absolute(before, 2, 0), 24);
      expect(absolute(after, 2, 0), 4812);
    });
  });

  group('阅读器接线', () {
    final String corpus = readReaderPageSource();
    final String masked = maskComments(corpus);

    test('拦截层确认取章的那一刻换字数；失败文案经 describeOnlineSourceError 归一', () {
      final String body = maskComments(
        methodBody(corpus, 'Future<void> _ensureOnlineChapter('),
      );
      final int ensure = body.indexOf('await loader.ensureLoaded(');
      final int adopt = body.indexOf(
        '_adoptOnlineChapterCharCount(book, loaded)',
      );
      expect(ensure, isNonNegative);
      expect(adopt, greaterThan(ensure));
      expect(
        body,
        contains(
          't.novel_online_chapter_failed(error: describeOnlineSourceError(e))',
        ),
      );
      expect(body, isNot(contains(r"error: '$e'")), reason: '不把异常原文甩给用户');
    });

    test('换字数只有拦截层这一个入口（后台预取落盘时不能换：会丢当前未结算单元）', () {
      // 定义 1 处 + 调用 1 处。
      expect('_adoptOnlineChapterCharCount('.allMatches(masked), hasLength(2));
    });

    test('换字数 = 重建累计前缀 + 重注入免解析提示 + 账本 reset，顺序固定', () {
      final String body = maskComments(
        methodBody(corpus, 'void _adoptOnlineChapterCharCount('),
      );
      final int apply = body.indexOf('_applyCharCounts(counts);');
      final int hints = body.indexOf('book.setChapterCharCountHints(counts);');
      final int reset = body.indexOf('_readLedger.reset();');
      expect(body, contains('if (!identical(_book, book)) return;'));
      expect(apply, isNonNegative);
      expect(hints, greaterThan(apply));
      expect(reset, greaterThan(hints), reason: '先换坐标系再清账本');
      expect(
        body.indexOf('if (counts == null) return;'),
        inInclusiveRange(0, apply - 1),
        reason: '字数没变就不 reset，免得白丢并集',
      );
    });

    test('关书 / 换书时停掉加载器里排队的取章', () {
      final String dispose = maskComments(methodBody(corpus, 'void dispose()'));
      expect(dispose, contains('_onlineChapterLoader?.dispose();'));
      final String open = maskComments(
        methodBody(corpus, 'Future<void> _initBookInner() async'),
      );
      final int release = open.indexOf('_onlineChapterLoader?.dispose();');
      expect(release, isNonNegative);
      expect(open.indexOf('_onlineChapterLoader =\n'), greaterThan(release));
    });
  });
}
