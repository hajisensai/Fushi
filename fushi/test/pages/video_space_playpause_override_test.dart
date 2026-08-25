import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/panel_focus_scope.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart'
    show PageSpaceOverrideDecision, decidePageSpaceOverride;
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show focusedEditableText;
import 'package:fushi/src/shortcuts/global_navigation.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 回归守卫（TODO-755，回归 c152fcd91）：视频按空格无反应。
///
/// 根因：全局导航层 [wrapWithGlobalNavigation] 把裸空格中和掉
/// （`global_navigation.dart` 的 `_neutralizeBareSpace`，真消费按键）。视频空格的正常
/// 路径是 media_kit 桌面 controls 的 `keyboardShortcuts`，但那只在 `_videoFocusNode`
/// （或 controls 内置 Focus）**精确持焦**时才生效；一旦焦点落在视频页子树里其它节点
/// （关对话框/菜单后短暂失焦、点了非视频区控件等），裸空格就上浮到全局被吞 →「按了
/// 没反应」。
///
/// 修复：视频页加**页内局部**覆盖层绑裸空格 → `playOrPause()`，位于全局中和之下、
/// 离视频更近。
///
/// `VideoFushiPage` 驱动 media_kit、无法离屏整页 widget 测试，故本文件的 widget 用例
/// 用与真实拓扑同构的最小树验证**拓扑不变式**；「消不消费」那一步的判据则直接打生产
/// 纯函数 [decidePageSpaceOverride]（逐条判据的单测在
/// `test/media/video/video_page_space_override_decision_test.dart`），生产与测试之间的
/// 对应关系由文件末尾的源码守卫钉住。
void main() {
  /// 复刻真实拓扑：全局导航层（裸空格中和）在外，页内局部覆盖层在内，最里是一个
  /// 普通可聚焦子节点。[pageLocalOverride] 为 false 时去掉页内局部层，用作「未修复 =
  /// 被全局吞掉」的对照。
  Future<int> pumpAndCountSpaces(
    WidgetTester tester, {
    required bool pageLocalOverride,
  }) async {
    int playOrPause = 0;
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode genericNode = FocusNode(debugLabel: 'generic-not-video');
    addTearDown(genericNode.dispose);

    Widget child = Focus(
      focusNode: genericNode,
      child: const SizedBox(width: 100, height: 100),
    );
    if (pageLocalOverride) {
      child = CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.space): () => playOrPause++,
        },
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
    return playOrPause;
  }

  testWidgets(
    '页内局部空格覆盖在焦点不精确落在视频节点时仍触发 playOrPause（修复）',
    (WidgetTester tester) async {
      expect(
        await pumpAndCountSpaces(tester, pageLocalOverride: true),
        1,
        reason: '焦点落在视频页子树任意节点上时，裸空格必须先被页内局部覆盖消费 → '
            'playOrPause，永不下沉到全局中和层',
      );
    },
  );

  testWidgets(
    '对照：没有页内局部覆盖时裸空格被全局中和吞掉（复现回归）',
    (WidgetTester tester) async {
      expect(
        await pumpAndCountSpaces(tester, pageLocalOverride: false),
        0,
        reason: '撤掉页内局部覆盖即回归 c152fcd91：裸空格被全局中和层吞掉，'
            '视频「按了没反应」',
      );
    },
  );

  /// BUG-1864 的真实拓扑复刻：**全屏是推到根 navigator 的独立路由**，页面 Scaffold
  /// 不在它的祖先链上。
  ///
  /// 三个关键点，缺一条这组用例就退化成自证：
  /// ① 全局导航层挂在 `MaterialApp.builder`（= 生产位置，Navigator 之上），所以推出去
  ///    的路由**真的**在它的作用域里——挂在 `home:` 上的旧写法根本不是路由的祖先，
  ///    「被全局中和吞掉」这句话当时是空的；
  /// ② 修复前的挂载点（页面 Scaffold，`_buildScaffold`）在**每个**用例里都挂着、且都
  ///    wired 到同一个 playOrPause 计数器——所以全屏用例里的 0 不是「计数器没接
  ///    上」，而是「Scaffold 层够不到全屏路由」；
  /// ③ 路由内挂真的 [PanelFocusScope]（生产组件，字幕列表 / 剧集轨 / 侧栏用的就是
  ///    它），由它自己抢焦，不在测试里手动摆焦点。
  Future<int> pumpFullscreenRouteAndCountSpaces(
    WidgetTester tester, {
    required bool pushFullscreen,
    required bool routeLevelOverride,
  }) async {
    int playOrPause = 0;
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode homeNode = FocusNode(debugLabel: 'home-video-surface');
    addTearDown(homeNode.dispose);

    Widget spaceOverride(Widget child) => CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.space): () =>
                playOrPause++,
          },
          child: child,
        );

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        // 生产位置：全局导航层包 MaterialApp 的 builder child（Navigator 之上），
        // 故它是**所有路由**的祖先，含推出去的全屏路由。
        builder: (BuildContext context, Widget? child) =>
            wrapWithGlobalNavigation(
          navigatorKey: navKey,
          child: child!,
        ),
        // 修复前的挂载点：页面 Scaffold。恒挂、恒 wired。
        home: spaceOverride(
          Scaffold(
            body: Focus(
              focusNode: homeNode,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );

    if (!pushFullscreen) {
      // 活性自证：不进全屏时，Scaffold 层的覆盖必须真的会 +1。没有这一条，
      // 下面那条 0 就无法与「计数器压根不会动」区分开。
      homeNode.requestFocus();
      await tester.pump();
      expect(homeNode.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      return playOrPause;
    }

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
            if (routeLevelOverride) content = spaceOverride(content);
            return content;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // PanelFocusScope 自己把焦点移进面板，这正是用户「打开右侧字幕列表后按空格」
    // 的真实焦点归属。
    expect(
      FocusManager.instance.primaryFocus?.context?.widget,
      isNotNull,
      reason: '面板打开后焦点必须落在面板内某个可聚焦节点上',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    return playOrPause;
  }

  testWidgets(
    'BUG-1864 活性自证：不进全屏时 Scaffold 层的覆盖会 +1',
    (WidgetTester tester) async {
      expect(
        await pumpFullscreenRouteAndCountSpaces(
          tester,
          pushFullscreen: false,
          routeLevelOverride: false,
        ),
        1,
        reason: '这条一旦为 0，下面的负向对照就是自证空转，必须先修脚手架',
      );
    },
  );

  testWidgets(
    'BUG-1864 负向对照：覆盖层只挂 Scaffold 时够不到全屏路由，空格被全局中和吞掉',
    (WidgetTester tester) async {
      expect(
        await pumpFullscreenRouteAndCountSpaces(
          tester,
          pushFullscreen: true,
          routeLevelOverride: false,
        ),
        0,
        reason: '同一个覆盖层、同一个计数器，只因为它挂在页面 Scaffold 上而不在全屏'
            '路由的祖先链上就够不着——面板持焦后裸空格一路冒到 _neutralizeBareSpace '
            '被吞，「按了没反应」（BUG-1864 本体）',
      );
    },
  );

  testWidgets(
    'BUG-1864：全屏路由内也挂覆盖层后，面板持焦时裸空格仍触发 playOrPause（修复）',
    (WidgetTester tester) async {
      expect(
        await pumpFullscreenRouteAndCountSpaces(
          tester,
          pushFullscreen: true,
          routeLevelOverride: true,
        ),
        1,
        reason: '空格覆盖上提到窗口/全屏共用的 wrapper 后，全屏下打开字幕列表'
            '（PanelFocusScope 抢焦）按空格必须照常播放/暂停',
      );
    },
  );

  /// BUG-1864 跟进 / BUG-962 同源：覆盖层**不得**在文本框持焦时吞掉空格。
  ///
  /// 「哨兵祖先 [Focus]」范式抄自 `test/shortcuts/global_space_no_activate_test.dart`：
  /// 哨兵包在覆盖层**外面**，故覆盖层消费 → 哨兵看不到按键；覆盖层放行 → 哨兵看得到
  /// （生产里哨兵位置上坐着的就是全局中和层与 text-input 通道）。
  ///
  /// widget 树是同构副本，但**「消不消费」这一步走的是生产判据**
  /// [decidePageSpaceOverride]，副本只把结论翻译成 [KeyEventResult]，与
  /// `_withPageSpaceOverride` 里那段 switch 逐条对应。
  Future<({int playOrPause, bool sentinelSawSpace})> pumpEditableFocusCase(
    WidgetTester tester, {
    required bool editable,
  }) async {
    int playOrPause = 0;
    bool sentinelSawSpace = false;
    final FocusNode focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (FocusNode _, KeyEvent event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.space) {
              sentinelSawSpace = true;
            }
            return KeyEventResult.ignored;
          },
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (FocusNode _, KeyEvent event) {
              switch (decidePageSpaceOverride(
                event: event,
                hasModifier: false,
                hasEditableFocus: focusedEditableText() != null,
                hasVisiblePopup: false,
                hasController: true,
              )) {
                case PageSpaceOverrideDecision.passThrough:
                case PageSpaceOverrideDecision.yieldToTextInput:
                  return KeyEventResult.ignored;
                case PageSpaceOverrideDecision.swallowRepeat:
                case PageSpaceOverrideDecision.dismissPopup:
                  return KeyEventResult.handled;
                case PageSpaceOverrideDecision.togglePlayPause:
                  playOrPause++;
                  return KeyEventResult.handled;
              }
            },
            child: Scaffold(
              body: Center(
                child: editable
                    ? TextField(focusNode: focusNode)
                    : TextButton(
                        focusNode: focusNode,
                        onPressed: () {},
                        child: const Text('确认'),
                      ),
              ),
            ),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasPrimaryFocus, isTrue);
    expect(
      focusedEditableText() != null,
      editable,
      reason: 'focusedEditableText 必须认出（或认不出）这个焦点落点，'
          '否则本用例测的不是它自称要测的东西',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    return (playOrPause: playOrPause, sentinelSawSpace: sentinelSawSpace);
  }

  testWidgets(
    'BUG-962 同源：视频页文本框持焦时，空格放行冒泡且不触发播放/暂停',
    (WidgetTester tester) async {
      final ({int playOrPause, bool sentinelSawSpace}) result =
          await pumpEditableFocusCase(tester, editable: true);
      expect(
        result.playOrPause,
        0,
        reason: '在 mpv.conf / 弹幕屏蔽规则 / 弹幕手动匹配搜索框里打空格，'
            '不得被当成播放/暂停',
      );
      expect(
        result.sentinelSawSpace,
        isTrue,
        reason: '空格必须放行到上层（生产里是 text-input 通道），否则输入框打不出空格'
            '——BUG-962 原样重演',
      );
    },
  );

  testWidgets(
    '非文本框持焦时，空格照旧被覆盖层消费并触发播放/暂停',
    (WidgetTester tester) async {
      final ({int playOrPause, bool sentinelSawSpace}) result =
          await pumpEditableFocusCase(tester, editable: false);
      expect(result.playOrPause, 1);
      expect(
        result.sentinelSawSpace,
        isFalse,
        reason: '覆盖层必须消费掉，不得下沉到全局把「空格不确认焦点」的语义搅乱',
      );
    },
  );

  test('页内局部裸空格覆盖的形状与挂载点（源码守卫）', () {
    final String src = readVideoFushiSource();

    // 要求型断言一律走剥注释的判据（containsCodeLine / containsIdentifierCall）：
    // 裸 contains 下「把实现删光、把同样的字面量留在注释里」是合法骗绿写法，
    // 见 test/helpers/source_guard.dart 的说明。
    final String body = methodBody(src, 'Widget _withPageSpaceOverride(');
    expect(
      containsIdentifierCall(body, 'Focus'),
      isTrue,
      reason: '页内局部覆盖必须是旁观 Focus：CallbackShortcuts 匹配即 handled，'
          '表达不了「文本框持焦时让开」',
    );
    expect(
      containsIdentifierCall(body, 'CallbackShortcuts'),
      isFalse,
      reason: 'CallbackShortcuts 无条件消费按键，不得回退（BUG-1864 跟进 / '
          'BUG-962 同源）',
    );
    expect(
      containsIdentifierCall(body, 'decidePageSpaceOverride'),
      isTrue,
      reason: '判据必须走可单测的生产纯函数 decidePageSpaceOverride',
    );
    expect(
      containsIdentifierCall(body, 'focusedEditableText'),
      isTrue,
      reason: '文本框持焦时必须让位给 text-input（BUG-962 同款判据），否则视频页'
          '侧栏的 mpv.conf / 弹幕规则 / 弹幕搜索框打不出空格；注释里写着不算实现',
    );
    expect(
      containsCodeLine(body, '_runWhenImmersiveAllowsShortcuts'),
      isTrue,
      reason: '必须经沉浸锁快捷键门控（与注册表 togglePlayPause 同语义）',
    );
    expect(
      containsCodeLine(body, 'playOrPause()'),
      isTrue,
      reason: '裸空格应触发播放/暂停',
    );

    // BUG-1864：挂载点必须是 _wrapVideoGamepadControls——窗口 build() 与全屏路由
    // pageBuilder 的**唯一共同外层**。挂在 _buildScaffold 上时全屏路由根本没有这层。
    final String wrapper = methodBody(src, 'Widget _wrapVideoGamepadControls(');
    expect(
      containsIdentifierCall(wrapper, '_withPageSpaceOverride'),
      isTrue,
      reason: '空格覆盖必须挂在窗口/全屏共用的 _wrapVideoGamepadControls 内，'
          '否则全屏路径没有兜底（BUG-1864 回归）',
    );

    // 全屏路由 pageBuilder 必须真的走同一个 wrapper。锚点收进方法体：裸
    // indexOf('pageBuilder: (_, __, ___) =>') 取的是合并语料里的第一处，将来任一
    // part 出现同形字符串就会静默守错对象。
    final String fullscreen =
        methodBody(src, 'Future<void> _pushNeutralizedVideoFullscreen(');
    expect(
      containsCodeLine(fullscreen, 'pageBuilder:'),
      isTrue,
      reason: '全屏路由 pageBuilder 必须在本方法体内（锚点自校验）',
    );
    expect(
      containsIdentifierCall(fullscreen, '_wrapVideoGamepadControls'),
      isTrue,
      reason: '全屏路由内容必须包进同一个 _wrapVideoGamepadControls，'
          '窗口与全屏的键盘/手柄语义才一致',
    );
  });
}
