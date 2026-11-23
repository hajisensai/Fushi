## BUG-5269 · srs4-parity-unverified-card-stats
- **报告**：2026-11-22（应用内反馈 mwdfN2VvzL，同用户早期反馈 x-1PWg56ZV）
- **真实性**：✅ 迁移报告属实：第三个 profile `01a14e58-4a64…` 对拍 notes / canonicalCards / canonicalStats 各一换一，整次升级撤回。根因未证实。
- **[ ] ① 未修复** — 2026-11-23 调查结论：
  - 协议 3 一侧的卡 `c01cffd9-db48-5898-b20b-4467b63df2e0` = card(笔记 `978c5904`, 不带盐的规范 fushi_card 模板 "Card 1" `a3e292f3-56d1-5e7f-be5d-f37f40a121db`, ord 0)，即按协议 4 规范内置模板派生，却出现在带盐的 profile 里，所以别名层验不上（`aliases.unverified=1`）。
  - 新代用的 `7770c888-1b90-56f9-a0fb-9ee5c665c21a` 在四种盐（含不带盐）下都不是 lapis / fushi_card 模板派生的；推测是笔记换类型后按血统继承的新卡。新代 cards 里没有这一行（cards onlyNew=0），只有统计行指向它。
  - 下一步：查 `native/fushi_fsrs/src/store/gen4/inherit.rs` / `cache.rs` 在「日志的卡验不上、笔记换过类型」时为何把统计行改挂到继承卡，而协议 3 保留了 `c01cffd9` 的卡行。`alias.rs` A_UNVERIFIED 分支的推测未证实。需要用户的库，或笔记 `978c5904` 的类型 / 模板 ID。
  - 2026-11-23 补诊断（报告推不出原因是报告设计缺口，不是只能等库）：迁移 / 干跑报告新增 `idTrace`（`native/fushi_fsrs/src/store/gen4/trace.rs`）——对拍与按规范 ID 比的例子、别名层验不上的 ID 逐个摊开：别名判定（how / 规范 ID）、两侧笔记行（笔记类型、牌组、guid 在哪个盐下派生出笔记 ID、名下卡）、两侧卡行（笔记 / 模板 / 序号、行 ID 是否由这三者派生）、统计行与日志索引挂的卡、内置实体的规则身份（哪个盐，`salt#i`），以及卡 ID 的派生反查（相关笔记及别名类 × 全部盐下的内置模板与相关卡行的模板 × 序号）。`parity.notes` 也带 `columns` / `columnExamples`（内容列只报字符数，另带笔记类型）；`aliases.unverifiedExamples` 列出验不上的 ID。用户升级到带这版的 debug 包再触发一次迁移，发回的报告即可定位 `7770c888` 的来历，不再需要整库。
- **[ ] ② 未加自动化测试** — 诊断本身的测试：`dryrun.rs` `a_projection_that_disagrees_with_the_log_fails`（笔记列差异与溯源）、`the_id_trace_explains_where_a_card_id_comes_from`（卡 ID 派生反查），`trace.rs` 两条。根因的回归测试等新报告定位后补。
- **备注**：同批跨 profile 实体撞车（n4WhWEKPtQ）是另一个根因，已由 BUG-5267 修。
