## BUG-4960 · 统计中心「总览」页签在主 isolate 上有 90～250 ms 的同步段（大库）
- **报告**：2026-11-20（测量组 m5，PR #3835；拍板台 design-nmv-stats-main-isolate 第 2 条，维护者「全根本性做」）
- **真实性**：✅ 真问题（实测，非崩溃）。总览要全域事实：`fushi/lib/src/pages/implementations/statistics_center_page.dart:264`
  调 `loadStatFacts` 全域读，`packages/fushi_engine/lib/stats/stat_facts.dart` 的 `loadStatFacts` 在 UI isolate 上把
  legacy 四表 + 段 + 游玩会话逐行构造成 `StatFact`、`deriveStudySessions` 归并会话，页面再做范围 / 趋势 / 热力图派生。
  Drift 只把 SQL 放在后台，行映射与全部派生都在 UI isolate；大库实测 90～250 ms 同步段（掉帧）。
- **[ ] ① 未修复** — 同一拍板里的另两条已在 `claude/dec-design-nmv-stats-main-isolate` 做完：阅读 / 游戏页签只读本域
  （阅读页目标环另读本周起的全域日面）；收藏句从偏好整段 JSON 迁成 `favorite_sentences` 表（v166），计数面只读三列。
  本条按仓库「Rust 胖核心」规则要单独立项：新建 `native/fushi_stats`（或并进现有统计相关 crate）持有事实面与派生
  （日面 / 小时面 / 会话流 / 范围聚合），只出粗粒度命令 + 快照，Dart 版 `loadStatFacts` 派生搬过去后删除、不留回退；
  需要先定 Rust 侧读主库的方式（主库是 Drift 管的 `fushi.db`，Rust 只读连接 + WAL）与快照的 FFI 形状。
- **[ ] ② 未加自动化测试** — 立项时以现有 `test/stats/stat_facts_scope_test.dart` / `stat_counter_facts_test.dart`
  的口径为契约，Rust 侧逐条对拍。
- **备注**：拍板台 design-nmv-stats-main-isolate 的第 2 条，结单留言指到这里。
