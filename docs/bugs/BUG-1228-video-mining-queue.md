## BUG-1228 · 连续视频制卡未串行且换集可能污染在途任务
- **报告**：2026-07-29（用户要求多次制卡进入队列，换集不得中断已提交任务）
- **真实性**：✅ 真 bug。每次视频制卡各自新建 `ImmersionMiningEngine` 并立即执行，整个“抽 GIF/音频 → 写固定临时文件名 → 上传媒体 → add/update note”没有共享串行边界；连续制卡会争用同名临时文件并同时压向单一 AnkiConnect GUI 端点。若只在页面 State 上排队，本地换集的 `pushReplacement` 又会销毁队列所有者；若到任务出队时才读 controller，远端原地换集还会把旧卡污染成新集数据。根因位于 `hibiki/lib/src/mining/immersion_mining_engine.dart:75` 与 `hibiki/lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart:302`。
- **[x] ① 已修复** — `1a222a587`：为所有沉浸制卡建立进程级共享 FIFO，整笔制卡事务串行；入队时冻结字段、媒体源、时间段、音轨、集数、标题、标签和当前帧 Future，临时目录也在队列内按点击顺序解析。本地换页或远端换流都不取消、重排或篡改已入队任务；单个任务失败保留原异常，但不会毒化后续队列。
- **[x] ② 已加自动化测试** — `immersion_mining_queue_test.dart` 覆盖第一张等待期间第二张不得启动、异步临时目录不得导致逆序、换集后各卡仍使用各自源和字段快照；`serial_job_queue_test.dart` 覆盖失败原样返回且后续任务继续。
- **备注**：已撤销未经用户授权的 4 MiB GIF 降质策略，并以 5 MiB GIF 反回归测试锁定“按所选最高质量只抽一次、不重制、不降静态图”。本轮 36 个定向测试通过，相关 analyzer 为 0 issues；按用户要求未运行 Windows/整包编译。
