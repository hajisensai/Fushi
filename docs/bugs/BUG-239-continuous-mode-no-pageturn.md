## BUG-239 · 连续/滚动模式滑动无法翻页（手势轴向与原生滚动冲突）

- **报告**：2026-06-13（TODO-290 ①：滚动/连续模式没办法翻页；书：転生王女と天才令嬢の魔法革命）
- **真实性**：✅ 真 bug。沿真实代码路径定位到手势轴向错配。
- **根因**：阅读器统一手势处理 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` 的共享 setup 脚本 `_gestureEnd`（`reader_hibiki_page.dart:2124`）只在 **水平滑动**（`absDx > absDy`）时回传 `onSwipe`。这套逻辑是为 **分页模式** 设计的：分页模式 CSS（`reader_content_styles.dart:411` `touch-action:none`）禁掉了原生 pan，水平滑动是唯一翻页通道。
  - 但 **连续模式** 没有 `touch-action:none`，靠的是 **原生滚动**，且滚动轴 = 书写轴（横排 → 竖向滚动；竖排 → 横向滚动，见 `reader_content_styles.dart:449` `_continuousLayoutCss` 的 `overflow` 轴）。
  - 横排书连续模式下：用户做竖向滑动（= 原生滚动方向）翻屏时，`_gestureEnd` 因 `absDy > absDx` 直接 return 不回传 `onSwipe` → 翻页动作被原生滚动「吞掉」，主观上「没办法翻页」；而横向滑动（非滚动轴）却错误触发 `onSwipe` → 连续 `paginate()`（`reader_pagination_scripts.dart:1515`）沿滚动轴跳 90%，与刚发生的原生滚动叠加成轴向冲突 / 误响应。竖排书方向关系相反，同样错配。
  - 章间切换在连续模式由边界手势 IIFE（`reader_pagination_scripts.dart:1716` 的 `onBoundarySwipe`）负责，只在滚到首/末边界才触发。
- **[x] ① 已修复**：给共享 setup 脚本注入 `continuousMode` 布尔标志，`_gestureEnd` 的 `onSwipe` 回传改为「仅分页模式」。连续模式下交给原生滚动（沿滚动轴的翻屏）+ 边界 IIFE（章间切换）+ 按钮/键盘/音量键 `_paginate` 连续分支（`reader_hibiki_page.dart:5466` 调 `window.scrollBy` 90%），消除横向滑动 90% 跳页与原生滚动的轴向冲突。分页模式行为完全不变。`reader_hibiki_page.dart:_gestureEnd` 改动 + setup 脚本注入 `continuousMode`。
- **[x] ② 已加自动化测试**：
  - 源码守卫 `hibiki/test/pages/reader_continuous_swipe_axis_guard_static_test.dart`：断言 setup 脚本注入了 `continuousMode` 标志、`_gestureEnd` 的 `onSwipe` 触发被 `!continuousMode` 门控（连续模式不发跨轴 onSwipe）。
  - 纯函数行为：连续模式翻页轴向判定纯谓词 `ReaderPaginationScripts.continuousSwipeShouldPaginate`（恒 false：连续模式 `_gestureEnd` 不发 onSwipe）+ 分页模式仍按轴向判定，单测 `hibiki/test/reader/continuous_swipe_axis_test.dart`（红→绿）。
- **备注**：触摸手感（原生滚动顺滑度 / 边界章节切换）属手势敏感问题，声明「修好了」前需真机/模拟器复测横排 + 竖排两种书在连续模式下的滚动翻屏与到边界跨章；本轮只到代码 + 单测层。
