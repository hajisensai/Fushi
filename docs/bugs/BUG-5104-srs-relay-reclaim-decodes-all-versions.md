## BUG-5104 · 中继回收每收新头解码整位作者的签名版本（HBK-AUDIT-052，未复现）
- **报告**：2026-11-22（外部审计 Codex 2026-11-21 项目审查 HBK-AUDIT-052，来自 PR #3764）
- **真实性**：❌ 未复现（不构成随历史增长的性能缺陷）。`native/fushi_fsrs/src/store/gen4/cmd/sync_relay.rs:222` `note_head` → `:240` `reclaim_material` 每收到更新的 head 确实会读出并解码这位作者在 `relay_auth` 里的全部作者签名版本（`sync_state.rs:387` `author_versions_of`）。但回收后留下的版本 ⊆「最新 head 列着的区间 ∪ 转发缓存里的区间」，两次回收之间新增的版本只来自新收的段，所以每次回收的工作量是 O(|head.segs| + 缓存行 + 新收段数)，与触发它的 head 本身同阶：`plan` 收到这份 head 必须整份解码验签，`note_head` 里 `stored_head` 也要整份解码旧 head。head 的段清单由小段分层合并（`store/gen4/compact.rs`，满段 2–4 MB）限住，不随操作条数增长。
  实测（`cargo test --profile quick`，临时测试，未入库；每轮 head 加一段、随后记下它的作者签名版本，连续 50 轮取平均）：
  - 段清单 32：head 解码验签 1.79 ms，`note_head`（含旧 head 解码 + 回收）1.92 ms；
  - 段清单 512：2.17 ms vs 2.81 ms；
  - 段清单 4096（约 8–16 GB 操作历史，远超实际）：5.81 ms vs 11.0 ms。
  回收额外开销始终不超过一次 head 解码，没有超线性。按报告「持久化保留区间与签名头的增量状态」要给 SYNC 加表或列、动 `schema.rs` `SCHEMA`（gen4 号段需与长期集成分支协调），只省常数倍，不做。
- **[ ] ① 未修复** — 未复现，不修。
- **[ ] ② 未加自动化测试** — 未复现，不加。
- **备注**：若以后 head 段清单不再受合并约束（例如关掉分层合并），这里的结论需要重验。
