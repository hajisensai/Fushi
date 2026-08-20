import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

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
      'assets/browser_extension/vendor/popup.js',
      'assets/browser_extension/vendor/popup.css',
      '随包扩展 vendor 副本',
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

  for (final (String jsPath, String cssPath, String label) in mirrors) {
    test('$label: layoutMasonry 不得回退到不存在的 CSS 原生分支', () {
      final File js = File('${Directory.current.path}/$jsPath');
      // 缺席即判红，不再静默 return：静默自禁用会让守卫在最该说话时闭嘴
      // （三镜像本就必须逐字节一致，缺一份本身就是问题）。
      expect(js.existsSync(), isTrue,
          reason: '\$label: 找不到 \$jsPath —— 三镜像必须齐全');
      // 词法遮蔽而非手写剥行：test/tools/source_guard_adoption_test.dart 明令禁止
      // startsWith 那种形态；且 JS 有模板串与正则字面量，裸剥行会错。
      final String jsCode = maskJsComments(js.readAsStringSync());

      // ① 断言面是**整份文件**，不是 layoutMasonry 的函数体。
      //    原守卫只切 `function layoutMasonry(` 到下一个换行 function 之间，于是
      //    observeMasonryTargets / scheduleMasonry 里残留的两处
      //    `if (HAS_NATIVE_MASONRY || ...)` 完全扫不到 —— 删了 const 声明却漏删引用，
      //    运行时 ReferenceError，弹窗每次渲染后调 fushiRelayoutDictionaries 都炸，
      //    而守卫全绿。断言字面量：HAS_NATIVE_MASONRY。
      expect(
        jsCode,
        isNot(contains('HAS_NATIVE_MASONRY')),
        reason: '$label: 可执行代码里仍出现 HAS_NATIVE_MASONRY。它要么是「原生 '
            'masonry 就整体放弃」的死分支（CSS 侧没有对应实现，命中即退化成行对齐 '
            'grid、矮卡下方留空洞），要么是删了声明没删干净的悬空引用（运行时 '
            'ReferenceError，masonry 直接不工作）。两种都不允许。',
      );

      // ② 更一般的不变式：JS 代码只要**检测**某个原生 masonry 特性，CSS 就必须真的
      //    用上它；否则这个检测只能通向死分支。
      final File css = File('${Directory.current.path}/$cssPath');
      expect(css.existsSync(), isTrue,
          reason: '$label: 找不到 $cssPath —— 缺席会让下面这条检查静默失效');
      final String cssCode = css.readAsStringSync();
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
