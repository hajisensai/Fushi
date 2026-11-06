## BUG-3542 · 数据根迁移后下载任务 observed_save_path 仍指向旧默认下载根
- **报告**：2026-10-19（内部审查：核 BUG-3541 相邻问题时发现）
- **真实性**：✅ 真 bug（代码路径核实）。`video_download_jobs.observed_save_path` 在
  `fushi/lib/src/storage/path_rebase_coverage.dart:516-518`（修前）登记为 `externalUserPath`，迁移器从不改写它。
  但内置引擎用默认下载根 `<documents>/anime_downloads/content` 时，这列就是数据根内的本机路径：文件随根搬走、
  引擎 resume 也被改写（BUG-3541），这列却停在旧根；已完成的任务不再刷新它（下载阶段只在未完成时写，
  `video_download_pipeline_service.dart` 下载 tick），任务删除 / 打开位置的兜底与持久化详情都拿着一个不存在的
  目录（#2358 之后同机映射要求目录在本机存在，兜底被跳过而不是删错，但记录本身失效）。
- **[x] ① 已修复** — 527e0ce5bd：分类改为 `documentsRooted`；`DataRootMigrator._rebaseVideoDownloadJobs`
  在 DB 改写事务里经同一个按搬移作用域判断的 `DocumentsPathRebaser` 改写这列。外接远端 qBittorrent 的远端
  坐标、用户自选的外部下载根不在旧根下，原样跳过（远端坐标仍由显式 remote→local 映射解释）；已改写路径首段
  不在白名单里，天然幂等。沙箱重定位共用 `rebaseOpenDatabasePaths`，自动覆盖。
- **[x] ② 已加自动化测试** — `fushi/test/media/torrent/download_job_path_relocate_test.dart`「数据根迁移」组：
  内置默认根改到新根、远端坐标 `/srv/qbittorrent/downloads` 与外部根原样；新根落在旧根内部时连跑两次只改一次。
  `fushi/test/storage/path_rebase_coverage_guard_test.dart` 的 `_rebase<Table>` 接线守卫随分类自动覆盖。
  变异实测：去掉 `_rebaseVideoDownloadJobs` 调用 → 两条用例 + 接线守卫红；改成不看作用域的 `rebasePath` →
  幂等用例红（`.../Fushi/data/Fushi/data/...`）；不分青红皂白全改 → 远端坐标断言红。
- **备注**：远端坐标被误改的唯一可能是远端 qB 报告的路径字面上恰好落在本机旧数据根之下（同一路径布局），那时
  它与本机同视角，按本机路径改写也是对的。
