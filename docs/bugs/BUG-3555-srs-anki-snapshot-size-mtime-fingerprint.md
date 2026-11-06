## BUG-3555 · 复习：本机 Anki 集合快照的一致性只看大小 + 修改时刻，拷贝期间原位覆盖可能检测不出
- **报告**：2026-10-19（PR #2336 审查遗留，协调要求根本性修复）
- **真实性**：✅ 真 bug（条件比原描述窄），测试复现：拷贝期间主文件 / -wal 原位覆盖且大小与 mtime 不变（测试里把 mtime 拨回），旧判据判为一致。根因（修前）`packages/fushi_engine/lib/srs/apkg/anki_collection_snapshot.dart:305-377` 用 `_Fingerprint(size, modified)` 前后比较；WAL 重置后原位覆盖大小不变，时间戳粒度粗的文件系统（FAT/exFAT、按 tick 的 ext4）上 mtime 也可能不变，`quick_check` 查不出跨事务拼起来的页。Windows NTFS 上 mtime 为微秒级、实测会变，风险主要在粗粒度文件系统。
- **[x] ① 已修复** — 整组文件（主文件 + -wal / -journal）用 `File.copy` 拷两遍，在后台 isolate 里比对文件集合、两份副本的长度与 SHA-256（复用 `ffcSha256FileSync`），任一不同报 `changedDuringCopy`；原始文件只经 `File.copy` 读（dart:io 自己 open 的句柄不带 FILE_SHARE_DELETE，会挡住 Anki 删 -wal，已实测）。排除了 SQLite 在线备份 API（要对原库加共享锁 / 写 -shm）与检测锁文件（Anki 无可靠锁文件）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/apkg/anki_collection_snapshot_consistency_test.dart` snapshot consistency 组（主文件 / -wal 原位覆盖、拷贝期间出现 -journal、无写入正常）；变异实测：只比长度，2 条红。
- **备注**：代价：原始文件多读一遍，临时空间峰值为集合大小的两倍。
