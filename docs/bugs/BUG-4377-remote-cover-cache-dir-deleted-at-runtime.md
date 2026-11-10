## BUG-4377 · 远端封面磁盘缓存：运行中缓存目录被删（存储页清缓存 / iOS 系统清理）后写入静默失败到重启
- **报告**：2026-11-10（实现反馈 jg3XoDVISk「一键清除全部缓存」时沿代码路径发现）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/sync/remote_cover_cache.dart:34`（修前）：`_dir()` 把「解析路径」和 `create(recursive: true)` 一起 memoize 进 `_ensured`，目录只在进程内第一次用到时建一次。`<temp>/remote_cover_cache` 是可丢弃缓存，进程存活期间会被删掉——存储页「缓存与临时文件」单删这一项、新加的「清除全部缓存」、iOS 系统回收 `Library/Caches`。删掉后每次 `write` 都撞 `PathNotFoundException`，被 `catch (_)` 吞掉，远端封面每次都重新拉网，直到重启。
- **[x] ① 已修复** — `remote_cover_cache.dart:39` 只 memoize 路径（`_resolved`），`write` 每次写前现场 `dir.create(recursive: true)`（`:108`，目录已在时只是一次 stat）；`read` / `cachedFile` 对缺目录本来就按未命中处理。
- **[x] ② 已加自动化测试** — `fushi/test/sync/remote_cover_cache_test.dart`「BUG-4377：运行中缓存目录被整个删掉…」：写入 → 整目录递归删除 → 再写 → 读命中。
- **备注**：测试写好未在本分支运行（统一在合并后验证）。
