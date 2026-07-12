## BUG-766 · Netflix字幕面板file://下postMessage因opaque origin报错致列表空

- **报告**：2026-07-13（用户：控制台报错 + 截图）
- **真实性**：✅ 真 bug。根因：跨世界自投消息用 `location.origin` 作 `postMessage` 的
  `targetOrigin`，在 `file://` 页（opaque origin）下 recipient 真实源序列化为 `'null'`，而
  `location.origin` 返回 `'file://'` → 二者不匹配，浏览器抛
  `Failed to execute 'postMessage' on 'DOMWindow': The target origin provided ('file://')
  does not match the recipient window's origin ('null')` 并丢弃消息。
  - 发送端（全部同窗自投）：
    - `content.js`：`window.postMessage({ __hibikiNf: 'replayCues' }, location.origin)`（用户报错行）
    - `content.js`：`window.postMessage({ __hibikiNf: 'seek', ms }, window.location.origin)`
    - `hibiki/assets/browser_extension/subtitle-panel.js:140`：`seek` 自投
    - `hibiki/assets/browser_extension/netflix-bridge.js:25`：`cues` 自投；`:131`：`seekDone` 自投
  - 接收端：`hibiki/assets/browser_extension/netflix-bridge.js:9,119`：
    `var ORIGIN = window.location.origin;` + `if (e.origin !== ORIGIN ...) return;`
    —— `file://` 下 `e.origin==='null'` ≠ `ORIGIN==='file://'`，即便消息送达也被拒。
  - 症状链：content.js `document_idle` 就绪后发 `replayCues` 请求 bridge 重放已存档 cue，
    但该 postMessage 在 `file://` 页直接抛错永不送达 → bridge 不重放 → 面板 store 空、
    勾选开关无物可挂、列表只剩预取的下一集轨（空）。content.js 走 `<all_urls>` 注入，故任何
    `file://` 页都会触发这条握手。
- **[x] ① 已修复** — 同窗自投一律改用 `targetOrigin '/'`（= 仅同源同窗才投递，对不透明源恒成立、
  不做 URL 解析，故 `file://` 与 `https` 都送达）；接收端期望源改用 `window.origin`（不透明源
  返回 `'null'`，与 `e.origin` 一致；`https` 下与 `location.origin` 等价），保留原「拒绝异源」守卫。
  改动文件（两镜像 `hibiki/assets/browser_extension/` + `tools/browser-extension/` 字节一致）：
  `netflix-bridge.js`（`ORIGIN=window.origin` + 两处 `'/'`）、`subtitle-panel.js`（seek `'/'`）、
  `content.js`（replayCues/seek `'/'`）。
- **[x] ② 已加自动化测试** —
  - `tools/browser-extension/netflix-bridge.test.js`：新增
    `BUG-766 opaque origin（file://）下 cue 往返不丢` —— 以 `windowOrigin:'null'/locationOrigin:'file://'`
    加载桥，断言抓轨自投 `targetOrigin==='/'`，且 `e.origin==='null'` 的 `replayCues` 被接收端认可整批重放。
  - `hibiki/test/build/browser_extension_dict_media_mirror_guard_test.dart`：新增
    `cross-world postMessage is file:// opaque-origin safe` 源码扫描守卫 —— 两镜像的
    `netflix-bridge.js`/`subtitle-panel.js`/`content.js` 均不得再用 `location.origin` 作 targetOrigin，
    且桥接收端必须 `var ORIGIN = window.origin;`、不得出现 `window.location.origin`。
- **备注**：验证 `node --test netflix-bridge.test.js`（15/15）+
  `flutter test test/build/browser_extension_dict_media_mirror_guard_test.dart`（59/59）全绿。
  待用户在真机 `file://` 页复测原始失败路径。
