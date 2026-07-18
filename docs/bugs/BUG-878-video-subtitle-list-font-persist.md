## BUG-878 · 字幕列表字号每次重开重置且上限太小
- **报告**：2026-07-18（用户：看 2 分钟动漫默认设置反馈，第 2 点）
- **真实性**：✅ 真 bug（两点均成立）。根因 `hibiki/lib/src/media/video/video_subtitle_jump_panel.dart`：① 字号档 `_fontScaleIndex` 是面板本地 State（初值硬编码 1）、`_stepFont` 只 `setState` 无持久化回调 → 每次重开面板回默认档（对比同面板「自动滚动」有 `onAutoScrollChanged` 落盘）；② 上限写死 `_kFontScaleSteps` 最后一档 = **1.3×**（有效字号 ≈ 18.2），用户「拉到最大才够用、还不够」。
- **[x] ① 已修复** — 扩展 `_kFontScaleSteps` 追加 `1.5/1.75/2.0`（上限 1.3→**2.0×**）；新增持久化字段 `videoSubtitleListFontScaleIndex`（`preferences_repository.dart` + `app_model.dart`，默认档 1）；面板加 `initialFontScaleIndex`（种子化 `_fontScaleIndex`，clamp 防越界）+ `onFontScaleIndexChanged`（`_stepFont` 落盘）；`subtitle.part.dart` 接线读 / 写 appModel。另加 **Ctrl/⌘+滚轮缩字号**（浏览器式）：面板体 `Listener(onPointerSignal)` 步进字号，配 `HardwareKeyboard` ctrl 键处理器在按住时把 ListView 物理切 `NeverScrollableScrollPhysics` 抑制列表滚动，松开恢复。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_jump_panel_test.dart`（`initialFontScaleIndex:6` 种子字号 = 28 = 2.0×基准 + A+ 越界禁用；A+/A- 触发 `onFontScaleIndexChanged` 报新档位）；`hibiki/test/pages/video_subtitle_list_zoom_lookup_wiring_guard_test.dart`（BUG-878 组：初值读 / setter 落盘接线）。
- **备注**：与 BUG-877 同一 PR。修复提交 `96763ac23`。Ctrl+滚轮抑制列表滚动的手感需真机验收。
