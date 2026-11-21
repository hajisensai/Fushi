## BUG-5072 · 下载页已完成仍做种的视频任务无法暂停/恢复做种（单条与批量）
- **报告**：2026-11-21（用户实测：下载页全选 → 批量暂停，提示「已处理 7 项 · 135 项不支持此操作」；被跳过的 135 条全是 `video_download_jobs` 里 lifecycle=completed、种子仍在后端（本次为 `fushi_host`）做种的任务）
- **真实性**：✅ 真 bug。视频任务的暂停 / 继续可用性只看持久生命周期，不看后端种子：
  - `fushi/lib/src/pages/implementations/video_download_jobs_panel.dart:66` `videoDownloadJobCanPause` 只认 `active`，`:62` `videoDownloadJobCanResume` 只认 `cancelled`；
  - 批量槽位 `:423`（`_entryActions`）与卡片行尾主操作 `:1684`（`_quickAction`）/ 按钮行都用这两条判据，completed 任务两处都拿不到 pause / resume（单条入口同样缺失，批量计为 unsupported）；
  - 引擎侧也没有对应原语：`packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:1775` `cancelJob` 对 completed 直接拒绝，且 cancel/resume 改的是持久生命周期，本就不是「停做种」的语义。
- **[x] ① 已修复** — 引擎新增 `VideoDownloadPipelineService.pauseSeedingJob` / `resumeSeedingJob`：只接 completed 任务，经 `backendResolver` + `_validateBackendBinding` 取**任务自己绑定的后端**（kind/profile/fingerprint 不符即拒绝，不去别的下载器上动同 hash 种子），种子不在后端拒绝，调 `TorrentPauseBackend.pauseTorrent/resumeTorrent`（内置引擎宿主视图 = `pauseTorrentByUser`，记进持久 user_paused 集，上传策略不会抢回；`fushi_host` 由对端引擎执行同一原语），生命周期保持 completed。面板新增 `videoDownloadJobCanPauseSeeding/ResumeSeeding`（判据 = completed + 后端快照存在 + 是否 paused），并用 `videoDownloadJobPauseAction/ResumeAction` 一个选择器同时供卡片按钮与批量槽位，消除两份判据；动作完成后立即重读快照。`browse_page.dart` 接线。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart`（group `BUG-5072 completed job seeding pause / resume`：精确种子暂停/恢复且生命周期不变、种子已移除拒绝、后端身份不符拒绝、非 completed 拒绝）；`fushi/test/pages/unified_download_jobs_panel_test.dart`（做种中 / 已暂停做种 / 种子已移除三类 completed 任务的批量槽位、`runDownloadTaskBatch` 批量暂停与继续计数、卡片行尾主操作同判据且不走 cancel/resume）。
- **备注**：后端只能按当前设置构造（app 只存一份下载配置），所以「按任务行解析」落实为「当前后端身份必须与任务行一致，否则拒绝并提示」，与 cancel/resume/delete 同一契约。真机复测未做（按记忆规则不做真机验证）。
