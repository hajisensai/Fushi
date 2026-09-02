// BUG-2030 真机端到端：键盘跳句/seek 只**续命**控制条(OSC)，不把隐藏的它唤起。
//
// 源码守卫（test/pages/video_controls_poke_guard_test.dart）只能锁接线——媒体页
// headless 跑不了 media_kit，合成 hover → fork `onHover` → `visible=true` 这条真实
// 链路在单测里根本不存在。本文件在真 Windows 桌面 app 上跑原始失败路径：
//
//   ① 控制条隐藏态按 Ctrl+→（下一句字幕）→ 断言控制条**仍隐藏**，且播放位置真变了
//      （证明快捷键确实执行了，不是「什么都没发生」这种假绿）。旧实现在这里会把底栏
//      整个弹出来 + 字幕上顶一次，正是用户报的「快捷键上下句字幕会弹出 OSC」。
//   ② 控制条可见态（真实鼠标 hover 唤起）下按 Ctrl+→ → 断言它**不被反手收起**
//      （键盘既不唤起也不收起），并用「真实 hover 每 <2s 挪一次、跨过两个
//      `_videoControlsHoverDuration`(2s) 仍可见」做对照组，证明本环境里
//      「hover → fork onHover → 重置隐藏 Timer」链路是通的。
//      **键盘续命那一半跑不出真值**（合成 hover 在 integration_test binding 下
//      不触发 MouseRegion.onHover，实测见文件末尾说明），故不在此断言、也不宣称
//      已验证；它由 BUG-176 ②/BUG-215 的用户实测 + 源码守卫背书。
//
// 真相源是页面 test hook `debugControlsVisible`（= fork 推来的
// `_mediaKitControlsVisible`，控制条 State 每次改 `visible` 都推送），不是任何镜像。
//
// hover 是**被测输入**（等同必须发方向键才能测方向键），故用
// GestureBinding.handlePointerEvent 注入真实 PointerHoverEvent 是合法输入注入，
// 不是「用坐标点击做焦点确认」；键盘走 tester.sendKey*，全程无 tester.tap。
//
// 运行：fushi/ 下
//   .\tool\run_windows_itest.ps1 integration_test\video_keyboard_controls_keepalive_itest.dart -Visible
// （media_kit 控制条要 DWM 合成，用 -Visible；窗口非激活，不抢焦点。）
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';

import 'test_helpers.dart';

/// 本机测试视频（与 video_shader_focus_test 同一份 fixture）。
const String _kVideoFixture = r'D:\hibiki_video_test\sample.mp4';
const String _kVideoBookUid = 'video/keepalive-itest-sample';

