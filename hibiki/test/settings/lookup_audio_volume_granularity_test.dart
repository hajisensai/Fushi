import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// 查词音量滑条粒度（飞书 row57「查词音量的滑条也改成和有声书音量一样的」）：
/// 旧实现 divisions: 20（0–100% 共 20 档）= 拖动和方向键都是 5% 一跳，标题无读数。
/// 新契约与有声书音量行（TODO-037 / AudiobookVolumeRow）同款：拖动 1% 一档
/// （divisions 100），键盘/手柄左右键 5% 一步（经 SettingsSliderItem.step 与档位
/// 解耦），标题带实时百分比读数 `查词音量 (95%)`（titleReadout，裸 title 不变）。
/// 持久化 key（lookup_audio_volume）/默认值（100）/播放链路（lookupAudioVolumeGain
/// → TtsChannel）不变，由 lookup_audio_volume_settings_test +
/// lookup_audio_volume_wiring_static_test 兜底；这里验证 UI 行为层的粒度契约。
void main() {
  HibikiDatabase testDb() {
    return HibikiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
  }

  /// 从真实 schema 里取出 lookup.audio_volume 这一条（保证测的是生产配置，
  /// 不是测试自拟副本），包成单行 destination：HibikiFocusRoot 内只有这一个
  /// 焦点停靠点，ensureFocus 必然落在音量滑条上。
  SettingsDestination volumeOnlyDestination(SettingsContext settingsContext) {
    final SettingsSliderItem item = buildSettingsSchema(settingsContext)
        .expand((SettingsDestination d) => d.sections)
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsSliderItem>()
        .firstWhere((SettingsSliderItem i) => i.id == 'lookup.audio_volume');
    return SettingsDestination(
      id: SettingsDestinationId.lookup,
      title: t.lookup_audio_volume,
      icon: Icons.volume_up_outlined,
      sections: <SettingsSection>[
        SettingsSection(items: <SettingsItem>[item]),
      ],
    );
  }

  /// 真实管线 harness：schema item → MaterialSettingsRenderer →
  /// AdaptiveSettingsSliderRow → Slider，refresh 走 setState（与真实设置页 /
  /// 阅读器快捷设置面板同语义），读数才能实时跟随。
  Widget buildHarness(AppModel appModel) {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    return ProviderScope(
      child: MaterialApp(
        navigatorKey: navKey,
        theme: ThemeData.light(useMaterial3: true),
        builder: (BuildContext context, Widget? child) =>
            wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
        home: Scaffold(
          body: HibikiFocusRoot(
            child: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                return StatefulBuilder(
                  builder: (BuildContext context, StateSetter setState) {
                    final SettingsContext live = SettingsContext(
                      context: context,
                      appModel: appModel,
                      ref: ref,
                      readerSource: ReaderHibikiSource.instance,
                      refresh: () => setState(() {}),
                    );
                    return const MaterialSettingsRenderer().buildDetailContent(
                      settingsContext: live,
                      destination: volumeOnlyDestination(live),
                      shrinkWrap: true,
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  late HibikiDatabase db;

  setUp(() async {
    db = testDb();
    MediaSource.setDatabase(db);
    final ReaderSettings readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderHibikiSource.readerSettings = readerSettings;
  });

  tearDown(() async {
    ReaderHibikiSource.readerSettings = null;
    await db.close();
  });

  group('lookup audio volume slider granularity', () {
    testWidgets('drag snaps to the 1% grid, not the old 5% grid', (
      WidgetTester tester,
    ) async {
      await ReaderHibikiSource.instance.setLookupAudioVolume(50);
      await tester.pumpWidget(buildHarness(AppModel(testPlatformServices())));
      await tester.pump();

      final Slider slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, 0);
      expect(slider.max, 100);
      expect(slider.divisions, 100,
          reason: '0–100% 共 100 档 = 拖动 1% 一档（旧 20 档 = 5% 太粗）');

      // 行为证明：从 50% 拖 +2.5% 轨道宽，divisions=100 吸附到 51–54 之间
      // 某个非 5 倍数；旧 divisions=20 只能落 50 或 55。
      final double width = tester.getSize(find.byType(Slider)).width;
      final double trackWidth = width - 48; // Material 轨道左右各 ~24 inset
      await tester.drag(find.byType(Slider), Offset(trackWidth * 0.025, 0));
      await tester.pump();

      final int volume = ReaderHibikiSource.instance.lookupAudioVolume;
      expect(volume, isNot(50), reason: '拖动确实改了音量');
      expect(volume, inInclusiveRange(51, 54));
      expect(volume % 5, isNot(0),
          reason: '落点不是 5 的倍数 ⇒ 拖动档位确实细到 1%（旧 5% 网格给不出这个值）');
    });

    testWidgets('arrow keys nudge 5% per press with live title readout', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(buildHarness(AppModel(testPlatformServices())));
      await tester.pump();

      expect(find.text('${t.lookup_audio_volume} (100%)'), findsOneWidget,
          reason: '标题带实时百分比读数（与有声书音量行同款）');

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.byType(Slider)),
      );
      controller.ensureFocus();
      await tester.pump();
      expect(controller.activeId, isNotNull, reason: '音量行注册为单一焦点停靠点');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(ReaderHibikiSource.instance.lookupAudioVolume, 95,
          reason: '左方向键 = -5%（键步经 step 与 1% 拖动档位解耦）');
      expect(find.text('${t.lookup_audio_volume} (95%)'), findsOneWidget,
          reason: '标题实时读数跟随（没有读数细步进等于白调）');

      // clamp 在 100% 不过冲。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(ReaderHibikiSource.instance.lookupAudioVolume, 100);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(ReaderHibikiSource.instance.lookupAudioVolume, 95);

      // 持久化往返：新 ReaderSettings 从 DB 重读得到同一个值。
      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();
      expect(restored.lookupAudioVolume, 95);
    });

    testWidgets('D-pad left/right adjusts by the same 5% step', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(buildHarness(AppModel(testPlatformServices())));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.byType(Slider)),
      );
      controller.ensureFocus();
      await tester.pump();

      expect(
        Actions.maybeInvoke<GamepadButtonIntent>(
          controller.activeContext!,
          const GamepadButtonIntent(GamepadButton.dpadLeft),
        ),
        isTrue,
        reason: 'D-pad 左右被音量行消费（不移动焦点）',
      );
      await tester.pump();
      expect(ReaderHibikiSource.instance.lookupAudioVolume, 95);

      Actions.maybeInvoke<GamepadButtonIntent>(
        controller.activeContext!,
        const GamepadButtonIntent(GamepadButton.dpadRight),
      );
      await tester.pump();
      expect(ReaderHibikiSource.instance.lookupAudioVolume, 100);
    });
  });

  group('source guard (anti-regression)', () {
    test('schema keeps the fine-grained lookup volume contract', () {
      final String source =
          File('lib/src/settings/settings_schema.dart').readAsStringSync();
      final int start = source.indexOf("id: 'lookup.audio_volume'");
      expect(start, isNonNegative);
      final int end = source.indexOf("id: 'lookup.pause_on_lookup'", start);
      expect(end, greaterThan(start));
      final String block = source.substring(start, end);

      expect(block, contains('divisions: 100'),
          reason: '拖动必须保持 1% 一档（与有声书音量行同款粒度）');
      expect(block, contains('step: 5'), reason: '键盘/手柄步进必须保持 5%（与拖动档位解耦）');
      expect(block, contains('titleReadout: true'), reason: '标题必须保留实时百分比读数');
      expect(block, isNot(contains('divisions: 20')),
          reason: '旧的 5% 粗粒度档位不得回潮');
    });

    test('shared schema widget passes step + readout through to the slider row',
        () {
      // _slider 已从两个渲染器收口到共享 settings_schema_widgets（单一位置），
      // material/cupertino 都复用它，故 step/readout 接线只需在共享文件断言一次。
      final String shared = File(
        'lib/src/settings/settings_schema_widgets.dart',
      ).readAsStringSync();
      expect(shared, contains('step: slider.step'),
          reason: '共享 schema widget 必须把 SettingsSliderItem.step 传给滑条行');
      expect(
          shared,
          contains('readout: slider.titleReadout ? '
              'slider.label?.call(value) : null'),
          reason: '共享 schema widget 必须把 titleReadout 投影成标题读数');
    });
  });
}
