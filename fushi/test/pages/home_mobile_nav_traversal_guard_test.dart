import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-713 守卫：首页移动端布局（[_HomePageState._buildMobileLayout]）的
/// body 与 bottomNavigationBar 必须各自被 [FocusTraversalGroup] 隔离。
///
/// 桌面布局已给 rail / content 各包一个 [FocusTraversalGroup]，使方向遍历在
/// 每个面板内闭合。移动端原本缺这一层隔离 —— 边缘 tab（书架按 Left、查询按
/// Right）没有同行 ahead 候选时，几何遍历会在整页找候选并选中 body 里上方注册
/// 的焦点目标，焦点「跑到上部」。两组隔离让左右遍历各自闭合，只有上下才跨区。
void main() {
  test('mobile layout isolates body and bottom-nav with FocusTraversalGroup',
      () {
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();

    final int mobileStart = source.indexOf('Widget _buildMobileLayout()');
    expect(mobileStart, isNonNegative, reason: '应存在 _buildMobileLayout');

    // 截取 _buildMobileLayout 到下一个方法（buildBody）之间的片段。
    final int mobileEnd = source.indexOf('Widget buildBody()', mobileStart);
    expect(mobileEnd, greaterThan(mobileStart));
    final String mobileBody = source.substring(mobileStart, mobileEnd);

    // body 与 bottomNavigationBar 两处都必须包 FocusTraversalGroup。
    expect(
      mobileBody.contains('FocusTraversalGroup(child: _bodyWithMiniBar())'),
      isTrue,
      reason: '移动端 body 必须被 FocusTraversalGroup 隔离（TODO-713）',
    );
    expect(
      'FocusTraversalGroup('.allMatches(mobileBody).length,
      greaterThanOrEqualTo(2),
      reason: '移动端 body 与 bottomNavigationBar 各需一个 '
          'FocusTraversalGroup（共 2 个）以隔离左右遍历（TODO-713）',
    );
    // 底栏外面可以再套一层重建器（Apple 玻璃底栏随滚动收起要监听 chrome 状态，
    // 见 `ListenableBuilder(listenable: _appleChrome ...)`），但从
    // `bottomNavigationBar:` 到真正的底栏 `adaptiveBottomBar(` 之间必须有一个
    // FocusTraversalGroup 把整条底栏包成闭合遍历块。
    final int navStart = mobileBody.indexOf('bottomNavigationBar:');
    expect(navStart, isNonNegative, reason: '移动端应有 bottomNavigationBar');
    final int barStart = mobileBody.indexOf('adaptiveBottomBar(', navStart);
    expect(barStart, greaterThan(navStart), reason: '底栏应由 adaptiveBottomBar 构建');
    expect(
      mobileBody.substring(navStart, barStart).contains('FocusTraversalGroup('),
      isTrue,
      reason: '移动端 bottomNavigationBar 必须被 FocusTraversalGroup 隔离（TODO-713）',
    );
  });
}
