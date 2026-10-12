## BUG-3308 · 查词弹窗点「+」制卡按钮时背后出现直角方形底色
- **报告**：2026-10-13（用户：反馈 #qFuEIpcwsC，Windows 视频页查词弹窗「点击制卡按钮，会出现一个蓝色方框背景」；用户补充：大小与按钮差不多、完全直角、像选中时的背景）
- **真实性**：⏳ 未复现，根因未定。
  - **已排除（第一版误判，已回退）**：M3E 按压态把整圆收成 12px 圆角方块（`popup.css` 词条头按钮 `:active`）是**设计如此**的 M3E 形状变化，有圆角，不是用户说的直角方块。第一版提交 `a2568e6040` 把它当根因删掉了，已由 `1f25c6fe8f` 原样恢复（含 `popup_ctx_adjust_button_m3e_guard_test` 的原断言）。
  - **Edge 无头复现（真实 popup.html + popup.js + popup.css，CDP 真鼠标事件）**：MD3/M3E 与 Apple 两套样式，各做单击、快速双击、三击、按住小幅拖动、从按钮拖进词头五种操作，每种都在操作后 150ms 与松开 900ms 后分别读 `getSelection()`、按钮及全部祖先计算后的 `background-color` / `outline` / `box-shadow` / `:focus` / `:focus-within` / `:active`，并截图。结果：选区恒为空（按钮 `user-select: none`，双击/三击也选不中任何东西）；没有任何祖先出现非透明底色、outline 或 box-shadow；按钮被鼠标聚焦时 `:focus-visible` 为 false（M3E 头部按钮本就 `outline: none`）；截图没有直角底色。`-webkit-tap-highlight-color` 已在 `html` 上设为透明。**所以该现象不在弹窗 CSS 和 DOM 层**，在 headless Chromium 中复现不出来。
  - **剩余候选**（都在 Edge 无头之外，需要真机证据）：① Windows 宿主的 WebView2 是 composition 模式（`transparentBackground: true`，经 Graphics Capture 转成 Flutter 纹理）：按下时按钮的 transform 过渡会生成独立合成层，透明背景下的合成层可能在纹理里露出方块；② 视频页的选词光标环（`reader_caret_scripts.dart` 的 `#fushi-caret-ring`：主题主色、2px 描边、3px 圆角，外扩 1px 包住按钮）。阅读器在切到鼠标时会调用 `caretSuspend()` 隐藏光标环（`reader_fushi_page.dart:3446`），视频页没有这一步。所以只要光标曾用键盘或手柄进过弹窗，之后再用鼠标点，光标环也会一直留着。不过它是空心框，不是填充背景。
- **[ ] ① 未修复** — 等真机截图或录屏后再定根因。
- **[ ] ② 未加自动化测试** —
- **备注**：反馈附带的截图数为 0。下一步：请用户提供按下时的截图或录屏，或在真 Windows app 里用 SendInput 真鼠标加桌面 BitBlt 抓合成后的像素（CDP 截图拿不到纹理那一层）。
