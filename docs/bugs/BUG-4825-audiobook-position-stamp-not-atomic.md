## BUG-4825 · 有声书播放位置与时间戳分两次提交，中间可被同步的比较后写入插队
- **报告**：2026-11-17（优化计划 c13 复核项 novel-17c，只读核实确认）
- **真实性**：✅ 真 bug。`packages/fushi_audio/lib/src/audiobook/audiobook_repository.dart:286-296`（修前）`updatePositionMs` 是一次 `getPrefTyped` 加两次独立的 `setPrefTyped`（各自一个事务），没有外层事务。位置 `audiobook_pos_<key>` 与时间戳 `audiobook_pos_at_<key>` 是一对：同步侧的「比较后写入」`FushiDatabase.runIfIntPrefUnchanged`（`packages/fushi_core/lib/src/database/database_prefs_media.part.dart:302-311`）在事务里重读时间戳后成对写入，能落在本机两次写之间——结果是「对端的位置 + 本机的时间戳」；进程死在两次写之间则是「新位置 + 旧时间戳」，LWW 拿一个不属于这个位置的时刻去比。播放中每个整秒走一次这里，另有每次两个事务、两次偏好版本号自增的开销。
- **[x] ① 已修复** — `updatePositionMs` 整段包进 `_db.transaction`：比位置、写位置、写时间戳同一次提交，两个键用 `setPrefs` 一次写（一次版本号自增）。「位置没变不写」（BUG-2328）与两个键名不动。
- **[x] ② 已加自动化测试** — `packages/fushi_audio/test/audiobook/audiobook_position_atomic_write_test.dart`：时间戳写失败时位置一起回滚；一次位置变动只自增一次偏好版本号；位置没变不写；与本机写入并发发出的比较后写入看得到本机这次写入而放弃。
- **备注**：「恰好插在两次写之间」的交错在单测里排不出确定的时序，用「第二次写失败 → 第一次写回滚」钉原子性。待真机复测：有声书播放中杀进程，重开后位置与杀进程前一致。
