import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart'
    show lnReaderPendingChapterBody;
import 'package:fushi/src/media/novel/online/online_novel_chapter_loader.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show
        OnlineChapterCharCountAdoption,
        absoluteCharOffsetOf,
        charCountsWithLoadedOnlineChapter,
        countChapterCharsWithPending,
        persistRecomputedChapterCharCounts;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi/src/stats/read_unit_ledger.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// BUG-4809：在线小说书 / 网页小说书按需取回一章正文后，阅读器内存里那一章的
/// 字数必须从占位页的换成正文的——否则章内偏移被夹在占位文案长度以内（整章只
/// 入账那几个字），进度也按占位页算。
///
/// 加载器一侧「把新字数交回来」由 `test/media/novel/lnreader_online_book_test.dart`
/// 与 `test/media/novel/web/web_novel_library_test.dart` 钉住；这里钉阅读器一侧：
/// 换表的纯函数、换表后偏移不再被夹、换表时机（[OnlineChapterCharCountAdoption]：
/// 导航目标章立刻换，阅读中途取回的邻章等当前单元结算后再换），以及页面的接线。
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
        reason: '起止都被夹到章末，单元为空、不入账（BUG-4809 的漏计）',
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

  group('OnlineChapterCharCountAdoption：换表时机', () {
    OnlineNovelChapterLoaded loaded(int index, int? characters) =>
        OnlineNovelChapterLoaded(index: index, characters: characters);

    test('导航目标章：立刻给出新表', () {
      final OnlineChapterCharCountAdoption adoption =
          OnlineChapterCharCountAdoption();
      expect(
        adoption.chapterLoaded(
          <int>[12, 12, 12],
          loaded(1, 4800),
          isNavigationTarget: true,
        ),
        <int>[12, 4800, 12],
      );
      expect(adoption.hasDeferred, isFalse);
    });

    test('字数未知（null）：不换也不记', () {
      final OnlineChapterCharCountAdoption adoption =
          OnlineChapterCharCountAdoption();
      for (final bool target in <bool>[true, false]) {
        expect(
          adoption.chapterLoaded(
            <int>[12, 12],
            loaded(1, null),
            isNavigationTarget: target,
          ),
          isNull,
        );
      }
      expect(adoption.hasDeferred, isFalse);
      expect(adoption.takeDeferred(<int>[12, 12]), isNull);
    });

    test('阅读中途取回的邻章（无缝衔接挂前后章）：先记着，结算后一次换上', () {
      final OnlineChapterCharCountAdoption adoption =
          OnlineChapterCharCountAdoption();
      const List<int> counts = <int>[12, 4800, 12];
      // 正读第 2 章，JS 先后挂上第 3 章与第 1 章。
      expect(
        adoption.chapterLoaded(
          counts,
          loaded(2, 5200),
          isNavigationTarget: false,
        ),
        isNull,
      );
      expect(
        adoption.chapterLoaded(
          counts,
          loaded(0, 3000),
          isNavigationTarget: false,
        ),
        isNull,
      );
      expect(adoption.hasDeferred, isTrue);
      expect(adoption.takeDeferred(counts), <int>[3000, 4800, 5200]);
      expect(adoption.hasDeferred, isFalse);
      expect(adoption.takeDeferred(<int>[3000, 4800, 5200]), isNull);
    });

    test('记着的章随后成了导航目标：按目标章立刻换，不再留在待换表里', () {
      final OnlineChapterCharCountAdoption adoption =
          OnlineChapterCharCountAdoption();
      const List<int> counts = <int>[12, 12];
      adoption.chapterLoaded(
        counts,
        loaded(1, 4000),
        isNavigationTarget: false,
      );
      expect(
        adoption.chapterLoaded(
          counts,
          loaded(1, 4100),
          isNavigationTarget: true,
        ),
        <int>[12, 4100],
      );
      expect(adoption.hasDeferred, isFalse);
    });

    test('后台整本重算落定：已换上的章盖回正文字数；记着没换的只盖进写回书行的那份', () {
      final OnlineChapterCharCountAdoption adoption =
          OnlineChapterCharCountAdoption();
      adoption.chapterLoaded(
        <int>[12, 12, 12, 12],
        loaded(1, 4800),
        isNavigationTarget: true,
      );
      adoption.chapterLoaded(
        <int>[12, 4800, 12, 12],
        loaded(2, 5200),
        isNavigationTarget: false,
      );
      // isolate 读盘早于取章：重算结果里这两章还是占位页的字数（新口径 9）。
      const List<int> recomputed = <int>[9, 9, 9, 9];
      expect(adoption.overlay(recomputed, includeDeferred: false), <int>[
        9,
        4800,
        9,
        9,
      ], reason: '内存：记着没换的章留到结算后（那一刻才能 reset）');
      expect(adoption.overlay(recomputed, includeDeferred: true), <int>[
        9,
        4800,
        5200,
        9,
      ], reason: '书行：这两章早已是正文字数，不能被占位页字数盖回去');
      expect(recomputed, <int>[9, 9, 9, 9], reason: '不改入参');
      // 章数对不上的表（换过书）不越界。
      expect(adoption.overlay(<int>[9], includeDeferred: true), <int>[9]);
    });

    test('clear：换书后前一本的账作废', () {
      final OnlineChapterCharCountAdoption adoption =
          OnlineChapterCharCountAdoption();
      adoption.chapterLoaded(
        <int>[1, 1],
        loaded(0, 50),
        isNavigationTarget: true,
      );
      adoption.chapterLoaded(
        <int>[50, 1],
        loaded(1, 60),
        isNavigationTarget: false,
      );
      adoption.clear();
      expect(adoption.hasDeferred, isFalse);
      expect(adoption.overlay(<int>[1, 1], includeDeferred: true), <int>[1, 1]);
    });

    // 审查发现的原始失败路径：连续模式章节无缝衔接下，读第 N 章途中 JS 挂 N+1，
    // 旧实现当场换表 + reset，并集被清——往回滚再往前读会把已入账的屏再入账一次。
    test('阅读中途取回邻章不动账本：回翻再前翻不重复入账；结算后换表才 reset', () {
      int credited = 0;
      final ReadUnitLedger ledger = ReadUnitLedger(
        onCredit: (List<(int, int)> fresh) =>
            credited += readUnitsLength(fresh),
        onRetract: (List<(int, int)> retracted) =>
            credited -= readUnitsLength(retracted),
      );
      final OnlineChapterCharCountAdoption adoption =
          OnlineChapterCharCountAdoption();
      List<int> counts = <int>[4800, 12, 12];

      /// 阅读器的换表动作：有新表才换 + reset（与 `_switchOnlineChapterCharCounts`
      /// 同一个条件）。
      void switchTo(List<int>? next) {
        if (next == null) return;
        counts = next;
        ledger.reset();
      }

      // 第 1 章读了三屏。
      ledger.arrive(0, 600);
      ledger.arrive(600, 1200);
      ledger.arrive(1200, 1800);
      expect(credited, 1200);

      // 此刻无缝衔接挂上第 2 章（占位页 → 正文 5000 字）。
      switchTo(
        adoption.chapterLoaded(
          counts,
          loaded(1, 5000),
          isNavigationTarget: false,
        ),
      );
      expect(counts, <int>[4800, 12, 12], reason: '阅读中途不换表');
      expect(ledger.current, (1200, 1800), reason: '当前单元还在');

      // 往回滚一屏再滚回来、接着往下读一屏：并集还在，所以不会重复入账。
      ledger.arrive(600, 1200);
      ledger.arrive(1200, 1800);
      ledger.arrive(1800, 2400);
      expect(credited, 1800);

      // 滚过章界：先结算当前单元，再换表。
      ledger.leave();
      expect(credited, 2400);
      switchTo(adoption.takeDeferred(counts));
      expect(counts, <int>[4800, 5000, 12]);
      expect(ledger.current, isNull);
      expect(credited, 2400, reason: '已入账的沉没，不撤回');
    });
  });

  group('阅读器接线', () {
    final String corpus = readReaderPageSource();
    final String masked = maskComments(corpus);

    test('拦截层确认取章后交给换表入口；失败文案经 describeOnlineSourceError 归一', () {
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

    test('立刻换只限「导航在飞 + 取回的就是在装的那一章」；拦截层的请求不都是导航', () {
      final String body = maskComments(
        methodBody(corpus, 'void _adoptOnlineChapterCharCount('),
      );
      expect(body, contains('if (!identical(_book, book)) return;'));
      expect(
        body,
        contains(
          'isNavigationTarget: _restoreInFlight && '
          'loaded.index == _currentChapter,',
        ),
      );
      expect(body, contains('if (counts == null) return;'));
      expect(
        body,
        isNot(contains('_readLedger')),
        reason: '清账本只在 _switchOnlineChapterCharCounts，这里不直接碰',
      );
      // 定义 1 处 + 调用 1 处（后台预取落盘时不能换）。
      expect('_adoptOnlineChapterCharCount('.allMatches(masked), hasLength(2));
    });

    test('记着的章只在当前单元结算之后换：无缝换章的 leave 之后、整章导航在飞且单元已空', () {
      // 定义 1 处 + 两个结算点。
      expect(
        '_applyDeferredOnlineChapterCharCounts('.allMatches(masked),
        hasLength(3),
      );
      final String seamless = maskComments(
        methodBody(corpus, 'Future<void> _onSeamlessChapterActivated({'),
      );
      final int leave = seamless.indexOf('_readLedger.leave();');
      final int apply = seamless.indexOf(
        '_applyDeferredOnlineChapterCharCounts();',
      );
      expect(leave, isNonNegative);
      expect(apply, greaterThan(leave), reason: '先结算上一章的当前单元');
      expect(
        apply,
        lessThan(seamless.indexOf('_currentChapter = to;')),
        reason: '在第一个 await 之前的同步段里',
      );

      final String ensure = maskComments(
        methodBody(corpus, 'Future<void> _ensureOnlineChapter('),
      );
      final int gate = ensure.indexOf(
        'if (_restoreInFlight && _readLedger.current == null) {',
      );
      final int flush = ensure.indexOf(
        '_applyDeferredOnlineChapterCharCounts();',
      );
      expect(gate, isNonNegative);
      expect(flush, greaterThan(gate));
      expect(
        flush,
        lessThan(ensure.indexOf('await loader.ensureLoaded(')),
        reason: '判据与换表之间不能隔着 await',
      );
    });

    test('换字数 = 重建累计前缀 + 重注入免解析提示 + 账本 reset，顺序固定', () {
      final String body = maskComments(
        methodBody(corpus, 'void _switchOnlineChapterCharCounts('),
      );
      final int apply = body.indexOf('_applyCharCounts(counts);');
      final int hints = body.indexOf('book.setChapterCharCountHints(counts);');
      final int reset = body.indexOf('_readLedger.reset();');
      expect(apply, isNonNegative);
      expect(hints, greaterThan(apply));
      expect(reset, greaterThan(hints), reason: '先换坐标系再清账本');
      // 定义 1 处 + 立刻换 / 结算后换各 1 处。
      expect(
        '_switchOnlineChapterCharCounts('.allMatches(masked),
        hasLength(3),
      );
    });

    test('后台整本重算落定：内存与写回书行都先盖上已知的正文字数', () {
      final String body = maskComments(
        methodBody(corpus, 'void _recomputeCharCountsInBackground()'),
      );
      final int memory = body.indexOf('includeDeferred: false');
      final int apply = body.indexOf('_applyCharCounts(counts);');
      final int persist = body.indexOf('_persistRecomputedCharCounts(');
      expect(memory, isNonNegative);
      expect(apply, greaterThan(memory));
      expect(persist, greaterThan(apply));
      expect(body.indexOf('includeDeferred: true'), greaterThan(persist));
      expect(
        body,
        isNot(contains('_applyCharCounts(recomputed)')),
        reason: '重算读到的可能还是占位页，不能原样整表覆盖',
      );
    });

    test('关书 / 换书时停掉加载器里排队的取章，并清掉前一本的换表账', () {
      final String dispose = maskComments(methodBody(corpus, 'void dispose()'));
      expect(dispose, contains('_onlineChapterLoader?.dispose();'));
      final String open = maskComments(
        methodBody(corpus, 'Future<void> _initBookInner() async'),
      );
      final int release = open.indexOf('_onlineChapterLoader?.dispose();');
      expect(release, isNonNegative);
      expect(open.indexOf('_onlineChapterLoader =\n'), greaterThan(release));
      expect(
        open.indexOf('_onlineCharCountAdoption.clear();'),
        inInclusiveRange(release, open.indexOf('_onlineChapterLoader =\n')),
      );
    });
  });
  // 第一波 c01 遗留（c40 收）：字数口径升级后首次开在线书，后台整本重算读盘时
  // 某章还是占位页；随后后台预取把那一章正文取回、把正文字数写进书行；重算
  // 落定后的写回再拿占位页字数整列盖回去，口径标记已是当前、那一章也不再是占位
  // 页，书行从此停在占位页字数。
  group('后台整本重算写回书行', () {
    late FushiDatabase db;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'b',
          title: 'b',
          epubPath: 'b.epub',
          extractDir: '/b',
          chapterCount: 3,
          chaptersJson: jsonEncode(<Object?>[
            for (int i = 0; i < 3; i++)
              <String, Object?>{
                'id': 'c$i',
                'characters': 12,
                'charCaliber': 1,
              },
          ]),
          importedAt: 0,
        ),
      );
    });

    tearDown(() => db.close());

    Future<List<Map<String, Object?>>> entries() async =>
        <Map<String, Object?>>[
          for (final Object? e
              in jsonDecode((await db.getEpubBook('b'))!.chaptersJson)
                  as List<Object?>)
            e! as Map<String, Object?>,
        ];

    test('重算读到占位页的章：保留书行里的值，只打口径标记', () async {
      // 预取已把第 1 章的正文字数写进书行。
      final List<Map<String, Object?>> before = await entries();
      before[1]['characters'] = 5000;
      await db.updateEpubBookChaptersJson('b', jsonEncode(before));

      await persistRecomputedChapterCharCounts(
        database: db,
        bookKey: 'b',
        counts: <int>[700, 9, 9],
        keepStored: <bool>[false, true, true],
      );
      final List<Map<String, Object?>> after = await entries();
      expect(after.map((Map<String, Object?> e) => e['characters']), <int>[
        700,
        5000,
        12,
      ]);
      expect(
        after.map((Map<String, Object?> e) => e['charCaliber']).toSet(),
        <Object?>{kChapterCharCountCaliber},
      );
      expect(after.first['id'], 'c0', reason: '条目其余字段原样保留');
    });

    test('写回与加载器的字数写入交错：读改写在事务里，不把中途写进来的正文字数盖掉', () async {
      final Future<void> persisting = persistRecomputedChapterCharCounts(
        database: db,
        bookKey: 'b',
        counts: <int>[700, 9, 9],
        keepStored: <bool>[false, true, true],
      );
      // 加载器在写回读行之后、写行之前把第 1 章的正文字数写进来。
      final List<Map<String, Object?>> loaderView = await entries();
      loaderView[1]['characters'] = 5000;
      await db.updateEpubBookChaptersJson('b', jsonEncode(loaderView));
      await persisting;

      final List<Map<String, Object?>> after = await entries();
      expect(after[1]['characters'], 5000);
    });

    test('章数对不上（换过书 / 脏数据）不写', () async {
      await persistRecomputedChapterCharCounts(
        database: db,
        bookKey: 'b',
        counts: <int>[1, 2],
        keepStored: <bool>[false, false],
      );
      expect(
        (await entries()).map((Map<String, Object?> e) => e['characters']),
        <int>[12, 12, 12],
      );
    });

    test('重算同时标出哪些章读到的是占位页', () {
      String xhtml(String body) =>
          '<html><body><section>\n$body\n</section></body></html>';
      final EpubBook book = EpubBook(
        title: 'b',
        chapters: <EpubChapter>[
          EpubChapter(
            id: '0',
            href: '0',
            mediaType: 'application/xhtml+xml',
            html: xhtml('<p>本文です。とても長い本文。</p>'),
          ),
          EpubChapter(
            id: '1',
            href: '1',
            mediaType: 'application/xhtml+xml',
            html: xhtml(lnReaderPendingChapterBody('読み込み中')),
          ),
        ],
      );
      final ({List<int> counts, List<bool> pending}) result =
          countChapterCharsWithPending(book);
      expect(result.pending, <bool>[false, true]);
      expect(result.counts, <int>[
        book.chapterCharacterCount(0),
        book.chapterCharacterCount(1),
      ]);
    });
  });
}
