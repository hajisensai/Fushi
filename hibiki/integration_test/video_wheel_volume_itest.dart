// TODO-1058 运行时端到端验证：桌面在视频「画面区」滚鼠标滚轮真的改音量，
// 且落在控制条 chrome 上的滚轮**不**改音量（`_isVideoChromePointer` 门控）。
//
// 现有 test/pages/video_wheel_volume_guard_test.dart 只在源码层锁接线契约
// （断言 `_handleVideoWheelSignal` 被挂到画面 Listener、门控分支存在），从不真跑
// 一次滚轮 → 观察音量真变。本文件补运行时缺口：启动真 app、seed 视频、焦点驱动
// 打开播放页、向画面区注入真实 [PointerScrollEvent]，读音量 level-HUD 的真值
// （`videoVolumeHudProgressKey` 的 [LinearProgressIndicator.value] = 音量/100，
// 由 `_showVolumeOsd` 在每次改音量后驱动，是被显示的权威音量真相源），断言：
//   ① 向上滚 → 音量真升；② 向下滚 → 音量真降；
//   ③ 门控反证：滚轮落在底栏 chrome 区 → 音量**不变**（chrome 指针不接管）。
//
// 滚轮事件本身就是被测输入（等同必须发方向键才能测方向键导航），故用
// GestureBinding.handlePointerEvent 注入 PointerScrollEvent 是合法的被测输入，
// 不是「用坐标点击做焦点确认」。开视频/切 tab 仍走焦点驱动（禁 tester.tap）。
//
// 运行：hibiki/ 下 `.\tool\run_windows_itest.ps1 integration_test\video_wheel_volume_itest.dart -Visible`
// （视频 media_kit 需 DWM 窗，必须 -Visible）。
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/video/video_book_repository.dart'
    show VideoBookRepository;
import 'package:hibiki/src/media/video/video_volume_overlays.dart'
    show videoVolumeHudProgressKey;
