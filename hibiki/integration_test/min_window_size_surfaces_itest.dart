// TODO-1377 离屏验收：把真实 Windows 主窗口 resize 到最小尺寸下限
// [DesktopWindowPlacement.minimumSize]，遍历主要表面（书架 / 视频 / 查词 /
// 设置 / 词典管理页），断言：
//   1. OS 真接受了低于旧下限 (480x640) 的窗口外框尺寸（启动期
//      setMinimumSize 新值生效，不再被旧钳制挡住）；
//   2. 全程无布局溢出（RenderFlex "overflowed by ..."，FlutterError 收口，
//      启动期网络噪声除外）；
//   3. 词典管理页在 <480 逻辑宽下走 compact 手机分支（与页面同源的
//      MediaQuery 判据，见 dictionary_dialog_page.dart 的 width < 480）；
//   4. 每个表面 Flutter 帧截图落盘（.codex-test/windows-itest/<runId>/
//      screenshots/min-window-*.png）留证。
//
// 经 tool/run_windows_itest.ps1 跑；纯 Flutter UI 离屏可抓（layer.toImage，
// 与窗口可见性无关），无需 -Visible。
//
// 注意坐标口径：windowManager.setSize/getSize 是**窗口外框**逻辑尺寸；
// FlutterView.physicalSize 是 **client 区**（去掉标题栏/隐形边框），恒小于
// 外框。故外框断言对齐下限常量，client 区只断言「低于旧下限、不超新下限」。
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:hibiki/src/pages/implementations/media_sources_dialog.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';
import 'package:hibiki/src/startup/desktop_window_placement.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TODO-1377: 最小窗口下限下主要表面无布局溢出', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];

    /// 当前 Flutter 视图（client 区）的逻辑尺寸。
    Size logicalClientSize() {
      final ui.FlutterView view = tester.binding.platformDispatcher.views.first;
      return view.physicalSize / view.devicePixelRatio;
    }

    /// 收口断言：到目前为止没有任何布局溢出错误，失败信息带上表面名。
    void expectNoOverflow(String surface) {
      final List<FlutterErrorDetails> overflow = errors
          .where((FlutterErrorDetails e) =>
              e.exceptionAsString().toLowerCase().contains('overflowed'))
          .toList();
      expect(
        overflow,
        isEmpty,
        reason: '「$surface」在最小窗口下出现布局溢出：'
            '${overflow.map((e) => e.exceptionAsString()).join('; ')}',
      );
    }

    /// 抓当前表面 Flutter 帧留证 + 收口溢出断言。
    Future<void> sweepSurface(String surface) async {
      await tester.pump(const Duration(seconds: 1));
      final ObserveShot shot =
          await captureFlutterFrame(tester, 'min-window-$surface');
      expect(shot.saved, isTrue, reason: '「$surface」截图应落盘');
      expect(shot.nonBlank, isTrue,
          reason: '「$surface」不应是空白帧（${shot.path}, ${shot.bytes}B）');
      debugPrint('[min-window] $surface -> ${shot.path} (${shot.bytes}B)');
      expectNoOverflow(surface);
    }

    await runHibikiItest(
      label: 'min-window',
      collectedErrors: errors,
      body: () async {
        app.main();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        await tester.pump(const Duration(seconds: 2));

        // 播种一本书：书架在最小宽度下要渲染真实书卡（空态卡不出书卡布局的溢出）。
        await seedReaderBook(tester);

        // 把真实窗口外框缩到下限。启动期 applyInitialPlacement 已按新常量
        // setMinimumSize；若 OS 仍按旧下限 (480x640) 钳制，下面的外框实测断言
        // 会失败。
        const Size minSize = DesktopWindowPlacement.minimumSize;
        await windowManager.setSize(minSize);
        Size outer = await windowManager.getSize();
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          outer = await windowManager.getSize();
          if ((outer.width - minSize.width).abs() <= 2 &&
              (outer.height - minSize.height).abs() <= 2) {
            break;
          }
        }
        final Size client = logicalClientSize();
        debugPrint('[min-window] resized: outer=$outer client=$client '
            'target=$minSize');
        expect(outer.width, closeTo(minSize.width, 2),
            reason: '窗口外框宽应真被缩到下限 ${minSize.width}（实测 ${outer.width}，'
                '若仍 >=480 说明最小尺寸钳制没放开）');
        expect(outer.height, closeTo(minSize.height, 2),
            reason: '窗口外框高应真被缩到下限 ${minSize.height}（实测 ${outer.height}，'
                '若仍 >=640 说明最小尺寸钳制没放开）');
        // client 区（Flutter 逻辑视口）必须已低于旧下限、且不超新下限外框。
        expect(client.width, lessThan(480),
            reason: 'client 逻辑宽应 <480（词典 dialog compact 分支可达）');
        expect(client.height, lessThan(640));
        expect(client.width, lessThanOrEqualTo(minSize.width + 2));

        // 主要表面遍历：书架 / 视频 / 查词 / 设置。
        expect(HomePage.debugSelectTab, isNotNull,
            reason: 'HomePage 切 tab 测试钩子应已注册（debug/profile build）');
        HomePage.debugSelectTab!(HomeTab.books);
        await sweepSurface('shelf');
        HomePage.debugSelectTab!(HomeTab.video);
        await sweepSurface('video');
        HomePage.debugSelectTab!(HomeTab.dictionaries);
        await sweepSurface('lookup');
        HomePage.debugSelectTab!(HomeTab.settings);
        await sweepSurface('settings');

        // 词典管理页（TODO-1377 特别关注面）：<480 逻辑宽下必须走 compact
        // 手机分支——用与页面同源的 MediaQuery 判据验证分支真的生效。
        // 先切回书架作干净基座（设置 tab 有自绘全屏外壳），再经 AppModel 走
        // 与「菜单打开词典管理」同源的 showDictionaryMenu 推页面路由。
        HomePage.debugSelectTab!(HomeTab.books);
        await tester.pump(const Duration(seconds: 1));
        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        unawaited(appModel.showDictionaryMenu());
        // 页面路由过渡 + 首帧挂载有时序，轮询等 DictionaryDialogPage 真挂上，
        // 不靠单次固定 pump。
        final Finder dialogFinder = find.byType(DictionaryDialogPage);
        for (int i = 0; i < 40 && dialogFinder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(dialogFinder, findsOneWidget, reason: '词典管理页应已打开');
        // 同步闭包内现取 element 再读 MediaQuery，不把 BuildContext 变量跨
        // async gap 持有（use_build_context_synchronously）。
        double dialogLogicalWidth() =>
            MediaQuery.sizeOf(tester.element(dialogFinder)).width;
        expect(dialogLogicalWidth(), lessThan(480),
            reason: '最小窗口下词典管理页应走 <480 compact 手机分支');
        await sweepSurface('dict-dialog-compact');
        // 经根 NavigatorState 关掉词典管理页（State 不是 BuildContext，可跨 await）。
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pump(const Duration(seconds: 1));

        // TODO-1389：TODO-1377 未覆盖的弹窗表面——「管理来源库」对话框 body
        // （HibikiReorderableColumn）在最小窗高下若不套滚动视口会 RenderFlex 底部溢出。
        // 播种 24 条来源（远超受限 body 高度）后打开对话框，扫掠断言无溢出（修后应整体
        // 滚动而非出框）。种到隔离库（FUSHI_TEST_ROOT），不碰真实数据。
        for (int i = 0; i < 24; i++) {
          await appModel.database.insertMediaSource(
            MediaSourcesCompanion.insert(
              label: 'itest_src_$i',
              mediaKind: 'book',
              rootPath: '/tmp/itest_src_$i',
              createdAt: i,
            ),
          );
        }
        // 经根 NavigatorState 推 DialogRoute（State 可跨 await，不触
        // use_build_context_synchronously；navigator.context 仅用于捕获继承主题，
        // 与 showDialog 内部一致）。
        final NavigatorState rootNavigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);
        unawaited(rootNavigator.push(DialogRoute<void>(
          // rootNavigator 是刚从树里取到的活 State（必然 mounted），context 立即被
          // DialogRoute 同步消费用于捕获继承主题；lint 的跨 await 告警在此为误报。
          // ignore: use_build_context_synchronously
          context: rootNavigator.context,
          builder: (_) => const MediaSourcesDialog(mediaKind: 'book'),
        )));
        final Finder mediaSourcesFinder = find.byType(MediaSourcesDialog);
        for (int i = 0; i < 40 && mediaSourcesFinder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(mediaSourcesFinder, findsOneWidget, reason: '来源库对话框应已打开');
        await sweepSurface('media-sources');
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pump(const Duration(seconds: 1));
      },
    );
  });
}
