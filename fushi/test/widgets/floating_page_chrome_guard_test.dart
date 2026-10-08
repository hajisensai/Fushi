import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 2026-10-05 用户「都一起改，全部用浮动工具栏统一」：全应用顶 / 底栏统一为
/// M3 Expressive 浮动工具栏。普通页面的页头全部走共享包装（FushiAppBar /
/// FushiSliverAppBar / FushiTabBar / FushiPageHeader / FushiPageScaffold /
/// FushiToolScaffold / FushiShellLargeTitleBar），这些包装的 Material 分支画成
/// 悬浮胶囊；页面里再直接 new 一条框架实体栏（AppBar / SliverAppBar /
/// BottomAppBar），就绕开了悬浮形态。本守卫钉死两件事：
///
/// 1. `lib/` 下除白名单外不再直接构造框架实体栏；
/// 2. 共享包装的 Material 分支确实走悬浮胶囊实现（不被回退成实体栏）。
void main() {
  /// 确需保留框架实体栏的文件与理由。
  const Map<String, String> allowlist = <String, String>{
    // 包装本身：Material 分支里用框架 AppBar 承载悬浮胶囊（透明、无阴影）。
    'lib/src/utils/components/glass/fushi_glass_bars.dart': '设计系统分派包装本身',
    // 设置模块由 sh-settings-redesign 负责重设计（大标题 SliverAppBar）。
    'lib/src/settings/settings_home_page.dart': '设置模块另有负责人',
  };

  final RegExp rawBar = RegExp(
    r'(?<![A-Za-z0-9_])(AppBar|SliverAppBar|BottomAppBar)(\.(medium|large))?\(',
  );

  test('lib/ 下除白名单外不直接构造框架实体顶 / 底栏', () {
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String path = entity.path.replaceAll(r'\', '/');
      if (path.endsWith('.g.dart')) continue;
      if (allowlist.containsKey(path)) continue;
      final String code = maskCommentsAndScriptLines(entity.readAsStringSync());
      if (rawBar.hasMatch(code)) offenders.add(path);
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '页头请走 FushiAppBar / FushiPageHeader / FushiPageScaffold 等共享包装'
          '（Material 下是 M3E 悬浮胶囊）；确需实体栏的加进白名单并写理由',
    );
  });

  test('白名单里的文件都还在（过期条目要删）', () {
    for (final String path in allowlist.keys) {
      expect(File(path).existsSync(), isTrue, reason: '$path 已不存在');
    }
  });

  test('共享包装的 Material 分支走悬浮胶囊', () {
    final String bars = maskCommentsAndScriptLines(
      File(
        'lib/src/utils/components/glass/fushi_glass_bars.dart',
      ).readAsStringSync(),
    );
    expect(
      bars,
      contains('_buildFloating(context, floating, scrolledUnder)'),
      reason: 'FushiAppBar 的 Material 分支必须画悬浮胶囊顶栏',
    );
    expect(
      bars,
      contains('_FushiM3eSegmentedTabs(bar: this)'),
      reason: 'FushiTabBar 的 Material 分支必须是分段胶囊轨道',
    );
    expect(
      bars,
      contains('FushiPageChromeCircle('),
      reason: 'FushiRouteBackButton / 隐含返回键必须是圆形悬浮胶囊',
    );

    final String components = maskCommentsAndScriptLines(
      File(
        'lib/src/utils/components/fushi_material_components.dart',
      ).readAsStringSync(),
    );
    expect(
      components,
      contains('FushiPageChromeTitle('),
      reason: 'FushiPageHeader 的标题必须装进悬浮标题胶囊',
    );
    expect(
      components,
      contains('FushiPageChromeCapsule('),
      reason: '页头动作必须收进悬浮按钮组胶囊',
    );
    expect(
      components,
      contains('FushiScrollAwayChrome('),
      reason: 'FushiPageScaffold 的页头必须随滚动收起 / 出现',
    );

    final String batch = maskCommentsAndScriptLines(
      File('lib/src/utils/components/batch_action_bar.dart').readAsStringSync(),
    );
    expect(
      batch,
      contains('fushiFloatingPillDecoration('),
      reason: '多选批量操作栏必须是 M3E 悬浮工具栏',
    );
  });
}
