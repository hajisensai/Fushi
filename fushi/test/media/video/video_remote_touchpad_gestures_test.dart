import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_remote_touchpad_gestures.dart';

/// 触控板手势判别：整屏操作只看位移与时长，不看落点。
void main() {
  Duration ms(int value) => Duration(milliseconds: value);
  const Offset o = Offset(200, 400);

  List<VideoRemotePadGesture> tap(
    VideoRemotePadGestureTracker tracker,
    int at, {
    Offset position = o,
    int pointer = 1,
  }) => <VideoRemotePadGesture>[
    ...tracker.down(pointer, position, ms(at)),
    ...tracker.up(pointer, ms(at + 60)),
  ];

  test('a tap waits out the double-tap window, two taps make a double tap', () {
    final VideoRemotePadGestureTracker tracker = VideoRemotePadGestureTracker();
    expect(tap(tracker, 0), isEmpty);
    expect(tracker.busy, isTrue);
    expect(tracker.tick(ms(200)), isEmpty);
    expect(tracker.tick(ms(400)), <VideoRemotePadGesture>[
      VideoRemotePadGesture.tap,
    ]);
    expect(tracker.busy, isFalse);

    expect(tap(tracker, 1000), isEmpty);
    expect(
      tap(tracker, 1200, position: o + const Offset(20, 10)),
      <VideoRemotePadGesture>[VideoRemotePadGesture.doubleTap],
    );
    expect(tracker.tick(ms(2000)), isEmpty);
  });

  test('without double tap a tap fires on release', () {
    final VideoRemotePadGestureTracker tracker = VideoRemotePadGestureTracker(
      doubleTapEnabled: false,
    );
    expect(tap(tracker, 0), <VideoRemotePadGesture>[VideoRemotePadGesture.tap]);
  });

  test('holding still is a long press and no tap follows', () {
    final VideoRemotePadGestureTracker tracker = VideoRemotePadGestureTracker();
    tracker.down(1, o, ms(0));
    tracker.move(1, o + const Offset(5, 5), ms(100));
    expect(tracker.tick(ms(300)), isEmpty);
    expect(tracker.tick(ms(520)), <VideoRemotePadGesture>[
      VideoRemotePadGesture.longPress,
    ]);
    expect(tracker.tick(ms(900)), isEmpty);
    expect(tracker.up(1, ms(1000)), isEmpty);
    expect(tracker.tick(ms(2000)), isEmpty);
  });

  test('flicks resolve by the dominant axis and need enough travel', () {
    final VideoRemotePadGestureTracker tracker = VideoRemotePadGestureTracker();
    List<VideoRemotePadGesture> flick(Offset delta) {
      tracker.down(1, o, ms(0));
      tracker.move(1, o + delta, ms(80));
      return tracker.up(1, ms(120));
    }

    expect(flick(const Offset(-90, 10)), <VideoRemotePadGesture>[
      VideoRemotePadGesture.flickLeft,
    ]);
    expect(flick(const Offset(90, -10)), <VideoRemotePadGesture>[
      VideoRemotePadGesture.flickRight,
    ]);
    expect(flick(const Offset(5, -80)), <VideoRemotePadGesture>[
      VideoRemotePadGesture.flickUp,
    ]);
    expect(flick(const Offset(5, 80)), <VideoRemotePadGesture>[
      VideoRemotePadGesture.flickDown,
    ]);
    // 斜着划：两轴都不占优，不猜。
    expect(flick(const Offset(70, 60)), isEmpty);
    // 走出 slop 但不够快滑：既不是点也不是滑。
    expect(flick(const Offset(30, 0)), isEmpty);
    expect(tracker.tick(ms(5000)), isEmpty);
  });

  test('stepping emits one step per distance on the locked axis', () {
    final VideoRemotePadGestureTracker tracker = VideoRemotePadGestureTracker(
      stepping: true,
      doubleTapEnabled: false,
    );
    tracker.down(1, o, ms(0));
    expect(tracker.move(1, o + const Offset(10, 0), ms(10)), isEmpty);
    // 18 slop + 28 一格。
    expect(
      tracker.move(1, o + const Offset(46, 3), ms(20)),
      <VideoRemotePadGesture>[VideoRemotePadGesture.stepRight],
    );
    expect(
      tracker.move(1, o + const Offset(110, 8), ms(30)),
      <VideoRemotePadGesture>[
        VideoRemotePadGesture.stepRight,
        VideoRemotePadGesture.stepRight,
      ],
    );
    // 拖回来按同一轴计（来回拖 = 前后挪），纵向漂移不改轴。
    expect(
      tracker.move(1, o + const Offset(30, 40), ms(40)),
      <VideoRemotePadGesture>[
        VideoRemotePadGesture.stepLeft,
        VideoRemotePadGesture.stepLeft,
      ],
    );
    expect(tracker.up(1, ms(50)), isEmpty);

    tracker.down(2, o, ms(100));
    expect(
      tracker.move(2, o + const Offset(0, -50), ms(110)),
      <VideoRemotePadGesture>[VideoRemotePadGesture.stepUp],
    );
    expect(tracker.up(2, ms(120)), isEmpty);
  });

  test('two fingers tapping together is a two-finger tap only', () {
    final VideoRemotePadGestureTracker tracker = VideoRemotePadGestureTracker();
    tracker.down(1, o, ms(0));
    tracker.down(2, o + const Offset(80, 0), ms(60));
    expect(tracker.up(1, ms(150)), isEmpty);
    expect(tracker.up(2, ms(180)), <VideoRemotePadGesture>[
      VideoRemotePadGesture.twoFingerTap,
    ]);
    expect(tracker.tick(ms(1000)), isEmpty);

    // 第二指来得太晚：整轮作废。
    tracker.down(1, o, ms(2000));
    tracker.down(2, o, ms(2400));
    expect(tracker.up(2, ms(2450)), isEmpty);
    expect(tracker.up(1, ms(2460)), isEmpty);
    expect(tracker.tick(ms(4000)), isEmpty);
  });

  test('a cancelled pointer produces nothing', () {
    final VideoRemotePadGestureTracker tracker = VideoRemotePadGestureTracker(
      doubleTapEnabled: false,
    );
    tracker.down(1, o, ms(0));
    tracker.cancel(1);
    expect(tracker.up(1, ms(50)), isEmpty);
    expect(tracker.tick(ms(1000)), isEmpty);
  });
}
