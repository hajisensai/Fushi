## BUG-2170 · Netflix 批量自动制卡切集后把片头年龄分级 overlay 录进卡片

- **报告**：2026-09-06（用户：截图为 AnkiDroid 复习界面，卡片图整张是 Netflix 的
  「RATED 13+ / 暴力, 自杀」分级提示，看不到剧情画面）
- **真实性**：✅ 真 bug。根因在批量状态机的**开录时机**：
  `tools/browser-extension/content.js:955`（切集到位后只 `fushiWaitForPlayer(20000)` +
  `sleep(800)` 就 `nfEnsureCapture` 开 tabCapture，紧接着 `fushiRunNetflixBatch()` 逐句
  seek/录制）。Netflix 每集**开播时**会在画面左上角显示数秒年龄分级 overlay；批量录的是
  tabCapture 的**合成后标签页画面**（不是 `<video>` 像素），落在这一窗内的 clip 会把提示
  烧进卡片图/GIF。

  已有的第一道防线是常驻 CSS 隐藏（TODO-1391 / BUG-702，`content.js:1016` 的选择器清单 +
  `:1039` 注入 `display:none`），但它挡不住这个场景：
  1. 它整条受用户开关 `netflixHideNextEpisode` 门控（守卫 `netflix_todo1391_maturity_overlay_guard_test.dart`
     明确要求共用同一开关）。用户想留住 Netflix 自己的「下一集」按钮而把开关关掉时，分级
     overlay 会跟着一起放出来 —— 录制侧却仍然照录；
  2. 选择器按 Netflix 类名匹配（`[class*="watch-video--maturity-rating"]` 等），站点换哈希
     类名就整条**静默**失效，没有任何报错。

  所以录制侧不能把 CSS 隐藏当保证，必须另有一道与选择器无关的门。

- **[x] ① 已修复** —— `tools/browser-extension/content.js`（+ `fushi/assets/browser_extension/`
  镜像，逐字节一致）三处，提交 `<pending>`：
  1. `:855` 新增提示窗常量 `kNfIntroOverlaySec = 8` 与 `:865`
     `fushiWaitPastNetflixIntroOverlay(v, maxMs)`：有界等待，让本集真正**向前播过**提示窗
     再返回。判据是「相对开始等待时的**播放推进量**」，不是墙钟（暂停干等不会让提示过期）、
     也不是绝对位置（Netflix 从中途续播时提示同样在开播那几秒出现，只看绝对位置会让续播集
     直接放行）。到 `maxMs` 上界仍推不动（DRM/弱网）就返回 false 让批量继续，绝不无限等。
  2. `:956` 把这道门接进批量状态机，**排在 `nfEnsureCapture` 之前** —— 录制器根本不在提示
     窗内开着。只挂在 `fromLoad` 上：就地续跑（用户看到一半点生成）时页面早已开播多时、提示
     不在，白等还会把用户的播放位置往前推。
  3. `:602` 落在提示窗内的队列项按用户决策**放弃**（`fushiSplitNetflixIntroOverlayItems`，
     `:884`）：不 seek、不录，按失败计入总账并单独 toast 告知，但**不出队**（用户排的卡不
     静默丢，仍可手动制卡）。这些句没有「先播过去再回来录」的余地 —— 回跳就跳回窗内。
  4. 附带：录制期 `hideStyle`（`:626` 一带）无条件补上分级 overlay 选择器，不受
     `netflixHideNextEpisode` 门控。录制作用域藏，用户可见作用域仍归那个开关管。

- **[x] ② 已加自动化测试** —— 两层：
  - 行为层 `tools/browser-extension/netflix-intro-overlay-gate.test.js`（node:test + vm，
    真加载 content.js，7 条）：等待判据是推进量而非绝对位置、有上界不卡死、无 `<video>`
    不 hang、放弃名单的边界（窗末即可录 / 缺 `startV` 当 0）、放弃 ≠ 出队、跳过必须可见。
    CI 由 `.github/workflows/main.yml` 的 `node --test *.test.js` 那步 glob 自动收。
  - 接线层 `fushi/test/mining/netflix_bug2170_intro_overlay_gate_test.dart`（源码扫描，两份
    镜像各 6 条）：常量存在且为正、门排在 `nfEnsureCapture` **之前**、有 deadline 逃生口、
    判据用基线差、循环只跑 `recordable`、`fushiRemoveQueued` 仍只认成功 id、录制期无条件藏
    overlay。接线错了行为测试照样全绿（helper 在、只是没人调用），所以这一层必须单列。
  - 变异实测（4 条全被抓）：判据退化成绝对位置 → node ①b 红；放弃名单失效 → node ③ 红；
    摘掉状态机那一行 → Dart 接线红；把门排到开录之后 → Dart 顺序红。

- **备注**：
  - 内容脚本版本标记同步 bump `v46 → v47`（用户可在 Console / `<html data-fushi-cs>` 确认
    加载的不是缓存旧版），三处旧断言一并更新。
  - `kNfIntroOverlaySec = 8` 是本模块唯一的经验值。调大更保守（更多片头句被放弃），调小则
    提示可能又被录进卡片。**尚未在真机上测过 Netflix 分级 overlay 的确切存活秒数**，8 秒是
    留余量的取值。
  - 遗留可收窄项：若日后实测确认该 overlay 是**播放会话级**（seek 回片头不会重新显示），
    则「放弃片头窗内的句」可以放宽成「先播过窗再 seek 回去录」，不必丢卡。本次按用户明确
    决策（「如在最开头无法留出时间则放弃」）取保守解。
