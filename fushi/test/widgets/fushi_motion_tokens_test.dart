// M3 Expressive 动效 token（2026-10-05）：弹簧数值、归一化曲线、兼容常量与
// 弹簧落定时长一致、设计系统映射、两档降级。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

Widget _probe(
  void Function(BuildContext) onBuild, {
  bool eink = false,
  bool reduceMotion = false,
  bool glass = false,
}) {
  return MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[
        FushiEinkTheme(eink),
        if (glass)
          const FushiGlassTheme(FushiGlassMaterial.off, glassDesign: true),
      ],
    ),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Builder(
        builder: (BuildContext context) {
          onBuild(context);
          return const SizedBox();
        },
      ),
    ),
  );
}

double _peak(Curve curve) {
  double peak = 0;
  for (int i = 0; i <= 2000; i++) {
    final double v = curve.transform(i / 2000);
    if (v > peak) peak = v;
  }
  return peak;
}

void main() {
  group('M3E 弹簧 token', () {
    test('数值与 material-components-android motion tokens 一致', () {
      expect(FushiSprings.spatialFast.dampingRatio, 0.6);
      expect(FushiSprings.spatialFast.stiffness, 800);
      expect(FushiSprings.spatialDefault.dampingRatio, 0.8);
      expect(FushiSprings.spatialDefault.stiffness, 380);
      expect(FushiSprings.spatialSlow.dampingRatio, 0.8);
      expect(FushiSprings.spatialSlow.stiffness, 200);
      expect(FushiSprings.effectsFast.dampingRatio, 1);
      expect(FushiSprings.effectsFast.stiffness, 3800);
      expect(FushiSprings.effectsDefault.dampingRatio, 1);
      expect(FushiSprings.effectsDefault.stiffness, 1600);
      expect(FushiSprings.effectsSlow.dampingRatio, 1);
      expect(FushiSprings.effectsSlow.stiffness, 800);
    });

    test('兼容常量 = 对应弹簧的落定时长（±5ms）', () {
      void near(Duration constant, FushiSpringSpec spring) {
        expect(
          (constant.inMicroseconds - spring.duration.inMicroseconds).abs(),
          lessThan(5000),
          reason: '$constant vs $spring → ${spring.duration}',
        );
      }

      near(FushiMotion.micro, FushiSprings.effectsFast);
      near(FushiMotion.short, FushiSprings.effectsDefault);
      near(FushiMotion.medium, FushiSprings.spatialDefault);
      near(FushiMotion.long, FushiSprings.spatialSlow);
      near(FushiMotion.longReverse, FushiSprings.effectsSlow);
    });

    test('时长随刚度单调：fast < default < slow；没有超过 500ms 的 token', () {
      for (final FushiMotionScheme scheme in <FushiMotionScheme>[
        FushiMotionScheme.expressive,
        FushiMotionScheme.apple,
      ]) {
        expect(
          scheme.spatialFast.duration < scheme.spatialDefault.duration,
          isTrue,
        );
        expect(
          scheme.spatialDefault.duration < scheme.spatialSlow.duration,
          isTrue,
        );
        expect(
          scheme.effectsFast.duration < scheme.effectsDefault.duration,
          isTrue,
        );
        expect(
          scheme.effectsDefault.duration < scheme.effectsSlow.duration,
          isTrue,
        );
        for (final FushiSpringSpec s in <FushiSpringSpec>[
          scheme.spatialFast,
          scheme.spatialDefault,
          scheme.spatialSlow,
          scheme.effectsFast,
          scheme.effectsDefault,
          scheme.effectsSlow,
        ]) {
          expect(
            s.duration.inMilliseconds,
            lessThanOrEqualTo(560),
            reason: '$s',
          );
        }
      }
    });

    test('Apple 方案是 SwiftUI 感知时长弹簧的换算', () {
      final FushiSpringSpec snappy = FushiSpringSpec.perceptual(
        durationSeconds: 0.5,
        bounce: 0.15,
      );
      expect(snappy.dampingRatio, closeTo(0.85, 1e-9));
      expect(
        FushiMotionScheme.apple.spatialDefault.stiffness,
        closeTo(snappy.stiffness, 0.01),
      );
      expect(FushiMotionScheme.apple.effectsDefault.dampingRatio, 1);
    });
  });

  group('FushiSpringCurve', () {
    test('端点精确', () {
      for (final double z in <double>[0.6, 0.8, 1, 1.4]) {
        final FushiSpringCurve c = FushiSpringCurve(dampingRatio: z);
        expect(c.transform(0), 0);
        expect(c.transform(1), 1);
        expect(c.transform(0.999), closeTo(1, 0.02), reason: 'ζ=$z 末端连续');
      }
    });

    test('effects（ζ1）单调不过冲，可安全驱动透明度', () {
      double last = 0;
      for (int i = 0; i <= 1000; i++) {
        final double v = FushiSpringCurve.effects.transform(i / 1000);
        expect(v, greaterThanOrEqualTo(last - 1e-12));
        expect(v, lessThanOrEqualTo(1));
        last = v;
      }
      expect(FushiMotion.enter, FushiSpringCurve.effects);
      expect(FushiMotion.standard, FushiSpringCurve.effects);
    });

    test('spatial 过冲量：ζ0.8 ≈ 1.5%、ζ0.6 ≈ 9.5%', () {
      expect(_peak(FushiSpringCurve.spatial), closeTo(1.015, 0.006));
      expect(_peak(FushiSpringCurve.spatialFast), closeTo(1.095, 0.01));
    });

    test('exit 是 enter 的时间反演：慢起步、快离场', () {
      expect(
        FushiMotion.exit.transform(0.25),
        lessThan(FushiMotion.enter.transform(0.25)),
      );
      expect(FushiMotion.exit.transform(0), 0);
      expect(FushiMotion.exit.transform(1), 1);
    });

    test('同阻尼比的曲线相等（隐式动画 didUpdateWidget 不重建）', () {
      expect(FushiSprings.spatialDefault.curve, FushiSpringCurve.spatial);
      expect(
        const FushiSpringCurve(dampingRatio: 0.8).hashCode,
        FushiSpringCurve.spatial.hashCode,
      );
    });
  });

  group('FushiMotionScheme.of', () {
    testWidgets('Material = expressive；Apple 设计系统 = apple', (tester) async {
      late FushiMotionScheme material;
      late FushiMotionScheme apple;
      await tester.pumpWidget(_probe((c) => material = c.fushiMotion));
      await tester.pumpWidget(
        _probe((c) => apple = c.fushiMotion, glass: true),
      );
      // MaterialApp 换主题走 AnimatedTheme 过渡：换主题那一帧仍是旧主题
      // （Tween.transform(0) == begin），过渡结束后才读得到玻璃设计系统。
      await tester.pumpAndSettle();
      expect(material.spatialDefault, FushiSprings.spatialDefault);
      expect(material.enabled, isTrue);
      expect(apple.spatialDefault, FushiMotionScheme.apple.spatialDefault);
    });

    for (final (String name, bool eink, bool reduce) in <(String, bool, bool)>[
      ('墨水屏', true, false),
      ('减弱动态效果', false, true),
    ]) {
      testWidgets('$name 下全部 token 时长归零', (tester) async {
        late FushiMotionScheme m;
        await tester.pumpWidget(
          _probe((c) => m = c.fushiMotion, eink: eink, reduceMotion: reduce),
        );
        expect(m.enabled, isFalse);
        for (final FushiSpringSpec s in <FushiSpringSpec>[
          m.spatialFast,
          m.spatialDefault,
          m.spatialSlow,
          m.effectsFast,
          m.effectsDefault,
          m.effectsSlow,
        ]) {
          expect(s.duration, Duration.zero);
        }
      });
    }
  });

  group('fushiSpringTo', () {
    testWidgets('真实弹簧推到终点、精确落定；spatial 途中过冲', (tester) async {
      final AnimationController c = AnimationController.unbounded(
        vsync: const TestVSync(),
      );
      addTearDown(c.dispose);
      double peak = 0;
      c.addListener(() {
        if (c.value > peak) peak = c.value;
      });
      c.fushiSpringTo(1, FushiSprings.spatialFast);
      await tester.pump();
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(c.isAnimating, isFalse);
      expect(c.value, 1);
      expect(peak, greaterThan(1.03));
    });

    testWidgets('降级 token 同帧到位', (tester) async {
      final AnimationController c = AnimationController.unbounded(
        vsync: const TestVSync(),
      );
      addTearDown(c.dispose);
      c.fushiSpringTo(0.5, FushiSprings.spatialDefault.reduced);
      expect(c.value, 0.5);
      expect(c.isAnimating, isFalse);
    });

    testWidgets('打断时沿用当前速度（不急停）', (tester) async {
      final AnimationController c = AnimationController.unbounded(
        vsync: const TestVSync(),
      );
      addTearDown(c.dispose);
      c.fushiSpringTo(1, FushiSprings.spatialDefault);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 48));
      final double v = c.velocity;
      expect(v, greaterThan(0));
      c.fushiSpringTo(0, FushiSprings.spatialDefault);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(c.velocity, isNot(0));
      c.stop();
    });
  });
}
