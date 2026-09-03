## BUG-1671 · 浏览器扩展侧边栏获取字幕不全
- **报告**：2026-08-15（用户：shishamo 群报「侧边栏获取字幕不全」）
- **真实性**：✅ 真 bug，两个独立根因都在 `tools/browser-extension/content.js` 的 textTracks 收割器 `fushiHarvestTextTracks()`（修复前 :625-649）：
  1. **增量判据错误**：用「cue 条数单调增长」当增量门（`existing.length >= tt.cues.length` 就整段跳过，长了就整轨覆盖）。hls.js/Shaka/MSE 分片字幕会随 back-buffer 回收、seek 重建把 `tt.cues` 整批换成另一时间窗——条数没长 → 新区间字幕永远进不来；条数长了 → 旧区间已收字幕被整轨覆盖抹掉。正是「只拿到一段/条数不全」；
  2. **disabled 轨直接跳过**：浏览器对 `mode === 'disabled'` 的轨不加载 cues，收割器从不主动升 `hidden` → 只有播放器当前开着的那条轨能进 store，侧边栏语言轨永远只有一条。
- **[x] ① 已修复** —（提交哈希：a22c46daf）
  1. 收割改为**归并**：逐条 `fushiSortedCueInsert`（同文本 ±750ms 去重）并入既有轨，轨只增不减，快进/回看各区间都留得住；有真插入才通知面板；
  2. disabled 的 subtitles/captions 轨升为 `hidden`（加载 cues 但不渲染、不影响站点显示，asbplayer 同款），下一轮轮询收割全部语言轨。
  未覆盖（记录为已知边界）：DOM 采样 live 轨天然只有播过的部分、后台标签页 setInterval 节流丢行、跨域 iframe 播放器（需 all_frames）、YouTube server 兜底「拿到一条就不再补」门闩——均不是本次用户路径的主因，另行排期。
- **[x] ② 已加自动化测试** — `tools/browser-extension/universal-subtitle-providers.test.js` 新增两用例：「disabled 语言轨强制升 hidden 下一轮收齐」「分片整批替换按归并合并，旧区间不丢/新区间进得来/重复收割去重」。变异实测：去掉升 hidden、归并退化为盲追加，两用例分别红。
- **备注**：镜像 `fushi/assets/browser_extension/` 由 `scripts/sync-mirrors.mjs` 同步。
- **审查修复（code review 后补，同 PR）**：①同语言多轨（"English" 与 "English [CC]" 的 language 同为 en）会被归并进同一条侧边栏轨、台词穿插重复——语言撞车时把 label 编进轨 key 消歧（单轨语言保持裸语言码，对齐其它 provider 的 key 习惯）；②textTracks 精确时间轴下 750ms 同文去重会误杀连续两声相同短句——`fushiSortedCueInsert` 加窗宽参数，收割路径用 1ms（等于 startMs 精确相等），live 轨保持 750ms；③升 hidden 与站点播放器（hls.js 等）可能拉锯——加 WeakSet 一轨一次门，站点拨回 disabled 即尊重站点，杀死 1.2s 轮询无限翻转。
- **⚠ implemented_unverified**：`tt.mode='hidden'` 在 hls.js 真站（字幕全关时被 hls.js 反读为活动轨、触发分片下载/UI 状态）的实际行为**未真机取证**，本会话无浏览器环境；一轨一次门已把最坏情况限制在每轨一次翻转。合并前建议在一个 hls.js 站点实测字幕菜单状态与网络面板。
