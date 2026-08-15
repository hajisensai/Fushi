## BUG-1670 · 浏览器扩展查词不暂停视频且关闭弹窗不恢复播放
- **报告**：2026-08-15（用户：shishamo 群报「查词不能暂停或者恢复视频的播放」）
- **真实性**：✅ 真 bug（半成品功能）：
  - 「不暂停」：开关 `subtitlePauseOnLookup` 默认**关**（`tools/browser-extension/options.js`，修复前 :18），而 app 侧 `pauseOnLookup` 早已默认开（TODO-1108，`fushi/test/media/sources/pause_on_lookup_default_1108_test.dart:25`），扩展没跟；
  - 「不恢复」：全扩展没有任何 `play()` 恢复代码——`content.js` 两个暂停点（修复前 :1714-1716 / :1839-1841）只 pause，注释还把「不自动恢复」写成契约；
  - 附带：`document.querySelector('video')` 只搜顶层文档第一个 video，shadow DOM / 同源 iframe 里的播放器完全够不着。
- **[x] ① 已修复** — 对齐 app 侧 `shouldResumeAfterLookupDismiss` 三条不变式（提交哈希：a22c46daf）：
  1. 默认值翻到开启（`options.js` settingDefaults + `content.js` 无显式偏好回落 true；新键/旧键显式选择仍优先）；
  2. 暂停记录唯一真相源 `fushiPausedForLookup`（记「被我们暂停的那个 video 元素」）；只暂停「正在播放」的视频（`fushiFindPlayingVideo()`：顶层快路径 + open shadow root/同源 iframe 深搜兜底）；
  3. 关窗汇聚点 `fushiRemoveContainer()` 恢复：只 play 确实由查词暂停的那个视频，用户自己暂停的绝不被播起来，用户已手动恢复的不重复 play；嵌套查词不经此处、天然不提前恢复。
  Side Panel 发起的查词（`fushiPrepareLookupFromSidePanel`）无「面板关闭」回调，维持只暂停不自动恢复（防止被无关的页面弹窗关闭误恢复），已注释说明。跨域 iframe（嵌入式第三方播放器）本轮不覆盖（需 all_frames + background 广播，影响面大，另行排期）。
- **[x] ② 已加自动化测试** — `tools/browser-extension/shift-hover.test.js` 新增：默认开启即暂停/显式关闭不暂停、关窗自动恢复且不重复 play、用户自己暂停的视频绝不被自动播放、旧键显式 false 压过新默认。变异实测：禁用恢复块「关闭查词弹窗后自动恢复」用例即红。守卫 `fushi/test/mining/netflix_mining_robustness_guard_test.dart` #1 同步为新暂停代码形状。
- **备注**：options.html 文案同步改为「关闭查词弹窗后自动恢复播放」。
- **审查修复（code review 后补，同 PR）**：①「用户播放→再暂停→关窗」会被误播——暂停时挂一次性 `play` 监听收回 `fushiPausedForLookup`（用户手动播放即收回控制权；我们自己 resume 前先置 null 不会误清）；②查词失败/扩展失效/SW 回收（12s 兜底定时器）等「弹窗没建出来」的路径没有关窗动作可触发恢复——恢复块抽成 `fushiResumePausedForLookup()`，这些路径在无在场弹窗时直接恢复；③深搜落热路径——已因查词暂停且视频仍停着时短路跳过整个暂停块，「找不到在播视频」记 2s TTL 负缓存（纯文本页高频扫词不再全树扫描）。测试各有独立用例（shift-hover.test.js），失败恢复路径变异实测红。
