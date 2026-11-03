// 首页「后台任务」入口（同步 / 复习同步 / 视频源补刮）的摆放判据（review of
// PR #2074，2026-11-03 并入同步进度后改名）。
//
// 回归原样：Apple（Cupertino）下 `_shellFabHostedByBar` 在桌面与移动布局都恒为
// true，右下 FAB 不再画；替代入口只在外壳大标题行右侧出现——而首页 / 设置 /
// 浏览器扩展这几个 tab 的外壳大标题行高度为 0（`_shellTitleFor` 返回 null），
// 按钮根本画不出来。后台任务跑着时用户既看不到进度也打不开面板。
//
// MD3 手机（2026-11-04 用户）：入口不许顶替悬浮底栏的「查词」FAB，而是在它正上方
// 另叠一颗小环钮——所以 MD3 从不由栏承载，底栏也不再接外壳的页面 FAB。
//
// 判据抽成纯函数 [homeBackgroundTasksHostedByChrome]，这里逐格钉住；末尾的源码
// 守卫钉住两套布局都经它赋值、且「标题行可见」与标题条判「有标题」同源。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';

void main() {
  group('homeBackgroundTasksHostedByChrome', () {
    test('Apple：外壳大标题行不可见（首页 / 设置 / 浏览器扩展）→ 保留 FAB', () {
      expect(
        homeBackgroundTasksHostedByChrome(
          apple: true,
          shellTitleVisible: false,
        ),
        isFalse,
        reason: '没有标题行可承载入口，FAB 不能收走',
      );
    });

    test('Apple：外壳大标题行可见（库页 / 浏览 / 查词）→ 入口在标题行动作位', () {
      expect(
        homeBackgroundTasksHostedByChrome(apple: true, shellTitleVisible: true),
        isTrue,
      );
    });

    test('MD3：从不由栏承载（手机叠在底栏 FAB 上方，桌面右下），与标题行无关', () {
      for (final bool shellTitleVisible in <bool>[false, true]) {
        expect(
          homeBackgroundTasksHostedByChrome(
            apple: false,
            shellTitleVisible: shellTitleVisible,
          ),
          isFalse,
        );
      }
    });
  });

  test('两套布局都经同一判据决定是否收走 FAB，标题行可见性与标题条同源', () {
    final String src = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    expect(
      RegExp(
        r'_shellFabHostedByBar = _backgroundTasksHostedByChrome\(\);',
      ).allMatches(src).length,
      2,
      reason: '桌面与移动布局各赋值一次',
    );
    expect(
      src,
      contains('shellTitleVisible: _shellTitleFor(_visibleTab) != null'),
      reason: '「标题行可见」必须取外壳标题条判「有标题」的同一份数据',
    );
    expect(
      src,
      isNot(contains('_shellFabHostedByBar = isGlassDesign(context);')),
      reason: '按设计系统一刀切收走 FAB 就是本条回归本身',
    );
    // 右下 FAB 仍由这一位门控，且同步任务也能点亮它（不只补刮）。
    expect(src, contains('_hasBackgroundTasks && !_shellFabHostedByBar'));
    expect(src, contains('_syncTasksActive ||'));
  });

  test('MD3 手机：入口叠在底栏 FAB 上方，不顶替「查词」FAB', () {
    final String src = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    expect(
      src,
      isNot(contains('materialFab:')),
      reason: '外壳不再把页面 FAB 塞进悬浮底栏，底栏那颗始终是「查词」',
    );
    expect(src, contains('FloatingActionButton.small('));
    expect(
      src,
      contains('materialNavBarFabExtent('),
      reason: '小环钮的中线按底栏 FAB 的实际边长对齐',
    );
  });
}
