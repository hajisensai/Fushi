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

## BUG-009 · 桌面端「外观→iOS(Cupertino)」设置页崩坏：三栏拥挤 + 右下角 RenderFlex 溢出 + 无返回出口
- **报告**：2026-06-03（用户，附两张截图：切 iOS 前为正常 Material 全屏二栏；切 iOS 后变成「最左 Material 药丸 3 图标侧栏 + 中间 Cupertino insetGrouped 目标列表 + 右侧详情底部黄黑条纹溢出」，无返回箭头）
- **真实性**：✅ 真 bug（代码追踪 + Win11 真机截图双确证）。两个独立根因：
  - **R1 详情溢出**（右下黄黑条纹）：`CupertinoSettingsRenderer.buildDetailContent`(`hibiki/lib/src/settings/cupertino_settings_renderer.dart:110`)返回**裸 `Column`（不可滚动）**，被 `SettingsHomePage._buildWideLayout`(`settings_home_page.dart:159-165`)塞进 `MaterialSupportingPaneLayout.primary`（`Expanded`，有限高度）→ 内容超高 RenderFlex 溢出。对照 `MaterialSettingsRenderer.buildDetailContent`(`material_settings_renderer.dart:114`)用 `ListView.builder` 自带滚动故不溢出。
  - **R2 结构割裂**（三栏拥挤 + 无返回 + 布局突变）：`home_page.dart:327` 的设置标签全屏分支带 `_currentTab==2 && !isCupertinoPlatform(context)` 门控，cupertino 桌面被排除 → 退化成「3 图标 rail + 嵌入设置」三栏；且 `SettingsHomePage._buildEmbeddedMaterialShell`(`settings_home_page.dart:101-103`)对 cupertino 提前返回裸 content（无页头/返回箭头）。桌面外壳本应「复用 Material 架构、叶子控件按设计系统切皮肤」(CLAUDE.md)，此处 cupertino 桌面是半成品特例路径。同款 overflow/退化在 macOS、iPad 横屏同样存在（同一份 `_buildDesktopLayout`），无人报。
- **[x] ① 已修复** — `918139165`（R1：`CupertinoSettingsRenderer.buildDetailContent` 裸 `Column` → 可滚动 `ListView.builder`，对齐 Material 渲染器，shrinkWrap 时禁自滚由外层 sliver/SingleChildScrollView 滚、底部留安全区；`buildDetailPage` sliver 内调用传 `shrinkWrap:true`；reader 设置弹窗 `shrinkWrap:!cupertino→true`。R2：去掉 `home_page.dart` 设置全屏分支的 `!isCupertinoPlatform` 门控，cupertino 桌面也隐藏 3 图标 rail 走全屏二栏；`settings_home_page._buildEmbeddedShell` 去掉 cupertino 提前返回、给桌面全屏设置补 `HibikiPageHeader`+返回箭头，并短路保留 cupertino 手机原生无页头。消除特例分支，非补丁）
- **[x] ② 已加自动化测试** — `test/settings/settings_renderer_test.dart`（`BUG-009`：cupertino 详情在固定矮高度 pane 里渲染不抛 RenderFlex 溢出、提供可滚动视口；`BUG-009 R2`：`platform=windows + designSystem=cupertino` 下 pump 真实 `SettingsHomePage(embedded,onBack)`，断言渲染返回箭头出口且不溢出）
- **备注**：布局类。代码+单测已绿（settings_renderer_test 14/14；opus 审查 🟢 无致命问题，确认全 5 个 `buildDetailContent` 调用点覆盖、material 弹窗零变化、macOS/iPad/iOS手机/Android 各组合推演只有目标场景改变）。仍需 **Win11 真机肉眼复测**原始失败页（外观切 iOS）确认黄黑条纹消失、二栏、返回箭头可点回来源 tab、视觉协调——待补。R3 配色（Cupertino 列表系统灰 vs app 主题 surface 色不一致）属主观微调，本轮不做，真机看效果再定。
- **预存失败（非本轮）**：`test/settings/md3_design_system_static_test.dart` 的「page chrome surfaces use shared MD3 spacing tokens」用例引用 `home_page.dart` 已被删除的 `_buildRailLeading()`（「删宽屏 rail logo」改动遗留，与 BUG-009 无关），本轮未触碰，待对应改动方同步守卫。

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
