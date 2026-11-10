## BUG-4400 · 漫画 OCR client 出错时只报错不清理、host 任务成孤儿（未复现）
- **报告**：2026-11-10（互联远程长任务审查 V-D3 的一支：「`interconnect_manga_ocr_client.dart:497-500` 的 catch 只 `addError`、不调 `cleanupRemote()`，上传中途失败 / 轮询协议错 / host 侧 error 后任务留在 host 表里、running 的孤儿占住串行队列」）
- **真实性**：❌ 未复现。修复前（`556b4a45b5c`）catch 确实没有显式清理，但紧接着 `finally` 里的 `controller.close()`（`:504`）把 done 事件送到订阅者时，`StreamController` 会触发 `onCancel`（`:509-512`），后者调用 `cleanupRemote()`，此时 `jobId` 仍是 host 任务 id → 照样发出 DELETE。实测：① 独立探针（`StreamController` + 不带 `cancelOnError` 的 `listen(onError:)`，与向导 `manga_ocr_wizard_dialog.dart:554-568` 同形）在 `addError` + `close()` 后打印 `onCancel fired`；② 修复前跑 `fushi/test/sync/interconnect_manga_ocr_client_test.dart` group `remote job lifecycle` 的「protocol error while observing deletes the host job」「host-side OCR failure also deletes the host job」两例即为绿（`jobCount` 归 0、fake 服务流被 cancel）。所以错误路径不会留孤儿，只是清理靠「关流触发 onCancel」这条隐式路径。
  - V-D3 的另外两支是真的，归 [BUG-4399](BUG-4399-remote-job-client-lifecycle.md)：create 在途时取消（`onCancel` 那一刻 `jobId` 还是 null，create 回来后 `if (cancelled) return;` 不清理）留下 pending 孤儿；任何一次传输抖动都被当成任务失败、进而经同一条 onCancel 路径 DELETE 掉 host 任务。
- **[ ] ① 无需修复** — 不另改。BUG-4399 的 OCR 部分把 run() 改成显式三阶段后，catch 里已显式 `cleanupRemote()`，不再依赖关流触发 onCancel。
- **[ ] ② 无需测试** — 上述两例留作回归守卫（修复后仍绿）。
- **备注**：无。
