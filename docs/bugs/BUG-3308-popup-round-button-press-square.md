## BUG-3308 · 查词弹窗点「+」制卡按钮时闪出完全直角的方块
- **报告**：2026-10-13（用户：反馈 #qFuEIpcwsC，Windows 视频页查词弹窗「点击制卡按钮，会出现一个蓝色方框背景」；补充说明：大小与按钮差不多、完全直角、像选中时的背景）
- **真实性**：✅ 真 bug，已在真 Windows app 复现。
  - **根因**：`fushi/assets/popup/popup.css` 中 M3E 圆形图标按钮的按压形变（设计如此，保留）。静息圆角用的是 corner-full 的哨兵值 999px（词条头按钮 `html.fushi-m3e .header-buttons > .inline-action-button`，修前 :3000；通用 `html.fushi-m3e .inline-action-button`，修前 :3208；句子上下文步进按钮，修前 :3251）。按下时 border-radius 过渡到 corner-medium 12px（通用规则是 corner-small 8px），曲线是会过冲的弹簧 `--md-sys-motion-spring-fast-spatial: cubic-bezier(0.42, 1.67, 0.21, 0.90)`（峰值进度约 1.092）。插值 `999 + (12 − 999)·p` 在 p > 1.013 时就是负数，被钳成 0px，所以**每次按下都有约 120ms 是完全直角的方块**，随后才回弹到 12px 的圆角方块。用户看到的「直角方形背景」就是这一段。
  - **证据**（截图都在本机 `C:\Users\wrds\.claude\jobs\678f980d\tmp\probe-sq\evidence\`，不入库）：
    - Edge 无头 + CDP 真鼠标，逐帧采样真实 popup.html/js/css 的 computed border-radius：+ / ☆ / ♪ 三颗按钮都在按下后 119–237ms 恒为 `0px`（`edge-before-170ms.png` 是直角方块）。第一轮探针只在按下 500ms 后取样，正好错过这一段，所以当时误判为「复现不出」。
    - 真 Windows app：`run_windows_itest.ps1 -Visible`，视频页查词浮层（DictionaryPopupWebView，WebView2 透明背景）。用 SendInput 级 `mouse_event` 真按「+」，按住期间用桌面级 `Graphics.CopyFromScreen` 每 40–100ms 截一帧合成后的像素。暗色主题下按下后第二帧是**完全直角的方块**（`real-before-square.png`，整列见 `real-before-sheet-dark.png`）。
  - **已排除**：
    - 选区：按钮带 `user-select: none`，单击、双击、三击、拖动后选区都为空。
    - 焦点环：鼠标聚焦时 `:focus-visible` 为 false。
    - 父元素 :active / :focus-within 底色：全部透明。
    - 光标环：真 app 里 `#fushi-caret-ring` 不存在。
    - 触屏点按的默认高亮：已透明。
    - WebView2 合成层：按下的同一时刻 computed 值本身就是 0px，不是纹理问题。
  - **误判记录**：第一版提交 `a2568e6040` 把 M3E 形变整体当根因删掉了，已由 `1f25c6fe8f` 原样恢复；形变是设计，问题出在插值起点。
- **[x] ① 已修复** — 会做按压形变的正方形图标按钮（头部按钮、通用 inline-action-button、句子上下文步进按钮）静息圆角改为 `50%`：盒子是正方形，50% 就是正圆。插值从真实几何半径起算，过冲峰值处约 11.3px（40px 按钮），仍为正值。M3E 形变与弹簧回弹不变。三份 popup.css 已同步，两份扩展 content.css 由 `generate-content-css.mjs` 重新生成。修后：
  - Edge 逐帧采样不再出现 0px（最小约 calc(−4.6% + 13.1px) ≈ 11.3px），`edge-after-170ms.png` 是圆角方块；
  - 真 app 亮色主题连按 4 次、每 40ms 截一帧，只有「整圆 → 圆角方块」的形变，没有直角帧（`real-after-4presses.png`）。

  提交 `9aa591460d`。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/popup_round_button_press_radius_bug3308_test.dart`：从 popup.css 读出弹簧曲线算过冲峰值，再读静息/按压半径，断言过冲峰值处半径 > 0。另用 999px 跑同一公式断言 ≤ 0，作为反向对照。变异实测：换回 develop 的 popup.css 后 3 条红。
- **备注**：
  - 真 app 复现用的临时探针（`popup_mine_press_square_*probe_itest.dart` 与 `press_capture.ps1`）依赖本机真鼠标与桌面截屏，没有入库，留在上面的 evidence 目录。
  - 本机跑 Windows itest 时，flutter 3.47 会选中缺组件的 VS BuildTools，报「Unable to find suitable Visual Studio toolchain」。本次用一个只在本机临时生效的 vswhere 垫片（`ProgramFiles(x86)` 指向它、只返回 Community 实例）绕过，未改系统与仓库。
  - 真机暗色主题的「修后」样本因 Anki 窗口遮挡（WindowFromPoint 命中 Anki 进程）两次没跑成，亮色主题样本完整。
