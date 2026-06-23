import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';

import 'video_hibiki_page_source_corpus.dart';

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
/// [VideoHibikiPage] 驱动 media_kit、无法离屏整页 widget 测试，故本测试用与真实
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

  test('视频页 body 在 drop target 外层套页内局部裸空格覆盖（源码守卫）', () {
    final String src = readVideoHibikiSource();

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
    expect(body, contains('_runWhenImmersiveAllowsFullControls'),
        reason: '必须经沉浸锁门控（与注册表 togglePlayPause 同语义）');
    expect(body, contains('controller.playOrPause()'), reason: '裸空格应触发播放/暂停');

    // body 真正用上了它（包在 _pageDropTarget 外层），否则 helper 是死代码。
    expect(src, contains('_withPageSpaceOverride('),
        reason: '_buildScaffold 必须实际套用页内局部空格覆盖');
  });
}
