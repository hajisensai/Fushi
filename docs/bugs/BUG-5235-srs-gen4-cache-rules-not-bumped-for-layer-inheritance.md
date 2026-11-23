## BUG-5235 · gen4 缓存推导口径没随 BUG-5190 升级：已物化的新代库原地重开留着按卡 ID 序继承的卡片标志（HBK-AUDIT-203）
- **报告**：2026-11-22（2026-11-22 合并后代码审查 HBK-AUDIT-203，针对 PR #4142）
- **真实性**：✅ 真 bug。BUG-5190（`498babba87`）把卡片标志按血统继承的规则从「同一层取卡 ID 序在前的前身」改成「取生效写入最新的」（`native/fushi_fsrs/src/registers.rs` `cards_group`，约 :1054），这改变了缓存层 `cards` 行的推导结果，但缓存推导口径修订号没升（`native/fushi_fsrs/src/store/gen4/cache.rs:370` 修复前 `CACHE_RULES = 4`）。`cache_config_set`（`dispatch.rs`）只在库里记的口径不等于 `CACHE_RULES` 或配置变了时整层重建，所以 BUG-5190 之前物化过的新代库开库不重建，后继卡（同一层两张以上前身记了不同值）的 `flag` / `new_position` / 牌组……仍是旧规则算的，直到那张卡被别的写入碰到才换——原地升级与显式重建结果不同。
- **[x] ① 已修复** — `CACHE_RULES` 升到 5，修订表记一行（BUG-5190 / HBK-AUDIT-203）；`cache_rules_matches_the_pinned_derivation_table` 的 `ELSEWHERE` 登记这一版。宿主每次开库发的 `cache_config_set` 见到库里记的 4 就整层重建一次。真相与线格式不动，不升 schema。
- **[x] ② 已增加自动化测试** — `store/gen4/cmd/sync_tests.rs` `a_cache_with_card_flags_inherited_by_the_old_layer_rule_is_rebuilt_on_open`：后继卡两张同层前身 `flag` 不同（ID 序在前的先写），把缓存行改回旧规则的值并记口径 4，经 C ABI 发 `cache_config_set` → `changed: true`、`cards` 行回到新规则、口径记 5、增量 == 重建。修复前（`CACHE_RULES` 4）回包 `changed: false`，红。
- **备注**：以后改任何影响缓存行的推导规则（`registers.rs` 的继承 / 胜者规则也算）都要同时升 `CACHE_RULES`。
