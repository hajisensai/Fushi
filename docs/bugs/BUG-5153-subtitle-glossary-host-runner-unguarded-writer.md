## BUG-5153 · subtitle-glossary-host-runner-unguarded-writer
- **报告**：2026-11-22（PR #4070 独立审查，HBK-AUDIT-039 / BUG-5122 的遗留面）
- **真实性**：✅ 真 bug（源码确认，未写复现测试）。app 进程里专名表还有第四个写方：`fushi/lib/src/models/app_model.dart` 的 host 任务表装配了 `VideoSubtitleHostJobRunner`（远端设备提交的 `video_subtitle` 任务在本机跑），它的 S0 走 `packages/fushi_engine/lib/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart` 的「load → `SubtitleGlossaryBuilder.build` → save」，存储是同一个库的 `SubtitleGlossaryDriftStore`（`video_subtitle_host_job_runner.dart` 装配 `glossaryStore`），作品键来自同一个 `SubtitleWorkContextLoader`，所以写的是与视频页面板同一行。BUG-5008（`glossaryWriterFor` 只看 `AppVideoSubtitleService._active`）与 BUG-5122（`_regeneratingGlossaries` 是服务私有集合）都看不到它：host 任务 S0 在飞时，本机编辑页保存 / 重新生成 / 起校对任务照样放行，反过来也一样，后写的整张盖掉先写的。
- **[ ] ① 未修复** — 建议方向：把「同一张表同时只许一个写方」从 `AppVideoSubtitleService` 私有状态提成进程内共享的按 glossaryKey 的写方登记（engine 层，pipeline S0、host runner、app 服务的保存 / 重新生成 / 起任务都经它），host 任务撞上时暂停并给出原因。涉及 engine 管线、host runner、`app_model.dart` 装配与 host 任务可见行为，属范围扩大，待拍板后做。
- **[ ] ② 未加自动化测试** — 需要：host runner S0 在飞时 app 服务保存 / 重新生成被拒；app 重新生成在飞时 host 任务 S0 不写表。
- **备注**：`fushi_server` 是独立进程、独立库，不在此范围。
