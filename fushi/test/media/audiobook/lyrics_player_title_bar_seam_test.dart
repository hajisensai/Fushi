import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';

/// 歌词覆盖层与桌面自绘标题栏之间不得有接缝（用户 2026-10-04 报：标题栏还是阅读器
/// 纸色、下面是播放页渐变，一条硬边）。覆盖层上报自己的顶边底色、盖过阅读器的纸色；
/// 背景最上面一条带压成同一色，第一行像素与标题栏严格同色（≤ 2/255）。
class _Clock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(seconds: 30);
  @override
  Duration get duration => const Duration(minutes: 5);
  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

int _channel(double v) => (v * 255).round();

void main() {
  const Color paper = Color(0xFFE3F0D8); // 阅读器的浅绿纸色
  for (final bool apple in <bool>[false, true]) {
    for (final Brightness brightness in Brightness.values) {
      final String name = '${apple ? 'Apple' : 'MD3'} ${brightness.name}';
      testWidgets('$name：标题栏跟随覆盖层顶边、首行像素无接缝', (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1200, 700);
        addTearDown(tester.view.reset);
        final GlobalKey boundary = GlobalKey();
        Widget app({required bool lyrics}) => MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            colorSchemeSeed: const Color(0xFF3B6EA5),
            extensions: <ThemeExtension<dynamic>>[
              FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
            ],
          ),
          home: FushiTitleBarColorScope(
            // 阅读器先上报纸色（它的 scope 包着整页、更早挂上）。
            colors: (background: paper, foreground: Colors.black),
            child: Scaffold(
              backgroundColor: paper,
              body: lyrics
                  ? RepaintBoundary(
                      key: boundary,
                      child: ReaderLyricsPlayerOverlay(
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
                      ),
                    )
                  : const SizedBox.expand(),
            ),
          ),
        );

        await tester.pumpWidget(app(lyrics: true));
        await tester.pump(const Duration(milliseconds: 100));
        final FushiTitleBarColors? bar = FushiDesktopTitleBar.pageColors.value;
        expect(bar, isNotNull);
        expect(
          bar!.background,
          isNot(paper),
          reason: '覆盖层在场时标题栏必须跟覆盖层，而不是阅读器纸色',
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
        // 第一行像素（标题栏正下方）在左 / 中 / 右三处都与上报底色相差 ≤ 2/255。
        for (final int x in <int>[4, width ~/ 2, width - 5]) {
          final int o = x * 4;
          final List<int> px = <int>[
            bytes.getUint8(o),
            bytes.getUint8(o + 1),
            bytes.getUint8(o + 2),
          ];
          final List<int> want = <int>[
            _channel(bar.background.r),
            _channel(bar.background.g),
            _channel(bar.background.b),
          ];
          for (int c = 0; c < 3; c++) {
            expect(
              (px[c] - want[c]).abs(),
              lessThanOrEqualTo(2),
              reason: '$name x=$x 通道 $c：像素 $px vs 标题栏 $want',
            );
          }
        }

        // 退出歌词：覆盖层撤回上报，标题栏回落到阅读器纸色。
        await tester.pumpWidget(app(lyrics: false));
        await tester.pump(const Duration(milliseconds: 50));
        expect(FushiDesktopTitleBar.pageColors.value?.background, paper);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }
  }
}
