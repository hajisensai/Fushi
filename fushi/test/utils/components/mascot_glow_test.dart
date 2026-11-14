import 'dart:ui' show ImageFilter;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/mascot_glow.dart';
import 'package:material_ui/material_ui.dart';

/// 吉祥物光晕：开关、忙碌档、减弱动态效果下的行为。
void main() {
  late ValueNotifier<bool> busy;

  setUp(() {
    mascotGlowEnabled.value = false;
    busy = ValueNotifier<bool>(false);
  });

  tearDown(() {
    mascotGlowEnabled.value = false;
    busy.dispose();
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
