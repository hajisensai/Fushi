## BUG-581 · 普通网页制卡误报没找到当前字幕
- **报告**：2026-07-07（用户：这也不是视频，哪来的字幕）
- **真实性**：✅ 真 bug。根因 `tools/browser-extension/bridge-shim.js`（及镜像 `hibiki/assets/browser_extension/bridge-shim.js`）`mineEntry` 分支。批量剪辑重构后 `mineEntry` 无条件走视频剪辑队列 `window.hibikiEnqueue`（`tools/browser-extension/content.js:219` `hibikiEnqueue` → `:225` 取窗失败返回 `{reason:'no-cue'}`）。普通网页（`hibikiSite()==='other'`）没有视频时间窗，取窗恒 null → 误弹 `✗ 没找到当前字幕，稍候再试` 且卡片没建成。用户在一个日语学习资源目录网页上查词制卡即命中。
- **[x] ① 已修复** — `mineEntry` 先判 `hibikiSite()`：非 `youtube`/`netflix` 站点回落 background.js 早已存在的 `type:'mine'`（纯文本挖词，直接 POST `{fields,sentence}` 立即制卡）；视频剪辑队列 + `no-cue` 提示只保留给流媒体页。两份扩展镜像同步修改。提交见本轮 commit（TODO-1271）。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/browser_extension_nonvideo_mine_guard_test.dart`（源码扫描守卫，两镜像各断言 `mineEntry` 按 `hibikiSite` 门控、非流媒体走 `type:'mine'` 即时制卡、`no-cue` 提示只在流媒体分支可达）。字节一致由 `test/build/browser_extension_dict_media_mirror_guard_test.dart` 保证。
- **备注**：截图为浏览器扩展在普通网页上的查词弹窗 + `✗ 没找到当前字幕，稍候再试` toast，非 app 内视频字幕叠层；triage 最初猜测 `desktop_video_subtitle_overlay` 误显不成立。