import 'package:hibiki/src/models/app_model.dart' show AppModel;
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart'
    show VideoHibikiPage, VideoHibikiTestHooks;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TODO-1058：视频画面区滚轮真改音量，chrome 区滚轮不接管',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[wheel-vol] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));

      // ── 1) seed 视频 + 直接 push 打开播放页 ───────────────────────────────
      // 用 Navigator.push(VideoHibikiPage) 直达（与 video_shader_focus_test 同范式）：
      // 离屏 IndexedStack 下焦点卡激活偶发不触发书卡 onTap（observe_media 亦见此
      // seed-not-visible warning），push 是确定性入口，避开 flaky 卡激活。开视频不是
      // 本测目标（滚轮调音量才是），故这里不强求焦点驱动。
      final String uid = await seedVideo(tester);
      final AppModel appModel = await readyAppModel(tester);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final NavigatorState navigator =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => VideoHibikiPage(bookUid: uid, repo: repo),
      )));

      // 等 controller load（debugPositionMs 可读即 controller 就绪；桌面控制条要
      // hover 才显示图标，不靠图标判就绪，与 video_shader_focus_test 一致）。
      VideoHibikiTestHooks hooks() =>
          tester.state<State<VideoHibikiPage>>(find.byType(VideoHibikiPage))
              as VideoHibikiTestHooks;
      bool ready = false;
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byType(VideoHibikiPage).evaluate().isNotEmpty &&
            hooks().debugPositionMs != null) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue, reason: 'video controller 应 load（debugPositionMs 可读）');

      // 真实播放，贴近用户在放视频时滚轮调音量的场景。
      await hooks().debugPlay();
      await tester.pump(const Duration(milliseconds: 600));

      // ── 2) 定位视频页几何：中心=画面区、底部=控制条 chrome 区 ────────────
      final Finder pageFinder = find.byType(VideoHibikiPage);
      final RenderBox pageBox =
          tester.renderObject<RenderBox>(pageFinder.first);
      final Offset topLeft = pageBox.localToGlobal(Offset.zero);
      final Size pageSize = pageBox.size;
      // 画面区中心：远离顶/底 chrome，_isVideoChromePointer 判定为「非 chrome」放行。
      final Offset pictureCenter =
          topLeft + Offset(pageSize.width / 2, pageSize.height / 2);
      // 底栏 chrome：贴近底边（bottomChromeTop 之下）；_isVideoChromePointer=true 不接管。
      final Offset bottomChrome =
          topLeft + Offset(pageSize.width / 2, pageSize.height - 6);

      // ── HUD 音量真值读取（videoVolumeHudProgressKey 的 LinearProgressIndicator
      //    .value = 音量/100，由 _showVolumeOsd 在每次改音量后驱动）。HUD 是瞬态
      //    （1.6s 后消失），故每次注入滚轮后立刻读。─────────────────────────────
      double? readHudVolumePercent() {
        final Finder hud = find.byKey(videoVolumeHudProgressKey);
        if (hud.evaluate().isEmpty) return null;
        final LinearProgressIndicator w =
            tester.widget<LinearProgressIndicator>(hud);
        final double? v = w.value;
        return v == null ? null : v * 100.0;
      }

      // 向指定全局位置注入一次真实鼠标滚轮（scrollDelta.dy：向下为正）。用
      // TestPointer 先 hover 到该点（注册鼠标指针位置，使随后的滚轮信号能命中该点
      // 的 RenderPointerListener），再 sendEventToBinding 发 scroll——这是 Flutter
      // 测试注入滚轮的规范路径，会走真实 hit-test 命中画面 Listener.onPointerSignal。
      final TestPointer wheelPointer =
          TestPointer(1, ui.PointerDeviceKind.mouse);
      Future<void> sendWheel(Offset at, double dy) async {
        await tester.sendEventToBinding(wheelPointer.hover(at));
        await tester.sendEventToBinding(wheelPointer.scroll(Offset(0, dy)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
      }

      // 建立音量基线：先向下滚几次把音量压到中段，确保上/下都有可观测余量，并让
      // HUD 出现读到确定基线值。dy>0（向下）= 音量减（_onVolumeWheel 取负号）。
      for (int i = 0; i < 6; i++) {
        await sendWheel(pictureCenter, 40);
      }
      final double? baseline = readHudVolumePercent();
      debugPrint('[wheel-vol] baseline=$baseline');
      expect(baseline, isNotNull,
          reason: '压低音量后音量 HUD 应出现并可读（说明画面区滚轮已被 '
              '_handleVideoWheelSignal 接管并改了音量）');
      expect(baseline!, lessThan(100.0),
          reason: '向下滚数次后音量应已低于满值（画面区滚轮真的在减音量）');

      // ── ① 画面区向上滚 → 音量真升 ─────────────────────────────────────────
      await sendWheel(pictureCenter, -40); // dy<0（向上）= 增
      await sendWheel(pictureCenter, -40);
      final double? afterUp = readHudVolumePercent();
      debugPrint('[wheel-vol] afterUp=$afterUp (baseline=$baseline)');
      expect(afterUp, isNotNull, reason: '向上滚后音量 HUD 应可读');
      expect(afterUp!, greaterThan(baseline),
          reason: '画面区向上滚音量应上升（$baseline → $afterUp）');

      // ── ② 画面区向下滚 → 音量真降 ─────────────────────────────────────────
      await sendWheel(pictureCenter, 40); // dy>0（向下）= 减
      await sendWheel(pictureCenter, 40);
      final double? afterDown = readHudVolumePercent();
      debugPrint('[wheel-vol] afterDown=$afterDown (afterUp=$afterUp)');
      expect(afterDown, isNotNull, reason: '向下滚后音量 HUD 应可读');
      expect(afterDown!, lessThan(afterUp),
          reason: '画面区向下滚音量应下降（$afterUp → $afterDown）');

      // ── ③ 门控反证：滚轮落在底栏 chrome 区 → 音量不变 ────────────────────
      // 先读一个稳定的「反证前」音量真值（再滚一次画面区确保 HUD 在场、拿到确定值）。
      await sendWheel(pictureCenter, 40);
      final double? beforeChrome = readHudVolumePercent();
      debugPrint('[wheel-vol] beforeChrome=$beforeChrome '
          'chromeAt=$bottomChrome (page=$pageSize)');
      expect(beforeChrome, isNotNull, reason: '反证前音量 HUD 应可读');
      // 向底栏 chrome 区连发多次滚轮：若画面级 handler 误接管，音量会明显变化。
      for (int i = 0; i < 5; i++) {
        await sendWheel(bottomChrome, -40); // 若被接管会「增大」音量，反证更敏感
      }
      final double? afterChrome = readHudVolumePercent();
      debugPrint('[wheel-vol] afterChrome=$afterChrome (before=$beforeChrome)');
      // afterChrome 可能为 null（HUD 已淡出且 chrome 滚轮没触发新 HUD）——那本身也
      // 证明 chrome 区滚轮没经画面级 handler 改音量（否则会刷出新音量 HUD）。
      if (afterChrome != null) {
        expect((afterChrome - beforeChrome!).abs(), lessThan(1.0),
            reason: 'chrome 区滚轮不应被画面级 handler 接管改音量'
                '（$beforeChrome → $afterChrome，应几乎不变）');
      } else {
        debugPrint('[wheel-vol] chrome 区滚轮未刷出新音量 HUD → 未接管（符合门控）');
      }

      // ── 4) 抓一帧作证据 ───────────────────────────────────────────────────
      // 再滚一次画面区让音量 HUD 在场，然后抓帧。
      await sendWheel(pictureCenter, -40);
      final ObserveShot shot =
          await captureFlutterFrame(tester, 'todo1058-wheel-volume-hud');
      expect(shot.saved, isTrue, reason: '证据帧应落盘');
      debugPrint('[wheel-vol] evidence=${shot.path} (${shot.bytes}B '
          'nonBlank=${shot.nonBlank})');

      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
