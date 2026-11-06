## BUG-3541 · 数据根迁移后内置引擎 fast-resume 里的 save_path 仍指向旧目录，种子指向已搬空的位置
- **报告**：2026-10-19（内部审查：修 BUG-3540 时发现）
- **真实性**：✅ 真 bug（代码路径核实 + 真引擎复现）。
  - 内置引擎 resume 目录 `<documents>/anime_downloads/resume`（`fushi/lib/src/models/app_model.dart:5624`，修前）
    在搬移白名单 `anime_downloads` 下，随数据根一起搬走；默认下载根 `<documents>/anime_downloads/content` 同样被搬走。
  - native `ht_load_resume_dir`（`native/fushi_torrent/fushi_torrent_ffi.cpp:1578-1623`）用 `lt::read_resume_data`
    把 resume 里记的**绝对** save_path 原样读回再 `add_torrent`；迁移器只改写 DB 路径列
    （`fushi/lib/src/storage/data_root_migrator.dart:330`，修前，「③」步只有 `_rebaseDatabasePaths`），从不碰 resume 文件
    → 重启后每个种子都指向已搬空的旧目录：续传从零开始、做种断。
  - 时序上还有一个洞：迁移前的 `_closeRuntimeResources`（`fushi/lib/src/sync/sync_settings_schema/data_root.part.dart:521`，
    修前）不停内置引擎——引擎在搬移期间仍握着下载内容的文件句柄（Windows 目录 rename 被占用），退出时
    `EmbeddedTorrentHost.dispose` 还会按旧路径往旧 resume 目录强制落盘。
  - 真引擎复现：`embedded_torrent_fast_resume_relocate_test.dart` 去掉改写一步，新 session 从新根加载 resume 后
    30 s 内始终不完成（`Bad state: timed out waiting for restore at new root`）。
- **[x] ① 已修复** — c701988c65：
  - `packages/fushi_engine/lib/media/torrent/torrent_fast_resume.dart`：只在整份 bencode 字典完整合法时，
    按字节拼接替换顶层 `save_path`（其余字节原样，截断 / 尾部垃圾 / 非字典一律不改）。
  - `DataRootMigrator.rebaseEmbeddedTorrentFastResume`：与 DB 改写同一个 `DocumentsPathRebaser`（搬移作用域判据，
    用户自选的外部下载根原样；已改写路径天然幂等），先在内存算好全部新字节、逐个临时文件 + 原子替换，中途失败
    全部写回。接进 `migrate()` 的「③」步（DB 改写失败 → resume 写回原字节；提交位置失败 → 在文件此刻所在的根上
    反向改写），沙箱重定位 `SandboxRelocation.reconcile` 跑同一步。
  - 停 / 启时序：`_closeRuntimeResources` 先调 `AppModel.releaseEmbeddedTorrentForDataRootMove()`——强制落一次
    resume（迁移器改写的是最新状态）、关 session、禁止本进程再懒建（迁移成功后进程重启，新进程按改写后的 resume
    恢复）。停不下引擎就抛出，迁移在搬任何文件前失败。
- **[x] ② 已加自动化测试** —
  - `fushi/test/media/torrent/embedded_torrent_fast_resume_relocate_test.dart`：真 libtorrent 往返（建种 → 校验完成 →
    落 resume → 搬目录 → 迁移器改写 → 新 session 从新根恢复，断言 save_path 是新根且直接认成已完成）。需
    `FUSHI_TORRENT_LIB`，CI 无原生库时 skip。
  - `fushi/test/storage/data_root_migrator_fast_resume_test.dart`：字节级改写（嵌套同名键、二进制串不动；截断 / 尾部
    垃圾 / 非字典不改）、`migrate()` 成功 / DB 改写失败 / 提交失败三条路径、外部下载根原样、沙箱重定位。
  - 变异实测：去掉 `migrate()` 里的改写 → 成功用例红；改写函数变 no-op → 真引擎往返红；真引擎往返去掉改写一步 →
    30 s 超时红（证明不改写时 libtorrent 确实找不到数据）。
- **备注**：没有改 native。选在迁移器里改写，而不是在 `ht_load_resume_dir` 加载时重映射：迁移器本来就是「数据根
  内绝对路径」的唯一改写点（DB / prefs / profile_settings 同一个判据与事务边界）；加载时重映射得把旧→新映射持久化、
  每次启动都套一遍。
