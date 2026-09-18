import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show computeTocAnchorCharOffsets, tocAnchorKey;
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/reader/ttu_toc_flatten.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/stats/study_char_count.dart';

import '../helpers/test_platform_services.dart';

/// BUG-2580：「一个 xhtml 装多话、目录靠 `#anchor` 分节」的书，顶栏章名永远显示
/// 该 xhtml 的**最后一话**、导航面板把同章的每一条都打上「当前」勾。
///
/// 用户那本 `無職転生 23`：正文只有 4 个 xhtml，第一～六话全在 `p-002.xhtml`、
/// 第七～十话全在 `p-003.xhtml`（`#id-a008`…`#id-a011`）。读在第七话 11% 处，
/// 顶栏却写「第十話」、目录里第七～十话四个勾——只按 spine 章号比，同章的四条
/// 分不出先后。修复：目录锚点在章内的字符偏移（[EpubBook.chapterAnchorCharOffsets]，
/// 与阅读器回报的 `charOffset` 同为 `countStudyChars` 口径）进
/// [TtuTocEntry.anchorCharOffset]，[resolveCurrentTocEntry] 按 (章号, 章内偏移)
/// floor 只落在一条上。
class _FakeInAppWebViewController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppModel _testAppModel(FushiDatabase db) {
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = AppModel(testPlatformServices())
    ..themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
  });
  return appModel;
}

/// 用户那本书的形状，数值全部取自真书（`EpubParser.parseFromExtracted` +
/// [computeTocAnchorCharOffsets] 实跑）：spine 里 9 = `p-002.xhtml`（55020 字，
/// 第一～六话）、10 = `p-003.xhtml`（49298 字，第七～十话）、11 = `p-004.xhtml`。
const List<TtuTocEntry> _anchoredToc = <TtuTocEntry>[
  TtuTocEntry(index: 0, label: '表紙'),
  TtuTocEntry(index: 7, label: 'CONTENTS'),
  TtuTocEntry(
      index: 9, label: '第二十三章　青年期', fragment: 'id-a001', anchorCharOffset: 0),
  TtuTocEntry(index: 9, label: '第一話', fragment: 'id-a002', anchorCharOffset: 8),
  TtuTocEntry(
      index: 9, label: '第二話', fragment: 'id-a003', anchorCharOffset: 7614),
  TtuTocEntry(
      index: 9, label: '第六話', fragment: 'id-a007', anchorCharOffset: 44440),
  TtuTocEntry(
      index: 10, label: '第七話', fragment: 'id-a008', anchorCharOffset: 0),
  TtuTocEntry(
      index: 10, label: '第八話', fragment: 'id-a009', anchorCharOffset: 9688),
  TtuTocEntry(
      index: 10, label: '第九話', fragment: 'id-a010', anchorCharOffset: 25600),
  TtuTocEntry(
      index: 10, label: '第十話', fragment: 'id-a011', anchorCharOffset: 40770),
  TtuTocEntry(index: 11, label: '間話', fragment: 'id-a012', anchorCharOffset: 0),
  TtuTocEntry(index: 13, label: '奥付'),
];

String _labelAt(int chapter, int? offset) {
  final int? row = resolveCurrentTocEntry(_anchoredToc, chapter, offset);
  return row == null ? '' : _anchoredToc[row].label;
}

