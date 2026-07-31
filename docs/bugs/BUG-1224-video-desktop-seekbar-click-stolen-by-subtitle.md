## BUG-1224 · 桌面视频点进度条被字幕吸走成查词
- **报告**：2026-07-28（用户：点进度条时进度条会下去、点成了字幕查词，附全屏截图——字幕行紧贴进度条上方，且 seek hover 缩略图预览正显示在同一位置）
- **真实性**：✅ 真 bug（桌面几何恒定重叠，非偶发）。根因 `hibiki/lib/src/media/video/video_subtitle_style.dart:87-89`（旧桌面分支 `return buttonBarHeight`），几何来源 `third_party/media_kit_video/lib/media_kit_video_controls/src/controls/material_desktop.dart:873-878`（写死 `Transform.translate(Offset(0, 16))`）+ `:1228-1231`（`seekBarContainerHeight` 高的透明命中容器 + 裸 `Listener`），吸收层 `hibiki/lib/src/media/video/video_subtitle_overlay.dart:2445-2460`（`_RenderGlyphPriorityHitTest.hitTest`）。

### 根因
桌面 seek bar 的**可点区域不是那条可见轨道**：`MaterialDesktopSeekBar` 把一个 `seekBarContainerHeight`（fork 默认 36）高的**全透明** `Container` 包在裸 `Listener` 里（`onPointerUp` 直接 `player.seek`），可见轨道只有 3.2px 且在容器里竖直居中；容器又被 `Transform.translate(Offset(0,16))` 整体下压去骑按钮行上沿。于是热区实际占据

```
[buttonBarHeight − 16 , buttonBarHeight − 16 + 36]   （离视频底边）
```

即**上缘比按钮行高再高 20px**，那 20px 正好探出按钮行、露在按钮行上方。

而字幕避让 `videoSubtitleControlsReserve` 的桌面分支只 `return buttonBarHeight`——它让出的是**可见轨道**所在高度，不是热区上缘。字幕底缘（`max(用户 bottomPadding, reserve)`）因此恒落在这段热区里。字幕层在 controls Stack 之上（`video_hibiki/layout.part.dart:257` vs `:323`），且 BUG-838 起对命中 glyph 的指针**主动吸收**（`_GlyphPriorityHitTest.hitTest` 返回 true，截断父 Stack 向下命中）——指针根本到不了 seek 的裸 `Listener`。

症状因此表现为「看得见能点、点下去却是查词」：hover 走 `opaque:false` 的 `MouseRegion`、不被吸收，所以缩略图预览照常出现（用户截图里预览正显示），但按下就被字幕赢走 → 弹查词 + 视频暂停（控制条随即淡出＝用户说的「进度条会下去」），seek 从未发生。

同一根因的第二症状：在重叠带按下并拖动想 scrub，指针被吸收层截断（seek 收不到 pointerDown），而 tap 识别器又因超 slop 被 reject → 既不 seek 也不查词的死区。

**为什么移动端没事**：BUG-901 已把移动 reserve 改成「触摸热区上缘 + 呼吸间距」，桌面分支当时没跟上（BUG-838 备注里写的「方案 B（收窄 reserve 避让）后续单独评估，本次不动」就是这里）。这是平台特例分支各自腐化的典型：不变量（字幕命中区必须清出整段 seek 命中区）本该无分支。

### 修复
- fork 把写死的下压量提成主题字段 `seekBarBottomButtonBarOverlap`（默认仍 16.0，渲染逐像素不变），`Transform.translate` 改读它；见 `third_party/media_kit_video/PATCHES.md` 的 BUG-1224 段。
- 桌面 theme 显式传 `seekBarContainerHeight` / `seekBarBottomButtonBarOverlap`（36 / 16，仍不随缩放，外观不变），于是**控制条布局**与**字幕避让**读同一份常量，不再一个吃 fork 构造器默认、一个靠猜。
- `videoSubtitleControlsReserve` 改成：先按平台算**热区下缘**，再统一 `+ 热区全高 + 呼吸间距`。安全不变量（reserve ≥ 热区上缘）两平台同一条、无分支，桌面不会再单独腐化。
- 页面新增 `_activeSeekBarContainerHeight` / `_activeSeekBarButtonBarOverlap`，保证避让永远用**当前平台 theme 真实生效**的值（桌面 36 不随缩放 / 移动 40×缩放）。

数值：桌面 reserve 由 `56×scale` 变为 `56×scale − 16 + 36 + 8×scale`（scale=1.0 时 84）。仍小于 BUG-228 被用户否掉的 98，默认基线 75 下字幕只多抬 9px；控制条隐藏后字幕照旧落回用户基线。

- **[x] ① 已修复** — 见本次提交（fork 主题字段 + 桌面 theme 显式几何 + reserve 改用热区上缘）。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/video/video_subtitle_style_test.dart`「桌面 reserve = 进度条触摸热区上缘 + 呼吸间距…」：钉死 84 / 不变量 `reserve ≥ 热区上缘` / 防退回 `> buttonBarHeight` / BUG-228 不回归 `< 98`，并在缩放 2.0 下复验不变量。
  - `hibiki/test/pages/video_subtitle_push_up_guard_test.dart`「BUG-1224：桌面 theme 与字幕避让读同一份进度条几何…」：扫 fork 确认下压偏移读主题字段（写死 `const Offset(0.0, 16.0)` → 红）、命中容器高读主题字段，并扫页面确认桌面 theme 显式传两项、reserve 用 `_active*` 而非移动端值。
  - 变异实测（三条各自单独还原成旧写法后复跑，全部真红）：fork 退回写死偏移 → guard 159 行红；页面退回 `_videoSeekBarContainerHeight` → guard 128 行红；纯函数退回 `if (isDesktop) return buttonBarHeight` → 单测 332 行红。

### 备注 / 遗留
- 控制条淡入 150ms 与字幕 `AnimatedPadding` 200ms 不同相位：淡入途中字幕尚未抬到位，那一小段时间内重叠仍在（seek bar 一 mount 就可命中）。属瞬态、未在本次处理；若真机上仍能稳定复现「刚唤出控制条就点不中进度条」，再按「避让必须先行于命中」单独立项。
- `videoSeekBarTrackBand` 桌面分支把轨道中线近似成 `buttonBarHeight`（真实是 `buttonBarHeight + 2`），章节刻度因此有 2px 偏差——既存、与本 bug 无关，未一并改。
- 真机验收未做（本轮为离线定位 + 单测/守卫层验证）：需在 Windows 真机沿原始失败路径复测「点进度条上缘 20px 带 → 真 seek、不弹查词」，以及界面缩放放大后同样成立。
