## BUG-3676 · SRS 浏览把整个集合所有卡全部字段加载进内存
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：SRS 浏览打开时把整个集合所有卡的全部字段加载进内存。
- **真实性**：✅ 真 bug。根因：`srs_browse.dart` 打开时物化全部笔记视图；改为只读两张缓存表、字段按搜索逐页送原生内核（装载 1494→510 ms，内存 +194→+106 MB）。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_browse_test.dart`
- **备注**：无。
