## BUG-5294 · gen4 迁移对拍：第二个 profile 的三个加盐内置实体协议 3 一侧哪儿都没有，`entities` 判新代多出、整份撤回
- **报告**：2026-11-23（应用内反馈 CQKRyvMoOC：Android 3.4.0-debug.31707，复习库升级 `aborted` / `profileVerdict: fail`；风险标记 duplicate:RhMpA6bn8v 只是正文相同，签名不同）
- **真实性**：⏳ 待查（报告签名已核，根因未定位）。报告签名：主 profile `01a13f60…` 通过（`imported.devices = 3`）；第二个 profile `01a141bf…` 只有 6 条操作（1 台设备，`prev.seq = 6`），`parity` 只有 `entities` onlyNew 3，正是它按 `salt#0` 加盐的三个内置实体（`8667ab89…` fushi_card 笔记类型、`b48b18d8…` 默认牌组、`edcf6853…` lapis 笔记类型），`collidedEntities: 0`。
  - 与 BUG-5267（n4WhWEKPtQ）签名相同，但报告里已有 BUG-5267 加的 `collidedEntities` 项且为 0：`compare.rs` `taken_entities` 只认「行在库里、归了另一个 profile」的，这里三行要么根本不在 `srs_entities`，要么在却没被认出。`srs_entities` 全仓没有删除路径（只有测试），所以更可能是这三条身份记录从没投影过（`project_body` 的 `project = false` 路径或别的写入路径），需要用户的库或在报告的 `idTrace` 里补「实体行归属」才能定。
  - 与 PR #4245 的重复日志代表不一致无关（`oldSideStaleResults` 0、没有卡 / 统计差异）。
- **[ ] ① 未修复** — 根因未定位。
- **[ ] ② 未加自动化测试** —
- **备注**：下一步：`trace.rs` 的 `idTrace` 对 `entities` 一类的 ID 补报 `srs_entities` 行在不在、归哪个 profile、本 profile 的操作里有没有它的身份记录，让下一份报告能直接分型。
