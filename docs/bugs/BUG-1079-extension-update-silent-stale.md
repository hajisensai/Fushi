## BUG-1079 · 扩展自更新失败永久静默无重试且无任何更新提示
- **报告**：2026-07-25（用户：）
- **真实性**：✅ 真 bug（自更新静默失败部分）+ 功能补全（双向版本感知/更新提示部分）。
  沿真实代码路径验真：
  - **永不重试 latch**：`tools/browser-extension/background.js:82-83`（修复前）——
    `maybeSelfReload` 里 `if (st.hibikiReloadedForBuild === remote) return;`，对同一
    remote build reload 过一次就永久早退。自更新失败（磁盘副本没刷成 / 用户从别的
    目录加载扩展 / 浏览器拒绝 reload）后扩展永久停在旧版，且无任何提示。
  - **零感知**：`tools/browser-extension/background.js:150`（修复前）——状态请求体写死
    `body: '{}'`，从不上报自身 `HIBIKI_DEFAULTS.build`；server 侧
    `hibiki/lib/src/sync/yomitan_api_server.dart:248-261`（修复前）状态端点完全不读
    body → app 对浏览器中实际加载的版本零感知；扩展页版本卡
    `hibiki/lib/src/pages/implementations/browser_extension_page.dart:302-318`（修复前）
    只显示 app 内置指纹，扩展 action popup 无版本/更新提示。
  - 注：前轮调查记的 server 路径 `media/sources/player/yomitan_api_server.dart` 有误，
    实际在 `hibiki/lib/src/sync/yomitan_api_server.dart`。
- **[x] ① 已修复** — 提交 `c931d8f98`。双向闭环：
  - 扩展侧新增纯状态机 `tools/browser-extension/self-update.js`
    （`HIBIKI_SELF_UPDATE.decide`）：同一 remote build 仍只 reload 一次（防无限循环
    不变），但每次心跳重新比对；已 reload 过仍不一致 → 写
    `chrome.storage.local.hibikiUpdateStale {remote, local}`；恢复一致 → 清除。
    `statusRequestBody` 让 `/api/extension/status` 请求体自报
    `{build, version}`（心跳/启动检查/连接诊断同一路径）。
  - 提示：`vendor/action-popup.html/js` 连接卡下新增更新提示行（stale 时显示
    「需到 chrome://extensions 重新加载」+ 两侧 build 简写）；扩展图标打「↑」角标
    （`refreshUpdateBadge`，录制红点优先——录制中跳过、录制结束恢复）。
  - app 侧：`yomitan_api_server.dart` `_handleExtensionStatus` 容错解析 body
    （旧扩展 '{}' / 空 body / 非法 JSON 行为等同现状），经 `onExtensionReport` →
    `app_model.dart` `browserExtensionReportedBuild`（ValueNotifier）+ 时间戳；
    `browser_extension_page.dart` 版本卡改双行（app 内置 / 浏览器中加载），不一致时
    显示 Material 3 警示条（errorContainer 主题色）+ 指引文案。
  - i18n 新增（i18n_sync + slang 再生成）：`browser_extension_version_app` /
    `browser_extension_version_browser` / `browser_extension_version_mismatch`。
- **[x] ② 已加自动化测试** —
  - JS：`tools/browser-extension/self-update.test.js`（15 例：状态机 reload 一次/
    stale/clear/缺指纹/录制让位、请求体自报、popup 提示文案、background 接线源码断言）。
  - Dart：`hibiki/test/sync/yomitan_api_server_status_report_test.dart`（真实 HTTP 层：
    自报 build+version 回调、'{}' 兼容、空 body/非法 JSON/类型错容错、未注入回调不炸）；
    `hibiki/test/lookup/browser_extension_update_stale_guard_test.dart`（两镜像接线 +
    self-update.js 字节一致 + server/app_model/页面警示条源码守卫）。
- **备注**：`hibiki/assets/browser_extension/` 镜像已同步（background.js /
  self-update.js / vendor/action-popup.*）。角标策略：录制角标（红点 ●）优先，
  更新角标（↑）仅在非录制时显示，录制结束由 `setRecordingBadge(false)` 恢复。
