import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// P4 display-title 门面面级守卫（沿 shelf_srt_card_override_title_guard_test
/// 的源码切片范式）：
///
/// 正向：清单里每个**上屏面**必须经 `display_title.dart` 门面
/// （displayTitleForBook / displayTitleForVideo / displayTitleForGame /
/// displayTitleForStatRow）取显示名，不得再裸读 raw title 上屏。
///
/// 反向（身份红线）：统计聚合键 / 落库快照 / 查词计数身份必须**恒 raw**，
/// 这些切片内不得出现门面调用——override 一旦混进聚合键，改名前后的统计会
/// 分叉成两个桶、快照身份会漂移。
void main() {
  String read(String path) => File(path).readAsStringSync();

  /// 取 [start]（含）到其后第一个 [end]（不含）的源码切片；找不到即 fail，
  /// 防止函数被改名后守卫静默空转。
  String slice(String src, String start, String end, {required String where}) {
    final int a = src.indexOf(start);
    expect(a, greaterThanOrEqualTo(0), reason: '$where：找不到切片起点 `$start`');
    final int b = src.indexOf(end, a + start.length);
    expect(b, greaterThan(a), reason: '$where：找不到切片终点 `$end`');
    return src.substring(a, b);
  }

  final String facade = read('lib/src/media/display_title.dart');
  final String dashboard =
      read('lib/src/pages/implementations/home_dashboard_page.dart');
  final String galgameHome =
      read('lib/src/pages/implementations/galgame_home_page.dart');
  final String collections =
      read('lib/src/pages/implementations/collections_page.dart');
  final String booksPart =
      read('lib/src/pages/implementations/reader_history/books.part.dart');
  final String historyPage =
      read('lib/src/pages/implementations/reader_hibiki_history_page.dart');
  final String miningPart =
      read('lib/src/pages/implementations/reader_hibiki/mining.part.dart');
  final String chromePart =
      read('lib/src/pages/implementations/reader_hibiki/chrome.part.dart');
  final String navigationPart =
      read('lib/src/pages/implementations/reader_hibiki/navigation.part.dart');
  final String readerPage =
      read('lib/src/pages/implementations/reader_hibiki_page.dart');

  group('门面本体', () {
    test('displayTitleForVideo 是显式 no-op（视频 raw 即显示名，守卫知道这里想过）', () {
      expect(
        facade,
        contains('String displayTitleForVideo(VideoBookRow row) => row.title;'),
      );
    });

    test('四个门面入口齐备', () {
      expect(facade, contains('String displayTitleForBook('));
      expect(facade, contains('String displayTitleForGame('));
      expect(facade, contains('String displayTitleForStatRow('));
    });
  });

  group('dashboard 上屏面（home_dashboard_page.dart）', () {
    test('热力图日明细「阅读」节经 displayTitleForStatRow', () {
      final String fn = slice(
        dashboard,
        'String _readingStatDisplayTitle(',
        'String _gameDisplayTitle(',
        where: '_readingStatDisplayTitle',
      );
      expect(fn, contains('displayTitleForStatRow('));
    });

    test('日明细「游戏」节与活动时间轴游戏行经 _gameDisplayTitle → displayTitleForGame', () {
      // 日明细游戏节。
      expect(
        dashboard,
        contains('(title: _gameDisplayTitle(title), chars: chars,'),
      );
      // 活动时间轴游戏行。
      expect(
        dashboard,
        contains('_gameDisplayTitle(entry.title, mediaKey: entry.mediaKey)'),
      );
      // helper 委托门面。
      final String fn = slice(
        dashboard,
        'String _gameDisplayTitle(',
        'List<({String title, int chars, int timeMs})> _watchDayRows',
        where: '_gameDisplayTitle',
      );
      expect(fn, contains('displayTitleForGame(entry: entry'));
    });
  });

  group('游戏首页活动时间轴（galgame_home_page.dart）', () {
    test('时间轴条目标题经 displayTitleForGame（快照回退）', () {
      expect(
        galgameHome,
        contains('displayTitleForGame(entry: game, rawTitle: entry.title)'),
      );
    });
  });

  group('收藏页（collections_page.dart）', () {
    test('SRT 书名反查表值经门面（bookKey/srtUid 双通道分派）', () {
      expect(
        collections,
        contains('bookTitleMap[b.bookKey] = displayTitleForBook('),
      );
    });

    test('统一解析 helper 覆盖书（override 门面）与视频（列值 no-op 门面）', () {
      // 切片终点原来写死后继方法的**完整签名** `void _openBook(`，PR#647 把它改成
      // `Future<void> _openBook(...) async` 后 indexOf 返 -1，守卫什么都没校到就红。
      // 把返回类型写进锚点＝把「邻居长什么样」当成本函数的不变量。改用 methodBody
      // 的花括号配对定边界：只依赖本函数自己的签名，邻居怎么改都不咬。
      final String fn =
          methodBody(collections, 'String? _displayBookTitleFor(');
      expect(fn, contains('displayTitleForVideo(row)'));
      expect(fn, contains('displayTitleForBook('));
    });

    test('列表副标题与详情弹窗副标题走 _itemDisplayBookTitle，不裸读快照列', () {
      // 详情弹窗。
      expect(
        collections,
        contains(
            'final String? bookDisplayTitle = _itemDisplayBookTitle(item);'),
      );
      // 列表副标题（快照列 item.bookTitle 不得再直接进 subtitle join）。
      expect(
        collections,
        contains(
            RegExp(r'_itemDisplayBookTitle\(item\),\s*item\.chapterLabel')),
      );
    });

    test('导出分组名（给人看的导出）经门面；DB 全量两侧同口径', () {
      expect(
        collections,
        contains(
            'bookTitle: _itemDisplayBookTitle(item) ?? t.collection_sentence'),
      );
      // _loadMinedForExport / _loadFavoritesForExport 各自过 _displayBookTitleFor。
      expect(
        RegExp(r'_displayBookTitleFor\(').allMatches(collections).length,
        greaterThanOrEqualTo(3),
        reason: '导出两侧 + _openBook/_itemDisplayBookTitle 应复用同一 helper',
      );
    });
  });

  group('书架（books.part.dart / reader_hibiki_history_page.dart）', () {
    test('SRT 上屏名统一入口 _srtDisplayTitle 委托门面', () {
      expect(
        booksPart,
        contains(
            'String _srtDisplayTitle(SrtBook book) => displayTitleForBook('),
      );
    });

    test('删除确认弹窗（SRT/EPUB）书名经门面', () {
      expect(
        booksPart,
        contains('t.srt_delete_confirm(title: _srtDisplayTitle(book))'),
      );
      final String fn = slice(
        booksPart,
        'Future<void> _confirmDeleteEpub(',
        'Future<void> _openIllustrations(',
        where: '_confirmDeleteEpub',
      );
      expect(fn, contains('displayTitleForBook(item: item'));
    });

    test('「查看插画」页标题经门面', () {
      final String fn = slice(
        booksPart,
        'Future<void> _openIllustrations(',
        'Future<void> _openAudioImport(',
        where: '_openIllustrations',
      );
      expect(
        fn,
        contains('bookTitle: displayTitleForBook(item: item'),
      );
    });

    test('批量组合默认名与单卡加入合集默认名经门面', () {
      // 批量档1（EPUB + SRT 成员标题）。
      final String combine = slice(
        booksPart,
        'Future<void> _combineCreateNew(',
        'Future<void> _combineAddToExisting(',
        where: '_combineCreateNew',
      );
      expect(combine, contains('displayTitleForBook(item: item'));
      expect(combine, contains('_srtDisplayTitle(book)'));
      // 单卡：SRT 侧。
      final String srtAdd = slice(
        booksPart,
        'Future<void> _addSrtToCollection(',
        'Future<void> _showSrtBookDialog(',
        where: '_addSrtToCollection',
      );
      expect(srtAdd, contains('_srtDisplayTitle(book)'));
      // 单卡：EPUB 侧（宿主文件）。
      final String epubAdd = slice(
        historyPage,
        'Future<void> _addEpubToCollection(',
        'Future<void> _toggleBookCompleted(',
        where: '_addEpubToCollection',
      );
      expect(epubAdd, contains('displayTitleForBook(item: item'));
    });
  });

  group('制卡显示语境（mining.part.dart）', () {
    test('{document-title} 卡片字段与书名标签经门面（同源一个显示变量）', () {
      expect(miningPart, contains('final String? displayDocumentTitle ='));
      expect(miningPart, contains('documentTitle: displayDocumentTitle,'));
      expect(
        miningPart,
        contains('BaseAnkiRepository.sanitizeTitleTag(displayDocumentTitle)'),
      );
    });
  });

  group('身份面反向断言（统计聚合键 / 落库快照恒 raw）', () {
    test('reader 阅读统计 flush（navigation.part.dart）聚合键恒 raw', () {
      final String fn = slice(
        navigationPart,
        'Future<void> _flushReadingStats()',
        '}\n}',
        where: '_flushReadingStats',
      );
      expect(fn, contains('final String title = _book!.title;'));
      expect(
        fn,
        isNot(contains('displayTitleFor')),
        reason: 'reading_statistics/activity_events 的 title 是聚合键，禁过门面',
      );
    });

    test('per-book 制卡计数（mining.part.dart _recordMined）聚合键恒 raw', () {
      final String fn = slice(
        miningPart,
        'Future<void> _recordMined()',
        'Future<void> _recordMinedSentence(',
        where: '_recordMined',
      );
      expect(fn, contains("title: _book?.title ?? '',"));
      expect(
        fn,
        isNot(contains('displayTitleFor')),
        reason: 'addMineCountPerBook.title 与阅读统计聚合键对齐，禁过门面',
      );
      expect(
        fn,
        isNot(contains('displayDocumentTitle')),
        reason: '统计路径不得复用显示变量',
      );
    });

    test('制卡历史快照（_recordMinedSentence）documentTitle 恒 raw', () {
      final String fn = slice(
        miningPart,
        'Future<void> _recordMinedSentence(',
        'Future<String?> _prepareSasayakiCuesJson()',
        where: '_recordMinedSentence',
      );
      expect(fn, contains('documentTitle: _book?.title,'));
      expect(
        fn,
        isNot(contains('documentTitle: context.documentTitle')),
        reason: 'context.documentTitle 已过显示门面，落库快照必须直取 raw',
      );
    });

    test('收藏句落库快照（chrome.part.dart）bookTitle 恒 raw', () {
      expect(chromePart, contains('bookTitle: _book!.title,'));
      expect(chromePart, isNot(contains('displayTitleFor')));
    });

    test('查词计数身份（reader_hibiki_page.dart lookupBookIdentity）恒 raw', () {
      expect(
        readerPage,
        contains('(bookKey: widget.bookKey, title: _book?.title);'),
      );
    });
  });
}
