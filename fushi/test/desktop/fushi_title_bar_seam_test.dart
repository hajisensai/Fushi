import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show einkReaderThemeColors;
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';

/// 桌面自绘顶栏（挂在 Navigator 外，只认根主题 surface 或页面上报色）与页面
/// 顶部第一排像素之间不许有接缝：真实像素逐对比较顶栏最后一行（y = 31）与
/// 页面第一行（y = 32），MD3 / Apple × 浅 / 深四套主题都要 ≤ 2/255。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          MethodCall call,
        ) async {
          switch (call.method) {
            case 'isMaximized':
            case 'isFullScreen':
            case 'isFocused':
              return false;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  const List<({bool apple, Brightness brightness})> themes =
      <({bool apple, Brightness brightness})>[
        (apple: false, brightness: Brightness.light),
        (apple: false, brightness: Brightness.dark),
        (apple: true, brightness: Brightness.light),
        (apple: true, brightness: Brightness.dark),
      ];

  String label(({bool apple, Brightness brightness}) t) =>
      '${t.apple ? 'Apple' : 'MD3'} ${t.brightness.name}';

  final GlobalKey shot = GlobalKey();
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  Future<void> pumpShell(
    WidgetTester tester,
    ({bool apple, Brightness brightness}) t,
    Widget home,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ThemeData theme = buildFushiThemeData(
      scheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF8B7355),
        brightness: t.brightness,
      ),
      textTheme: Typography.material2021().black,
      glass: t.apple ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
      glassDesign: t.apple,
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: MaterialApp(
          theme: theme,
          navigatorKey: navigatorKey,
          builder: (BuildContext context, Widget? child) => FushiGlassScope(
            child: FushiDesktopTitleBar(
              title: const SizedBox.shrink(),
              child: child!,
            ),
          ),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 顶栏最后一行与页面第一行在 [x] 处的像素。
  Future<(Color, Color)> seamPixels(WidgetTester tester, {double x = 440}) async {
    final RenderRepaintBoundary boundary =
        shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ByteData bytes = (await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage();
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      image.dispose();
      return data!;
    }))!;
    Color at(int px, int py) {
      final int o = (py * 800 + px) * 4;
      return Color.fromARGB(
        bytes.getUint8(o + 3),
        bytes.getUint8(o),
        bytes.getUint8(o + 1),
        bytes.getUint8(o + 2),
      );
    }

    const int h = FushiDesktopTitleBar.height ~/ 1;
    return (at(x.toInt(), h - 1), at(x.toInt(), h));
  }

  int channelDelta(Color a, Color b) => <double>[
    (a.r - b.r).abs(),
    (a.g - b.g).abs(),
    (a.b - b.b).abs(),
  ].map((double d) => (d * 255).round()).reduce((int x, int y) => x > y ? x : y);

  Future<void> expectNoSeam(WidgetTester tester, String why) async {
    final (Color bar, Color page) = await seamPixels(tester);
    expect(
      channelDelta(bar, page),
      lessThanOrEqualTo(2),
      reason: '$why：顶栏 $bar vs 页面 $page',
    );
  }

  for (final ({bool apple, Brightness brightness}) t in themes) {
    testWidgets('${label(t)}：普通整页（Scaffold 默认底）与顶栏无缝', (
      WidgetTester tester,
    ) async {
      await pumpShell(tester, t, const Scaffold(body: SizedBox.expand()));
      await expectNoSeam(tester, '默认页');
    });

    testWidgets('${label(t)}：带顶栏的页面滚动前后与顶栏无缝', (
      WidgetTester tester,
    ) async {
      await pumpShell(
        tester,
        t,
        Scaffold(
          appBar: const FushiAppBar(),
          body: ListView.builder(
            itemCount: 100,
            itemBuilder: (_, int i) => SizedBox(
              height: 48,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('row $i'),
              ),
            ),
          ),
        ),
      );
      await expectNoSeam(tester, '未滚动');

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      await expectNoSeam(tester, '滚到顶栏下面之后（MD3 顶栏换 surfaceContainer）');

      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pumpAndSettle();
      await expectNoSeam(tester, '滚回顶部之后');
    });

    testWidgets('${label(t)}：黑底整页（视频 / 串流）上报后与顶栏无缝', (
      WidgetTester tester,
    ) async {
      await pumpShell(
        tester,
        t,
        FushiTitleBarColorScope(
          colors: fushiTitleBarColorsOn(Colors.black),
          child: const Scaffold(
            backgroundColor: Colors.black,
            body: SizedBox.expand(),
          ),
        ),
      );
      await expectNoSeam(tester, '黑底页');
    });

    testWidgets('${label(t)}：阅读器纸色热切换（含墨水屏）顶栏同帧跟随', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<Color> paper = ValueNotifier<Color>(
        const Color(0xFFF7F6EB),
      );
      addTearDown(paper.dispose);
      await pumpShell(
        tester,
        t,
        ValueListenableBuilder<Color>(
          valueListenable: paper,
          builder: (_, Color bg, __) => FushiTitleBarColorScope(
            colors: fushiTitleBarColorsOn(bg),
            child: Scaffold(backgroundColor: bg, body: const SizedBox.expand()),
          ),
        ),
      );
      await expectNoSeam(tester, 'ecru 纸色');
      for (final Color next in <Color>[
        const Color(0xFF23272A),
        const Color(0xFFC7EDCC),
        einkReaderThemeColors(_anyThemed, dark: true).bg,
        einkReaderThemeColors(_anyThemed, dark: false).bg,
      ]) {
        paper.value = next;
        await tester.pumpAndSettle();
        await expectNoSeam(tester, '切到 $next');
      }
    });
  }

  testWidgets('对话框里的 MD3 顶栏滚动不改窗口顶栏', (WidgetTester tester) async {
    await pumpShell(
      tester,
      (apple: false, brightness: Brightness.light),
      const Scaffold(body: SizedBox.expand()),
    );
    showDialog<void>(
      context: navigatorKey.currentContext!,
      builder: (_) => Center(
        child: SizedBox(
          width: 300,
          height: 300,
          child: Scaffold(
            appBar: const FushiAppBar(),
            body: ListView.builder(
              itemCount: 100,
              itemBuilder: (_, int i) =>
                  SizedBox(height: 48, child: Text('dialog row $i')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(FushiDesktopTitleBar.pageColors.value, isNull);
  });

  group('阅读器 Dart 侧纸色与正文 CSS 同源', () {
    Future<ReaderSettings> settings() async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final ReaderSettings s = ReaderSettings(db);
      await s.refreshFromDb();
      return s;
    }

    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

    test('翻页 / 滚动 / VN 三种模式的 html,body 底色都是上报给顶栏的那个色', () async {
      final ReaderSettings s = await settings();
      for (final String mode in <String>['paginated', 'continuous', 'vn']) {
        await s.setViewMode(mode);
        final String css = ReaderContentStyles.css(
          settings: s,
          themeOverride: 'custom-theme',
          customBg: '#f7f6eb',
        );
        expect(
          RegExp(
            r'html, body \{[^}]*background: #f7f6eb !important',
          ).hasMatch(css),
          isTrue,
          reason: '$mode 模式正文底色必须是阅读器纸色',
        );
      }
    });

    test('墨水屏：Dart 侧纸色与 CSS 墨水屏分支同值（不随预设纸色）', () async {
      final ReaderSettings s = await settings();
      for (final bool dark in <bool>[false, true]) {
        for (final String mode in <String>['paginated', 'continuous', 'vn']) {
          await s.setViewMode(mode);
          final String css = ReaderContentStyles.css(
            settings: s,
            themeOverride: 'ecru-theme',
            einkMode: true,
            einkDark: dark,
          );
          final Color dartBg = einkReaderThemeColors(_anyThemed, dark: dark).bg;
          final String cssBg = dark ? '#000' : '#fff';
          expect(css, contains('background: $cssBg !important'));
          expect(hex(dartBg), dark ? '#000000' : '#ffffff', reason: mode);
        }
      }
    });
  });
}

const ({
  Color bg,
  Color fg,
  Color sentenceAudioHighlight,
  Color selection,
  Color link,
  bool dark,
})
_anyThemed = (
  bg: Color(0xFFF7F6EB),
  fg: Color(0xDE000000),
  sentenceAudioHighlight: Color(0x66A8C68C),
  selection: Color(0x59C2B280),
  link: Color(0xFF7A6232),
  dark: false,
);
