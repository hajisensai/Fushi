## BUG-3252 · 远端书隐藏列表偏好读取假定一定是字符串
- **报告**：2026-10-10（上一轮 PR 审查遗留疑点，PR #2024）
- **真实性**：❌ 未复现（无可达路径）。`fushi/lib/src/models/preferences_repository.dart:583` `hiddenRemoteBooks` 用 `getPref('hidden_remote_books', defaultValue: null) as String?`，旧实现（0635e84c）先判 `raw is! String`。沿真实路径核对：`getPref` → `PrefCodec.decode(raw, null)`，只有带 `j:` / `b:` / `i:` / `d:` 标签的落盘值才会解出非字符串；该键全仓唯一写点是 `setHiddenRemoteBooks` → `encodeHiddenRemoteBooks`（`String`，编码为 `s:`），引入它的 0635e84c 写的也是 `jsonEncode(...)` 字符串；它是设备本地键（`SyncRepository.deviceLocalPrefKeys`），不随备份 / 同步 / Profile 快照从别处写入。未编码的旧值走 `_heuristic`，默认值为 null 时原样返回字符串。故 `as String?` 在现有写入面上不会抛。
- **[ ] ① 未修复** — 不改：没有写入非字符串的路径，加类型分支只是给不存在的状态兜底。若将来有别的写点（如把它纳入备份并以 List 写入），应在那个写点统一编码，而不是在读点吞类型。
- **[ ] ② 未加自动化测试** — 无可复现行为可测。
- **备注**：
