## BUG-4960 · 统计中心「总览」页签在主 isolate 上有 90～250 ms 的同步段（大库）
- **报告**：2026-11-20（测量组 m5，PR #3835；拍板台 design-nmv-stats-main-isolate 第 2 条，维护者「全根本性做」）
- **真实性**：✅ 真问题（实测，非崩溃）。总览要全域事实：`fushi/lib/src/pages/implementations/statistics_center_page.dart:264`
  调 `loadStatFacts` 全域读，`packages/fushi_engine/lib/stats/stat_facts.dart` 的 `loadStatFacts` 在 UI isolate 上把
  legacy 四表 + 段 + 游玩会话逐行构造成 `StatFact`、`deriveStudySessions` 归并会话，页面再做范围 / 趋势 / 热力图派生。
  Drift 只把 SQL 放在后台，行映射与全部派生都在 UI isolate；大库实测 90～250 ms 同步段（掉帧）。
- **[x] ① 已修复**（2026-11-22，根因：事实面的行映射与派生全在调用方 isolate，且是 Dart）：
  `loadStatFacts` 的库读取 + 行映射 + 派生整体挪进一次性后台 isolate（`Isolate.run`，经
  `FushiDatabase.backgroundConnection` 接同一个 drift 服务端，`packages/fushi_engine/lib/stats/stat_facts.dart`
  `_loadStatFactsHere`）；派生搬进 Rust `native/fushi_compute/src/stats.rs`（`ffc_stats_derive`：日面 / 小时面 /
  会话流 / 全域与阅读域按日合计，一个粗粒度命令 + 一份快照，原始行与快照都走整块缓冲、不逐行跨边界），
  Dart 版构造与 `deriveStudySessions` 的归并实现已删、不留回退。统计中心总览改吃快照里的按日合计
  （`statistics_center_page.dart` `_load`：`statDaysByKeyOf(facts.dayTotals)`、`statBookCphOfTotals`），
  不再在 UI isolate 上逐条遍历全域日面。没有新建 crate：`fushi_compute` 本来就是五端 app 与无头服务端的
  硬依赖计算内核；Rust 直接开 `fushi.db` 被否（同进程两份 SQLite 在 POSIX 上共用一个库文件会因 fcntl 锁
  互相释放而损坏，且测试的内存库 Rust 读不到）。
- **[x] ② 已加自动化测试**：`packages/fushi_engine/test/stats/stat_facts_parity_test.dart`——确定性大杂烩库
  （`stat_facts_parity_seed.dart`）上四种读口（总览 / 首页 / 游戏域 / 单书）与**迁移前 Dart 实现**冻结的
  向量（`fixtures/stat_facts_parity.json`）逐条相同（日面、小时面、会话流、按日合计、活动流），并断言派生
  跑在 `stat-facts` 后台 isolate；Rust 侧 `native/fushi_compute/src/stats/tests.rs`（构造顺序 / 身份反查 /
  gap 边界 / 游戏骨架吸收与窗口 / UTF-16 排序 / 坏输入）。原有 `stat_facts_scope_test` / `study_sessions_test`
  等口径测试照常跑在新实现上。大库主 isolate 阻塞实测（`packages/fushi_engine/benchmark/stat_facts_main_isolate_benchmark.dart`，
  文件库 + 生产同款 drift 后台连接，12 万段 + 1500 天 legacy 行 + 2000 条游玩会话 → 12.9 万条日面事实 / 11 万个会话，
  主 isolate 1 ms Timer 的最大间隔，5 次中位数，i5-12600KF / Windows 11）：同一实现放在调用方 isolate 跑 239 ms，
  后台 isolate 20 ms，空载底噪 16 ms（Windows 计时器粒度）——同步段只剩 isolate 起停与收结果的几毫秒。
- **备注**：拍板台 design-nmv-stats-main-isolate 的第 2 条，结单留言指到这里。
