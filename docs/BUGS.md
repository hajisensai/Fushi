# Bug 跟踪

> 约定（Claude/Codex 必须遵守）：用户报一个 bug → **先沿真实代码路径验真伪**（复现或定位根因）。
> - **是真 bug** → 追加一条到本文件（分配 `BUG-NNN`，记报告日期、根因 `file:line`），然后：
>   - **① 修复**这个 bug（根因修，不补丁），完成后勾 `[x] ①`，记提交哈希。
>   - **② 增加自动化测试**（在最强可落地层：真 widget 行为 / CSS 生成器 / 源码扫描守卫；纯视觉像素只能设备截图兜底并注明），完成后勾 `[x] ②`，记测试文件。
> - **不是真 bug / 无法复现** → 也记一条，标「未复现」并说明，不勾 ① ②。
> - reader/WebView/导入/播放/布局类修复：代码正确 + 单测无回归后，仍需**设备肉眼复测原始失败路径**（CLAUDE.md 验证纪律）；未做的在「备注」标注待补。
>
> 分层测试选型见 [docs/specs/2026-06-03-test-flow-refactor-*.md] 与各守卫测试范式
> （源码扫描：`test/pages/reader_paginate_lyrics_guard_static_test.dart` 的 `_functionSource`；
> CSS 生成器：`test/reader/reader_content_styles_test.dart`；widget 行为：`test/settings/`）。

---

## BUG-006 · 改 String 型 segmented 设置（书写方向/视图模式/振假名/跨页）渲染器崩溃
- **报告**：2026-06-03（由 settings schema 焦点驱动覆盖测试发现，非用户报告）
- **真实性**：✅ 真 bug。`material_/cupertino_settings_renderer.dart` 把 `SettingsSegmentedItem<String>` 经 `as <Object>` 转型，闭包读 `onChanged` 因函数参数逆变抛 `_TypeError`。两渲染器同病；现有测试只渲染不真改 segmented 所以潜伏。
- **[x] ① 已修复** — `07784a786`（两渲染器改 `(segmented as dynamic).onChanged` 绕开读取期检查）
- **[x] ② 已加自动化测试** — `test/settings/settings_renderer_test.dart`（material + cupertino segmented 改值不抛 _TypeError 回归用例）

## BUG-005 · 阅读器 live 设置 hook 异步异常逃逸 zone
- **报告**：2026-06-03（emulator app.main 跑设置覆盖 ~29s 未捕获异步错误，Workflow 根因排查）
- **真实性**：✅ 真 bug。`onSettingsChangedLive`/`onLayoutReloadLive` fire-and-forget 丢 Future；await 后 `_controller!.evaluateJavascript` 在 WebView 半销毁时抛 `PlatformException` 无 try/catch → 逃 zone，绕过所有 handler。改 reader 布局设置时若 reader teardown 竞态即触发。
- **[x] ① 已修复** — `a5b046c40` + `972147a8d`（两 hook unawaited+catchError 归 ErrorLogService；4 个 eval 点包 try/catch no-op）
- **[x] ② 已加自动化测试** — `test/reader/reader_live_settings_guard_test.dart`（源码扫描守卫 5 个 ErrorLogService tag + unawaited 在位）
- **备注**：半销毁竞态难确定性复现（reader 含真实 InAppWebView 无法 widget 挂载）；**设备复测待补**（改 reader 设置无逃异常）。

## BUG-004 · 设置页向下滑动会自动跳回上面，得再滑一下
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。纯触屏快速滚长设置列表，行回收 → `ensureFocus` 被动修复 re-home + `_maybeRevealOnRepair` reveal（居中）与手指方向相反把视口拽回。
- **[x] ① 已修复** — `f6ef60d27`（`_maybeRevealOnRepair` 门控到 `FocusHighlightMode.traditional`；touch 无光标 → 不 reveal）
- **[x] ② 已加自动化测试** — `test/settings/settings_scroll_no_rollback_test.dart`（真实渲染器，本会话补）+ `test/focus/focus_repair_touch_no_scroll_test.dart`（合成核心路径，已有）
- **备注**：本会话写设置专用测试时一度误把 `jumpTo(maxScrollExtent)` 后弹道 clamp 当成 reveal 拽回（懒加载列表 extent 不稳）；诊断确认 Hibiki reveal 门控正常、bug 已修，测试改成先 settle 再验。

## BUG-003 · 阅读器竖排模式下部分文本显示在刘海/notch 区域
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。竖排翻页轴是 scrollTop，column-gap（页间周期）须含 chrome insets，否则 pitch 比视口矮，上一页尾部漏进顶部刘海条。
- **[x] ① 已修复** — `ee9b2e1f6`（竖排 `column-gap` 含 `--chrome-top/bottom-inset`，pitch==pageHeight）
- **[x] ② 已加自动化测试** — `test/reader/reader_content_styles_test.dart:273-281`「vertical paginated column-gap includes both chrome insets」（CSS 生成器测试，已有，正是此 bug 的回归）
- **备注**：竖排排版的真实像素结果只能设备截图验；本测试守的是「生成的 CSS 契约正确」。

## BUG-002 · 阅读器切章时底栏（bottom chrome）闪烁
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。底栏可见性原耦合在「每切章翻转」的 `_readerContentReady`，切章瞬间硬卸载再挂回 → 闪烁。另有 spread（漫画双页）路径漏置位缺口。
- **[x] ① 已修复** — `84f1a22af`（门控改 set-once `_hasEverLoaded`）+ `7a8577347`（补 spreadReady 置 `_hasEverLoaded=true`，否则 spread 冷开底栏等 8s）
- **[x] ② 已加自动化测试** — `test/pages/reader_bottom_chrome_gate_static_test.dart`（源码扫描守卫：门控用 `_hasEverLoaded` 不用 `_readerContentReady`、spreadReady 置位、set-once 无复位）
- **备注**：切章无闪/spread 底栏即时出现的真实帧只能设备复测；**设备复测待补**。

## BUG-001 · 给书本打标签后封面展示异常
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。标签覆盖层 `_adaptiveTagColumn` 用 `Positioned(top,left)`（无 bottom/height）落进封面卡片 `Stack(fit: StackFit.expand)` → 子树拿到 unbounded `maxHeight==infinity` → `(maxHeight*0.55/22).floor()` 抛 `UnsupportedError: Infinity or NaN toInt`；覆盖层只在带 tag 时存在，故只在打 tag 后崩。
- **[x] ① 已修复** — `22b5bafc8`（抽纯函数 `adaptiveTagSlots` 加 `isFinite` 守卫，无界时渲染全部标签）
- **[x] ② 已加自动化测试** — `test/pages/adaptive_tag_column_layout_test.dart`（widget 真约束传播：`Positioned`-in-`StackFit.expand` 不抛 + 封面 sibling 满尺寸；纯函数 infinity/NaN/clamp 单测）
