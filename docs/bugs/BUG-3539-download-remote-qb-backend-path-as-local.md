## BUG-3539 · 外接远端 qBittorrent：改名/移动、任务删除与打开位置把后端坐标的保存路径当本机路径用
- **报告**：2026-10-19（内部审查：上一轮修 e90c6d581c 时子代理标出）
- **真实性**：✅ 真 bug（代码路径核实）。仓库早有远端 ↔ 本机路径映射契约（`VideoDownloadPathMapping` /
  `VideoDownloadBackendPathMappingConfig`，按 backend profile id 隔离，偏好键
  `video_download_backend_path_mappings`，设置页「外部来源」里可配；下载流水线整理阶段经它换算），但有三处
  消费方绕开了它：
  1. 改名/移动入口：`anime_download_dialog.dart:1338/1346`（修前）把后端快照 `snapshot.savePath`（远端坐标）
     原样交给 `DownloadRelocateService`，后者用它拼库路径做迁移（`download_relocate_service.dart:68/91`，修前）——
     远端 `/downloads/...` 与本机库路径永远对不上，库不迁移但报「成功」；移动时把本机文件夹选择器选出的本机路径
     直接发给远端 `moveStorage`（`download_relocate_service.dart:90`，修前），远端机器上没有这个路径。
  2. 任务删除：`deletePersistedVideoDownloadJob` 用 `observedSavePath`（后端坐标）当本机根拼要删的文件
     （`packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:506`，修前）。
  3. 打开位置：`resolveJobLocation` 把快照 content/save path 与 `observedSavePath` 拼出的路径当本机候选
     （同文件 `:1616/:1628`，修前）。
- **[x] ① 已修复** — 3ab3df74c9：映射判据收成一处公共函数（`video_download_path_mapping.dart`：
  `videoDownloadPathMappingsForProfile` / `effectiveVideoDownloadPathMappings` /
  `videoDownloadRemoteToLocal` / `videoDownloadLocalToRemote`，流水线原私有实现改为委托），语义与流水线一致：
  显式映射优先；没配映射只在后端保存位置**真实存在于本机**时按同机恒等映射。
  - `DownloadRelocateService` 先把后端 save_path 经当前配置档映射换成本机路径（映射不到 → 动引擎前拒绝，
    提示配置下载路径映射）；移动目的地（本机）经映射换成后端坐标再发；`AppModel.downloadRelocateService`
    注入 `downloadPathMappingsForProfile(identity.profileId)`。
  - 任务删除 / 打开位置：后端坐标一律经任务**自己配置档**（`job.backendProfileId`，流水线内用核对过身份的
    binding）的映射换算，映射不到的不进删除 / 候选集合；`deletePersistedVideoDownloadJob` 的 `pathMappings`
    改为必填，app 侧两个调用点（下载页、桌面 ctl）传 `appModel.downloadPathMappingsForProfile(job.backendProfileId)`。
- **[x] ② 已加自动化测试** — `fushi/test/media/torrent/download_relocate_service_test.dart`
  「远端 qB + 显式映射…」「远端 qB 没配映射：动引擎前就拒绝…」「目的地不在任何映射里…」；
  `fushi/test/media/video/download/video_download_pipeline_service_test.dart`
  「delete resolves the backend save path through the path mapping」组（映射到的远端路径删本机挂载文件；映射不到
  不当本机路径解释）。
- **备注**：没有流水线实例时的「库侧删视频 → 对账任务」路径（`reconcileVideoDownloadJobsAfterLocalDelete`
  的 pipeline==null 分支）拿不到核对过身份的绑定，按「仅同机」解释；远端任务在这种情况下只按
  `finalAbsolutePath` 精确删，`observedSavePath` 兜底不走（安全方向）。
  变异实测：任务删除改回拿 `observedSavePath` 当本机根 → 映射删除用例红；relocate 映射不到时把远端路径当本机
  路径 → 「远端 qB 没配映射」用例红。
