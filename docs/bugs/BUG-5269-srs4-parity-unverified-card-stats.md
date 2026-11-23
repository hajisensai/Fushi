## BUG-5269 · srs4-parity-unverified-card-stats
- **报告**：2026-11-22（应用内反馈 mwdfN2VvzL，同用户早期反馈 x-1PWg56ZV）
- **真实性**：✅ 迁移报告属实：第三个 profile `01a14e58-4a64…` 对拍 notes / canonicalCards / canonicalStats 各一换一，整次升级撤回。根因未证实。
- **[ ] ① 未修复** — 2026-11-23 调查结论：
  - 协议 3 一侧的卡 `c01cffd9-db48-5898-b20b-4467b63df2e0` = card(笔记 `978c5904`, 不带盐的规范 fushi_card 模板 "Card 1" `a3e292f3-56d1-5e7f-be5d-f37f40a121db`, ord 0)，即按协议 4 规范内置模板派生，却出现在带盐的 profile 里，所以别名层验不上（`aliases.unverified=1`）。
  - 新代用的 `7770c888-1b90-56f9-a0fb-9ee5c665c21a` 在四种盐（含不带盐）下都不是 lapis / fushi_card 模板派生的；推测是笔记换类型后按血统继承的新卡。新代 cards 里没有这一行（cards onlyNew=0），只有统计行指向它。
  - 下一步：查 `native/fushi_fsrs/src/store/gen4/inherit.rs` / `cache.rs` 在「日志的卡验不上、笔记换过类型」时为何把统计行改挂到继承卡，而协议 3 保留了 `c01cffd9` 的卡行。`alias.rs` A_UNVERIFIED 分支的推测未证实。需要用户的库，或笔记 `978c5904` 的类型 / 模板 ID。
- **[ ] ② 未加自动化测试** —
- **备注**：同批跨 profile 实体撞车（n4WhWEKPtQ）是另一个根因，已由 BUG-5267 修。
