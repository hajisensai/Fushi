// FushiWavySeekBar 点击换算：与画法（thumb / 已播填充 / 跳转刻度）同一口径——轨道
// 可用区间两端各缩半个线宽。视频、有声书、歌词模式都用这条进度条，口径错了点哪儿
// 都会偏一点（两端最明显）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:material_ui/material_ui.dart';

class _Clock implements FushiPlaybackClock {
  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration => const Duration(minutes: 4);
}

const double _stroke = 8;

Future<List<Duration>> _seeksAt(
  WidgetTester tester,
  List<double Function(Rect bar)> xs, {
  TextDirection direction = TextDirection.ltr,
  Duration? holdFor,
}) async {
  final List<Duration> seeks = <Duration>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: FushiWavySeekBar(
                clock: _Clock(),
                isPlaying: false,
                animateWave: false,
                showTimes: false,
                onSeek: seeks.add,
                strokeWidth: _stroke,
                barHeight: 32,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final Rect bar = tester.getRect(
    find
        .descendant(
          of: find.byType(FushiWavySeekBar),
          matching: find.byType(GestureDetector),
        )
        .first,
  );
  expect(bar.width, 400);
  for (final double Function(Rect bar) x in xs) {
    if (holdFor == null) {
      await tester.tapAt(Offset(x(bar), bar.center.dy));
    } else {
      final TestGesture g = await tester.startGesture(
        Offset(x(bar), bar.center.dy),
      );
      await tester.pump(holdFor);
      await g.up();
    }
    await tester.pump(const Duration(seconds: 1));
  }
  return seeks;
}

void main() {
  const double half = _stroke / 2;
  const double usable = 400 - _stroke;

  testWidgets('两端各缩半个线宽：起点 / 1/4 / 中点 / 终点按画法比例落点', (
    WidgetTester tester,
  ) async {
    final List<Duration> seeks = await _seeksAt(tester, <double Function(Rect)>[
      (Rect b) => b.left + half,
      (Rect b) => b.left + half + usable * 0.25,
      (Rect b) => b.center.dx,
      (Rect b) => b.right - half,
    ]);
    expect(seeks, <Duration>[
      Duration.zero,
      const Duration(minutes: 1),
      const Duration(minutes: 2),
      const Duration(minutes: 4),
    ]);
  });

  testWidgets('半个线宽以内的两端夹到 0 / 全长', (WidgetTester tester) async {
    final List<Duration> seeks = await _seeksAt(tester, <double Function(Rect)>[
      (Rect b) => b.left + 1,
      (Rect b) => b.right - 1,
    ]);
    expect(seeks, <Duration>[Duration.zero, const Duration(minutes: 4)]);
  });

  testWidgets('RTL 翻转：左端是终点、右端是起点', (WidgetTester tester) async {
    final List<Duration> seeks = await _seeksAt(tester, <double Function(Rect)>[
      (Rect b) => b.left + half,
      (Rect b) => b.right - half,
    ], direction: TextDirection.rtl);
    expect(seeks, <Duration>[const Duration(minutes: 4), Duration.zero]);
  });

  // #358s4Ae_fn：真机点按常超过 kPressTimeout（100ms），onTapDown 先于抬起触发。
  testWidgets('按住超过 kPressTimeout 再松手也提交 seek', (WidgetTester tester) async {
    final List<Duration> seeks = await _seeksAt(tester, <double Function(Rect)>[
      (Rect b) => b.center.dx,
      (Rect b) => b.left + half + usable * 0.25,
    ], holdFor: const Duration(milliseconds: 300));
    expect(seeks, <Duration>[
      const Duration(minutes: 2),
      const Duration(minutes: 1),
    ]);
  });
}
