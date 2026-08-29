## BUG-1949 · netflix-bridge 整集字幕轨在当前 Netflix 上零命中（JSON.parse 钩子看不到 timedtexttracks）
- **报告**：2026-08-29（内置网页播放器真机验证时发现；用户自己 Chrome 里的扩展侧栏当时也只显示「实时采集」轨）
- **真实性**：✅ 真 bug。根因锚点 `tools/browser-extension/netflix-bridge.js:98-113`（`JSON.parse` 纯透传 hook 只嗅探
  `r.timedtexttracks` / `r.result.timedtexttracks` / `r.result.manifests[]`）。实测（pywebview，登录 profile，
  document-created 时机注入 `netflix-bridge.js + subtitle-adapters.js + subtitle-providers.js`，前置诊断脚本计数）：
  播放 `/watch/81236554` 75 s 内 `parseHits=0`（主世界 `JSON.parse` 从未收到含 timedtexttracks 的对象）、
  `fetches=[]`（无任何 `*.nflxvideo.net` / timedtext 请求经 `window.fetch`）、`cues=0`、无 `console.warn`；
  store 里只有 DOM 采样 `81236554|live` 轨。app 内 itest（`integration_test/web_video_netflix_live_itest.dart`）
  同样 `parseHooked:true` 但 store 仅 live 轨。结论：当前 Netflix 播放清单不再经主世界 `JSON.parse`
  （疑似 MSL 解包在 Worker 或用 `Response.json()`），钩子的前提失效；DOM 采样是唯一还在工作的通道。
- **[ ] ① 未修复** — 候选：`window.netflix.appContext.state.playerApp.getAPI().videoPlayer` 播放器 API 的
  `getTimedTextTrackList()` + 切轨后从播放器内部取 cue；或拦 `XMLHttpRequest`/`Response.prototype.json`；
  需先在真机确认清单实际经哪条路径。
- **[ ] ② 未加自动化测试** — 现有 `netflix-bridge.test.js` 只喂合成清单给 `JSON.parse`，无法发现「站点不再走
  JSON.parse」这类前提失效；需要一条 live 探针（默认 skip）记录 parse 命中数。
- **备注**：不阻塞内置网页播放器 P1（live 轨可用），但影响扩展与 app 两侧的整集字幕列表 / 精确制卡窗。
