## BUG-4800 · 漫画 OCR 取消 / 暂停后 isolate 还没退出就释放并发名额，新旧任务同时占模型内存
- **报告**：2026-11-17（用户：代码审查，漫画优化清单第 16 条）
- **真实性**：✅ 真 bug。根因有两处，都在「取消只是请求、没人等它真的停下」（行号按
  `pr/manga-ocr-pipeline` `4a5fd7a06bb`）：
  - `packages/fushi_engine/lib/ocr/manga_ocr_service_impl.dart:1693` —— `ocrFolder` 的
    `controller.onCancel` 同步调 `job?.cancel()` 就返回。`cancel()`（`:1300`）只置标志 +
    向 isolate 发一条消息；isolate 侧（`:611`）收到后只是 `cancelToken.cancel()`，要等当前页
    跑完、`engine.close()` 之后才 `Isolate.exit`（`:679-683`）。取消订阅的 Future 因此在
    isolate 还活着时就完成了，上层拿不到「已退出」的信号。
  - `fushi/lib/src/media/manga/ocr/manga_ocr_job_registry.dart:121` —— `MangaOcrRunningJob.cancel()`
    `await _source?.cancel()` 后立刻 `_end()`；`enqueue`（`:512`）的同书队列与全局名额
    （`_releaseSlot`）都挂在 `whenEnded` 上。暂停（`pause`）走同一个 `cancel()`，继续
    （`resume`）立刻 `enqueue`。
  - 修的时候另外查到的第三处：`fushi/lib/src/media/manga/manga_ocr_job_stream.dart:269` ——
    `mangaOcrLocalEvents` 是 `async*`，对服务的事件流用的是 `await for`。`async*` 挂在
    `await for` 上时收不到取消，要等内层流的下一个事件到了、走到下一个 `yield` 才收尾。于是
    取消请求要等「当前页跑完、进度事件到达」之后才传到 isolate，那时它多半已经开始下一页，
    还得再多跑一页才退出；注册表原先的 `await _source?.cancel()` 也一直等到那一刻。

  后果：手机 / 低内存模式并发恒为 1（`resolveMangaOcrJobConcurrency`），但取消或暂停后的
  这段时间里新任务已经起了 isolate、建了第二套 ORT 会话，旧 isolate 的那一套还没放——
  「只跑 1 卷」失效，两套模型同时在内存。同书「暂停后立刻继续」更糟：新任务按逐页缓存跳过
  已完成页后要补的第一个缺页，正是旧 isolate 在收尾的那一页，两边同时识别、同时写这一页的
  缓存（写入撞名见 BUG-4801）。
- **[x] ① 已修复** — 提交 `18c64f2557c`。
  - 执行器侧：`ocrFolder` 的 `onCancel` 返回「`job.result` 完成」的 Future。`result` 在收到随
    `Isolate.exit` 发出的终局消息时才完成（既有协议，BUG-3997 同款），所以取消订阅的 Future
    完成 ⇔ 推理会话已关、isolate 已退出。不加新消息、不加延迟。契约写进
    `MangaOcrService.ocrFolder` 与 `MangaOcrVolumeJob.result` 的文档。
  - 事件流侧：`mangaOcrLocalEvents` 尾部的 `await for` 换成 `yield* events.asyncMap(...)`。
    `yield*` 期间的取消直接转给内层订阅：取消请求当场到 isolate（它跑完当前页就退出，不再多跑
    一页），取消的 Future 也原样传回注册表的 `asyncMap`，中间不用另外接线。
  - 注册表侧：`MangaOcrRunningJob` 新增 `whenStopped` / `isStopped`（执行器真正停下）。
    `cancel()` 不再 await 底层订阅的取消——**用户侧照旧立即返回**（删书、切 Profile 的
    `cancelAll`、退出 app 都 await 它，原生推理卡住时不能把这些流程挂住），只把那个 Future 接到
    `whenStopped` 上。`enqueue` 的全局名额与同书队列改等 `whenStopped`；被取消 / 暂停后已不在
    `_jobs` 里的任务记进 `_stopping[bookKey]`，同书重新排上的任务排在它们停下之后。
  - Lens / 系统 OCR / 外部 mokuro / 配对主机没有可等的 isolate，它们取消订阅的 Future 本来就
    很快完成，行为不变（只是注册表不再 await 它，收尾抛的错改为记日志）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/media/manga/ocr/manga_ocr_job_registry_stop_test.dart`（6 条）：取消本书后
    `cancel` 立即返回但名额等退出才让给下一本；暂停后立刻继续，重建的任务等旧执行器退出才开跑；
    不占名额直接 `start` 的任务同理；`cancelAll` 不等退出；自然结束立即算停下；执行器收尾抛错
    名额照样归还。
  - `fushi/test/ocr/manga_ocr_cancel_waits_exit_test.dart`（3 条）：`ocrFolder` 取消订阅的
    Future 等 `job.result`；任务没起时立即完成；端到端一条把真链路接起来（注册表 →
    `mangaOcrLocalEvents` → `MangaOcrServiceImpl.ocrFolder`），不发任何进度事件：取消请求没有当场
    传到任务、或中间任何一层丢掉取消 Future 都变红。
- **备注**：
  - 真机待验（Android / iOS，本地模型）：整卷识别中点暂停后立刻点继续、以及取消后立刻对另一本
    点识别，量 ① 取消到旧 isolate 退出的时间（`manga_ocr_volume_job` isolate 消失）② 这段时间
    的内存峰值（应只有一套模型）。尾巴多长此前没有实测数据。
  - 副作用（有意）：所有 await `ocrFolder` 订阅取消的调用方现在都等到 isolate 退出，包括互联主机
    `fushi_manga_ocr_host.dart` 的 `cancelAndCleanup` / `disposeAll`（它的串行队列原先有同一个
    问题：补完成信号时旧 isolate 还活着）与 `fushi_server` 的 `ocr` 命令。客户端的 DELETE 因此
    最多多等一页的识别时间。
  - 没动：Lens / 系统 OCR / 外部 mokuro / 配对主机的事件流也是 `async*` + `await for`，取消同样
    要等到下一个事件才生效（Lens 一页一次 HTTP、系统 OCR 一页一次平台调用，晚的是「当前这一页
    之后才停」；外部 mokuro 的 kill 要等它下一行输出）。它们不占模型内存，不在本条范围，另记。
  - 没覆盖：注册表之外的本地模型使用者（阅读器的页级会话 `openPageSession`）不占整卷名额，
    本条不涉及。