void main() {
  group('resolveCurrentTocEntry 按 (章号, 章内偏移) 只落一条', () {
    test('用户截图的位置：DB 里 (section 10, char_offset 7923) 是第七話，不是第十話', () {
      expect(_labelAt(10, 7923), '第七話');
    });

    test('同一 xhtml 里逐话推进，每个锚点处切到该话', () {
      expect(_labelAt(10, 0), '第七話');
      expect(_labelAt(10, 9687), '第七話');
      expect(_labelAt(10, 9688), '第八話');
      expect(_labelAt(10, 25600), '第九話');
      expect(_labelAt(10, 40769), '第九話');
      expect(_labelAt(10, 40770), '第十話');
      expect(_labelAt(10, 49298), '第十話');
      expect(_labelAt(9, 30000), '第二話');
      expect(_labelAt(9, 7), '第二十三章　青年期', reason: '第一話锚点（8）之前的那 8 个字是章标题');
      expect(_labelAt(12, 0), '間話', reason: '目录没指向的 spine 12 按 floor 归上一条');
    });

    test('章内位置未知（null / -1）时命中该章第一条，而不是最后一条', () {
      // 修复前 _currentChapterLabelFor 从目录末尾往前找，恒命中「第十話」。
      expect(_labelAt(10, null), '第七話');
      expect(_labelAt(10, -1), '第七話');
      expect(_labelAt(9, null), '第二十三章　青年期');
      expect(_labelAt(13, null), '奥付');
    });

    test('位置未知且当前章首条锚点不在 0：仍取当前章的首条，不掉到上一章', () {
      const List<TtuTocEntry> toc = <TtuTocEntry>[
        TtuTocEntry(index: 9, label: '第六話', anchorCharOffset: 44440),
        TtuTocEntry(index: 10, label: '第七話', anchorCharOffset: 100),
        TtuTocEntry(index: 10, label: '第八話', anchorCharOffset: 9688),
      ];
      expect(resolveCurrentTocEntry(toc, 10, null), 1);
      // 位置已知且早于首条锚点：按 floor 确实归上一章末条。
      expect(resolveCurrentTocEntry(toc, 10, 99), 0);
    });

    test('锚点偏移全 null（后台还没算完）时退化成旧的按章 floor，取第一条', () {
      const List<TtuTocEntry> pending = <TtuTocEntry>[
        TtuTocEntry(index: 10, label: '第七話', fragment: 'id-a008'),
        TtuTocEntry(index: 10, label: '第八話', fragment: 'id-a009'),
        TtuTocEntry(index: 10, label: '第九話', fragment: 'id-a010'),
        TtuTocEntry(index: 10, label: '第十話', fragment: 'id-a011'),
      ];
      expect(resolveCurrentTocEntry(pending, 10, 40000), 0);
    });

    test('落在首条之前 / 无章号：null', () {
      expect(resolveCurrentTocEntry(_anchoredToc, null, 5), isNull);
      expect(
        resolveCurrentTocEntry(
          const <TtuTocEntry>[
            TtuTocEntry(index: 3, label: 'x', anchorCharOffset: 10),
          ],
          3,
          5,
        ),
        isNull,
      );
    });
  });

  group('EpubBook.chapterAnchorCharOffsets', () {
    EpubBook bookWith(String html, {List<EpubTocItem> toc = const []}) =>
        EpubBook(
          title: 'test',
          chapters: <EpubChapter>[
            EpubChapter(
              id: 'p-003',
              href: 'xhtml/p-003.xhtml',
              mediaType: 'application/xhtml+xml',
              html: html,
            ),
          ],
          toc: toc,
        );

    test('锚点前的实义字数 = countStudyChars(锚点前纯文本)，振假名不计', () {
      const String html = '<html><body>'
          '<h3 id="id-a008">第七話「狂犬古巣に帰る」</h3>'
          '<p>　<ruby>剣<rt>けん</rt></ruby>の聖地へ、エリスは帰ってきた。</p>'
          '<p>「んん？」</p>'
          '<h3 id="id-a009">第八話</h3>'
          '<p>続き。</p>'
          '</body></html>';
      final EpubBook book = bookWith(html);
      final Map<String, int> offsets = book.chapterAnchorCharOffsets(
        0,
        <String>['id-a008', 'id-a009', 'missing'],
      );
      expect(offsets['id-a008'], 0);
      expect(
        offsets['id-a009'],
        countStudyChars('第七話「狂犬古巣に帰る」　剣の聖地へ、エリスは帰ってきた。「んん？」'),
      );
      expect(offsets.containsKey('missing'), isFalse, reason: '找不到的 id 不出现');
      // 与全章计数闭合：最后一个锚点之后只剩「第八話続き。」。
      expect(
        offsets['id-a009']! + countStudyChars('第八話続き。'),
        book.chapterCharacterCount(0),
      );
    });

    test('kobo 自闭合 <script/> 章节也能找到锚点（走 parseChapterHtml）', () {
      const String html = '<?xml version="1.0"?><html><head>'
          '<script src="../js/kobo.js"/></head><body>'
          '<p>前置。</p><div id="id-a011">第十話</div></body></html>';
      expect(
        bookWith(html).chapterAnchorCharOffsets(0, <String>['id-a011']),
        <String, int>{'id-a011': countStudyChars('前置。')},
      );
    });

    test('computeTocAnchorCharOffsets 只算带 fragment 的目录项、按章分组一次遍历', () {
      const String html = '<html><body><p>甲乙丙</p>'
          '<h3 id="a">A</h3><p>丁戊</p><h3 id="b">B</h3></body></html>';
      final EpubBook book = bookWith(
        html,
        toc: <EpubTocItem>[
          EpubTocItem(label: '表紙', href: 'xhtml/cover.xhtml'),
          EpubTocItem(
              label: '本文',
              href: 'xhtml/p-003.xhtml',
              children: <EpubTocItem>[
                EpubTocItem(label: 'A', href: 'xhtml/p-003.xhtml#a'),
                EpubTocItem(label: 'B', href: 'xhtml/p-003.xhtml#b'),
              ]),
        ],
      );
      final Map<String, int> offsets = computeTocAnchorCharOffsets(book);
      expect(offsets, <String, int>{
        tocAnchorKey(0, 'a'): 3,
        tocAnchorKey(0, 'b'): 6,
      });
      // 压平时经解析器填进条目。
      final List<TtuTocEntry> toc = flattenTtuTocEntries(
        book.toc,
        book.chapterIndexForHref,
        anchorCharOffset: (int chapter, String fragment) =>
            offsets[tocAnchorKey(chapter, fragment)],
      );
      // 「表紙」的 href 不在 spine 里，压平时照旧丢掉。
      expect(
        toc.map((TtuTocEntry e) => e.anchorCharOffset).toList(),
        <int?>[null, 3, 6],
      );
      expect(resolveCurrentTocEntry(toc, 0, 5), 1, reason: '甲乙丙丁戊 第 5 字仍在 A');
      expect(resolveCurrentTocEntry(toc, 0, 6), 2);
    });
  });

  testWidgets('导航面板：同一 xhtml 四话只勾当前那一话', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final AppModel model = _testAppModel(db);
    final ReaderSettings? previousSettings = ReaderFushiSource.readerSettings;
    ReaderFushiSource.readerSettings = ReaderSettings(db)
      ..applyPrefsSnapshot(const <String, String>{});
    addTearDown(() {
      ReaderFushiSource.readerSettings = previousSettings;
    });

    // 用户 DB 里的落库位置：p-003（spine 10）章内 7923 字 = 第七話。
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) =>
                  ReaderQuickSettingsSheet(
                controller: null,
                toc: _anchoredToc,
                readerProgress: const (10, 16),
                readerCharOffset: 7923,
                onJumpSection: (_, __) async {},
                onExitReader: () {},
                webViewController: _FakeInAppWebViewController(),
                appModel: model,
                ref: ref,
                isFushiReader: true,
                presentation:
                    ReaderQuickSettingsPresentation.sideSheetNavigation,
                onStyleChanged: () async {},
                onThemeChanged: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check), findsOneWidget, reason: '修复前第七～十话四行全带勾');
    final Finder currentRow = find.ancestor(
      of: find.text('第七話'),
      matching: find.byType(AdaptiveSettingsRow),
    );
    expect(
      find.descendant(of: currentRow, matching: find.byIcon(Icons.check)),
      findsOneWidget,
      reason: '勾落在第七話，不是同 xhtml 的第十話',
    );
  });
}
