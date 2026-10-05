import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';

/// 歌词覆盖层与桌面自绘标题栏之间不得有接缝。
///  * 2026-10-04：标题栏还是阅读器纸色、下面是播放页渐变，一条硬边——覆盖层上报
///    自己的顶边底色、盖过阅读器的纸色。
///  * 2026-10-05（「歌词模式顶部模糊还是有点违和」）：上一版在背景顶上压了一条
///    44px「标题栏同色 → 透明」的渐变带，看起来就是一条奶白 / 更暗的独立色带。
///    现在没有任何独立顶带：背景画布向上延伸到标题栏底下，标题栏画同一张画布的
///    最上面一截（[FushiTitleBarBackdropView]），两边像素连续。
class _Clock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(seconds: 30);
  @override
  Duration get duration => const Duration(minutes: 5);
  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

int _channel(double v) => (v * 255).round();

bool _isOldSeamBand(Widget w, Color edge) {
  if (w is! DecoratedBox) return false;
  final Decoration d = w.decoration;
  if (d is! BoxDecoration) return false;
  final Gradient? g = d.gradient;
  return g is LinearGradient &&
      g.begin == Alignment.topCenter &&
      g.colors.any((Color c) => c == edge);
}

void main() {
  const Color paper = Color(0xFFE3F0D8); // 阅读器的浅绿纸色
  setUp(() => FushiDesktopTitleBar.debugIsEnabled = true);
  tearDown(() => FushiDesktopTitleBar.debugIsEnabled = false);

  for (final bool apple in <bool>[false, true]) {
    for (final Brightness brightness in Brightness.values) {
      final String name = '${apple ? 'Apple' : 'MD3'} ${brightness.name}';
      testWidgets('$name：标题栏画同一张背景的顶上一截，接缝两侧像素连续', (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1200, 700);
        addTearDown(tester.view.reset);
        const double bar = FushiDesktopTitleBar.height;
        final GlobalKey boundary = GlobalKey();
        Widget overlay() => ReaderLyricsPlayerOverlay(
          lyricsView: const SizedBox.expand(),
          data: LyricsPlayerData(
            title: 'T',
            cover: null,
            isPlaying: false,
            speed: 1,
            lyricsMasked: false,
            clock: _Clock(),
          ),
          callbacks: LyricsPlayerCallbacks(
            onClose: () {},
            onPlayPause: () {},
            onPreviousCue: () {},
            onNextCue: () {},
            onSeek: (_) {},
            onToggleMask: () {},
            onOpenStatistics: () {},
            onSpeedChanged: (_) {},
            onMore: (_) {},
            onTapBackground: () {},
          ),
          onHtmlThemeChanged: (_) {},
        );

        // 标题栏替身：与真顶栏同样先铺上报底色、再画上报的背景。
        Widget titleBar() => ValueListenableBuilder<FushiTitleBarColors?>(
          valueListenable: FushiDesktopTitleBar.pageColors,
          builder: (BuildContext _, FushiTitleBarColors? colors, Widget? _) =>
              ColoredBox(
                color: colors?.background ?? Colors.transparent,
                child: ValueListenableBuilder<FushiTitleBarBackdrop?>(
                  valueListenable: FushiDesktopTitleBar.pageBackdrop,
                  builder:
                      (
                        BuildContext _,
                        FushiTitleBarBackdrop? backdrop,
                        Widget? _,
                      ) => backdrop == null
                      ? const SizedBox.expand()
                      : FushiTitleBarBackdropView(backdrop: backdrop),
                ),
              ),
        );

        // 模拟真实窗口：顶上一条 32px 自绘标题栏，下面是页面。整窗一张截图，
        // 比较标题栏最后一行与页面第一行。
        Widget app({required bool lyrics}) => MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            colorSchemeSeed: const Color(0xFF3B6EA5),
            extensions: <ThemeExtension<dynamic>>[
              FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
            ],
          ),
          // 关动效：mesh 静止在相位 0，像素可复现。
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: RepaintBoundary(
              key: boundary,
              child: Column(
                children: <Widget>[
                  SizedBox(height: bar, child: titleBar()),
                  Expanded(child: child!),
                ],
              ),
            ),
          ),
          home: FushiTitleBarColorScope(
            // 阅读器先上报纸色（它的 scope 包着整页、更早挂上）。
            colors: (background: paper, foreground: Colors.black),
            child: Scaffold(
              backgroundColor: paper,
              body: lyrics ? overlay() : const SizedBox.expand(),
            ),
          ),
        );

        await tester.pumpWidget(app(lyrics: true));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        final FushiTitleBarColors? colors =
            FushiDesktopTitleBar.pageColors.value;
        expect(colors, isNotNull);
        expect(
          colors!.background,
          isNot(paper),
          reason: '覆盖层在场时标题栏必须跟覆盖层，而不是阅读器纸色',
        );
        final FushiTitleBarBackdrop? backdrop =
            FushiDesktopTitleBar.pageBackdrop.value;
        expect(backdrop, isNotNull, reason: '覆盖层必须把背景延伸进标题栏');
        // 画布 = 页面（700 - 32）+ 顶栏那一截。
        expect(backdrop!.canvas, const Size(1200, 700));

        // 覆盖层里不再有任何独立的顶部色带（旧版 44px 渐变带）。
        expect(
          find.descendant(
            of: find.byType(ReaderLyricsPlayerOverlay),
            matching: find.byWidgetPredicate(
              (Widget w) => _isOldSeamBand(w, colors.background),
            ),
          ),
          findsNothing,
        );

        late ByteData bytes;
        late int width;
        await tester.runAsync(() async {
          final RenderRepaintBoundary rb =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final ui.Image image = await rb.toImage();
          width = image.width;
          bytes = (await image.toByteData())!;
        });
        List<int> px(int x, int y) {
          final int o = (y * width + x) * 4;
          return <int>[
            bytes.getUint8(o),
            bytes.getUint8(o + 1),
            bytes.getUint8(o + 2),
          ];
        }

        final List<int> fallback = <int>[
          _channel(colors.background.r),
          _channel(colors.background.g),
          _channel(colors.background.b),
        ];
        for (final int x in <int>[4, width ~/ 3, width ~/ 2, width - 5]) {
          final List<int> above = px(x, bar.toInt() - 1);
          final List<int> below = px(x, bar.toInt());
          for (int c = 0; c < 3; c++) {
            expect(
              (above[c] - below[c]).abs(),
              lessThanOrEqualTo(3),
              reason: '$name x=$x 通道 $c：标题栏末行 $above vs 页面首行 $below',
            );
          }
        }
        // 标题栏里画的确实是背景本身（MD3 的 mesh 不是纯 surface 色），不是只
        // 铺了一层上报底色：至少有一处与底色明显不同。
        if (!apple) {
          int maxDiff = 0;
          for (final int x in <int>[4, width ~/ 3, width ~/ 2, width - 5]) {
            final List<int> top = px(x, 2);
            for (int c = 0; c < 3; c++) {
              final int d = (top[c] - fallback[c]).abs();
              if (d > maxDiff) maxDiff = d;
            }
          }
          expect(maxDiff, greaterThan(2), reason: '$name 标题栏只有底色');
        }

        // 退出歌词：覆盖层撤回上报，标题栏回落到阅读器纸色、不再画背景。
        await tester.pumpWidget(app(lyrics: false));
        await tester.pump(const Duration(milliseconds: 50));
        expect(FushiDesktopTitleBar.pageColors.value?.background, paper);
        expect(FushiDesktopTitleBar.pageBackdrop.value, isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }
  }
}
