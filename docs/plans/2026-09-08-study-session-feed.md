# 统计会话流：关书不结算 + 每个域的会话级统计与删除

日期：2026-09-08。裁定人：用户（「每个都支持会话级统计」）。起因三条：① 小说一次翻两页回翻不扣（v2.2.4 及更早没有账本；v2.3.0 已含回翻撤回，且账本口径下被跳过的页本就没入账）；② 只要重复打开书统计就涨（真 bug，BUG-2264）；③ 统计页想要会话流、能删 0 分钟的误点会话。

## 1. 数据结构判断

- 事实只有两处：`study_segments`（一段一行、整点切段、uid 键控）与 `galgame_sessions`（游玩时长；hook 字数走 chars-only 段，两表无外键）。**会话是派生视图**，不加表、不加 sessionId 列（schema bump 连带三十多处断言，派生归并够用）。
- 墓碑按身份不按段（`StudySegmentTombstones` 主键 (mediaKind, mediaKey)，压制 `startAt < deletedAt` 的全部段）。删单次会话**不能**走墓碑，走既有「写零」原语（`zeroStudySegmentsOnDays` 的 uid 版）：零值是一次新的绝对值写，经 uid LWW 同步传到对端。
- 游戏两张表拼一个概念是长期债（把游玩时长并进 `study_segments`、退役 `galgame_sessions`），本轮不动：骨架行硬删 + 吸收段写零，游戏统计不出本机（BUG-2221）。

## 2. A：关书不结算（BUG-2264，已落地 `8de00c9461`）

一页只在「从它翻走」那一刻入账。关书 / 退后台 / 进程退出不碰账本：EPUB / 漫画 / PDF 三域关书三条路零账本动作，`StudyClock.detach()` 去掉结算回调只停表，`ReadUnitLedger.settle` 删除。误点开书 = 0 字 + <1s，一行都不写。

否掉的备选「落地页不计、翻到的页关书时计」：续读时上次关书那页会在「关书时」与「下次翻走时」各计一次，每次续读都双计。

代价（已知、接受）：读完一页立刻关书，这页记到下次打开翻走的那天；读到全书末页关书不计末页。

## 3. B：会话流（本 PR）

| 层 | 落点 |
|---|---|
| 派生 | `fushi/lib/src/stats/study_sessions.dart`：`StudySession` + `deriveStudySessions`；`StatFacts.sessions` getter；`kStudySessionGap` = 30 分钟（活动流 `kActivitySessionGap` 改为引用它） |
| DAO | `zeroStudySegmentsByUids` / `deleteStudySession({segmentUids, gameSessionId})`（`database_content_misc.part.dart`，同一事务） |
| 展示 | `stat_session_list.dart`：`buildStatSessionSection`（前 8 行 + 「全部会话 (N)」）/ `StatSessionList` / `showStatSessionsSheet`；每行 域图标 · 标题 · `起 → 止` · 时长 / 字数 / 页数 · 垃圾桶（确认文案 `stat_session_delete_message`） |
| 接线 | 统计中心总览（跨域混排）+ 阅读 / 视频 / 游戏三 tab（各自切片）；书 tile / 视频 tile 点按 → 该媒体的会话 sheet；游戏行仍进详情页（那里已有会话列表） |
| i18n | `stat_sessions_recent` / `stat_sessions_show_all` / `stat_sessions_empty` / `stat_session_delete` / `stat_session_delete_message`（`i18n_sync --add`，15 语言待补译） |
| 测试 | `test/stats/study_sessions_test.dart`（归并 / gap 边界 / 跨媒体不并 / 零段不进不当桥 / 游戏吸收 / 孤儿字数段不丢 / title 取最新快照）、`test/database/study_segments_test.dart`（按 uid 写零不立碑 / 游戏骨架硬删 + 段写零 / 写零后不再出现在 sessions）、`test/pages/stat_session_list_test.dart`（行文案 / 空态 / limit + 全部会话 sheet / 确认→删除→行移除、取消不动） |

## 4. C：页面收敛到游戏页骨架（用户「全部做完」，同 PR 落地）

阅读页 9 个区块是「clunky」的本体。三个域 tab 统一为游戏页骨架：

| 页 | 顺序 |
|---|---|
| 阅读 | 时段卡 → 每日时长图（`_dailyData`，近 30 天）→ 最近会话 → 目标卡 → 「分析」折叠 → 按书 |
| 视频 | 时段卡 → 每日图 → 最近会话 → 「分析」折叠（小时分布）→ 按视频 |
| 游戏 | 时段卡 → 每日图 → 最近会话 → 按游戏（原样） |

- 「分析」折叠（`StatAnalysisFold`，`stat_shared.dart`，默认收起、不持久化）装下阅读页下沉的 KPI 条 / 趋势 / 今日环 + 速度摘要 / 来源分布 / 小时×格式——**一个区块都没删**，守卫 `stat_pages_skeleton_guard_static_test` 钉五个区块必须在折叠里。
- 按媒体一行统一为 `buildStatMediaRow`（原游戏页 `_buildGameRow` 提成共享件）：域图标 · 标题（+ 合集标签）· meta（书：字数 · N 次会话 · 速度；视频：N 次会话；游戏：次数 · 最后游玩）· 第二行查词 / 制卡 / 收藏 · 右侧时长 · 有点按则 chevron。书 / 视频点按进该媒体会话 sheet，长按 / 右键删该媒体统计。进度条排行删除（排序 chips 保留）。
- i18n 新增 `stat_analysis` / `stat_sessions_count`；本 PR 7 个新 key 的 15 种语言译文已补齐（`i18n_sync --add` 默认只填 en / zh）。
