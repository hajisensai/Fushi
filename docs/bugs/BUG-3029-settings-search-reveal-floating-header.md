## BUG-3029 · 设置搜索跳转定位被浮动页头首帧后让位推偏、高亮被重建拆掉
- **报告**：2026-10-06（PR #1984 CI：`test/settings/settings_body_search_navigation_test.dart` 两条红，目标行底 632 > 视口 600）
- **真实性**：✅ 真 bug。0a6d4be（设置页正文滚到浮动页头底下）让 `SettingsKitScaffold._buildOverlaid`（`fushi/lib/src/settings/settings_kit.dart`）的正文顶部让位 = 状态栏 + 页头实测高 + 跳转条实测高，而两个高度由 `FushiHeightReporter` 在**首帧之后**的 post-frame 才回报（首帧让位为 0）。搜索落点 `SettingsRevealTarget`（`fushi/lib/src/settings/settings_search.dart`）在首帧 post-frame 就按让位 0 的版面算好 `ensureVisible`；下一帧让位变大、内容整体下移，靠近页尾的目标被推出视口底部。同时那次 `setState` 让 bodyBuilder 整树重建，`SettingsSearchTarget` 再次 build 时挂点已被清空，于是 `SettingsRevealTarget` 包装被拆掉——定位跟不住、闪烁高亮也提前消失。
- **[x] ① 已修复** — `settings_search.dart`：`SettingsSearchTarget` 有状态保留请求代号；`SettingsRevealTarget` 随顶部让位变化重定位直到用户接手滚动（52c261182e1）
- **[x] ② 已加自动化测试** — `fushi/test/settings/settings_body_search_navigation_test.dart`（目标行在视口内 + 重建后落点包装仍在，深度 1/2 两条）
- **备注**：修法：`SettingsSearchTarget` 改为有状态，记住本次消费的请求代号，重建期间继续包着同一 key 的 `SettingsRevealTarget`；`SettingsRevealTarget` 依赖 `MediaQuery.paddingOf(context).top`，让位变化时重新定位，直到用户亲手滚动（`userScrollDirection` 离开 idle）为止。不靠延迟或重试。
