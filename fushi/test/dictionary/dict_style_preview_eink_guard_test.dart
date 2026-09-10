import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2434 ②：词典样式预览（设置 › 词典样式，用户在这里调词典字体/字号/配色）
/// 跑的是**真的** `popup.html` + `popup.js`，文件开头明写「渲染路径与真弹窗同源」
/// ——但它此前只设 `data-theme`，从不设 `eink` class。
///
/// 真弹窗的 eink class 由 `popup_settings_injection` 的主题变量段 toggle，而
/// popup.css 的整个 `html.eink` 覆盖块（纯黑白变量 / 去阴影 / 去半透明卡底 / 方角 /
/// 线式高亮）全挂在它上面。少了它，墨水屏下用户是照着一份灰阶 + 圆角 + 阴影的预览
/// 去调样式，真弹窗却是另一个样子——正是那句「不自绘近似渲染」要避免的失真。
///
/// 这条只能做源码守卫：预览的渲染发生在真 WebView 里，单元测试环境没有 WebView，
/// 断言不到最终像素（与既有 `popup_instant_scroll_guard_test` 同处境）。故钉的是
/// 「注入链路上每一段载荷位都还在」。
void main() {
  const String previewPath =
      'lib/src/pages/implementations/dict_style_preview.dart';

  late String source;

  setUpAll(() {
    source = File(previewPath).readAsStringSync();
  });

  test('预览读得到墨水屏主题扩展', () {
    expect(
      source,
      contains('FushiEinkTheme'),
      reason: '预览必须从 Theme 读出墨水屏标志，否则永远按普通主题渲染',
    );
  });

  test('预览把 eink class toggle 到 documentElement 上', () {
    expect(
      source,
      contains("classList.toggle('eink'"),
      reason: 'popup.css 的 html.eink 覆盖块挂在这个 class 上；'
          '少了它整块样式在预览里不生效',
    );
  });

  test('用 toggle 而非 add：主题来回切要能摘除（与真弹窗同款）', () {
    expect(
      source,
      isNot(contains("classList.add('eink'")),
      reason: 'add 摘不掉——关掉墨水屏后预览会一直卡在黑白方角态',
    );
  });

  test('主题变化时会补推，而不是只在首次 bootstrap 推一次', () {
    expect(
      source,
      contains('didChangeDependencies'),
      reason: '只在 bootstrap 推一次的话，开着预览去翻墨水屏开关不会有任何反应',
    );
  });
}
