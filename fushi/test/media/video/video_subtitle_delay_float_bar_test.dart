// 浮条调轴（反馈 JsICLVdq0i：手动调字幕延迟时字幕被设置面板挡住、看不到实时效果；
// 往返多次才调准，希望有 asbplayer 那种「上一句 / 下一句对齐到此刻」）。
//
// 设置面板「字幕调轴」行多一枚浮条按钮 → 页面收起面板、在画面顶部挂一条只含调轴
// 控件的浮条（VideoSubtitleSyncRow.floatBar）；浮条里有 ±步进、可点按输入的读数、
// 上 / 下一句对齐到此刻、完成。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_quick_settings_host.dart';
import 'package:fushi/src/media/video/video_subtitle_sync_row.dart';

import '../../helpers/video_quick_settings_harness.dart';

Future<void> _pumpRow(WidgetTester tester, Widget row) async {
  await tester.binding.setSurfaceSize(const Size(900, 400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(child: Material(child: row)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('float bar: steppers, snap-to-cue, inline input and done', (
    WidgetTester tester,
  ) async {
    final List<int> delays = <int>[];
    final List<bool> snaps = <bool>[];
    int done = 0;
    final VideoQuickSettingsHost host = buildTestVideoHost(
      state: TestVideoHostState(delayMs: -2000),
      onSetDelay: delays.add,
      onSnapDelayToCue: ({required bool next}) {
        snaps.add(next);
        return next ? 1500 : -500;
      },
    );
    await _pumpRow(
      tester,
      VideoSubtitleSyncRow(host: host, floatBar: true, onDone: () => done++),
    );

    // 浮条只有紧凑控件：没有滑条（那些要面积的控件留在面板里）。
    expect(find.byType(Slider), findsNothing);
    expect(find.text('-2000 ms'), findsOneWidget);
    // 浮条里不再出「浮条」入口本身。
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-delay-float')),
      findsNothing,
    );

    // +50ms 步进即时写穿。
    await tester.tap(find.byTooltip('+50ms'));
    await tester.pumpAndSettle();
    expect(delays.last, -1950);
    expect(find.text('-1950 ms'), findsOneWidget);

    // 「下一句对齐到此刻」：一步求出绝对偏移并同步读数。
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-delay-snap-next')),
    );
    await tester.pumpAndSettle();
    expect(snaps, <bool>[true]);
    expect(delays.last, 1500);
    expect(find.text('+1500 ms'), findsOneWidget);

    // 读数点按即原地输入（「当前延迟」与「手动输入」合成一行）。
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-delay-readout')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-subtitle-delay-input')),
      '-320',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(delays.last, -320);
    expect(find.text('-320 ms'), findsOneWidget);

    // 归零钮只在非零时出现。
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-delay-reset')),
    );
    await tester.pumpAndSettle();
    expect(delays.last, 0);
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-delay-reset')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-delay-bar-done')),
    );
    expect(done, 1);
  });

  testWidgets('panel row offers the float-bar entry when the page wires it', (
    WidgetTester tester,
  ) async {
    int entered = 0;
    await _pumpRow(
      tester,
      SingleChildScrollView(
        child: VideoSubtitleSyncRow(
          host: buildTestVideoHost(onEnterSubtitleDelayBar: () => entered++),
        ),
      ),
    );
    final Finder entry = find.byKey(
      const ValueKey<String>('video-subtitle-delay-float'),
    );
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    expect(entered, 1);
  });

  testWidgets('no float-bar entry without a player page', (
    WidgetTester tester,
  ) async {
    await _pumpRow(
      tester,
      SingleChildScrollView(
        child: VideoSubtitleSyncRow(host: buildTestVideoHost()),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-delay-float')),
      findsNothing,
    );
  });

  // BUG-3231：浮条开着时用快捷键（z/x / Ctrl+Shift+←/→）改了页面延迟——页面只发
  // OSD、不重建浮条，此前读数停在旧值，再点 ± 以旧镜像为基数把快捷键的调整覆盖掉。
  testWidgets('float bar follows delay changed outside the row (shortcuts)', (
    WidgetTester tester,
  ) async {
    final TestVideoHostState state = TestVideoHostState(delayMs: 0);
    final ValueNotifier<int> controllerTicks = ValueNotifier<int>(0);
    addTearDown(controllerTicks.dispose);
    final List<int> delays = <int>[];
    await _pumpRow(
      tester,
      VideoSubtitleSyncRow(
        host: buildTestVideoHost(
          state: state,
          onSetDelay: delays.add,
          subtitlePositionListenable: controllerTicks,
        ),
        floatBar: true,
      ),
    );
    expect(find.text('+0 ms'), findsOneWidget);

    // 快捷键路径：页面权威值变了，controller 随 setDelayMs 立即 notify。
    state.delayMs = 300;
    controllerTicks.value++;
    await tester.pumpAndSettle();
    expect(find.text('+300 ms'), findsOneWidget);

    // 再点 +50：以 300 为基数，而不是旧镜像 0。
    await tester.tap(find.byTooltip('+50ms'));
    await tester.pumpAndSettle();
    expect(delays.last, 350);
    expect(find.text('+350 ms'), findsOneWidget);

    // 即便没有任何通知（页面没挂 controller），± 也以页面权威值为基数。
    state.delayMs = -1000;
    await tester.tap(find.byTooltip('-50ms'));
    await tester.pumpAndSettle();
    expect(delays.last, -1050);
  });
}
