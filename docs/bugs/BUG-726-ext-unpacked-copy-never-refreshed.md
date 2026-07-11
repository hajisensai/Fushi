## BUG-726 · 浏览器扩展已解压副本永不随app升级刷新导致弹窗停留旧版
- **报告**：2026-07-11（用户：浏览器的查词弹窗，明显和app内的查词弹窗不一样，需要修复）
- **真实性**：✅ 真 bug（部署通道缺失，不是样式又坏了）。证据链：
  - 用户机上运行中的 app 是新的：curl `127.0.0.1:19633 /api/lookup/dictionary`，响应 `theme`
    已含 `--text-color` / `--hibiki-color-scheme`（= BUG-688 修复在跑）。
  - 但用户机 `<appSupport>/hibiki-browser-extension/`（`D:/APP/HIBIKI_date/support/`）里的
    已解压副本：`vendor/popup.js` 75546 字节（正是 BUG-621 描述的「75 KB 旧版」，当前
    156797）、`vendor/content.css` 16920（当前 54210）、`content.js` 41284（当前 75409）
    —— 停在 2026-07-08 之前，BUG-621 parity / BUG-688 主题两轮修复全都没到达浏览器。
  - 根因：`hibiki/lib/src/lookup/browser_extension_installer.dart` 的
    `prepareBundledBrowserExtension` **只有一个调用点** =
    `settings_schema_lookup.dart` 的手动「安装扩展」入口；app 升级从不刷新磁盘副本，
    浏览器加载的未解压扩展就永远停在用户最后一次跑助手那天。弹窗渲染器/样式
    （popup.js/content.css）随 app 演进越走越远 → 「明显和 app 内不一样」按月复发。
- **[x] ① 已修复** — 打通「app 升级 → 磁盘副本刷新 → 扩展自 reload」全自动链路（提交 `aee00d2b5`）：
  1. 指纹身份：`computeBrowserExtensionFingerprint`（内置扩展全资产 sha256 前 16 hex，排除
     解压时必被重写的 `hibiki-defaults.js`）；解压时写进 `hibiki-defaults.js` 的 `build` 键。
  2. 启动刷新：`AppModel.initialise` 桌面端 fire-and-forget 调 `refreshBrowserExtensionCopy`
     → `refreshBundledBrowserExtensionIfStale`（副本目录存在 && build ≠ 内置指纹才整目录
     重解压并注入当前 server host/port/token；没装过不落盘）。
  3. 自 reload：查词响应新增 `extensionBuild` 字段（`hibiki_remote_api_handlers.dart`，经
     `YomitanApiServer(Manager)` 注入，未注入不带字段=向后兼容）；扩展 `background.js` 在
     lookup `sendResponse` 之后比对 `HIBIKI_DEFAULTS.build`，不一致且非 Netflix 录制中 →
     `chrome.runtime.reload()` 从磁盘拉新（storage 记录已 reload 指纹防「磁盘没刷成」死循环；
     任一侧缺指纹不动，旧 app/占位默认永不空转）。
  4. 镜像同步：`background.js` / `hibiki-defaults.js` 已同步 `tools/browser-extension/`。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/lookup/browser_extension_installer_test.dart`：指纹确定性/序无关/排除
    defaults/内容变则指纹变；`build` 键写入+`parseBrowserExtensionBuild` round-trip；
    解压写指纹的源码接线守卫。
  - `hibiki/test/lookup/browser_extension_auto_refresh_guard_test.dart`（新）：AppModel 启动
    挂刷新 + provider 接线；刷新仅针对已安装副本；background.js 自 reload 三重防护
    （sendResponse 之后 / 防循环 / 录制中跳过）；background.js 双镜像字节一致。
  - `hibiki/test/sync/yomitan_api_server_extension_endpoints_test.dart`：`extensionBuild`
    随查词响应透传 + 未注入不带字段（向后兼容）。
- **备注**：
  - **用户侧一次性动作**：本修复进用户构建后，app 启动会把磁盘副本刷到最新，但**当前已加载
    的旧扩展没有自 reload 逻辑**，需在 `edge://extensions` / `chrome://extensions` 点一次
    「重新加载」（或重启浏览器）。此后 app 每次升级，扩展在下一次查词时自动 reload 拉新，
    不再需要任何手动步骤。
  - 扩展 `manifest.json` version 恒 0.1.0 无 bump 纪律，故身份用内容指纹而非语义版本。
  - 与 BUG-621（vendor 版本漂移，已修 `9b3ee8d`）/BUG-688（主题分裂，已修）区分：那两轮修的
    是仓库内 parity；本轮修的是仓库→用户浏览器的**部署通道**。
