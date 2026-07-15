## BUG-838 · 视频字幕点字查词被进度条隐形热区抢成seek跳走

- **报告**：2026-07-15（用户：冷盈閑酔 / shishamo，飞书群）
- **真实性**：✅ 真 bug。根因不在"谁优先级高"，而在两处叠加：
  1. **几何**：控制条可见时字幕被抬到进度条上缘（`_paddingFor` 取 `max(bottomBase, controlsBottomReserve)`，`hibiki/lib/src/media/video/video_subtitle_overlay.dart` 底部锚点分支），而 media_kit 进度条的**透明触摸热区向上生长**（`_videoSeekBarContainerHeightBase=40`×缩放，`hibiki/lib/src/pages/implementations/video_hibiki_page.dart`），覆盖到被抬起的字幕底行 → 点字命中热区。
  2. **命中拦不住**：进度条 seek 走 media_kit `MaterialSeekBar` 的**裸 `Listener.onPointerDown/onPointerUp`**（`onPointerUp` 直接 `player.seek(...)`，pub-cache `media_kit_video-2.0.1/.../material.dart:1671-1674`），Listener **不参与手势竞技场**。字幕查词识别器 `_SubtitleCharTapRecognizer` 即便赢竞技场也拦不住它，只要 pointer-down 命中路径穿透到 Listener 就会 seek。旧 `_wrapInteractive` 恒 `HitTestBehavior.translucent`，字幕字符上的 tap 无条件穿透到下层进度条。
- **[x] ① 已修复** — 提交 `2f410b780`：在 `_wrapInteractive` 的 `RawGestureDetector` 外再套 `_GlyphPriorityHitTest`（`hibiki/lib/src/media/video/video_subtitle_overlay.dart`）。命中字符 glyph（判据 `_hitEntryIndexAt(global) >= 0`，与查词识别器同一条）时 `hitTest` 返回 `true` **吸收指针**，父 `Stack` 就此止步、不再命中下层进度条 Listener（seek 被截断）；落在字缝/空白/盒外返回 `false`、保持 translucent 穿透 → 进度条 seek、点画面唤起控制条一切照旧（BUG-198/553 non-opaque 穿透纪律不回归）。桌面 hover（Shift 查词 / 显形）走外层 `opaque:false` MouseRegion（本层祖先），不受截断影响。
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/video_subtitle_lookup_seek_priority_test.dart`（提交 `2f410b780`）：把下层建模成与 media_kit 一致的**裸 `Listener`**（而非旧 fallthrough 测试的 opaque `GestureDetector`——正是那个失真模型放过了本 bug）。断言：点字符→查词触发且 `Listener.onPointerUp` 不触发（seek 截断，计数 0）；点字缝→不查词且穿透到 Listener（seek 照常，计数 1）。已验证：临时禁用吸收层后"点字→seek 截断"用例转红，证明守卫有牙。
- **备注**：仅方案 A（查词 glyph 命中优先）。方案 B（去掉/收窄 `_paddingFor` 的 reserve 避让，让字幕不再被抬到进度条上缘）作为观感优化后续单独评估，本次不动，避免回归 BUG-226/238 的视觉遮挡避让。真机复测原始失败路径（移动端控制条可见时点字幕底行词）待用户验收。
