import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_jump_history_controls.dart'
    show JumpProgressMarksPainter;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiWavySeekBar;
import 'package:material_ui/material_ui.dart';

import '../../helpers/source_guard.dart';
import '../../pages/reader_fushi_page_source_corpus.dart';

/// 歌词模式进度条上的跳转记录刻度（用户 2026-11-04「进度跳转、跳转记录最好就是
/// 跟视频一样进度条有标注」）：所有外观（MD3 / Apple × 新版 / 经典 × 宽 / 窄）
/// 的进度条都用共享的 `FushiJumpProgressMarks` 画同款刻度，按全书音频时间轴换算；
/// 没有记录不画；刻度只看不点，点在刻度上照常按进度条 seek 到那一处（与视频一致）。
class _Clock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(minutes: 3);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

ThemeData _theme({required bool apple}) => apple
    ? buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        textTheme: Typography.material2021().black,
        glass: FushiGlassMaterial.frosted,
        glassDesign: true,
      ).copyWith(platform: TargetPlatform.windows)
    : ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal));

const ({List<double> back, List<double> forward}) _marks = (
  back: <double>[0.25],
  forward: <double>[0.75],
);

Finder _findMarks() =>
    find.byKey(const ValueKey<String>('fushi_jump_progress_marks'));

void main() {
  late List<Duration> seeks;

  setUp(() => seeks = <Duration>[]);

  Widget app({
    required bool apple,
    required LyricsControlsStyle style,
    bool expanded = false,
    ({List<double> back, List<double> forward})? marks = _marks,
  }) => MaterialApp(
    theme: _theme(apple: apple),
    home: Scaffold(
      body: ReaderLyricsPlayerOverlay(
        lyricsView: const SizedBox.expand(),
        data: LyricsPlayerData(
          title: 'book',
          chapterLabel: '第四章',
          cover: null,
          isPlaying: false,
          speed: 1,
          lyricsMasked: false,
          clock: _Clock(),
          controlsStyle: style,
          compactControlsExpanded: expanded,
          jumpMarks: marks,
        ),
        callbacks: LyricsPlayerCallbacks(
          onClose: () {},
          onPlayPause: () {},
          onPreviousCue: () {},
          onNextCue: () {},
          onSeek: seeks.add,
          onToggleMask: () {},
          onOpenStatistics: () {},
          onSpeedChanged: (_) {},
          onMore: (_) {},
          onTapBackground: () {},
          onSeekRelative: (_) {},
        ),
        onHtmlThemeChanged: (_) {},
      ),
    ),
  );

  Future<void> pumpAt(WidgetTester tester, Size size, Widget widget) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.pump(const Duration(seconds: 1));
  }

  final List<
    ({
      String name,
      bool apple,
      LyricsControlsStyle style,
      Size size,
      bool expanded,
    })
  >
  layouts =
      <
        ({
          String name,
          bool apple,
          LyricsControlsStyle style,
          Size size,
          bool expanded,
        })
      >[
        for (final bool apple in <bool>[false, true])
          for (final LyricsControlsStyle style in LyricsControlsStyle.values)
            for (final Size size in const <Size>[
              Size(1600, 900),
              Size(390, 844),
            ])
              for (final bool expanded in <bool>[false, true])
                if (!expanded ||
                    (style == LyricsControlsStyle.modern && size.width < 600))
                  (
                    name:
                        '${apple ? 'apple' : 'md3'} ${style.wire} '
                        '${size.width.toInt()}x${size.height.toInt()}'
                        '${expanded ? ' expanded' : ''}',
                    apple: apple,
                    style: style,
                    size: size,
                    expanded: expanded,
                  ),
      ];

  group('progress bar jump marks', () {
    for (final layout in layouts) {
      testWidgets('${layout.name}: marks drawn from the record on the bar', (
        WidgetTester tester,
      ) async {
        await pumpAt(
          tester,
          layout.size,
          app(
            apple: layout.apple,
            style: layout.style,
            expanded: layout.expanded,
          ),
        );
        expect(tester.takeException(), isNull);
        final Finder marks = _findMarks();
        expect(marks, findsWidgets, reason: layout.name);
        final Rect window = Offset.zero & layout.size;
        for (final Element e in marks.evaluate()) {
          final CustomPaint paint = e.widget as CustomPaint;
          final JumpProgressMarksPainter painter =
              paint.painter! as JumpProgressMarksPainter;
          // 比例原样换算自记录（返回点 / 前进点各一颗）。
          expect(painter.back, <double>[0.25]);
          expect(painter.forward, <double>[0.75]);
          final Rect box = tester.getRect(find.byWidget(paint));
          expect(window.contains(box.center), isTrue, reason: '$box');
          expect(box.width, greaterThan(150), reason: '刻度层与轨道同宽');
          // MD3 的波浪线：刻度层正好是轨道可用区间（两端各缩半个线宽，与
          // thumb 同一换算），落点与 seek 的换算一致。
          final Finder bar = find.ancestor(
            of: find.byWidget(paint),
            matching: find.byType(FushiWavySeekBar),
          );
          if (!layout.apple) {
            expect(bar, findsOneWidget, reason: '刻度画在波浪进度条里');
            final FushiWavySeekBar seek = tester.widget<FushiWavySeekBar>(bar);
            final Rect barRect = tester.getRect(bar);
            expect(box.left, closeTo(barRect.left + seek.strokeWidth / 2, 0.5));
            expect(
              box.right,
              closeTo(barRect.right - seek.strokeWidth / 2, 0.5),
            );
          }
        }
      });
    }

    for (final layout in layouts) {
      testWidgets('${layout.name}: no record, no marks', (
        WidgetTester tester,
      ) async {
        await pumpAt(
          tester,
          layout.size,
          app(
            apple: layout.apple,
            style: layout.style,
            expanded: layout.expanded,
            marks: null,
          ),
        );
        expect(_findMarks(), findsNothing);
        await pumpAt(
          tester,
          layout.size,
          app(
            apple: layout.apple,
            style: layout.style,
            expanded: layout.expanded,
            marks: (back: <double>[], forward: <double>[]),
          ),
        );
        expect(_findMarks(), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    // 与视频一致：刻度只看不点，点在刻度上就是点进度条——seek 到刻度那一处。
    for (final bool apple in <bool>[false, true]) {
      for (final LyricsControlsStyle style in LyricsControlsStyle.values) {
        testWidgets(
          '${apple ? 'apple' : 'md3'} ${style.wire} wide: tapping a mark seeks '
          'the bar to it',
          (WidgetTester tester) async {
            await pumpAt(
              tester,
              const Size(1600, 900),
              app(apple: apple, style: style),
            );
            final Finder marks = _findMarks();
            expect(marks, findsWidgets);
            final Rect box = tester.getRect(marks.first);
            final double x = box.left + box.width * 0.25;
            await tester.tapAt(Offset(x, box.center.dy));
            await tester.pump(const Duration(milliseconds: 300));
            expect(seeks, isNotEmpty, reason: '点刻度落到进度条上');
            // 10 分钟时间轴的 25% = 150 秒（命中带取整误差内）。
            expect(seeks.last.inMilliseconds, closeTo(150000, 1500));
          },
        );
      }
    }
  });

  group('reader wiring', () {
    test(
      'lyrics data takes the audio-timeline marks of the one jump record',
      () {
        final String src = readReaderPageSource();
        final String body = methodBody(
          src,
          '  LyricsPlayerData _lyricsPlayerData(',
        );
        expect(containsCodeLine(body, 'jumpMarks: _audioJumpMarks(),'), isTrue);
      },
    );
  });
}
