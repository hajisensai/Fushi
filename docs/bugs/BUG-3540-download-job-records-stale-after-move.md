## BUG-3540 · 移动/改名/整理后下载任务行的保存位置与相对路径不跟着更新
- **报告**：2026-10-19（内部审查：上一轮修 e90c6d581c 时子代理标出）
- **真实性**：✅ 真 bug（部分）。e90c6d581c 已覆盖：改名/移动时 `video_download_job_files.final_absolute_path`
  同事务改写；数据根迁移时任务文件 / 任务字幕路径按搬移作用域 rebase。**未覆盖**的是任务表另外两列——
  任务删除（`deletePersistedVideoDownloadJob`）、打开位置（`resolveJobLocation`）与持久化详情
  （`buildPersistedVideoDownloadJobDetails`）都用 `observed_save_path + current_relative_path` 拼路径：
  1. 用户改名：`migrateMediaPaths`（`packages/fushi_engine/lib/media/video/video_book_repository.dart:611-673`，修前）
     只改 `final_absolute_path`，`current_relative_path` 仍是旧名；
  2. 用户移动：同上，`video_download_jobs.observed_save_path` 仍是旧保存根；
  3. 下载完成后的整理落库：`_organizeManagedDownload` 把种子 `moveStorage` 到来源根后
     （`packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:2994-3003`，修前）
     `current_relative_path` 已换成来源根下的新相对路径，`observed_save_path` 却仍是旧下载目录
     （下载阶段只在未完成时刷新它，`:2671`）——两列拼出一个不存在的路径。
- **[x] ① 已修复** — 3ab3df74c9：`VideoBookRepository.applyDownloadRelocation`（取代 `migrateMediaPaths`）在同一事务里
  按 info hash 找到该种子的任务行：移动时写新的后端保存位置（`observed_save_path`），改名时把对应
  `backend_file_index` 文件行的 `current_relative_path` 换成新种子内路径；`final_absolute_path` 只改真被搬走的
  文件（BUG-3538）。整理成功后 `_recordObservedSavePath(job, planned.remoteSourceRoot)`；崩溃重放分支
  （`_organizedFilesExist`）经映射把来源根换回后端坐标补记。
- **[x] ② 已加自动化测试** — `fushi/test/media/torrent/download_job_path_relocate_test.dart`（改名断言
  `currentRelativePath`、移动断言两条任务的 `observedSavePath`，其它种子的任务不动）；
  `fushi/test/media/video/download/video_download_pipeline_service_test.dart`
  「source and observed roots can use different backend path mappings」追加断言整理后
  `observedSavePath == '/media'`。
- **备注**：数据根迁移时 `observed_save_path` 仍按 `externalUserPath` 不改写（`path_rebase_coverage.dart`）。
  修本条时发现的相邻问题——内置引擎 fast-resume 里的绝对 save_path 不随数据根改写——已单独立为 BUG-3541 并修复。
  变异实测：去掉整理后的 `_recordObservedSavePath` → pipeline 用例红；去掉 relocation 写 `observed_save_path` →
  job_path_relocate 移动用例红。
