## BUG-1669 · 浏览器扩展侧边栏高频查词后「正在查词」永久卡死
- **报告**：2026-08-15（用户：shishamo 群报「浏览器插件查词频率高，会出现『正在查词』然后一直显示这个状态一直不动」）
- **真实性**：✅ 真 bug——BUG-1024（MV3 service worker 在消息在途时被系统回收，`chrome.runtime.sendMessage` 回调永不触发）的 Side Panel 孪生。BUG-1024 只修了 `content.js`（在途闸 + 1500ms 截止兜底），`side-panel.js` 完全没有等价兜底：
  - `tools/browser-extension/side-panel.js` `sendRuntime()`（修复前 :59-68）只有 resolve、无超时——回调不来 Promise 永久 pending，`lookupTerm()` 的 `await` 永久挂起，「正在查词…」（:361）永久停留；
  - 更糟的是 BUG-1525 引入的同词在途复用（:262 `lookupInFlight.get(value)`）会把这个死 Promise 缓存住，`.finally` 永不执行 → 同一个词此后每次查询直接拿回死 Promise，**永久锁死**，且 `activeScanKey` 去重（:415-417）挡住原地重试；
  - 触发器：Side Panel 的 pointermove 扫词只有 rAF 节流、无位移阈值、无在途闸，横扫一行 20 字 = 1 秒内 20 个 HTTP POST，打满 Chrome 每主机 6 连接上限 + app 侧串行词典查询，SW 在高压长挂起下被回收概率大增；`background.js` 查词 `fetch`（:618）也无超时，app 侧一旦长阻塞 `sendResponse` 永不被调。
- **[x] ① 已修复** — 四层根因修复（提交哈希：a22c46daf）：
  1. `side-panel.js` `sendRuntime()` 加 8s 超时竞速，Promise 一定 settle → `.finally` 一定执行、在途表去毒；
  2. `lookupTerm()` 包 try/finally：任何路径（含处理回调抛错）loading 必被替换成可重试失败文案；失败后复位 `activeScanKey` 允许原地重试；
  3. `lookupAtPointer()` 加在途闸（1500ms 截止，对齐 content.js 的 BUG-1024 兜底；显式手势不受闸）防请求放大；
  4. `background.js` 查词 fetch 加 `AbortSignal.timeout(10000)`，超时走既有 catch 分支必定 `sendResponse`。
  app 侧同步 FFI 串行/UI isolate 阻塞的根治在 PR#624（已另行处理），不在本条重复。
- **[x] ② 已加自动化测试** — `tools/browser-extension/side-panel-lookup-deadlock.test.js`：受控 vm 真加载 side-panel.js，stub sendMessage 永不回调 → 推进超时定时器 → 断言 loading 被替换成失败文案、同词重试真正重新发出 lookup（在途表已去毒）。变异实测：删掉超时定时器该测试即红。
- **备注**：镜像 `fushi/assets/browser_extension/` 由 `scripts/sync-mirrors.mjs` 同步。
