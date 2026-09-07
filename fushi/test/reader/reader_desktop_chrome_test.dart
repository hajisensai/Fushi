import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';

void main() {
  test('compact playback leaves footer and system inset outside its surface',
      () {
    final String chrome =
        File('lib/src/pages/implementations/reader_fushi/chrome.part.dart')
            .readAsStringSync();
    final String page =
        File('lib/src/pages/implementations/reader_fushi_page.dart')
            .readAsStringSync();
    expect(chrome, contains('? _statusFooterReserve + _stableBottomInset'));
    expect(chrome,
        contains('height: _separatePlaybackStatus ? 0 : _stableBottomInset'));
    expect(
        page,
        contains(
            'chromeHeight: _desktopChromeEnabled && _audiobookController == null'));
  });

  testWidgets('320 wide header keeps navigation and folds secondary actions',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int galleryOpened = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReaderDesktopHeader(
      title: '安達としまむら3 Long book title',
      textColor: Colors.black,
      backgroundColor: Colors.white,
      leading: <ReaderHeaderAction>[
        ReaderHeaderAction(
            icon: Icons.arrow_back,
            label: 'Back',
            pinned: true,
            onPressed: () {}),
        ReaderHeaderAction(
            icon: Icons.list,
            label: 'Contents',
            pinned: true,
            onPressed: () {}),
        ReaderHeaderAction(
            icon: Icons.collections,
            label: 'Gallery',
            onPressed: () => galleryOpened++),
      ],
      trailing: <ReaderHeaderAction>[
        ReaderHeaderAction(
            icon: Icons.tune,
            label: 'Settings',
            pinned: true,
            onPressed: () {}),
      ],
    ))));
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.list), findsOneWidget);
    expect(find.byIcon(Icons.collections), findsNothing);
    await tester.tap(
        find.byKey(const ValueKey<String>('fushi_desktop_header_overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();
    expect(galleryOpened, 1);
    expect(tester.takeException(), isNull);
  });

  group('readerDesktopChromeEnabled', () {
    test('各平台非歌词模式均启用', () {
      expect(
        readerDesktopChromeEnabled(desktop: true, lyricsMode: false),
        isTrue,
      );
      expect(
        readerDesktopChromeEnabled(desktop: true, lyricsMode: true),
        isFalse,
      );
      expect(
        readerDesktopChromeEnabled(desktop: false, lyricsMode: false),
        isTrue,
      );
    });
  });

  group('readerDesktopHeaderReserve', () {
    test('悬浮态恒 0；挤压态且底栏占位时占工具栏高', () {
      expect(
        readerDesktopHeaderReserve(
          enabled: true,
          barOccupiesLayout: true,
          floating: true,
          headerHeight: kReaderDesktopHeaderHeight,
        ),
        0,
      );
      expect(
        readerDesktopHeaderReserve(
          enabled: true,
          barOccupiesLayout: true,
          floating: false,
          headerHeight: kReaderDesktopHeaderHeight,
        ),
        kReaderDesktopHeaderHeight,
      );
      expect(
        readerDesktopHeaderReserve(
          enabled: true,
          barOccupiesLayout: false,
          floating: false,
          headerHeight: kReaderDesktopHeaderHeight,
        ),
        0,
      );
      expect(
        readerDesktopHeaderReserve(
          enabled: false,
          barOccupiesLayout: true,
          floating: false,
          headerHeight: kReaderDesktopHeaderHeight,
        ),
        0,
      );
    });
  });

  group('readerSideSheetWidth', () {
    test('宽窗取固定宽；窄窗留 48px 空白', () {
      expect(readerSideSheetWidth(1920), kReaderSideSheetWidth);
      expect(readerSideSheetWidth(400), 352);
      expect(readerSideSheetWidth(40), 0);
    });
  });

  testWidgets('ReaderDesktopHeader：左右按钮 + 居中书名', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderDesktopHeader(
            title: '無職転生 20',
            textColor: Colors.white,
            backgroundColor: Colors.black,
            leading: <ReaderHeaderAction>[
              ReaderHeaderAction(
                icon: Icons.arrow_back,
                label: 'back',
                pinned: true,
                onPressed: () {},
              ),
            ],
            trailing: <ReaderHeaderAction>[
              ReaderHeaderAction(
                icon: Icons.tune_outlined,
                label: 'settings',
                pinned: true,
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('無職転生 20'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byIcon(Icons.tune_outlined), findsOneWidget);
    final Size size = tester.getSize(find.byType(ReaderDesktopHeader));
    expect(size.height, kReaderDesktopHeaderHeight);
  });

  test('源码守卫：桌面端顶部工具栏接进页面 Stack 且自带 RepaintBoundary', () {
    final String chrome = File(
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
    ).readAsStringSync();
    final String page = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    final int at = chrome.indexOf('Widget _buildDesktopHeader() {');
    expect(at, greaterThan(-1));
    expect(
      chrome.substring(at, at + 900).contains('RepaintBoundary('),
      isTrue,
      reason: 'BUG-1692：排在 WebView 之后的 chrome 必须自带 RepaintBoundary',
    );
    final String header = File(
      'lib/src/reader/reader_desktop_chrome.dart',
    ).readAsStringSync();
    final int headerAt = header.indexOf('class ReaderDesktopHeader ');
    expect(headerAt, greaterThan(-1));
    expect(
      header.substring(headerAt).contains('return ExcludeFocus('),
      isTrue,
      reason: '纯指针面，不进焦点遍历池（TODO-700 不变式）——ExcludeFocus 在组件内部，'
          '让 chrome.part 里的 ExcludeFocus 仍唯一属于 _wrapBottomChromeBar',
    );
    expect(page.contains('_buildDesktopHeader(),'), isTrue);
    expect(
      page.contains('_desktopHeaderReserve;'),
      isTrue,
      reason: '挤压态工具栏预留高必须并入 _readerTopOffset',
    );
    // 桌面端不再画底部设置栏（有声书播放条保留）。
    final int gate = chrome.indexOf('if (_desktopChromeEnabled) {');
    final int bar = chrome.indexOf('return _buildSettingsBar();');
    expect(gate, greaterThan(-1));
    expect(gate, lessThan(bar));
  });
}
