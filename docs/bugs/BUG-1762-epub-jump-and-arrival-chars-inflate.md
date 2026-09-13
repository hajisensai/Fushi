## BUG-1762 · EPUB字数到达即计且四类跳转不播种水位整段前缀误计
- **报告**：2026-08-21（统计「到达即计」专项排查，随 BUG-1761 同批；产品决策：
  到达≠读过，漫画/书籍/视频同规则）
- **真实性**：✅ 真 bug，两个面：
  ① **到达即计**：`_refreshProgress`（`reader_fushi/navigation.part.dart`）在每次位置
  推进（翻页/滚动回传/恢复完成/10s 轮询）立刻按 high-water 增量全额计字——high-water
  只挡「重复计入」（往返回读），完全不挡「首次快速掠过」：按住翻页键章内扫到章末，
  每页都在到达瞬间全额入账。
  ② **跳转不播种水位**：章内进度条拖动（`_jumpToGlobalCharOffset` 同章分支直接
  evaluate、不抬水位）、同章文本搜索跳转（`chrome.part.dart` evaluateNow/replacePending
  分支）、跨章搜索跳转（水位只播到章首，章首→命中处的前缀被计）、EPUB 内链/脚注锚
  跳转（fragment 落点无字符锚）——一次点击把整段前缀记成已读。
- **[x] ① 已修复** — 两层：
  **速度封顶**（纯函数 `accumulateSessionCharsCapped` + `kMaxReadCharsPerSecond=40`）：
  单次水位推进可计入 ≤ 距上次推进的时间 × 40 字/秒（2400 字/分，正常阅读远够不到，
  行为不变；连翻时每步只隔几百毫秒 → 只计几十字）。超出封顶的余量随水位静默抬走、
  不回补（掠过视同跳转，重读也不再计，与 high-water 一致）。时间窗按 `kMaxReadingGap`
  （120s）封顶——挂机不攒计数额度；窗基准 `_lastWatermarkAdvanceAt` 只在水位真推进
  时重锚（原地采样重锚会把长停留页的窗压到轮询间隔）。
  **跳转播种**（语义同 `_handleExplicitCueJump`）：进度条拖动在解析落点前直接以
  `globalOffset` 抬水位；搜索跳转（三分支统一）以命中 `charOffset` 经
  `computeCharWatermark` 抬水位。fragment 锚跳转在 Dart 层无字符位置可播种，残余
  虚增由速度封顶兜底（≤ 时间窗 × 40 字/秒），已知取舍记备注。
- **[x] ② 已加自动化测试** — `fushi/test/reader/session_char_speed_cap_test.dart`
  （纯函数五条：正常节奏全额/连翻封顶/不回补/未越水位/异常窗）；
  `fushi/test/reader/reader_chars_arrival_cap_guard_test.dart`（接线守卫四条：裸
  accumulateSessionChars 不得回潮/时间窗只在推进时重锚/拖动先播种/搜索按命中位置
  播种）。既有 `reader_progress_save_wiring_guard_test`（落库不受门影响）与
  `reader_stats_pure_duration_guard_static_test`（恢复播种/cue 跳转）保持绿。
- **备注**：fragment（内链/脚注）跳转的水位播种需要 JS 侧回报落点字符位置，属独立
  改造；当前由速度封顶把单次虚增封在 ≤4800 字内。与 BUG-1761（漫画停留门）、
  BUG-1763（视频播放停留门）同批产品规则。
- **2026-09-06 追记**：速度封顶（`kMaxReadCharsPerSecond` 令牌桶）与跳转播种整套被 `ReadUnitLedger`（翻走即计 + 会话覆盖并集，用户裁定对齐 Hoshi）取代并删除；`session_char_speed_cap_test` / `reader_chars_arrival_cap_guard_test` 随之删除。见 `docs/plans/2026-09-06-read-unit-ledger.md`。
