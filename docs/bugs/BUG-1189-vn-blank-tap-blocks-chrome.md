## BUG-1189 · 视觉小说模式点空白只翻页，控制栏（菜单）永远唤不出
- **报告**：2026-07-28（用户：书籍的视觉小说模式，打不开菜单啊，点屏幕只会翻页）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:1043`（`_gestureEnd` 的 VN 分支直接 `window.hoshiReader.paginate('forward')` 并 return，抢在查词 / `onTapEmpty` 之前）。

  完整因果链：
  1. VN 是唯一把「点空白」绑成翻页的 view-mode（`vnMode && vnClickAdvance && _hoshiVnTapIsBlank(x, y)`），该分支排在 tap 分发链最前，命中即 `return`。
  2. `onTapEmpty`（`webview.part.dart:1856`）是**触屏唯一**能唤出控制栏的通道：悬浮态走 `_handleFloatingChromeReveal`、挤压态走 `_toggleChrome`（`chrome.part.dart:908/1017`）。
  3. `tap_empty_hide_chrome` 默认 `true`（`reader_settings.dart:485`）⇒ 底栏是悬浮态，`_armChromeAutoHide` 计时（默认 3s）后自动收起。
  4. 于是 VN 下底栏一旦自动收起：点文字=查词、点空白=翻页，**没有第三条路** ⇒ 菜单永久不可达。分页/连续模式无此分支，故只有 VN 复现。
  5. JS 侧无法自救：门控镜像 `window.__hoshiTapGate.chrome` 映的是 `_showChrome`，悬浮态下恒 `true`，区分不出「已自动收起」——可见性的真值 `_chromeTransientVisible` 只在 Dart 侧。

  同一处附带的旧漏：JS 直调 `paginate` 丢弃返回值，屏到章末返回 `"limit"` 无人处理 ⇒ VN 点击推进到章末即卡住（跨章只有滑动/键盘路径有）。

- **[x] ① 已修复** — 提交 `68f4ffe9c`。把「翻页还是唤栏」的决策从 JS 移交给状态拥有者 Dart，语义定为**唤出优先**（与仓库既有语义同款：防剧透图「揭开优先」、歌词模式点空白无条件唤出底栏）：
  - `webview.part.dart`：VN 空白点只回传事实 `callHandler('onVnBlankTap')`，不再自己 paginate；新增 `onVnBlankTap` handler。
  - `chrome.part.dart` `_handleVnBlankTap()`：唯一决策点。清弹窗栈 / 清选区 / 焦点 reclaim 与 `onTapEmpty` 同语义，然后按三态分派——挤压态收起 → `_toggleChrome()`；悬浮态已收起 → `_handleFloatingChromeReveal()`；底栏此刻可见 → `_paginate(ReaderNavigationDirection.forward)`（顺带修好 ④：跨章 / 节流 / caret 重锚全部与滑动、键盘路径一致）。
  - `reader_chrome_floating.dart`：新增纯谓词 `bottomBarVisible` / `readerVnBlankTapAction` + `ReaderVnBlankTapAction`；`_bottomBarShouldPaint` 改为委托 `bottomBarVisible`，使「底栏此刻可见吗」与「这一下该不该翻页」读同一套规则，不可能漂开。
  - 不改 `vn_click_advance` 语义、不加新设置、不发明菜单热区；VN 的滑动翻页不经此路径，用户不会被卡在「翻不动页」。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/vn_blank_tap_chrome_reveal_bug1189_test.dart`：
  - 纯谓词三态真值表（含本 bug 的原始失败路径「悬浮态已自动收起 → 必须先唤出」）；
  - 逐格对齐断言：`readerVnBlankTapAction == advance` 必须与 `bottomBarVisible` 同真同假（8 种组合全枚举），钉死「底栏叫不出来」与「底栏已在却不翻页」两种回归；
  - 源码守卫：JS 不得再出现 `window.hoshiReader.paginate('forward')`（去注释后扫描）、必须 `callHandler('onVnBlankTap')`、handler 已注册、`_handleVnBlankTap` 三条分支齐全且翻页走 `_paginate`、`_bottomBarShouldPaint` 委托单一真相源。

  连带更新两处既有守卫（它们钉的正是被修掉的旧结构）：`test/reader/vn_view_mode_three_state_guard_test.dart`（M0 blank-tap 断言改为「回传 Dart」）、`test/pages/reader_bottom_chrome_gate_static_test.dart`（`_hasEverLoaded` set-once 不变式随提取拆成「页喂参数」+「纯函数硬门」两半，强度不降）。
- **备注**：headless 跑不到真实 WebView 几何与自动收起计时，真机复测点为——VN 模式开书 → 等底栏自动收起 → 点空白：应先唤出底栏（不翻页）→ 底栏可见时再点空白：应推进一屏 → 底栏收起后再点：应再次唤出。另需复测 VN 章末点击能否跨章（旧实现卡死）。
