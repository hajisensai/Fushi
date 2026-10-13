// 首页视频源后台补刮任务入口的摆放判据（review of PR #2074）。
//
// 回归原样：Apple（Cupertino）下 `_shellFabHostedByBar` 在桌面与移动布局都恒为
// true，右下补刮 FAB 不再画；替代入口只在外壳大标题行右侧出现——而首页 / 设置 /
// 浏览器扩展这几个 tab 的外壳大标题行高度为 0（`_shellTitleFor` 返回 null），
// 按钮根本画不出来。后台补刮跑着时用户既看不到进度也打不开任务面板。
//
// 判据抽成纯函数 [homeScrapeEntryHostedByChrome]，这里逐格钉住；末尾的源码守卫
// 钉住两套布局都经它赋值、且「标题行可见」与标题条判「有标题」同源。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';

void main() {
  group('homeScrapeEntryHostedByChrome', () {
    test('Apple：外壳大标题行不可见且页头不带入口（首页 / 设置 / 浏览器扩展）→ 保留 FAB', () {
      for (final bool mobileLayout in <bool>[false, true]) {
        expect(
          homeScrapeEntryHostedByChrome(
            apple: true,
            mobileLayout: mobileLayout,
            shellTitleVisible: false,
            tabHeaderHasEntry: false,
          ),
          isFalse,
          reason: 'mobileLayout=$mobileLayout：没有页头可承载入口，FAB 不能收走',
        );
      }
    });

    test('Apple：外壳大标题行可见（库页 / 浏览 / 查词）→ 入口在标题行动作位', () {
      for (final bool mobileLayout in <bool>[false, true]) {
        expect(
          homeScrapeEntryHostedByChrome(
            apple: true,
            mobileLayout: mobileLayout,
            shellTitleVisible: true,
            tabHeaderHasEntry: false,
          ),
          isTrue,
        );
      }
    });

    test('Apple：页头自带入口的 tab（视频库）→ 不再画 FAB', () {
      expect(
        homeScrapeEntryHostedByChrome(
          apple: true,
          mobileLayout: false,
          shellTitleVisible: true,
          tabHeaderHasEntry: true,
        ),
        isTrue,
      );
    });

    test('MD3：手机并进悬浮底栏，桌面画右下 FAB（与标题行无关）', () {
      for (final bool shellTitleVisible in <bool>[false, true]) {
        expect(
          homeScrapeEntryHostedByChrome(
            apple: false,
            mobileLayout: true,
            shellTitleVisible: shellTitleVisible,
            tabHeaderHasEntry: false,
          ),
          isTrue,
        );
        expect(
          homeScrapeEntryHostedByChrome(
            apple: false,
            mobileLayout: false,
            shellTitleVisible: shellTitleVisible,
            tabHeaderHasEntry: false,
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
      src,
      contains(
        '_shellFabHostedByBar = _scrapeEntryHostedByChrome(mobileLayout: false);',
      ),
      reason: '桌面布局',
    );
    expect(
      src,
      contains(
        '_shellFabHostedByBar = _scrapeEntryHostedByChrome(mobileLayout: true);',
      ),
      reason: '移动布局',
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
    // 右下 FAB 仍由这一位门控。
    expect(src, contains('controller.isBusy && !_shellFabHostedByBar'));
  });
}
