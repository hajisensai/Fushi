import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_volume_overlays.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

// BUG-4227（反馈 vskVvFumuG）：
// ① 点音量 / 倍速浮层的空白底（内边距、控件间缝）会下穿到下面的进度条——Apple
//    外框的玻璃是 IgnorePointer 兄弟层，Row 的缝不命中，点按落到 translucent
//    dismiss 层与进度条的原始 Listener（关浮层 + 跳进度）。按真实层序搭：进度条
//    原始 Listener → translucent dismiss 层 → 浮层外框。
// ② 拖滑条时控制条照样自动隐藏：拖动发的是 move 不是 hover，无人续命。浮层用
//    [VideoControlPopoverPressHold] 上报按住状态，宿主据此按住控制条。

class _Counters {
  int seekBarDowns = 0;
  int dismissTaps = 0;
}

Future<_Counters> _pumpPopoverOverSeekBar(
  WidgetTester tester, {
  required bool apple,
  required bool speed,
}) async {
  final _Counters counters = _Counters();
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: Brightness.dark,
    ),
    textTheme: Typography.material2021().white,
    glass: apple ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: apple,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(
          body: Stack(
            children: <Widget>[
              // 进度条：media_kit 的 seek bar 用原始 Listener 收按下。
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => counters.seekBarDowns++,
                ),
              ),
              // 与 controls_popover.part.dart 的 dismiss 层同形。
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => counters.dismissTaps++,
                  child: const SizedBox.expand(),
                ),
              ),
              Center(
                child: Builder(
                  builder: (BuildContext context) {
                    final ColorScheme cs = Theme.of(context).colorScheme;
                    if (speed) {
                      return VideoSpeedPopoverCard(
                        width: 240,
                        speed: 1.25,
                        uiScale: 1,
                        colorScheme: cs,
                        m3eSurfaceColor: const Color(0xFF223344),
                        icon: Icons.speed,
                        onReset: () {},
                        onChanged: (_) {},
                      );
                    }
                    return VideoVolumePopoverCard(
                      width: 240,
                      value: 42,
                      uiScale: 1,
                      colorScheme: cs,
                      m3eSurfaceColor: const Color(0xFF223344),
                      icon: Icons.volume_up,
                      tooltip: 'Mute',
                      onToggleMute: () {},
                      onChanged: (_) {},
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return counters;
}

void main() {
  for (final bool apple in <bool>[false, true]) {
    for (final bool speed in <bool>[false, true]) {
      final String label =
          '${apple ? 'Apple' : 'MD3E'} ${speed ? 'speed' : 'volume'}';
      testWidgets('$label popover: tapping its blank padding does not reach '
          'the seek bar or the dismiss layer', (WidgetTester tester) async {
        final _Counters counters = await _pumpPopoverOverSeekBar(
          tester,
          apple: apple,
          speed: speed,
        );
        final Rect frame = tester.getRect(
          find.byKey(
            speed ? videoSpeedPopoverFrameKey : videoVolumePopoverFrameKey,
          ),
        );
        // 左内边距（8 * uiScale）里、竖向居中：不在任何控件上的外框空白。
        await tester.tapAt(Offset(frame.left + 3, frame.center.dy));
        await tester.pump();
        expect(counters.seekBarDowns, 0, reason: '浮层空白处的点按下穿到了进度条');
        expect(counters.dismissTaps, 0, reason: '点浮层自己的空白处不应关掉浮层');

        // 对照：浮层外仍是 dismiss 层的地盘，桩本身是活的。
        await tester.tapAt(Offset(frame.left + 3, frame.top - 40));
        await tester.pump();
        expect(counters.dismissTaps, 1);
        expect(counters.seekBarDowns, 1);
      });
    }
  }

  group('VideoControlPopoverPressHold', () {
    testWidgets('reports pressed for the whole drag and released on up, '
        'without stealing the child gesture', (WidgetTester tester) async {
      final List<bool> reports = <bool>[];
      int childDragUpdates = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: VideoControlPopoverPressHold(
              onPressedChanged: reports.add,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (_) => childDragUpdates++,
                child: const SizedBox(width: 200, height: 40),
              ),
            ),
          ),
        ),
      );
      final Offset c = tester.getCenter(find.byType(SizedBox));
      final TestGesture g = await tester.startGesture(c);
      expect(reports, <bool>[true]);
      await g.moveBy(const Offset(30, 0));
      await g.moveBy(const Offset(30, 0));
      expect(reports, <bool>[true], reason: '拖动中途不得反复上报');
      await g.up();
      expect(reports, <bool>[true, false]);
      expect(childDragUpdates, greaterThan(0), reason: '旁听不得抢子树手势');
    });

    testWidgets('multi-pointer: released only after the last pointer lifts; '
        'cancel counts as release', (WidgetTester tester) async {
      final List<bool> reports = <bool>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: VideoControlPopoverPressHold(
              onPressedChanged: reports.add,
              child: const SizedBox(width: 200, height: 40),
            ),
          ),
        ),
      );
      final Offset c = tester.getCenter(find.byType(SizedBox));
      final TestGesture a = await tester.startGesture(c, pointer: 1);
      final TestGesture b = await tester.startGesture(
        c + const Offset(20, 0),
        pointer: 2,
      );
      expect(reports, <bool>[true]);
      await a.up();
      expect(reports, <bool>[true]);
      await b.cancel();
      expect(reports, <bool>[true, false]);
    });
  });
}
