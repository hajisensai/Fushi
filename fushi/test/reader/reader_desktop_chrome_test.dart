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
    // 读数行画在别处时底栏坐在它**画出来**的带上（悬浮态收起时 0，唤出时 28）。
    expect(
        chrome,
        contains(
            'bottom: _separatePlaybackStatus && !_statusFooterInBottomBar'));
    expect(chrome, contains('? _statusFooterPaintedBand'));
    expect(chrome,
        contains('height: _separatePlaybackStatus ? 0 : _stableBottomInset'));
    // 读数并进底栏那块遮罩时：它是底栏 Column 的最后一行（居中），底栏整体贴屏底，
    // 屏底那一层不再另画（否则同一串读数上下两份 / 两块半透明遮罩接缝）。
    expect(chrome, contains('if (_statusFooterInBottomBar)'));
    expect(chrome, contains('_buildStatusFooterRow(centered: true)'));
    expect(chrome,
        contains('!_statusFooterShouldPaint || _statusFooterInBottomBar'));
    expect(
        page,
        contains('bool get _statusFooterInBottomBar =>\n'
            '      _separatePlaybackStatus &&\n'
            '      _statusFooterShouldPaint &&\n'
            '      _bottomBarShouldPaint &&'));
    // 底栏只在「有声书播放条在场」或「用户把按钮拖进底栏槽位」时占位。
    expect(
        page,
        contains(
            'chromeHeight: _audiobookController == null && !_bottomSlotsHaveButtons'));
  });

  group('readerHeaderCompactForActions', () {
    test('顶部有空间就不折叠：横屏手机 ~700 逻辑 px 放得下六颗按钮加书名', () {
      // 用户 2026-09-14：固定阈值（760）会在这条宽度上把插图 / 统计 / 有声书折进 ⋮，
      // 而书名两侧还空着大半条。按实际按钮数算：16 + 6×48 = 304，剩 394 给书名。
      expect(
          readerHeaderCompactForActions(width: 698, actionCount: 6), isFalse);
      // 旧的固定阈值判据在同一条宽度上判折叠（漫画顶栏仍在用它，那一栏算不准）。
      expect(readerHeaderCompact(698), isTrue);
    });

    test('真放不下才折叠：按钮占完留给书名的不足 120', () {
      // 16 + 6×48 = 304；书名要 120 → 424 是分界。
      expect(
          readerHeaderCompactForActions(width: 424, actionCount: 6), isFalse);
      expect(readerHeaderCompactForActions(width: 423, actionCount: 6), isTrue);
    });

    test('不显示书名时按钮可以一路占到两端内边距', () {
      expect(
        readerHeaderCompactForActions(
            width: 304, actionCount: 6, showsTitle: false),
        isFalse,
      );
      expect(
        readerHeaderCompactForActions(
            width: 303, actionCount: 6, showsTitle: false),
        isTrue,
      );
    });
  });

  testWidgets('横屏手机宽度：六颗按钮全部直接画，没有 ⋮ 溢出菜单', (WidgetTester tester) async {
    // 用户 2026-09-14 报的原始现象（截图 698×~350 逻辑 px 的横屏）：顶部明明还有
    // 大半条空白，插图 / 统计 / 有声书却已经折进 ⋮。
    await tester.binding.setSurfaceSize(const Size(698, 350));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReaderDesktopHeader(
      title: '安達としまむら3',
      textColor: Colors.black,
      backgroundColor: Colors.white,
      leading: <ReaderHeaderAction>[
        ReaderHeaderAction(
            icon: Icons.arrow_back,
            label: 'Back',
            pinned: true,
            onPressed: () {}),
        ReaderHeaderAction(
            icon: Icons.format_list_bulleted,
            label: 'Contents',
            pinned: true,
            onPressed: () {}),
        ReaderHeaderAction(
            icon: Icons.collections_outlined,
            label: 'Gallery',
            onPressed: () {}),
        ReaderHeaderAction(
            icon: Icons.insights_outlined,
            label: 'Statistics',
            onPressed: () {}),
      ],
      trailing: <ReaderHeaderAction>[
        ReaderHeaderAction(
            icon: Icons.headphones_outlined,
            label: 'Audiobook',
            onPressed: () {}),
        ReaderHeaderAction(
            icon: Icons.tune_outlined,
            label: 'Settings',
            pinned: true,
            onPressed: () {}),
      ],
    ))));
    for (final IconData icon in <IconData>[
      Icons.arrow_back,
      Icons.format_list_bulleted,
      Icons.collections_outlined,
      Icons.insights_outlined,
      Icons.headphones_outlined,
      Icons.tune_outlined,
    ]) {
      expect(find.byIcon(icon), findsOneWidget, reason: '$icon 该直接画在栏里');
    }
    expect(
      find.byKey(const ValueKey<String>('fushi_desktop_header_overflow')),
      findsNothing,
    );
    expect(find.text('安達としまむら3'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    // 底栏（无播放条时）只在布局的底栏槽位有按钮时才画（默认布局为空）。
    final int gate = chrome.indexOf('if (!_bottomSlotsHaveButtons) {');
    final int bar = chrome.indexOf('return _buildSettingsBar();');
    expect(gate, greaterThan(-1));
    expect(gate, lessThan(bar));
  });

  testWidgets('顶栏标题槽：书名后跟当前章名', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReaderDesktopHeader(
      title: '水属性の魔法使い 第一部 中央諸国編2',
      chapter: '第三章 王都へ',
      textColor: Colors.black,
      backgroundColor: Colors.white,
      leading: <ReaderHeaderAction>[
        ReaderHeaderAction(
            icon: Icons.arrow_back,
            label: 'Back',
            pinned: true,
            onPressed: () {}),
      ],
      trailing: <ReaderHeaderAction>[
        ReaderHeaderAction(
            icon: Icons.tune,
            label: 'Settings',
            pinned: true,
            onPressed: () {}),
      ],
    ))));
    expect(find.text('水属性の魔法使い 第一部 中央諸国編2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('fushi_desktop_header_chapter')),
      findsOneWidget,
    );
    expect(find.text('第三章 王都へ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('章名与书名相同时不画两遍', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReaderDesktopHeader(
      title: '安達としまむら3',
      chapter: '安達としまむら3',
      textColor: Colors.black,
      backgroundColor: Colors.white,
      leading: const <ReaderHeaderAction>[],
      trailing: const <ReaderHeaderAction>[],
    ))));
    expect(find.text('安達としまむら3'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('fushi_desktop_header_chapter')),
      findsNothing,
    );
  });

  testWidgets('不给章名时标题槽与旧行为一致', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReaderDesktopHeader(
      title: '安達としまむら3',
      textColor: Colors.black,
      backgroundColor: Colors.white,
      leading: const <ReaderHeaderAction>[],
      trailing: const <ReaderHeaderAction>[],
    ))));
    expect(find.text('安達としまむら3'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('fushi_desktop_header_chapter')),
      findsNothing,
    );
  });

  testWidgets('超长章名最多吃掉标题槽的四成，书名仍占多数', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReaderDesktopHeader(
      title: '水属性の魔法使い 第一部 中央諸国編2【電子書籍限定書き下ろしSS付き】',
      chapter: '第三章 王都へ向かう長い旅路と、その途中で出会った人々についての覚書',
      textColor: Colors.black,
      backgroundColor: Colors.white,
      leading: const <ReaderHeaderAction>[],
      trailing: const <ReaderHeaderAction>[],
    ))));
    final double titleWidth = tester
        .getSize(
            find.byKey(const ValueKey<String>('fushi_desktop_header_title')))
        .width;
    final double chapterWidth = tester
        .getSize(
            find.byKey(const ValueKey<String>('fushi_desktop_header_chapter')))
        .width;
    // 对半分（两个 Flexible）时这条会挂：章名再长也只许拿四成，书名不能被挤成省略号。
    expect(chapterWidth, lessThan(titleWidth));
    expect(tester.takeException(), isNull);
  });
}
