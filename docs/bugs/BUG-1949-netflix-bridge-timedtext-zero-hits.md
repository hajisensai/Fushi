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
- **补充定位（2026-08-30，pywebview 前置 XHR/fetch 诊断脚本）**：清单经 XHR POST `/msl/playapi/cadmium/manifest/1`
  MSL 加密往返，解密后的 JSON 从不经主世界 `JSON.parse`；但播放器随后用 **XHR（responseType text）** 把**选中轨的
  字幕文件**整份下下来：`https://ipv4-c092-hkg001-ix.1.oca.nflxvideo.net/?o=1&v=53…`，50048 B，头 `<?xml …<tt ttp:…`
  （明文 TTML），当前轨 `getTimedTextTrack()` = `{"bcp47":"zh-Hans",…}`。所以数据源还在，只是入口换了。
- **[x] ① 已修复** — `tools/browser-extension/netflix-bridge.js`（+ 镜像 `fushi/assets/browser_extension/`）：
  新增 XHR `open/send` 与 `Response.prototype.text` 嗅探，响应正文像 WebVTT / TTML（`/^﻿?\s*WEBVTT/`、`/<tt[\s>]/`）
  就当整集轨投出 `{__fushiNf:'cues', videoId: /\/watch\/(\d+)/, lang: 播放器 API 当前轨 bcp47, format, text}`
  并进 `cueArchive`（晚注入的 content.js `replayCues` 同样重放）；arraybuffer 分片只解码开头 4 KB 判格式、命中才整份解码；
  按 URL+正文长度去重、清单路径已登记的 URL 不二次投递。`JSON.parse` 清单钩子保留作次要通道。
  不依赖清单/URL 形状，用户切轨触发新下载即得该语言整轨。
- **[x] ② 已加自动化测试** — `tools/browser-extension/netflix-bridge.test.js` 5 条 `BUG-1949` 用例（vm 里真加载桥，
  受控 `XMLHttpRequest`/`Response` 桩）：XHR text TTML 投出 + 语言/videoId；arraybuffer 媒体分片不投、VTT 分片投；
  去重 + 切轨再投 + replayCues 重放嗅探轨；fetch 路径 + 非字幕不投 + 无播放器 API 回落 `und`；清单路径不被嗅探二次投递。
- **真机复验（2026-08-30 01:59，pywebview + 登录 profile，注入修复后的 bridge + adapters + providers，播 `/watch/81236554`）**：
  35 s 后 `fushiEpisodeCues` = `81236554|zh-Hans` **381 条**（首条 `{startMs:19394,endMs:21522,text:"六万年前"}`）+ `81236554|live` 4 条；
  当前轨 `getTimedTextTrack()` bcp47=`zh-Hans`。证据 `.codex-test/web-video-player/bug1949/netflix_probe_bug1949.json`（不入库）。
- **备注**：不阻塞内置网页播放器 P1（live 轨可用），但影响扩展与 app 两侧的整集字幕列表 / 精确制卡窗。
