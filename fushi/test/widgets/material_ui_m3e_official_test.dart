// material_ui 1.11 升级：官方 M3E 新件接线（ElevatedButton 变体、IconButton
// 变体就近继承、官方弹簧 token）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/fushi_fill_slot.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:material_ui/material_ui.dart';

ThemeData _theme({bool eink = false, bool glassDesign = false}) =>
    buildFushiThemeData(
      scheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      textTheme: const TextTheme(),
      eink: eink,
      glassDesign: glassDesign,
    );

void main() {
  group('ElevatedButton 走官方 M3E', () {
    test('MD3 主题打开 M3E 变体、不写死形状（保留官方按压 / 选中形变）', () {
      final ElevatedButtonThemeData data = _theme().elevatedButtonTheme;
      expect(data.variant, StyleVariant.material3Expressive);
      expect(data.style?.shape, isNull);
    });

    test('Apple 与墨水屏保持 M3 原件与全胶囊', () {
      for (final ThemeData theme in <ThemeData>[
        _theme(glassDesign: true),
        _theme(eink: true),
      ]) {
        expect(theme.elevatedButtonTheme.variant, isNull);
        expect(
          theme.elevatedButtonTheme.style?.shape?.resolve(<WidgetState>{}),
          isA<StadiumBorder>(),
        );
      }
    });
  });

  testWidgets('填充槽里的 IconButton 经 variantOf 继承祖先 M3E 变体', (
    WidgetTester tester,
  ) async {
    StyleVariant? resolved;
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: Scaffold(
          body: FushiFillSlot.wrap(
            extent: const Size(40, 40),
            shape: const StadiumBorder(),
            child: Builder(
              builder: (BuildContext context) {
                resolved = IconButtonTheme.variantOf(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    expect(resolved, StyleVariant.material3Expressive);
  });

  test('FushiSprings 取官方 Springs 的 expressive 一族', () {
    void same(FushiSpringSpec spec, SpringDescription official) {
      expect(spec.stiffness, official.stiffness);
      expect(spec.description.damping, closeTo(official.damping, 1e-9));
    }

    same(FushiSprings.spatialFast, Springs.expressiveFastSpatial);
    same(FushiSprings.spatialDefault, Springs.expressiveDefaultSpatial);
    same(FushiSprings.spatialSlow, Springs.expressiveSlowSpatial);
    same(FushiSprings.effectsFast, Springs.expressiveFastEffects);
    same(FushiSprings.effectsDefault, Springs.expressiveDefaultEffects);
    same(FushiSprings.effectsSlow, Springs.expressiveSlowEffects);
  });
}
