import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';

import '../helpers/source_guard.dart';

void main() {
  test('compact playback leaves footer and system inset outside its surface',
      () {
    final String chrome =
        File('lib/src/pages/implementations/reader_fushi/chrome.part.dart')
            .readAsStringSync();
    final String page =
        File('lib/src/pages/implementations/reader_fushi_page.dart')
            .readAsStringSync();
    // 底栏坐在状态行**画出来**的带上（悬浮态收起时 0，唤出时 28）。
    expect(chrome, contains('? _statusFooterPaintedBand : 0'));
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

  testWidgets('pinned 动作在紧凑形态下仍是可见按钮（歌词模式回正文的入口靠它）',
      (WidgetTester tester) async {
    // 歌词模式里「切回阅读模式」是顶栏上唯一可见的回正文入口，页面为此把那颗键
    // 标成 pinned。这里钉的是 pinned 的**行为**：窄到进紧凑形态时它不进溢出菜单，
    // 仍是一颗按得着的图标按钮。
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int toggled = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReaderDesktopHeader(
      title: 'lyrics mode',
      textColor: Colors.black,
      backgroundColor: Colors.white,
      leading: <ReaderHeaderAction>[
        ReaderHeaderAction(
            icon: Icons.arrow_back,
            label: 'Back',
            pinned: true,
            onPressed: () {}),
        ReaderHeaderAction(
            icon: Icons.auto_stories_outlined,
            label: 'Book mode',
            pinned: true,
            onPressed: () => toggled++),
      ],
      trailing: <ReaderHeaderAction>[
        ReaderHeaderAction(
            icon: Icons.tune,
            label: 'Settings',
            pinned: true,
            onPressed: () {}),
      ],
    ))));
    expect(find.byIcon(Icons.auto_stories_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.auto_stories_outlined));
    await tester.pumpAndSettle();
    expect(toggled, 1);
    expect(tester.takeException(), isNull);
  });

  group('readerDesktopHeaderReserve', () {
    // 2026-09-13：用户拍板悬浮态「隐藏满屏、唤出覆盖」——悬浮 → 0，挤压占位才预留。
    // （BUG-2387 曾让悬浮态也恒定预留 48px，换来的是收起后正文顶上一条常驻空带。）
    test('挤压占位预留工具栏高；悬浮 / 未占位 / 未启用为 0', () {
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
          barOccupiesLayout: true,
          floating: true,
          headerHeight: kReaderDesktopHeaderHeight,
        ),
        0,
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

    // 「悬浮显隐不重锚」（reader_chrome_floating.dart 文件头设计律）：悬浮态的显隐
    // 不进本函数的任何参数（transientVisible 不是它的输入），返回值恒 0。
    test('悬浮态返回值与显隐无关（恒 0）——唤出/收起不改预留高', () {
      for (final bool occupies in <bool>[true, false]) {
        expect(
          readerDesktopHeaderReserve(
            enabled: true,
            barOccupiesLayout: occupies,
            floating: true,
            headerHeight: kReaderDesktopHeaderHeight,
          ),
          0,
        );
      }
    });

    test('悬浮态 chrome 底色半透明、挤压态原色', () {
      const Color bg = Color(0xFFFAF7F0);
      expect(readerChromeSurfaceColor(bg, floating: false), bg);
      final Color floating = readerChromeSurfaceColor(bg, floating: true);
      expect(floating.a, closeTo(0.92, 0.001));
      expect(floating.r, bg.r);
      expect(floating.g, bg.g);
      expect(floating.b, bg.b);
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
    // 取整个方法体，而不是「方法签名后 900 个字符」：那种定长窗口是 B 类要求型
    // 锚点——往方法开头加几行（比如歌词模式那颗模式键）就会把 RepaintBoundary 挤出
    // 窗口，行为分毫未变而守卫变红。
    expect(
      containsIdentifierCall(
        methodBody(chrome, '  Widget _buildDesktopHeader()'),
        'RepaintBoundary',
      ),
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
