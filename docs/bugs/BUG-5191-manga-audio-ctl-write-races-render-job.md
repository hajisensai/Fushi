## BUG-5191 · 漫画有声控制通道写操作与整卷生成任务之间没有互斥，期间排上的任务会盖掉改动
- **报告**：2026-11-22（审查 PR #4136 / 拍板 isATnQZ_eN 时发现）
- **真实性**：✅ 真缺陷（代码路径推断，未在真机复现）。控制通道的写操作（`fushi/lib/src/ops/ctl_tts_routes.dart` 的 `editLine` / `regenerate` / `replaceLines` 等）只在入口调一次 `requireNotRendering`（`fushi/lib/src/ops/ctl_tts_support.dart:262`），之后读演出稿 / 清单、改、再落盘之间不持有任何「这一卷正在被改」的标记；整卷生成任务（`runMangaRenderJob`，`fushi/lib/src/media/manga/audio/manga_audio_render_service.dart`）开跑时同样不看。`tts replace`（`fushi/lib/src/ops/ctl_tts_batch.dart:234` 起，逐句 ffmpeg 整形，最多 2000 句、可能几分钟）把这个窗口拉得很长：期间从复核页或另一条 CLI 排上的整卷生成先读到旧演出稿 / 旧清单，结束时把自己的版本写回，换上的本地音频音源与清单行被盖掉（用户原文件仍在，可重做；撤销会报 superseded）。按角色批量重生成里「排队时 enqueue 返回别处的任务」那一种已在 PR #4136 审查时修掉（`_isRerollJob`，见下），这里登记的是剩下的通用读改写竞态。
- **[ ] ① 未修复** — 根治方向：一卷一把进程内写锁（例如 `MangaAudioWriteGate.run(bookKey, fn)`），控制通道写操作、复核页保存与 `runMangaRenderJob` 读演出稿 / 写回都在锁里；或把这几个写操作都改成制作队列里的任务，由队列串行。需要动复核页与生成服务，超出 PR #4136 范围。
- **[ ] ② 未加自动化测试** — 修时在 `fushi/test/ops/ctl_tts_routes_test.dart` 加「replace 整形中途排上整卷生成」用例（后端整形处挂起，断言生成任务等写锁 / 结果不丢）。
- **备注**：PR #4136 审查修复：`regenerateMangaCharacterLines` 排队后核对返回的任务就是这次的批量重生成，否则删备份、409，避免把别人的整卷生成 ID 记进撤销快照（撤销会取消别人的任务），测试 `按角色批量重生成：门检查之后别处排上了这一卷的任务 → 409…`。
