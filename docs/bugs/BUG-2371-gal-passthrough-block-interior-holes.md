## BUG-2371 · 穿透态点字幕文字有时仍透给游戏（行盒并集在块内部留 alpha 0 空洞）
- **报告**：2026-09-09（用户：「悬浮字幕，下面的文字点击的时候有时候会传到下面的游戏」）
- **真实性**：✅ 真 bug，且**是 [[BUG-1853]] 自己在「已知缺口」里写下、当轮未修的那条**。
  根因 `fushi/windows/runner/floating_lyric_window.cpp` `Render()` 的 catch fill 循环。

### 根因

穿透态整窗背景是真 alpha 0（`body_bg &= 0x00FFFFFF`），命中判定整个交给
`UpdateLayeredWindow` 的逐像素 alpha。BUG-1853 把碰撞箱从「字形轮廓」放大到
「文字**行盒**并集」，但行盒宽度是 `HitTestTextRange` 给出的**该行文字实际排版范围**，
于是文字块**内部**仍剩三类 alpha 0 空洞，点上去照样推进游戏：

1. **空行**（台词含连续换行）得到宽度 0 的行盒，`FillRectangle` 一个像素都画不出
   → 文字块中间横着一条整行高的漏点带。（BUG-1853 文件里已记，未修。）
2. **多行参差时短行两侧的内凹**——居中对齐（`text_alignment` 默认 CENTER）时尤其明显：
   长行与短行之间那两块楔形区在块内部，视觉上就是「字幕这一块」，判定上却是背景。
3. 行与行之间若排版留了缝，缝里同样是 0。

三类的共同点是：**用户明明点在字幕这一块上，却被判成点背景**。「有时候」正是它——
命中与否取决于这一句有没有换行、有几行、行长差多少。

### 修复

- **[x] ① 已修复** — 碰撞箱从「逐行行盒并集」改成「**文字块的外接矩形**」：对
  `HitTestTextRange(0, text_.size())` 的行盒取 min/max 并成一个矩形，`FillRectangle`
  一次。零宽行盒只跳过**横向**并集、**纵向照并**（它就是那条漏点带）。
  - 这是消除特殊情况，不是加分支：没有为空行写 `if (m.width <= 0) 用整行宽` 的特例。
  - 块**外**（上下留白、居中块两侧的整片空白）仍是真 alpha 0，
    「点背景推台词」的不变式一字不动。
  - **单行文本时外接矩形 == 那一行的行盒，逐像素等于改动前**（Never break userspace）。

- **[x] ② 已加自动化测试** — `fushi/test/tools/gal_overlay_passthrough_dual_window_guard_test.dart`
  的 BUG-1853 那条改钉新不变式：`min_left/min_top/max_right/max_bottom` 四个并集变量在位、
  `FillRectangle(` 在该块内**只出现一次**（出现多次 = 退回逐行铺，漏点带回来）、填的就是
  `D2D1::RectF(min_left, min_top, max_right, max_bottom)`、零宽行盒只跳横向。
  同时把该守卫从**固定 2200 字符窗口**改成**结构锚**（块尾锚 `// Highlight range background.`），
  否则往块里插几行合法代码就会让它错位变红——见 `reference_literal_pinned_wiring_guards_break_on_gating`。

### 备注

- 用户真实设置（读生产库 `D:\APP\HIBIKI_date\support\fushi.db` 确认）：
  `gal_hook_passthrough_blocks_mouse` 未设 = 默认 `true`，所以 catch fill 这条路是开着的，
  症状只可能来自块内部空洞；浮窗 rect `2618x219` 物理 px（宽而扁，居中对齐下内凹面积大）。
- 尚未在真实游戏上复测（真机验证缺口），只有编译 + 源码守卫。
