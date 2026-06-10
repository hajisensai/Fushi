import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

import '../../widgets/widget_test_helpers.dart';

/// 有声书音量粒度（飞书 row50「音量调整要更细一点」）：
/// 旧实现 divisions: 20（0–200% 共 20 档）= 拖动和方向键都是 10% 一跳。
/// 新契约：拖动 1% 一档（divisions 200），键盘/手柄左右键 5% 一步
/// （经 step 与档位解耦），标题带实时百分比读数。
/// 持久化链路（setVolume → onVolumePersist → repo.updateVolume）由
/// audio_persist_wiring_static_test + audiobook_volume_persist_test 兜底，
/// 这里验证 UI 行为层的粒度契约。
void main() {
  Widget buildRow({
    required double initial,
    required ValueChanged<double> onValue,
    GlobalKey<NavigatorState>? navKey,
  }) {
    double value = initial;
    final Widget body = HibikiFocusRoot(
      child: StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => AudiobookVolumeRow(
          volume: value,
          onChanged: (double v) {
            onValue(v);
            setState(() => value = v);
          },
        ),
      ),
    );
    if (navKey == null) return buildTestApp(body);
    return MaterialApp(
      navigatorKey: navKey,
      theme: ThemeData.light(useMaterial3: true),
      home: Scaffold(body: body),
      builder: (BuildContext context, Widget? child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
    );
  }

  group('AudiobookVolumeRow granularity', () {
    testWidgets('slider snaps drags to 1% of the 0–200% range', (
      WidgetTester tester,
    ) async {
      double value = 1.0;
      await tester
          .pumpWidget(buildRow(initial: 1.0, onValue: (v) => value = v));
      await tester.pump();

      final Slider slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.max, AudiobookVolumeRow.maxVolume);
      expect(slider.divisions, AudiobookVolumeRow.sliderDivisions,
          reason: '0–2.0 共 200 档 = 1% 一档（旧 20 档 = 10% 太粗）');

      // 行为证明：真实拖动后的值仍落在 1% 网格上（snap 由 SDK divisions 实现）。
      await tester.drag(find.byType(Slider), const Offset(37, 0));
      await tester.pump();
      expect(value, isNot(1.0), reason: '拖动确实改了音量');
      final double percent = value * 100;
      expect(percent, closeTo(percent.roundToDouble(), 1e-6),
          reason: '拖动结果必须吸附在整数百分比（1% 档位）上');
    });

    testWidgets('arrow keys nudge by 5% per press and stay clamped', (
      WidgetTester tester,
    ) async {
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      double value = 1.0;
      await tester.pumpWidget(
        buildRow(initial: 1.0, onValue: (v) => value = v, navKey: navKey),
      );
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.byType(Slider)),
      );
      controller.ensureFocus();
      await tester.pump();
      expect(controller.activeId, isNotNull, reason: '音量行注册为单一焦点停靠点');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(value, closeTo(1.05, 1e-9), reason: '右方向键 = +5%（旧 10% 一跳，细化一倍）');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(value, closeTo(0.95, 1e-9));

      // 标题实时读数跟随细粒度值（没有读数细步进等于白调）。
      expect(find.textContaining('(95%)'), findsOneWidget);
    });

    testWidgets('D-pad right/left adjusts by the same 5% step', (
      WidgetTester tester,
    ) async {
      double value = 1.0;
      await tester
          .pumpWidget(buildRow(initial: 1.0, onValue: (v) => value = v));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.byType(Slider)),
      );
      controller.ensureFocus();
      await tester.pump();

      expect(
        Actions.maybeInvoke<GamepadButtonIntent>(
          controller.activeContext!,
          const GamepadButtonIntent(GamepadButton.dpadRight),
        ),
        isTrue,
        reason: 'D-pad 左右被音量行消费（不移动焦点）',
      );
      await tester.pump();
      expect(value, closeTo(1.05, 1e-9));

      Actions.maybeInvoke<GamepadButtonIntent>(
        controller.activeContext!,
        const GamepadButtonIntent(GamepadButton.dpadLeft),
      );
      await tester.pump();
      expect(value, closeTo(1.0, 1e-9));
    });

    testWidgets('key step clamps at 200% without overshoot', (
      WidgetTester tester,
    ) async {
      double value = 1.98;
      await tester
          .pumpWidget(buildRow(initial: 1.98, onValue: (v) => value = v));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.byType(Slider)),
      );
      controller.ensureFocus();
      await tester.pump();

      Actions.maybeInvoke<GamepadButtonIntent>(
        controller.activeContext!,
        const GamepadButtonIntent(GamepadButton.dpadRight),
      );
      await tester.pump();
      expect(value, closeTo(2.0, 1e-9), reason: '1.98 + 0.05 钳到上限 2.0');
    });
  });

  group('sheet wiring source guard', () {
    test('volume section routes through AudiobookVolumeRow into setVolume', () {
      final String source =
          File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
              .readAsStringSync();
      final int start = source.indexOf(
          'Widget _buildVolumeSection(AudiobookPlayerController ctrl)');
      final int end = source.indexOf('Widget _buildSpeedSection(', start);
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final String section = source.substring(start, end);

      expect(section, contains('AudiobookVolumeRow('),
          reason: 'sheet 的音量行必须走共享的细粒度音量 widget');
      expect(section, contains('ctrl.setVolume(v)'),
          reason: '回调必须写穿控制器（setVolume → onVolumePersist 持久化）');
      expect(section, isNot(contains('divisions: 20')),
          reason: '旧的 10% 粗粒度档位不得回潮');
    });
  });
}
