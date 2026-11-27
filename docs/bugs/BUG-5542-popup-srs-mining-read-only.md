## BUG-5542 · Android 应用外查词卡（:popup）制卡到 Fushi 复习报 SrsCoreReadOnlyException

- **报告**：2026-11-27（用户：应用内反馈 cG0XybpnkA）
- **真实性**：✅ 真 bug（3.4.0 回归，复习库换代 gen4 引入）。根因
  `fushi/lib/src/models/app_model.dart:6596`（:popup 进程 `_resetSrsStorageHost(isMainProcess: false)`）→
  `fushi/lib/src/srs/srs_storage_host.dart:122`（非主进程按 `SrsOpenMode.secondary` 只读打开 `srs4.db`）→
  `fushi/lib/src/anki/anki_view_model.dart:955` `_readSrsMiner` 拿到的就是这个只读句柄，写命令在 Rust
  侧报 `READ_ONLY`。只读是有意设计：拍板 D10（`docs/specs/2026-11-15-srs-gen4-g7-g11-plan.md:285`、
  `docs/specs/2026-11-11-srs-generation-break.md:998`）规定新代下弹窗进程只读、**弹窗里的制卡转交主进程**；
  转交这一半从未实现（全仓没有 :popup → 主进程的制卡通道，现有跨进程只有截屏会话的原生定向广播）。
  协议 3 时代没有 Secondary，:popup 直接读写同一个库，所以 3.4.0 之前能用。
- **[ ] ① 未修复** — 不能让 :popup 改成 Primary 打开：Primary 的写连接上装着出卡会话的临时触发器、
  统计缓存按本进程写入代数失效，第二个写者的写入主进程看不见（D10 拍掉的「跨进程缓存与同设备双写」）。
  根本修法是补上 D10 的转交通道，方案与取舍待拍板（见委托方回报 / 拍板台）。
- **[ ] ② 未加自动化测试** —
- **备注**：与 BUG-5541（☆ 收藏）同报；收藏写的是 Drift 主库，:popup 可写，已单独修。
