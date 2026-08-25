## BUG-1853 · 穿透态点到文字笔画镂空处直接透给游戏，碰撞箱应为行矩形
- **报告**：2026-08-25（用户：开启鼠标穿透模式时，点到文字镂空的地方就直接穿过去了，碰撞箱应该改成矩形）
- **真实性**：✅ 真 bug（[[BUG-1480]] 方案的固有属性，不是回归）。
  - 穿透态的「哪里可点」整个交给 OS 的 `UpdateLayeredWindow` 逐像素 alpha 判定：
    `floating_lyric_window.cpp` `Render()` 里穿透态无条件 `body_bg &= 0x00FFFFFF`，
    整窗背景真 alpha 0 → 「窗口存在的像素」只剩字形本身。
  - 于是口/国/目 的内部、笔画之间、字距、行距全是 alpha 0，OS 判「窗口在这里不存在」，
    点击落到游戏（推进台词 / 误触分支），点字查词变成看笔画粗细的运气。8 向描边只让
    笔画变粗，镂空依旧是 0。
  - 不是 `WS_EX_TRANSPARENT`（BUG-1480 已拆）、不是 `WM_NCHITTEST`（只回 HTBOTTOMRIGHT/HTCLIENT）、
    不是 `SetWindowRgn`（此窗无 region）、不是低阶鼠标钩子（它只盯查词卡窗）。
- **[x] ① 已修复** — 命中粒度从「字形轮廓」改成「文字行矩形并集」，机制一行不动：
  - `Render()` 在 `PushAxisAlignedClip(text_clip)` 之后、高亮之前，穿透态用
    `text_layout_->HitTestTextRange(0, text_.size())` 取 DirectWrite 排好版的逐行行盒
    （有注音时行盒已被 `SetLineSpacing` 加高，注音带自然在内），每个行盒
    `FillRectangle` 一层 `kHookTextMinCatchAlpha`（≈2%，不可见）的 catch fill——与非穿透
    态整窗 alpha 兜底同一技法（BUG-1046）。行盒内任意一点都成了窗口像素，行盒外仍是
    真 alpha 0，「点背景推台词」不变式保住。
  - 坐标换算与高亮框 / `CharIndexAt` 同一公式（`text_rect_.left + m.left`、
    `text_origin_y + m.top`），外层 `text_clip` 裁掉滚出视口的行。
  - 不走的路：回到 `WS_EX_TRANSPARENT` 按光标翻转（PR#460 已 revert 的竞态）、
    `SetWindowRgn` 裁行矩形（layered + region 丢逐像素语义）、低阶钩子按 rect 吞点击
    （把该给游戏的点击塞进全局钩子时序）。
- **[x] ② 已加自动化测试** — `fushi/test/tools/gal_overlay_passthrough_dual_window_guard_test.dart`
  新增「穿透态必须在文字行矩形内铺不可见 catch fill（BUG-1853）」：钉住守门条件
  `hook_text_mode_ && pass_through_ && !text_.empty()`、行盒来源 `HitTestTextRange(0, text_.size())`、
  alpha 用 `kHookTextMinCatchAlpha`、真 `FillRectangle`、且位于 `PushAxisAlignedClip(text_clip)` 之后。
- **备注**：⚠️ **真机未复验**（本轮真机验证已取消）。BUG-1480 的四条复验清单仍适用，第 ② 条改为
  「穿透态点文字块任意处（含笔画镂空、字距、行距）出查词卡且游戏不推进」；另加第 ⑤ 条
  「穿透态文字行盒外的空白（例如居中对齐时短行两侧）仍透给游戏」。
- **已知缺口（审查发现，本轮未修）**：`HitTestTextRange` 给出的行盒宽度是**该行文字的实际
  排版范围**，于是行盒并集里还剩两类 alpha 0 空洞：① 居中对齐时短行两侧的留白（这条是**有意**
  的，就是上面复验点 ⑤）；② **空行**（文本含连续换行）会得到宽度 0 的行盒，`FillRectangle`
  画不出任何像素 → 文字块中间横着一条整行高的漏点带，点上去仍会透给游戏推台词。若 hook 台词
  可能带空行，可把空行的行盒宽度兜底成 `text_rect_.width`。⚠️ 未真机复验。
