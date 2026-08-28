import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/panel_focus_scope.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 回归守卫（TODO-755 回归 c152fcd91 / BUG-1864）：视频按空格无反应。
///
/// 根因两层：
/// ① 全局导航层 [wrapWithGlobalNavigation] 无条件把裸空格中和成 [DoNothingIntent]
///    （`global_navigation.dart`，[DoNothingAction.consumesKey] 为 true → 真消费按键），
///    所以视频页**必须**在它之下、离视频更近的地方自己接住裸空格；
/// ② 而「接住的地方」历史上一直不是整页：先是 media_kit controls 的
///    `keyboardShortcuts`（只包 `AdaptiveVideoControls` 子树），后是页面 Scaffold 上的
///    局部覆盖（全屏是推到根 navigator 的独立路由、不经过 Scaffold）。焦点一落到那两个
///    子树之外（[PanelFocusScope] 把焦点领进字幕列表 / 剧集轨 / 侧栏就是最常见的一种），
///    裸空格就上浮到全局中和层被吞 =「按了没反应」。
///
/// 方案 D 之后键盘只剩**一个**挂载点：[_wrapVideoGamepadControls] 的
/// `Focus.onKeyEvent` → press-time 的 [resolveVideoKeyboardShortcut]。它是窗口
/// `build()` 与全屏路由 `pageBuilder` 的唯一共同外层，也是所有子焦点节点的共同祖先，声明的作用域
/// （[ShortcutScope.video]，整页）第一次与物理挂载点对齐。
///
/// [VideoFushiPage] 驱动 media_kit、无法离屏整页 widget 测试，故本测试用与真实拓扑同构
/// 的最小 widget 树 + **生产的判决函数与真注册表默认绑定**（不在测试里另写一份键位）。
void main() {
  FushiShortcutRegistry defaults() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  /// 复刻生产 [_handleVideoKeyboardShortcut]：取页面态 → 问
  /// [resolveVideoKeyboardShortcut] → 按判决执行。测试只提供页面态，判据一律走
  /// 生产纯函数。
  KeyEventResult Function(FocusNode, KeyEvent) videoKeyboardChannel({
    required FushiShortcutRegistry registry,
    required List<ShortcutAction> log,
    bool panelHoldsFocusNavigation = false,
    bool videoSurfaceHoldsFocus = false,
  }) {
    return (FocusNode node, KeyEvent event) {
      final VideoKeyboardResolution resolution = resolveVideoKeyboardShortcut(
        registry,
        event,
        modifiers: currentKeyboardModifiers(HardwareKeyboard.instance),
        hasEditableFocus: false,
        hasVisiblePopup: false,
        videoSurfaceHoldsFocus: videoSurfaceHoldsFocus,
        panelHoldsFocusNavigation: panelHoldsFocusNavigation,
      );
      switch (resolution.dispatch) {
        case VideoKeyboardDispatch.ignore:
          return KeyEventResult.ignored;
        case VideoKeyboardDispatch.dismissPopup:
          return KeyEventResult.handled;
        case VideoKeyboardDispatch.run:
          log.add(resolution.action!);
          return KeyEventResult.handled;
      }
    };
  }

  /// 复刻真实拓扑：全局导航层（裸空格 → DoNothingIntent）在外，页级键盘通道在内，
  /// 最里是一个普通可聚焦子节点（**不是**视频画面节点）。[pageLevelChannel] 为 false
  /// 时去掉页级通道，用作「未修复 = 被全局吞掉」的负向对照。
  Future<List<ShortcutAction>> pumpAndCollect(
    WidgetTester tester, {
    required bool pageLevelChannel,
  }) async {
    final List<ShortcutAction> log = <ShortcutAction>[];
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode genericNode = FocusNode(debugLabel: 'generic-not-video');
    addTearDown(genericNode.dispose);

    Widget child = Focus(
      focusNode: genericNode,
      child: const SizedBox(width: 100, height: 100),
    );
    if (pageLevelChannel) {
      child = Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: videoKeyboardChannel(registry: defaults(), log: log),
        child: child,
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: wrapWithGlobalNavigation(
          navigatorKey: navKey,
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );

    // 关键：不调任何「视频节点」的 requestFocus；焦点只落在一个普通子节点上，
    // 模拟「焦点在视频页子树内但不精确在 _videoFocusNode」的真实使用路径。
    genericNode.requestFocus();
    await tester.pump();
    expect(genericNode.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    return log;
  }

  testWidgets(
    '页级键盘通道在焦点不精确落在视频节点时仍触发播放/暂停（修复）',
    (WidgetTester tester) async {
      expect(
        await pumpAndCollect(tester, pageLevelChannel: true),
        <ShortcutAction>[ShortcutAction.videoTogglePlayPause],
        reason: '焦点落在视频页子树任意节点上时，裸空格必须先被页级通道解析成 '
            'videoTogglePlayPause，永不下沉到全局 DoNothingIntent',
      );
    },
  );

  testWidgets(
    '负向对照：没有页级通道时裸空格被全局 DoNothingIntent 吞掉（复现回归）',
    (WidgetTester tester) async {
      expect(
        await pumpAndCollect(tester, pageLevelChannel: false),
        isEmpty,
        reason: '撤掉页级通道即回归 c152fcd91：裸空格被全局中和层吞掉，'
            '视频「按了没反应」',
      );
    },
  );

  /// BUG-1864 的真实拓扑复刻：**全屏是推到根 navigator 的独立路由**，页面 Scaffold
  /// 不在它的祖先链上。路由内容包一层与生产 `_wrapVideoGamepadControls` 同位的 wrapper
  /// （[routeLevelChannel] 决定它是否带页级键盘通道），里面挂真的 [PanelFocusScope]——
  /// 它正是字幕列表 / 剧集轨 / 侧栏打开时把焦点从视频画面抢走的那个组件。
  Future<List<ShortcutAction>> pumpFullscreenRouteAndCollect(
    WidgetTester tester, {
    required bool routeLevelChannel,
  }) async {
    final List<ShortcutAction> log = <ShortcutAction>[];
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: wrapWithGlobalNavigation(
          navigatorKey: navKey,
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );

    // 全屏：推到 root navigator 的独立路由（与 fullscreen.part.dart 同构）。
    unawaited(
      navKey.currentState!.push<void>(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, __, ___) {
            Widget content = PanelFocusScope(
              visible: true,
              child: Material(
                child: TextButton(
                  onPressed: () {},
                  child: const Text('面板里的按钮'),
                ),
              ),
            );
            if (routeLevelChannel) {
              content = Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: videoKeyboardChannel(
                  registry: defaults(),
                  log: log,
                  // 面板开着 —— 但空格不是焦点导航键，不该受让位影响。
                  panelHoldsFocusNavigation: true,
                ),
                child: content,
              );
            }
            return content;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // PanelFocusScope 自己把焦点移进面板（不在测试里手动 requestFocus 视频节点），
    // 这正是用户「打开右侧字幕列表后按空格」的真实焦点归属。
    expect(
      FocusManager.instance.primaryFocus?.context?.widget,
      isNotNull,
      reason: '面板打开后焦点必须落在面板内某个可聚焦节点上',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    return log;
  }

  testWidgets(
    'BUG-1864：全屏路由内面板持焦时裸空格仍触发播放/暂停（修复）',
    (WidgetTester tester) async {
      expect(
        await pumpFullscreenRouteAndCollect(tester, routeLevelChannel: true),
        <ShortcutAction>[ShortcutAction.videoTogglePlayPause],
        reason: '键盘通道挂到窗口/全屏共用的 wrapper 后，全屏下打开字幕列表'
            '（PanelFocusScope 抢焦）按空格必须照常播放/暂停',
      );
    },
  );

  testWidgets(
    'BUG-1864 负向对照：全屏路由没有键盘通道时裸空格被全局中和吞掉（复现）',
    (WidgetTester tester) async {
      expect(
        await pumpFullscreenRouteAndCollect(tester, routeLevelChannel: false),
        isEmpty,
        reason: '通道只挂在页面 Scaffold（不在全屏路由祖先链上）时即回归 BUG-1864：'
            '面板持焦后裸空格一路冒到 _neutralizeBareSpace 被吞，「按了没反应」',
      );
    },
  );

  /// 方案 D 的另一半：整张表上提到页级之后，**方向键**在面板持焦时必须让位给通用焦点
  /// 遍历，否则用户一开字幕列表就再也用不了上下键选行（方向键在注册表里绑着 seek /
  /// 音量）。这是手柄侧 `isVideoPanelFocusNavButton` 的键盘对应物。
  Future<({List<ShortcutAction> log, bool focusMoved})>
      pumpPanelArrowAndCollect(
    WidgetTester tester, {
    required bool panelHoldsFocusNavigation,
  }) async {
    final List<ShortcutAction> log = <ShortcutAction>[];
    final FocusNode first = FocusNode(debugLabel: 'panel-row-1');
    final FocusNode second = FocusNode(debugLabel: 'panel-row-2');
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: videoKeyboardChannel(
            registry: defaults(),
            log: log,
            panelHoldsFocusNavigation: panelHoldsFocusNavigation,
          ),
          child: Material(
            child: Column(
              children: <Widget>[
                TextButton(
                  focusNode: first,
                  onPressed: () {},
                  child: const Text('行 1'),
                ),
                TextButton(
                  focusNode: second,
                  onPressed: () {},
                  child: const Text('行 2'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    first.requestFocus();
    await tester.pump();
    expect(first.hasPrimaryFocus, isTrue, reason: '前置条件：焦点先落在面板第一行');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    return (log: log, focusMoved: second.hasPrimaryFocus);
  }

  testWidgets('面板持焦：裸方向键让位给焦点遍历，不解析成音量', (WidgetTester tester) async {
    final ({List<ShortcutAction> log, bool focusMoved}) r =
        await pumpPanelArrowAndCollect(tester, panelHoldsFocusNavigation: true);
    expect(r.log, isEmpty, reason: '面板持焦时裸 ↓ 不得被解析成 videoVolumeDown');
    expect(r.focusMoved, isTrue,
        reason: '不消费 → 冒泡到 WidgetsApp 的 DirectionalFocusIntent，焦点应移到下一行');
  });

  testWidgets('负向对照：没有面板时裸方向键照常调音量、焦点不动', (WidgetTester tester) async {
    final ({List<ShortcutAction> log, bool focusMoved}) r =
        await pumpPanelArrowAndCollect(
            tester, panelHoldsFocusNavigation: false);
    expect(r.log, <ShortcutAction>[ShortcutAction.videoVolumeDown],
        reason: '没有面板时方向键仍是视频动作——让位判据必须真的由面板态驱动，'
            '而不是无条件放行（那等于把方向键从视频快捷键里删掉）');
    expect(r.focusMoved, isFalse, reason: '被消费掉就不该再触发焦点遍历');
  });

  test('视频快捷键的唯一键盘挂载点是窗口/全屏共用的 wrapper（源码守卫）', () {
    final String src = maskComments(readVideoFushiSource());

    // ① press-time 派发方法存在，且判据走生产纯函数（不在页面里另写一份解析）。
    final int start = src.indexOf('bool _handleVideoKeyboardShortcut(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '_handleVideoKeyboardShortcut 派发方法必须存在');
    final int end = src.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body, contains('resolveVideoKeyboardShortcut('),
        reason: '判据必须走生产纯函数，页面不得另写一份键位解析');
    expect(body, contains('videoActionCallbacks('),
        reason: '执行体必须与手柄通道共用 videoActionCallbacks，两条通道行为才一致');
    expect(body, contains('_videoNavigablePanelOpen'),
        reason: '面板态必须喂进判决，否则方向键在面板里不会让位给焦点遍历');
    expect(body, contains('_videoFocusNode.hasPrimaryFocus'),
        reason: '画面持焦是 videoEnterCaret 放行判据的输入，不能省');

    // ② 挂载点必须是 [_wrapVideoGamepadControls]——窗口 build() 与全屏路由
    // pageBuilder 的**唯一共同外层**。挂在 _buildScaffold 上时全屏路由（推到根
    // navigator 的独立路由）根本没有这层（BUG-1864）。
    final int wrapperStart = src.indexOf('Widget _wrapVideoGamepadControls(');
    expect(wrapperStart, greaterThanOrEqualTo(0),
        reason: '_wrapVideoGamepadControls 必须存在（窗口/全屏共用输入层）');
    final int wrapperEnd = src.indexOf('\n  }', wrapperStart);
    expect(wrapperEnd, greaterThan(wrapperStart));
    final String wrapper = src.substring(wrapperStart, wrapperEnd);
    expect(wrapper, contains('_handleVideoKeyboardShortcut(event)'),
        reason: '键盘通道必须挂在窗口/全屏共用的 _wrapVideoGamepadControls 内，'
            '否则全屏路径没有快捷键（BUG-1864 回归）');

    // ③ 全屏路由的 pageBuilder 必须真的走这个 wrapper（BUG-697 已确立的边界）。
    final int fullscreenAt = src.indexOf('pageBuilder: (_, __, ___) =>');
    expect(fullscreenAt, greaterThanOrEqualTo(0),
        reason: '全屏路由 pageBuilder 必须存在');
    expect(
      src.substring(fullscreenAt, fullscreenAt + 200),
      contains('_wrapVideoGamepadControls('),
      reason: '全屏路由内容必须包进同一个 _wrapVideoGamepadControls，'
          '窗口与全屏的键盘/手柄语义才一致',
    );

    // ④ 按住倍速的 keyup 边沿必须排在主通道之前——主通道只看按下 / 重复沿，松开沿
    // 只有 _handleHoldSpeedKey 认；顺序反了就永远卡在加速态。
    final int holdAt = wrapper.indexOf('_handleHoldSpeedKey(event)');
    final int mainAt = wrapper.indexOf('_handleVideoKeyboardShortcut(event)');
    expect(holdAt, greaterThanOrEqualTo(0), reason: 'wrapper 里缺按住倍速分支');
    expect(holdAt, lessThan(mainAt), reason: '按住倍速必须排在主通道之前');
  });
}
