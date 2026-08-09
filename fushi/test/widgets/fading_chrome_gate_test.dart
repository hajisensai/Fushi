import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fading_chrome_gate.dart';

/// BUG-1301：视频页淡出型 chrome（剧集横轨 / 侧边沉浸锁 / on-rail 沉浸退出钮）
/// 隐藏态留树只挡指针不挡焦点，手柄浏览后焦点滞留在 opacity=0 的控件上，
/// `FushiFocusRing` 据 primaryFocus 画出一个空焦点框。
///
/// 根因修复：[FadingChromeGate] 把「不可见 ⇒ 不可点 + 不可聚焦」做成结构不变量。
/// 本文件测 1) 门控 widget 自身的焦点/指针行为；2) 三处视频页调用点不回退成
/// 裸 IgnorePointer + AnimatedOpacity（源码守卫）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host({required bool visible, required FocusNode inner, FocusNode? outer}) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            if (outer != null)
              TextButton(
                focusNode: outer,
                onPressed: () {},
                child: const Text('outside'),
              ),
            FadingChromeGate(
              visible: visible,
              duration: const Duration(milliseconds: 200),
              child: TextButton(
                focusNode: inner,
                onPressed: () {},
                child: const Text('inside'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('隐藏态：子孙不可聚焦（requestFocus 不生效）', (WidgetTester tester) async {
    final FocusNode inner = FocusNode(debugLabel: 'inner');
    addTearDown(inner.dispose);
    await tester.pumpWidget(host(visible: false, inner: inner));
    await tester.pump(const Duration(milliseconds: 300));

    inner.requestFocus();
    await tester.pump();
    expect(inner.hasFocus, isFalse,
        reason: '隐藏 chrome 内的控件绝不能拿到焦点（BUG-1301 根因）');
  });

  testWidgets('可见→隐藏：已持焦子孙被自动撤离，焦点回到门外', (WidgetTester tester) async {
    final FocusNode inner = FocusNode(debugLabel: 'inner');
    final FocusNode outer = FocusNode(debugLabel: 'outer');
    addTearDown(inner.dispose);
    addTearDown(outer.dispose);

    await tester.pumpWidget(host(visible: true, inner: inner, outer: outer));
    // 先让门外控件持焦一次（成为 scope 的 previouslyFocusedChild），再进门内——
    // 复刻用户路径：视频节点持焦 → dpad 把焦点移进剧集轨卡片。
    outer.requestFocus();
    await tester.pump();
    inner.requestFocus();
    await tester.pump();
    expect(inner.hasFocus, isTrue, reason: '可见态子孙应可正常聚焦');

    // 面板关闭（visible 翻 false）：焦点必须立刻撤离隐形子树。
    await tester.pumpWidget(host(visible: false, inner: inner, outer: outer));
    await tester.pump();
    expect(inner.hasFocus, isFalse,
        reason: '隐藏瞬间焦点必须撤离，否则焦点环画在隐形控件上（用户截图的空框）');
    expect(outer.hasFocus, isTrue,
        reason: 'Flutter unfocus(previouslyFocusedChild) 应把焦点还给门外上一个持焦者');
  });

  testWidgets('隐藏态：指针穿透（点不到门内按钮）', (WidgetTester tester) async {
    final FocusNode inner = FocusNode(debugLabel: 'inner');
    addTearDown(inner.dispose);
    int taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FadingChromeGate(
          visible: false,
          duration: const Duration(milliseconds: 200),
          child: TextButton(
            focusNode: inner,
            onPressed: () => taps++,
            child: const Text('inside'),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('inside'), warnIfMissed: false);
    expect(taps, 0, reason: '隐藏态 IgnorePointer 语义保持（与旧行为一致）');
  });

  test('源码守卫：视频页三处淡出 chrome 必须走 FadingChromeGate', () {
    // BUG-1301 调用点守卫：episode.part.dart（剧集横轨）与 layout.part.dart
    // （侧边锁按钮 + on-rail 沉浸退出钮）不得回退成「裸 IgnorePointer(ignoring:
    // !visible) 挡指针、不挡焦点」的旧写法。chapter.part.dart 的常驻 IgnorePointer
    // 是纯展示层（无可聚焦子孙、永不拦指针），不在此列。
    final String episode = File(
      'lib/src/pages/implementations/video_fushi/episode.part.dart',
    ).readAsStringSync();
    final String layout = File(
      'lib/src/pages/implementations/video_fushi/layout.part.dart',
    ).readAsStringSync();

    expect(RegExp(r'FadingChromeGate\(').allMatches(episode).length,
        greaterThanOrEqualTo(1),
        reason: '剧集横轨隐藏态必须经 FadingChromeGate（不可见⇒不可聚焦）');
    expect(RegExp(r'FadingChromeGate\(').allMatches(layout).length,
        greaterThanOrEqualTo(2),
        reason: '侧边锁按钮与 on-rail 沉浸退出钮都必须经 FadingChromeGate');
    // 旧病灶写法：IgnorePointer(ignoring: !visible…) 直接包淡出 chrome。
    final RegExp bare = RegExp(r'IgnorePointer\(\s*ignoring:\s*!\s*visible');
    expect(bare.hasMatch(episode), isFalse,
        reason: '剧集横轨不得回退成裸 IgnorePointer(ignoring: !visible)');
    expect(bare.hasMatch(layout), isFalse,
        reason: 'layout 淡出 chrome 不得回退成裸 IgnorePointer(ignoring: !visible)');
  });
}
