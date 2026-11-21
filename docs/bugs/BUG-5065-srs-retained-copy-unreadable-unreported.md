## BUG-5065 · SRS 保留副本 srs.db 坏了（不是 SQLite 文件）用户毫无提示
- **报告**：2026-11-21（来源：SRS 新代存储交接文档 `docs/specs/2026-11-15-srs-gen4-handoff.md` N2 条「`kernel.rs` `retained_copy_unreadable` 从没被读（G7-5 状态枚举的缺口，应按 bug 登记）」）
- **真实性**：✅ 真 bug。迁移后原位封存的旧代库 `srs.db`（保留副本，用途：退回旧版本的后路）变成不是 SQLite 的文件时：
  - 开库检测到了（`native/fushi_fsrs/src/store/gen4/files.rs` `finish_seal` → `Retained::Unreadable`），存进 `G4Core::retained_copy_unreadable`（`native/fushi_fsrs/src/store/gen4/kernel.rs:243`，赋值 `:310`），但 FFI 与 Dart 都不读，只有测试断言；
  - 设置页 / ctl / 服务端 WebUI 用的状态命令 `gen4_retained_state` 走 `retained::inspect`（`native/fushi_fsrs/src/store/gen4/retained.rs:142`），打不开 / 读不了一律报 `copy: "other"`（`:151`、`:165` 吞掉了 `SQLITE_NOTADB`），UI 按「没有保留副本」处理、整行隐藏。
  - 后果：保留副本坏了、退回旧版本这条路已经没了，用户毫无提示。
- **[x] ① 修复** — 根因：状态命令把「坏了」和「不归这里管的文件」混成同一个 `other`，开库那份标志又没有出口。修法：`retained::inspect` 按 `finish_seal` 同一判据（`SQLITE_NOTADB`）分出 `CopyState::Unreadable`，线上名 `unreadable`；`gen4_retained_delete` 遇到它报 `reason: "unreadable"`、不动文件；到期自动删本来就只认 `Sealed`，照旧不碰。删掉没人读的 `G4Core::retained_copy_unreadable`（状态命令现读磁盘，是唯一出口）。Dart：`SrsRetainedCopyKind.unreadable` + `SrsRetainedCopyState.unreadable`；设置 › 存储加只读状态行 `storage.srs_retained_copy_unreadable`（说明退回旧版本的路没了、当前复习数据不受影响；内核不删坏文件，所以不给动作）；ctl `srs retained` 文本与服务端 WebUI 同样提示。
- **[x] ② 自动化测试** — Rust `native/fushi_fsrs/src/store/gen4/retained_tests.rs` `an_unreadable_copy_is_reported_and_never_deleted`（状态报 unreadable、到期也不删、立即删除拒绝且字节不变、换回封存副本恢复 sealed）；Dart `packages/fushi_srs/test/store/srs_retained_copy_test.dart`（线上名解析）、`fushi/test/srs/srs_retained_copy_wiring_test.dart`「设置 › 存储：保留副本坏了时出现损坏提示行、不出删除行；封存的副本不出提示行」。
- **备注**：设置行是纯 schema 状态行（`SettingsStatusItem`），无新布局；未在真机上造坏文件肉眼复测。
