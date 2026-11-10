import 'dart:io';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/audiobook/audiobook_av_sync_stepper.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_av_sync_panel.dart';

import '../../helpers/source_guard.dart';

/// 歌词模式「音画同步」面板（反馈 G5xYgLcp4p，#3109 遗留）：在歌词模式里就能调整本
/// 偏移，与普通阅读模式快捷设置同一个步进器、写同一个偏好。
void main() {
  /// 模拟 `AudiobookPlayerController.setDelayMs`：夹取后写回通知器。
  late ValueNotifier<int> delay;
  late List<int> calls;
  void setDelayMs(int ms) {
    calls.add(ms);
    delay.value = ms.clamp(-600000, 600000);
  }

  setUp(() {
    delay = ValueNotifier<int>(0);
    calls = <int>[];
  });
  tearDown(() => delay.dispose());

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: LyricsAvSyncPanel(delayMs: delay, onChanged: setDelayMs),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  String readout(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(AudiobookAvSyncStepper.readoutKey)).data!;

  testWidgets('±50ms / ±1s 步进基于当前偏移，读数跟随控制器', (WidgetTester tester) async {
    delay.value = 200;
    await pumpPanel(tester);
    expect(find.byKey(kLyricsAvSyncPanelKey), findsOneWidget);
    expect(readout(tester), '+200ms');

    await tester.tap(find.byKey(AudiobookAvSyncStepper.stepKey(50)));
    await tester.pump();
    expect(calls, <int>[250]);
    expect(readout(tester), '+250ms');

    await tester.tap(find.byKey(AudiobookAvSyncStepper.stepKey(-1000)));
    await tester.pump();
    expect(calls.last, -750);
    expect(readout(tester), '-750ms');

    await tester.tap(find.byKey(AudiobookAvSyncStepper.stepKey(-50)));
    await tester.tap(find.byKey(AudiobookAvSyncStepper.stepKey(-1000)));
    await tester.pump();
    expect(calls.last, -1800);
    expect(readout(tester), '-1.8s');

    // 外部（设置页 / 快捷键）改了偏移，面板读数同步。
    delay.value = 1200;
    await tester.pump();
    expect(readout(tester), '+1.2s');
  });

  testWidgets('归零键与点读数都归零；已为 0 时归零键置灰', (WidgetTester tester) async {
    await pumpPanel(tester);
    final Finder reset = find.byKey(kLyricsAvSyncPanelResetKey);
    await tester.tap(reset);
    await tester.pump();
    expect(calls, isEmpty, reason: '偏移为 0 时归零键不可点');

    delay.value = 350;
    await tester.pump();
    await tester.tap(reset);
    await tester.pump();
    expect(calls, <int>[0]);
    expect(readout(tester), '0ms');

    delay.value = -100;
    await tester.pump();
    await tester.tap(find.byKey(AudiobookAvSyncStepper.readoutKey));
    await tester.pump();
    expect(calls.last, 0);
  });

  testWidgets('按住步进键连续调整，松手即停', (WidgetTester tester) async {
    await pumpPanel(tester);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(AudiobookAvSyncStepper.stepKey(50))),
    );
    // 长按识别（kLongPressTimeout）触发第一次，再等 500ms 进入每 100ms 连发。
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
    expect(calls, <int>[50]);
    await tester.pump(AudiobookRepeatIconButton.initialDelay);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls, <int>[50, 100, 150, 200]);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, hasLength(4), reason: '松手后不再连发');
    expect(readout(tester), '+200ms');
  });

  testWidgets('键盘：←/→ 50ms 一步，Shift+←/→ 1s 一步', (WidgetTester tester) async {
    await pumpPanel(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(calls, <int>[50]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(calls.last, -50);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(calls.last, 950);
    expect(readout(tester), '+950ms');
  });

  test('读数格式', () {
    expect(AudiobookAvSyncStepper.format(0), '0ms');
    expect(AudiobookAvSyncStepper.format(50), '+50ms');
    expect(AudiobookAvSyncStepper.format(-950), '-950ms');
    expect(AudiobookAvSyncStepper.format(1000), '+1.0s');
    expect(AudiobookAvSyncStepper.format(-1250), '-1.3s');
  });

  test('两处入口同一个步进器、写同一个偏好（setDelayMs），不逐行偏移', () {
    final String sheet = maskComments(
      File(
        'lib/src/media/audiobook/reader_quick_settings_sheet.dart',
      ).readAsStringSync(),
    );
    expect(sheet, contains('AudiobookAvSyncStepper('));
    expect(sheet, contains('onChanged: ctrl.setDelayMs'));
    expect(sheet, isNot(contains('_RepeatIconButton')));

    final String panel = maskComments(
      File(
        'lib/src/media/audiobook/lyrics_player/lyrics_av_sync_panel.dart',
      ).readAsStringSync(),
    );
    expect(panel, contains('AudiobookAvSyncStepper('));
    expect(panel, contains('showLyricsAnchoredPanel('));

    final String lyricsPart = maskComments(
      File(
        'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
      ).readAsStringSync(),
    );
    expect(lyricsPart, contains('onAvSyncPanel:'));
    expect(lyricsPart, contains('delayMs: ctrl.delayMs'));
    expect(lyricsPart, contains('onChanged: ctrl.setDelayMs'));
    expect(lyricsPart, contains('case LyricsControlItem.avSync:'));
  });
}
