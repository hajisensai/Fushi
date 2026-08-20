import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 查词弹窗「词典方框排列」在 macOS 26 / Safari 26 上塌成行对齐 grid 的回归守卫。
///
/// 根因：`popup.js` 里有
/// ```js
/// const HAS_NATIVE_MASONRY = (() => {
///     try { return CSS.supports('display', 'grid-lanes'); } catch (e) { return false; }
/// })();
/// function layoutMasonry() {
///     if (HAS_NATIVE_MASONRY) return; // 浏览器原生 masonry 时交给 CSS（未来分支）
/// ```
/// 但 CSS 侧那条「未来分支」**从未写过**（全仓 `grid-lanes` 只命中这行检测本身）。
/// 2026-08 WebKit 开始支持 `display: grid-lanes` 后检测转真，JS masonry 直接放弃，
/// 布局退回 `.glossary-section > .category-body` 的行对齐 grid：同一行的词典卡按最高
/// 的那张对齐，已折叠 / 义项少的矮卡下方留出大片空洞。
///
/// 不变式：**特性检测只有在对应实现确实存在时才允许提前返回。** 只要 popup.js 还提
/// 到某个原生 masonry 特性名，同目录 CSS 就必须真的用上它；否则那个分支是死路。
void main() {
  // 两镜像：app 内弹窗、浏览器扩展 vendor 副本（CLAUDE.md 的「弹窗样式三镜像同步」）。
  const List<(String js, String css, String label)> mirrors =
      <(String, String, String)>[
    (
      'assets/popup/popup.js',
      'assets/popup/popup.css',
      'app 内查词弹窗',
    ),
    (
      '../tools/browser-extension/vendor/popup.js',
      '../tools/browser-extension/vendor/popup.css',
      '浏览器扩展 vendor 副本',
    ),
  ];

  /// 原生 masonry 的特性名（CSSWG 几度改名，都列上）。
  const List<String> nativeMasonryTokens = <String>[
    'grid-lanes',
    'item-flow',
    'grid-template-rows: masonry',
  ];

  /// 剥掉整行 `//` 注释——本测试要断言的是**可执行代码**，而解释这段历史的注释里
  /// 必然会提到 `grid-lanes` / `HAS_NATIVE_MASONRY` 本身（否则没人看得懂为什么禁）。
  String codeOnly(String source) => source
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  for (final (String jsPath, String cssPath, String label) in mirrors) {
    test('$label: layoutMasonry 不得回退到不存在的 CSS 原生分支', () {
      final File js = File('${Directory.current.path}/$jsPath');
      if (!js.existsSync()) {
        // vendor 副本可能在某些精简 checkout 里缺席；缺席不算违规。
        return;
      }
      final String jsCode = codeOnly(js.readAsStringSync());

      // ① layoutMasonry 体内不得有「原生 masonry 就整体放弃」的提前返回。
      final int start = jsCode.indexOf('function layoutMasonry(');
      expect(start, greaterThanOrEqualTo(0),
          reason: '$label: 找不到 layoutMasonry，守卫失去意义，请更新本测试');
      final int end = jsCode.indexOf('\nfunction ', start + 1);
      final String body =
          jsCode.substring(start, end > start ? end : jsCode.length);
      expect(
        body,
        isNot(contains('HAS_NATIVE_MASONRY')),
        reason: '$label: layoutMasonry 依据原生 masonry 支持度提前返回，但 CSS 侧'
            '没有对应实现——命中即整个词典方框排列退化成行对齐 grid（矮卡下方留空洞）。',
      );

      // ② 更一般的不变式：JS 代码只要**检测**某个原生 masonry 特性，CSS 就必须真的
      //    用上它；否则这个检测只能通向死分支。
      final File css = File('${Directory.current.path}/$cssPath');
      final String cssCode = css.existsSync() ? css.readAsStringSync() : '';
      for (final String token in nativeMasonryTokens) {
        if (!jsCode.contains(token)) continue;
        expect(
          cssCode,
          contains(token),
          reason: '$label: popup.js 的代码里检测了原生 masonry 特性「$token」，但 '
              '$cssPath 没有任何对应实现。特性检测必须以「实现存在」为前提，'
              '否则命中时布局会掉进死分支。',
        );
      }
    });
  }
}
