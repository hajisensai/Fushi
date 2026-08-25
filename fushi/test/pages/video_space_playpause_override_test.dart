import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/panel_focus_scope.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';

import 'video_fushi_page_source_corpus.dart';

/// 回归守卫（TODO-755，回归 c152fcd91）：视频按空格无反应。
///
/// 根因：全局导航层 [wrapWithGlobalNavigation] 无条件把裸空格中和成
/// [DoNothingIntent]（`global_navigation.dart`，`DoNothingAction.consumesKey`
/// 为 true → 真消费按键）。视频空格的正常路径是 media_kit 桌面 controls 的
/// `keyboardShortcuts`，但那只在 `_videoFocusNode`（或 controls 内置 Focus）
/// **精确持焦**时才生效；一旦焦点落在视频页子树里其它节点（关对话框/菜单后短暂
/// 失焦、点了非视频区控件等），裸空格就上浮到全局 [DoNothingIntent] 被吞 →「按了
/// 没反应」。
///
/// 修复：视频页 body 外层加**页内局部** [CallbackShortcuts] 绑裸空格 →
/// `playOrPause()`，位于全局 [DoNothingIntent] 之下、离视频更近。只要焦点落在
/// 视频页子树内**任意**节点，空格都先被这层消费、永不下沉到全局中和层。
///
/// [VideoFushiPage] 驱动 media_kit、无法离屏整页 widget 测试，故本测试用与真实
/// 拓扑同构的最小 widget 树（global 中和层 → 页内局部 CallbackShortcuts → 普通
/// 可聚焦子节点）验证关键不变式：**焦点不精确落在视频节点上（这里是一个普通
/// FocusNode，且不调任何特殊内层节点的 requestFocus）时，裸空格仍触发
/// playOrPause**。这正是 integration 测试 `video_shader_focus_test.dart` 显式
/// `videoNode.requestFocus()` 漏掉的真实使用路径。
void main() {
  /// 复刻真实拓扑：全局导航层（裸空格 → DoNothingIntent）在外，页内局部
  /// CallbackShortcuts（裸空格 → onSpace）在内，最里是一个普通可聚焦子节点。
  /// [pageLocalOverride] 为 false 时去掉页内局部层，用作「未修复 = 被全局吞掉」
  /// 的负向对照。
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
            'playOrPause，永不下沉到全局 DoNothingIntent',
      );
    },
  );

  testWidgets(
    '负向对照：没有页内局部覆盖时裸空格被全局 DoNothingIntent 吞掉（复现回归）',
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
  /// 不在它的祖先链上。路由内容包一层与生产 [_wrapVideoGamepadControls] 同位的
  /// wrapper（[routeLevelOverride] 决定它是否带裸空格覆盖），里面挂真的
  /// [PanelFocusScope]——它正是字幕列表 / 剧集轨 / 侧栏打开时把焦点从视频画面抢走的
  /// 那个组件（`subtitle.part.dart` 的 `_subtitleJumpSidePanel` 用的就是它）。
  ///
  /// 关键：面板焦点节点既够不到 media_kit 的 `keyboardShortcuts`（那层只包
  /// `AdaptiveVideoControls` 子树，面板是它的兄弟），页面 Scaffold 上的覆盖层又不在
  /// 全屏路由里，所以裸空格只剩「路由级 wrapper 是否兜底」这一个变量。
  Future<int> pumpFullscreenRouteAndCountSpaces(
    WidgetTester tester, {
    required bool routeLevelOverride,
  }) async {
    int playOrPause = 0;
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
            if (routeLevelOverride) {
              content = CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.space): () =>
                      playOrPause++,
                },
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
    return playOrPause;
  }

  testWidgets(
    'BUG-1864：全屏路由内面板持焦时裸空格仍触发 playOrPause（修复）',
    (WidgetTester tester) async {
      expect(
        await pumpFullscreenRouteAndCountSpaces(
          tester,
          routeLevelOverride: true,
        ),
        1,
        reason: '空格覆盖上提到窗口/全屏共用的 wrapper 后，全屏下打开字幕列表'
            '（PanelFocusScope 抢焦）按空格必须照常播放/暂停',
      );
    },
  );

  testWidgets(
    'BUG-1864 负向对照：全屏路由没有覆盖层时裸空格被全局中和吞掉（复现）',
    (WidgetTester tester) async {
      expect(
        await pumpFullscreenRouteAndCountSpaces(
          tester,
          routeLevelOverride: false,
        ),
        0,
        reason: '覆盖层只挂在 _buildScaffold（不在全屏路由祖先链上）时即回归 BUG-1864：'
            '面板持焦后裸空格一路冒到 _neutralizeBareSpace 被吞，「按了没反应」',
      );
    },
  );

  test('页内局部裸空格覆盖挂在窗口/全屏共用的 wrapper 上（源码守卫）', () {
    final String src = readVideoFushiSource();

    // 覆盖 helper 存在，且绑裸空格 → 经沉浸锁门控的 playOrPause（与注册表
    // togglePlayPause 同语义，不引入特例分支）。
    final int start = src.indexOf('Widget _withPageSpaceOverride(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '_withPageSpaceOverride 覆盖 helper 必须存在');
    final int end = src.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body, contains('CallbackShortcuts'),
        reason: '页内局部覆盖必须用 CallbackShortcuts（位于全局 DoNothingIntent 之下）');
    expect(body, contains('LogicalKeyboardKey.space'), reason: '必须绑裸空格');
    expect(body, contains('_runWhenImmersiveAllowsShortcuts'),
        reason: '必须经沉浸锁快捷键门控（与注册表 togglePlayPause 同语义）');
    expect(body, contains('controller.playOrPause()'), reason: '裸空格应触发播放/暂停');

    // BUG-1864：挂载点必须是 [_wrapVideoGamepadControls]——窗口 build() 与全屏路由
    // pageBuilder 的**唯一共同外层**。挂在 _buildScaffold 上时全屏路由（推到根
    // navigator 的独立路由）根本没有这层，面板抢焦后裸空格被全局中和层吞掉。
    final int wrapperStart = src.indexOf('Widget _wrapVideoGamepadControls(');
    expect(wrapperStart, greaterThanOrEqualTo(0),
        reason: '_wrapVideoGamepadControls 必须存在（窗口/全屏共用输入层）');
    final int wrapperEnd = src.indexOf('\n  }', wrapperStart);
    expect(wrapperEnd, greaterThan(wrapperStart));
    final String wrapper = src.substring(wrapperStart, wrapperEnd);
    expect(wrapper, contains('_withPageSpaceOverride('),
        reason: '空格覆盖必须挂在窗口/全屏共用的 _wrapVideoGamepadControls 内，'
            '否则全屏路径没有兜底（BUG-1864 回归）');

    // 全屏路由的 pageBuilder 必须真的走这个 wrapper（BUG-697 已确立的边界，
    // BUG-1864 靠它顺带获得空格兜底）。
    final int fullscreenAt = src.indexOf('pageBuilder: (_, __, ___) =>');
    expect(fullscreenAt, greaterThanOrEqualTo(0),
        reason: '全屏路由 pageBuilder 必须存在');
    expect(
      src.substring(fullscreenAt, fullscreenAt + 200),
      contains('_wrapVideoGamepadControls('),
      reason: '全屏路由内容必须包进同一个 _wrapVideoGamepadControls，'
          '窗口与全屏的键盘/手柄语义才一致',
    );
  });
}
