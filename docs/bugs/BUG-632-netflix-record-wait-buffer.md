## BUG-632 · 网飞制卡录制时长不准（未等缓冲就绪即开录·录进 stall 冻结帧）
- **报告**：2026-07-08（用户：「制卡录制时长是不是不太精准，有没有等缓冲完再录制」）。TODO-1335 ④。
- **真实性**：✅ 真 bug（仅 Netflix 回放录制路径；YouTube 走服务端从真实流精确裁，无录制，不受影响）。
- **根因说明**：Netflix 沉浸制卡逐句录制在 `tools/browser-extension/content.js` 的 `hibikiRunNetflixBatch`
  （两份镜像 `tools/` + `hibiki/assets/browser_extension/`）。每句 `seekTo(cueStart-200)` 后仅
  `await sleep(150)`（"让首帧稳定"）就 `v.play()` + 立即 `beginClip`（offscreen 起 MediaRecorder）。
  但 Netflix seek 完成（`seeked` 事件）时数据常还没缓冲到位（`readyState` 可能仅 `HAVE_CURRENT_DATA=2`，
  只有当前帧、无法向前推进）→ 此刻开录会录进 **stall 冻结帧**；而 offscreen `endClip` 的时长是**墙钟**
  （`beginClip→endClip` 经过，见 `offscreen.js:84`），stall 期间画面冻结但墙钟照走 → 录制起点是冻结帧、
  片段时长虚长、音画与真实句子不对齐 → 用户报「录制时长不精准」。固定 150ms 太短且不判缓冲状态。
- **[x] ① 根因修复** — commit（本轮，见文末哈希）：
  - `content.js`（两份镜像 byte-identical 同步改）把 seek 后的 `await sleep(150)` 换成**暂停态等缓冲就绪**：
    `try { v.pause(); } catch (_) {}` + `await hibikiWaitForBuffered(v, 3000)`，等 `readyState>=HAVE_FUTURE_DATA(3)`
    （seek 目标已缓冲、可从该点顺畅前进）再 `v.play()` + `beginClip`。新增 `hibikiWaitForBuffered(v, maxMs)`
    轮询函数（`readyState>=3` 即就绪，`maxMs` 上界兜底，弱网/受阻退化到旧行为绝不无限等卡死批量）。
  - **暂停态**等缓冲是关键：暂停不推进 `currentTime` → 完整保留入队预留的 200ms 头部提前量
    （BUG-593 fix C 的红线，`v.play()` 仍紧邻确认在播轮询、play→beginClip 之间仍无固定 warmup，两条守卫都仍绿）。
  - content-script 版本标记 bump v41→v42（用户可据 Console `content script v42 loaded` / `data-hibiki-cs=v42`
    确认加载新版）。
- **[x] ② 自动化测试** — `hibiki/test/mining/netflix_mining_robustness_guard_test.dart` 追加
  「TODO-1335 网飞录制 seek 后等缓冲就绪再开录」组（两镜像源码守卫）：`hibikiWaitForBuffered` 缓冲门存在且用
  `readyState>=3` 阈值、`v.pause()` 紧邻 `hibikiWaitForBuffered` 且排在 `beginClip` 之前、旧 `sleep(150)`
  首帧稳定 warmup 已删；并 bump 版本断言到 v42。BUG-593 `netflix_card_dedup_guard_test.dart` fix C 守卫仍绿。
- **备注**：TODO-1335。`flutter analyze` 净、`flutter test`（mining 全域）全绿。缓冲/录制时序依赖 Netflix 真实
  DRM 播放页，本地无法复现；真机验收：关硬件加速 + 真实剧集，批量制卡逐句录制后回放卡片 → 片段应从句首缓冲
  点即时推进、无冻结前奏、时长与句子时长贴合（此前弱网/刚 seek 时前段冻结、时长虚长）。
