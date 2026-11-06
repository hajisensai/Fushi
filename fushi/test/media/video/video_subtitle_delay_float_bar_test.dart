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
import 'package:fushi/src/media/video/video_top_float_bar_layer.dart';
import 'package:fushi/src/utils/components/fushi_focusable.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';

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

  // BUG-3254：浮条开着时用快捷键（z/x / Ctrl+Shift+←/→）改了页面延迟——页面只发
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

  // BUG-3440（反馈 B-yPx_on2A）：读数胶囊自带不透明底色与 cardRadius，焦点环原先
  // 用 FushiFocusable 默认的 8 半径画在胶囊下面，被底色盖住、只在四角漏出残段。
  testWidgets('读数胶囊聚焦：焦点环与胶囊同形并画在胶囊上面', (WidgetTester tester) async {
    await _pumpRow(
      tester,
      VideoSubtitleSyncRow(
        host: buildTestVideoHost(state: TestVideoHostState(delayMs: 0)),
        floatBar: true,
      ),
    );
    final Finder readout = find.byKey(
      const ValueKey<String>('video-subtitle-delay-readout'),
    );
    final Finder ring = find.descendant(
      of: find.descendant(of: readout, matching: find.byType(FushiFocusable)),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null,
      ),
    );
    Focus.of(tester.element(find.text('+0 ms'))).requestFocus();
    await tester.pumpAndSettle();

    final DecoratedBox box = tester.widget<DecoratedBox>(ring.first);
    final BoxDecoration deco = box.decoration as BoxDecoration;
    expect(box.position, DecorationPosition.foreground);
    expect(deco.borderRadius, FushiM3eShape.cardRadius);
    final Border border = deco.border! as Border;
    expect(border.top.color, isNot(Colors.transparent));
  });

  // 视频页界面缩放 ≠ 1 时，缩放层曾包在 Align 里面：它把整片画面当画布铺满并传紧
  // 约束，浮条表面被撑成盖住大半个画面的空白大板（maxWidth 也失效），挡住字幕上方
  // 的画面。浮条必须按内容收缩、贴在顶部。
  for (final double scale in <double>[1.0, 1.4, 0.8]) {
    testWidgets('浮条层 scale=$scale：表面按内容收缩、不铺满画面', (WidgetTester tester) async {
      const Size view = Size(1600, 900);
      await tester.binding.setSurfaceSize(view);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const Key surface = ValueKey<String>('bar-surface');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                const Positioned.fill(child: ColoredBox(color: Colors.black)),
                VideoTopFloatBarLayer(
                  scale: scale,
                  surfaceKey: surface,
                  child: VideoSubtitleSyncRow(
                    host: buildTestVideoHost(
                      state: TestVideoHostState(delayMs: -1700),
                    ),
                    floatBar: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Rect rect = tester.getRect(find.byKey(surface));
      // 一行控件的高度（缩放后），远小于画面高度的四分之一。
      expect(rect.height, lessThan(view.height / 4), reason: '$rect');
      expect(rect.width, lessThanOrEqualTo(720 * scale + 1), reason: '$rect');
      expect(rect.top, lessThan(40 * scale), reason: '$rect');
      expect(rect.center.dx, closeTo(view.width / 2, 1), reason: '$rect');
    });
  }
}
