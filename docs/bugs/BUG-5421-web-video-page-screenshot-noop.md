## BUG-5421 · 内置网页播放器页（WebVideoFushiPage）按 S / Shift+S 截图、识别画面文字静默无反应
- **报告**：2026-11-24（用户：应用内反馈 bsozOyEfi1「s 的截图快捷键好像失效了，类似失效的修一下」；BUG-5417 只修了原生播放器页网页档）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/web_video_fushi_page.dart` `_shortcutActions` 把 `screenshot` / `screenshotSubtitled` / `ocrFrame` 写死成 `noop`，注释理由是「网页视频页没有 media_kit 帧可取」；但同一份 glue 已有 `window.__fushiWebVideo.captureFrame`（`assets/web_video/web_video_glue.js`，非 DRM 站点页面 canvas 截 `<video>`），原生播放器页网页档的截图 / 暂停 OCR 就靠它（`WebVideoPlatformPlayer.screenshot`）。按键被静默吞掉，Netflix 这类截不到的站点也没有任何提示。
- **[ ] ① 未修复** — 方案：把 `video_fushi/clip_export.part.dart` 里截图去向（询问对话框 / 剪贴板 / 指定目录、文件名、失败 OSD）抽成两页共用的组件，内置网页播放器页用 glue `captureFrame` + `decodeWebVideoFrameDataUrl` 取帧接上；截不到（`webVideoFrameCaptureSupported` 为假 / 没视频）给与原生播放器页同一条 OSD（`video_screenshot_web_unsupported`）。带字幕截图要接 Flutter 叠层字幕的合成渲染器。
- **[ ] ② 未加自动化测试** —
- **备注**：2026-11-25 PR #4400（拍板 cbKi3PN0G7-r2）后用户不再在内置网页播放器页看视频：两档都在原生播放器页，截图走 `_buildVideoShortcutActions` 的单一门控 + `_saveScreenshot`（「制卡优先」档截 WebView 表面，`_captureWebSurface`；「画质优先」截不到时 OSD 指明切到制卡优先）。本条剩下的只是重放宿主页（机器驱动、交接途中才可见）里 S 仍 no-op，用户路径上的症状随统一消失；是否还要给宿主页接截图，等用户确认后再定。