/// 真实鼠标设备 id：**不得**用页面的合成 hover 设备（`_syntheticHoverDevice`），
/// 否则会被 `_isSyntheticControlsHover` 当成自己派的 poke 过滤掉记账。
const int _kRealMouseDevice = 1;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-2030: keyboard cue-skip keeps controls alive but never wakes them',
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[keepalive] ${details.exceptionAsString()}');
      };

      try {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        final VideoBookRepository repo = VideoBookRepository(appModel.database);

        final File fixture = File(_kVideoFixture);
        expect(fixture.existsSync(), isTrue,
            reason: '测试视频 $_kVideoFixture 应存在');
        await repo.saveVideoBook(VideoBooksCompanion(
          bookUid: const Value(_kVideoBookUid),
          title: const Value('keepalive itest'),
          videoPath: Value(fixture.absolute.path),
        ));

        final NavigatorState navigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);
        unawaited(navigator.push<void>(MaterialPageRoute<void>(
          builder: (_) => VideoFushiPage(bookUid: _kVideoBookUid, repo: repo),
        )));

        VideoFushiTestHooks hooks() =>
            tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
                as VideoFushiTestHooks;

        // 第二个、与 hook 相互独立的真相源：media_kit 控制条自身那层
        // `AnimatedOpacity(opacity: visible ? 1.0 : 0.0)`（fork
        // material_desktop.dart 的控制条外壳）。只信 `debugControlsVisible` 有风险
        // ——若 fork 的 `visibilityNotifier` 没接上，它会一直停在初值 false，
        // 「控制条没弹出来」就成了假绿。两个来源必须一致。
        double? controlsOpacity() {
          final Finder f = find.descendant(
            of: find.byType(Video),
            matching: find.byType(AnimatedOpacity),
          );
          if (f.evaluate().isEmpty) return null;
          return tester.widget<AnimatedOpacity>(f.first).opacity;
        }

        bool ready = false;
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (find.byType(VideoFushiPage).evaluate().isNotEmpty &&
              hooks().debugPositionMs != null) {
            ready = true;
            break;
          }
        }
        expect(ready, isTrue, reason: 'video controller should load');

        // 键盘焦点交给 Video（离屏 push 不经真实点击，显式请求，与
        // video_shader_focus_test 同范式）。页面自己的焦点所有权逻辑刚 push 完还在
        // 过渡，一次 requestFocus + 200ms 抢不稳，故轮询重试；**不**在这里硬断言
        // hasFocus——快捷键挂在页面外层 Shortcuts 上，焦点落在页面任一后代都能命中，
        // 「按键到底生没生效」由下面的播放位置断言判定，那才是被测的东西。
        final FocusNode videoNode =
            tester.widget<Video>(find.byType(Video)).focusNode!;
        for (int i = 0; i < 20 && !videoNode.hasFocus; i++) {
          videoNode.requestFocus();
          await tester.pump(const Duration(milliseconds: 150));
        }
        debugPrint('[keepalive] videoNode.hasFocus=${videoNode.hasFocus} '
            'primaryFocus=${FocusManager.instance.primaryFocus?.debugLabel}');

        Future<void> pressCtrlRight() async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump(const Duration(milliseconds: 120));
        }

        // ── ① 隐藏态：跳句不得唤起控制条 ────────────────────────────────────
        // 先确保控制条处于隐藏态：离屏/无鼠标时它本就没被唤起过；保险起见等过一个
        // hover duration（2s）再确认。
        for (int i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (!hooks().debugControlsVisible) break;
        }
        debugPrint('[keepalive] pre: visible=${hooks().debugControlsVisible} '
            'opacity=${controlsOpacity()}');
        expect(hooks().debugControlsVisible, isFalse,
            reason: '前置条件：本步开始时控制条应已隐藏');
        expect(controlsOpacity(), 0.0,
            reason: '前置条件：控制条自身的透明度也应为 0（两个真相源必须一致）');

        final int? posBefore = hooks().debugPositionMs;
        debugPrint('[keepalive] pos before Ctrl+Right: $posBefore');
        await pressCtrlRight();
        for (int i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        final int? posAfter = hooks().debugPositionMs;
        debugPrint('[keepalive] pos after Ctrl+Right: $posAfter '
            'controlsVisible=${hooks().debugControlsVisible}');

        // 正向证据：快捷键真的执行了（有字幕跳下一句、无字幕退化前进 seekSeconds 秒），
        // 否则「控制条没弹出来」可能只是因为按键压根没生效。
        expect(posAfter, isNotNull);
        expect(posAfter != posBefore, isTrue,
            reason: 'Ctrl+→ 应真的改变播放位置（否则下面的断言是假绿）');
        // 本 bug 的断言：隐藏的控制条不得被键盘唤起。两个真相源一起断，
        // 单靠 notifier 万一没接上就是假绿。
        expect(hooks().debugControlsVisible, isFalse,
            reason: 'BUG-2030：键盘跳句不得把隐藏的控制条(OSC)弹出来');
        expect(controlsOpacity(), 0.0,
            reason: 'BUG-2030：控制条自身也必须仍然全透明（没被唤起）');

        // ── ② 可见态：连按跳句必须续命（BUG-176 ②/BUG-215 不回归）──────────
        // 真实鼠标 hover 唤起控制条（走 media_kit 自己的 MouseRegion）。必须用
        // `createGesture(kind: mouse)` + `addPointer` 让 MouseTracker 真正登记这个
        // 设备——裸 `handlePointerEvent(PointerHoverEvent)` 在测试环境里不会让
        // MouseRegion 收到 enter/hover（设备从未 added，实测第一版就卡在这里）。
        final RenderBox videoBox =
            tester.renderObject<RenderBox>(find.byType(Video));
        final Offset center =
            videoBox.localToGlobal(videoBox.size.center(Offset.zero));
        final TestGesture mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          pointer: _kRealMouseDevice,
        );
        await mouse.addPointer(location: center - const Offset(0, 40));
        addTearDown(() => mouse.removePointer());
        await tester.pump(const Duration(milliseconds: 100));

        bool woke = false;
        for (int i = 0; i < 12 && !woke; i++) {
          // 每次挪 1px，避开 MouseTracker 的同坐标去重（与 BUG-215 同一机制）。
          await mouse.moveTo(center + Offset(i.toDouble(), 0));
          await tester.pump(const Duration(milliseconds: 100));
          woke = hooks().debugControlsVisible;
        }
        debugPrint('[keepalive] after hover: visible=$woke '
            'opacity=${controlsOpacity()}');
        expect(woke, isTrue,
            reason: '真实鼠标 hover 应能唤起控制条（唤起权仍在指针通道）；'
                '这条同时证明 debugControlsVisible 真的跟着 fork 的 visible 走，'
                '上面那条「没被唤起」不是初值假绿');

        // 可见态下按跳句：控制条**不得**被键盘操作反手收起（可见性只归 media_kit
        // 的隐藏 Timer 管，键盘既不唤起也不收起）。
        final int? visiblePosBefore = hooks().debugPositionMs;
        await pressCtrlRight();
        for (int i = 0; i < 2; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        debugPrint('[keepalive] visible-state skip: '
            'pos $visiblePosBefore -> ${hooks().debugPositionMs} '
            'visible=${hooks().debugControlsVisible} '
            'opacity=${controlsOpacity()}');
        expect(hooks().debugPositionMs != visiblePosBefore, isTrue,
            reason: '可见态下 Ctrl+→ 也应真的跳句');
        expect(hooks().debugControlsVisible, isTrue,
            reason: '键盘跳句不得反手把正在显示的控制条收起来');

        // 真实 hover 续命：每 <2s 挪一次鼠标，跨过两个 `_videoControlsHoverDuration`
        // (2s) 后控制条仍可见。这条是**对照组**——它证明本测试环境里「hover →
        // fork onHover → 重置隐藏 Timer」这条链路本身是通的，可见态失效不是控制条坏了。
        for (int round = 0; round < 2; round++) {
          await mouse.moveTo(center + Offset(20.0 + round, 0));
          for (int i = 0; i < 7; i++) {
            await tester.pump(const Duration(milliseconds: 200));
          }
          debugPrint('[keepalive] hover-keepalive round $round '
              'visible=${hooks().debugControlsVisible}');
          expect(hooks().debugControlsVisible, isTrue,
              reason: '真实 hover 每 <2s 一次应续住控制条（对照组）');
        }

        // ── 关于「键盘续命」那一半为什么不在这里断言 ────────────────────────
        // 实测（本文件的诊断跑，evidence: .codex-test/windows-itest/
        // win-itest-20260902-140154-57390207）：可见态下每 1.32s 按一次 Ctrl+→，
        // 播放位置逐轮在变（按键确实生效），但控制条仍在 hover 的 2s 到期时消失 ——
        // `_pokeControlsVisible` 派的**合成** PointerHoverEvent 在
        // integration_test binding 下不触发 media_kit 的 MouseRegion.onHover
        // （同一原因让本文件第一版用裸 handlePointerEvent 注入 hover 也唤不起控制条，
        // 换成 tester.createGesture(kind: mouse) + addPointer 才通）。
        // 这是**测试环境限制，不是回归**：BUG-2030 没有动 `_pokeControlsVisible` 的
        // 派发逻辑，可见态下 `_keepControlsAliveIfVisible` 命中后调用的就是改动前那个
        // poke，字节级相同。键盘续命的真机有效性由 BUG-176 ②/BUG-215 的用户实测背书，
        // 接线由源码守卫（test/pages/video_controls_poke_guard_test.dart）锁死。
        // 不在这里写一条跑不出真值的断言，也不把它标成已验证。

        expect(errors, isEmpty,
            reason: errors.map((e) => e.exceptionAsString()).join('\n'));
      } finally {
        FlutterError.onError = oldHandler;
        try {
          final ProviderContainer container = ProviderScope.containerOf(
            tester.element(find.byType(MaterialApp).first),
          );
          final FushiDatabase db = container.read(appProvider).database;
          await (db.delete(db.videoBooks)
                ..where((VideoBooks t) => t.bookUid.equals(_kVideoBookUid)))
              .go();
        } catch (_) {}
      }
    },
    skip: !Platform.isWindows /* needs Windows desktop + media_kit native */,
  );
}
