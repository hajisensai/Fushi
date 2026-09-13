import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart'
    show mangaSelectionRectFromPayload;
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show kReaderDesktopHeaderCompactWidth;
import 'package:fushi/src/reader/reader_selection_data.dart';

void main() {
  group('mangaChromeTopInset', () {
    test('悬浮 / 界面隐藏 → 0；固定且可见 → 状态栏 + 栏高', () {
      expect(
        mangaChromeTopInset(
          floating: true,
          chromeVisible: true,
          statusBarInset: 24,
        ),
        0,
      );
      expect(
        mangaChromeTopInset(
          floating: false,
          chromeVisible: false,
          statusBarInset: 24,
        ),
        0,
      );
      expect(
        mangaChromeTopInset(
          floating: false,
          chromeVisible: true,
          statusBarInset: 24,
        ),
        24 + kMangaChromeBarHeight,
      );
    });
  });

  group('mangaChromeBarPainted', () {
    test('固定态只看 chromeVisible；悬浮态还要 transientVisible', () {
      expect(
        mangaChromeBarPainted(
          floating: false,
          chromeVisible: true,
          transientVisible: false,
          contentReady: true,
        ),
        isTrue,
      );
      expect(
        mangaChromeBarPainted(
          floating: true,
          chromeVisible: true,
          transientVisible: false,
          contentReady: true,
        ),
        isFalse,
      );
      expect(
        mangaChromeBarPainted(
          floating: true,
          chromeVisible: true,
          transientVisible: true,
          contentReady: true,
        ),
        isTrue,
      );
      // 没有正文（加载失败 / 未下载）：悬浮态也无条件画——没有 WebView 就没有
      // 中央点击这条唤出通道，返回键收起就是 iOS 死锁。
      expect(
        mangaChromeBarPainted(
          floating: true,
          chromeVisible: true,
          transientVisible: false,
          contentReady: false,
        ),
        isTrue,
      );
      // M 键隐藏界面：两种形态都不画（悬浮唤出态也压不过用户意图）。
      expect(
        mangaChromeBarPainted(
          floating: true,
          chromeVisible: false,
          transientVisible: true,
          contentReady: true,
        ),
        isFalse,
      );
    });
  });

  group('mangaSelectionRectFromPayload', () {
    test('固定态 WebView 让位后选区矩形整体下移 viewportOrigin', () {
      final ReaderSelectionData data = ReaderSelectionData.fromJson(
        <String, dynamic>{
          'text': 'x',
          'sentence': 'x',
          'rect': <String, dynamic>{
            'x': 10.0,
            'y': 20.0,
            'width': 30.0,
            'height': 40.0,
          },
        },
      );
      expect(
        mangaSelectionRectFromPayload(
          data,
          fallbackScreen: const Size(800, 600),
          viewportOrigin: const Offset(0, 72),
        ),
        const Rect.fromLTWH(10, 92, 30, 40),
      );
      // 无 rect 的兜底：WebView 中心再加偏移。
      final ReaderSelectionData noRect = ReaderSelectionData.fromJson(
        <String, dynamic>{'text': 'x', 'sentence': 'x'},
      );
      expect(
        mangaSelectionRectFromPayload(
          noRect,
          fallbackScreen: const Size(800, 528),
          viewportOrigin: const Offset(0, 72),
        ).center,
        const Offset(400, 264 + 72),
      );
    });
  });

  group('MangaReaderTopBar', () {
    Widget host({required double width, required bool floating}) {
      return MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(top: 20)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                child: MangaReaderTopBar(
                  title: 'Title',
                  floating: floating,
                  backTooltip: 'back',
                  onBack: () {},
                  pageLabel: () => '3-4 / 40',
                  onPageTap: () {},
                  status: const MangaChromeStatusChip(
                    key: ValueKey<String>('chip'),
                    text: '12/40 · DirectML',
                    warning: true,
                  ),
                  groups: <List<MangaChromeAction>>[
                    <MangaChromeAction>[
                      MangaChromeAction(
                        key: const ValueKey<String>('a_pinned'),
                        icon: Icons.list,
                        label: 'A',
                        pinned: true,
                        onPressed: () {},
                      ),
                    ],
                    const <MangaChromeAction>[],
                    <MangaChromeAction>[
                      MangaChromeAction(
                        key: const ValueKey<String>('b_overflow'),
                        icon: Icons.tune,
                        label: 'B',
                        active: true,
                        onPressed: () {},
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('宽窗：全部按钮直接画，返回键 / 页码 / 状态胶囊都在', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(width: kReaderDesktopHeaderCompactWidth + 40, floating: false),
      );
      expect(
        find.byKey(const ValueKey<String>('manga_reader_back_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('manga_page_jump_button')),
        findsOneWidget,
      );
      expect(find.text('3-4 / 40'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('chip')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('a_pinned')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('b_overflow')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manga_chrome_overflow')),
        findsNothing,
      );
      // 栏总高 = 状态栏 + 栏行高（固定态让位量与画出高度同源）。
      final Size size = tester.getSize(find.byType(MangaReaderTopBar));
      expect(size.height, 20 + kMangaChromeBarHeight);
    });

    testWidgets('窄窗：非 pinned 动作折进 ⋮，菜单项带勾', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(width: kReaderDesktopHeaderCompactWidth - 40, floating: true),
      );
      expect(find.byKey(const ValueKey<String>('a_pinned')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('b_overflow')), findsNothing);
      final Finder overflow = find.byKey(
        const ValueKey<String>('manga_chrome_overflow'),
      );
      expect(overflow, findsOneWidget);
      await tester.tap(overflow);
      await tester.pumpAndSettle();
      expect(find.text('B'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });
}
