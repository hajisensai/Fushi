import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/mascot_glow.dart';
import 'package:fushi/src/utils/scheduling/ambient_ticker.dart';
import 'package:material_ui/material_ui.dart';

/// 吉祥物光晕：开关、忙碌档、减弱动态效果下的行为。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  late ValueNotifier<bool> busy;
  late SchedulingStrategy savedStrategy;

  setUp(() {
    mascotGlowEnabled.value = false;
    busy = ValueNotifier<bool>(false);
    // 生产 binding 装的就是它（FushiWidgetsFlutterBinding.ensureInitialized）。
    savedStrategy = binding.schedulingStrategy;
    binding.schedulingStrategy = ambientAwareSchedulingStrategy;
  });

  tearDown(() {
    mascotGlowEnabled.value = false;
    busy.dispose();
    binding.schedulingStrategy = savedStrategy;
  });

  Widget host({bool disableAnimations = false}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Center(
        child: SizedBox.square(
          dimension: 48,
          child: MascotGlow(
            busyListenable: busy,
            isBusy: () => busy.value,
            child: const ColoredBox(
              key: ValueKey<String>('mascot'),
              color: Color(0xFFFFFFFF),
            ),
          ),
        ),
      ),
    ),
  );

  ImageFiltered haloFilter(WidgetTester tester) => tester.widget<ImageFiltered>(
    find.descendant(
      of: find.byKey(kMascotGlowHaloKey),
      matching: find.byType(ImageFiltered),
    ),
  );

  testWidgets('默认关：只有原图，没有光晕层也没有动画', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    expect(find.byKey(const ValueKey<String>('mascot')), findsOneWidget);
    expect(find.byKey(kMascotGlowHaloKey), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('打开后立即出现呼吸光晕，关掉即撤', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    mascotGlowEnabled.value = true;
    await tester.pump();
    expect(find.byKey(kMascotGlowHaloKey), findsOneWidget);
    expect(find.byType(FadeTransition), findsWidgets);
    expect(tester.hasRunningAnimations, isTrue);

    mascotGlowEnabled.value = false;
    await tester.pump();
    expect(find.byKey(kMascotGlowHaloKey), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('后台任务在跑时换到忙碌档（更大的模糊），结束后回空闲档', (WidgetTester tester) async {
    mascotGlowEnabled.value = true;
    await tester.pumpWidget(host());
    final ImageFilter idle = haloFilter(tester).imageFilter;

    busy.value = true;
    await tester.pump();
    final ImageFilter busyFilter = haloFilter(tester).imageFilter;
    expect(busyFilter, isNot(equals(idle)));
    expect(kMascotGlowBusy.sigma, greaterThan(kMascotGlowIdle.sigma));
    expect(kMascotGlowBusy.high, greaterThan(kMascotGlowIdle.high));

    busy.value = false;
    await tester.pump();
    expect(haloFilter(tester).imageFilter, equals(idle));
  });

  testWidgets('呼吸节奏：忙碌档一个往返比空闲档快一倍', (WidgetTester tester) async {
    expect(FushiMotion.ambientBreathBusy * 2, FushiMotion.ambientBreath);
    mascotGlowEnabled.value = true;
    await tester.pumpWidget(host());
    double opacity() => tester
        .widget<FadeTransition>(
          find.descendant(
            of: find.byKey(kMascotGlowHaloKey),
            matching: find.byType(FadeTransition),
          ),
        )
        .opacity
        .value;
    final double start = opacity();
    expect(start, closeTo(kMascotGlowIdle.low, 1e-6));
    await tester.pump(FushiMotion.ambientBreath);
    expect(opacity(), closeTo(kMascotGlowIdle.high, 1e-3));
  });

  // BUG-4893：悬浮球常驻时呼吸从启动一直在跑。它算进「有动画在跑」的话，启动期等空闲的
  // 工作永远等不到（改前还会让调度器空转、饿死 Windows 输入）。
  testWidgets('呼吸是常驻装饰动画：不算真实动画，等空闲照常完成', (WidgetTester tester) async {
    mascotGlowEnabled.value = true;
    await tester.pumpWidget(host());
    expect(AmbientTickers.liveCount, 1);
    expect(tester.binding.transientCallbackCount, 1);
    expect(AmbientTickers.scheduledFrameCallbackCount, 1);
    expect(hasRealAnimations(tester.binding), isFalse);

    bool idle = false;
    unawaited(waitForUiIdle().then((_) => idle = true));
    await tester.pump(const Duration(milliseconds: 1));
    expect(idle, isTrue);

    // 忙碌档换节奏后仍是同一个 ambient ticker。
    busy.value = true;
    await tester.pump();
    expect(AmbientTickers.liveCount, 1);
    expect(hasRealAnimations(tester.binding), isFalse);

    mascotGlowEnabled.value = false;
    await tester.pump();
    expect(AmbientTickers.liveCount, 0);
  });

  // BUG-4961：光晕开着时不再按屏幕刷新率逐帧重画整窗（4K 144 Hz 下 raster 约 47%）。
  testWidgets('呼吸约 30 fps 采样，不按刷新率逐帧', (WidgetTester tester) async {
    mascotGlowEnabled.value = true;
    await tester.pumpWidget(host());
    final Animation<double> opacity = tester
        .widget<FadeTransition>(
          find.descendant(
            of: find.byKey(kMascotGlowHaloKey),
            matching: find.byType(FadeTransition),
          ),
        )
        .opacity;
    int ticks = 0;
    void count() => ticks++;
    opacity.addListener(count);
    for (int ms = 0; ms < 1000; ms++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    opacity.removeListener(count);
    expect(
      ticks,
      lessThanOrEqualTo(
        1000 ~/ FushiMotion.ambientFrameInterval.inMilliseconds + 2,
      ),
    );
    expect(ticks, greaterThan(10), reason: '仍在呼吸');
  });

  testWidgets('减弱动态效果：静止光晕，不跑 ticker', (WidgetTester tester) async {
    mascotGlowEnabled.value = true;
    await tester.pumpWidget(host(disableAnimations: true));
    expect(find.byKey(kMascotGlowHaloKey), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    final Opacity still = tester.widget<Opacity>(
      find.descendant(
        of: find.byKey(kMascotGlowHaloKey),
        matching: find.byType(Opacity),
      ),
    );
    expect(still.opacity, kMascotGlowIdle.still);
  });
}
