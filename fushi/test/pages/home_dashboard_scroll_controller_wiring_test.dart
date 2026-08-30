import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1960：首页主纵向滚动区必须自己持有滚轮控制器并接上去。
///
/// 首页的正文是 `HomeDashboardPage` 里的 `ListView`，它是 `FushiPageScaffold`
/// 之外的**另一个** Scrollable——scaffold 那只控制器管不到它，不显式接线的话首页
/// 滚轮就还是 Flutter 默认的「一格一大跳」。
void main() {
  test('home dashboard owns, wires and disposes its wheel controller', () {
    final String source = File(
      'lib/src/pages/implementations/home_dashboard_page.dart',
    ).readAsStringSync();

    // 必须是全仓**唯一**那套桌面滚轮细化实现。曾经短暂存在过第二个平行控制器
    // （DesktopWheelScrollController），两套都拦 pointerScroll，同时在场就是两层
    // 折扣、阈值和倍率还各写一遍；这里反向钉死它不得复活。
    expect(source, contains('FushiScrollController()'));
    expect(source, isNot(contains('DesktopWheelScrollController')));
    expect(source, contains('controller: _dashboardScrollController'));
    expect(source, contains('_dashboardScrollController.dispose();'));
  });
}
