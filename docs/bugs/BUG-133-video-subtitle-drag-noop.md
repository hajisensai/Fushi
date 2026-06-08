## BUG-133 · 视频画面拖入字幕无反应
- **报告**：2026-06-08（用户：视频里面没办法拖动字幕导入，完全没反应 / Windows 桌面）
- **真实性**：✅ 真 bug（窗口模式拖放无反应）；确切失败点为 Windows OS 拖放未达深埋的内层 DropTarget，本机无法重现 → 用已验证可用的高层挂载点稳健修复，真机待复验。

### 根因（真实代码路径取证）
拖放目标只挂在 `_buildVideoControls` 里（`HibikiFileDropTarget`，注释说明放内层是为了全屏——media_kit 全屏另推根路由、复用同一 controls builder）。该 DropTarget 深埋在 media_kit `Video`→controls 子树里。代码层排查：media_kit 用 Flutter `Texture` 合成（`video_texture.dart:420`，非独立 HWND）、controls 常驻 `Positioned.fill`（`:461`）；默认缩放下 `HibikiAppUiScale`/`HibikiAppUiScaleNeutralizer` 都直接返回 child 不生成变换 → 理论上 desktop_drop 应收到。但用户实测窗口模式视频区「完全没反应」，而书架/视频库页级 DropTarget（`home_video_page.dart:281` 高层挂载）拖放正常工作。差异点=挂载层级深浅。

### 修复（稳健 + 待真机复验）
在视频页**顶层**（`_buildScaffold` body，与书架同款已验证可用的高层）新增页级 `HibikiFileDropTarget`（`_pageDropTarget`），窗口模式可靠收拖放；保留内层那个供全屏（全屏时本页被 Offstage、renderBox 归零 → 页级不命中，只剩内层，不双触发）。窗口模式下页级 + 内层可能对同一次拖放都触发 → `_importExternalSubtitle` 加 `_subtitleImportsInFlight` 去重防护（同一 srcPath 在途忽略二次调用，避免重复拷贝/重复加载遮罩/重复 SnackBar）。

- **[x] ① 已修复** — `video_hibiki_page.dart` 新增 `_pageDropTarget` 包裹 `_buildVideoBody`（页级拖放）；`_importExternalSubtitle` 拆出 `_importExternalSubtitleInner` + `_subtitleImportsInFlight` 去重外壳。
- **[x] ② 已加自动化测试** — `test/pages/video_subtitle_fixes_guard_test.dart`（页级 `_pageDropTarget` 存在且接 `HibikiFileDropTarget`/`_importExternalSubtitle`；去重防护 `_subtitleImportsInFlight` 存在）。
- **备注**：desktop_drop 的 OS 级行为无 headless 测试。**真机复验**：Windows 窗口模式拖字幕到视频画面应加载字幕；若页级仍无反应，则需在真机加 desktop_drop enter/done 诊断日志进一步定位（内层为何收不到）。
