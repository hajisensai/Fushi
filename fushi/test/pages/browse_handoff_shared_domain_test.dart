import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/browse_page.dart';

/// PR #1735：来源 ↔ 扩展共用一份内容域（`_onlineDomain`）。二级标签越界横滑接力
/// 时若按「往后首段 / 往前末段」改这份共享域，被拖那一页的二级 TabController 会
/// 在拖动途中被改下标，而 TabBarView 拖动中不跟随跳页，标签条与页面就此错位。
///
/// 真 widget 路径要起 Mihon / LNReader manager（`BrowseOnlineSourcesView` 一挂就
/// 碰 `databaseDirectory`），故这里钉决策函数 + `_handOffFrom` 的源码形态。
void main() {
  test('来源 ↔ 扩展之间接力不重新落端（不改共享域）', () {
    expect(
      browseHandOffRealignsSections(BrowseTab.sources, BrowseTab.extensions),
      isFalse,
    );
    expect(
      browseHandOffRealignsSections(BrowseTab.extensions, BrowseTab.sources),
      isFalse,
    );
  });

  test('其余页签之间接力照常落端', () {
    const List<(BrowseTab, BrowseTab)> pairs = <(BrowseTab, BrowseTab)>[
      (BrowseTab.extensions, BrowseTab.discover),
      (BrowseTab.discover, BrowseTab.extensions),
      (BrowseTab.discover, BrowseTab.downloads),
      (BrowseTab.downloads, BrowseTab.discover),
      (BrowseTab.extensions, BrowseTab.downloads),
      (BrowseTab.downloads, BrowseTab.extensions),
    ];
    for (final (BrowseTab from, BrowseTab to) in pairs) {
      expect(
        browseHandOffRealignsSections(from, to),
        isTrue,
        reason: '$from -> $to',
      );
    }
  });

  test('_handOffFrom 在改任何二级状态之前先问决策函数，不落端时只切顶层页签', () {
    final String source = File(
      'lib/src/pages/implementations/browse_page.dart',
    ).readAsStringSync();
    final int start = source.indexOf('void _handOffFrom(BrowseTab from');
    expect(start, greaterThanOrEqualTo(0), reason: '找不到 _handOffFrom');
    final int end = source.indexOf('\n  }\n', start);
    final String body = source.substring(start, end);

    final int decision = body.indexOf(
      'browseHandOffRealignsSections(from, _controllerTabs[target])',
    );
    final int setState = body.indexOf('setState(');
    expect(decision, greaterThanOrEqualTo(0), reason: '接力必须经决策函数');
    expect(setState, greaterThan(decision), reason: '决策必须在改二级状态之前');

    final String earlyReturn = body.substring(decision, setState);
    expect(
      earlyReturn.contains('controller.animateTo(target);') &&
          earlyReturn.contains('return;'),
      isTrue,
      reason: '不落端的分支只切顶层页签并返回，不得碰 _onlineDomain',
    );
    expect(earlyReturn.contains('_onlineDomain'), isFalse);
  });
}
