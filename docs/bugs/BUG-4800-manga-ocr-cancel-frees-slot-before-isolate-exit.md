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
  - `fushi/test/ocr/manga_ocr_cancel_waits_exit_test.dart`（4 条）：`ocrFolder` 取消订阅的
    Future 等 `job.result`；任务没起时立即完成；真起整卷 isolate 的一条（isolate 同步卡 1.5 秒
    模拟正在推理，取消订阅的 Future 在它收尾前不完成，提交 `7c3e8af6646`）；端到端一条把真链路
    接起来（注册表 → `mangaOcrLocalEvents` → `MangaOcrServiceImpl.ocrFolder`），不发任何进度
    事件：取消请求没有当场传到任务、或中间任何一层丢掉取消 Future 都变红。
  - `fushi/test/sync/manga_ocr_host_cancel_waits_exit_test.dart`（1 条，提交 `7c3e8af6646`）：
    互联主机 `cancelAndCleanup` 等执行体停下之后才删页图、才放行串行队列里的下一个任务。
    同文件「disposeAll」组 5 条（提交 `4e1d78fa2f8`）：执行体没停就返回、排队中的任务不再启动、
    完成信号等执行体停下才补；停机途中别的路径增删任务不抛并发修改；途中的 `cancelAndCleanup`
    不抢在执行体停下之前删页图；执行体收尾抛错时完成信号照补；真 `FushiSyncServer.stop()` 不被
    还没停下的执行体挂住。
    提交 `894f5205934` 再补 4 条并改 1 条：`start` 正在等模型状态时任务被取消 / 遇上停机，回来
    回 409 且不起跑（各 1 条）；两个 `start` 同时在等模型状态只起一个执行体；途中的
    `cancelAndCleanup` 跨「停机后新建管理器」不删新管理器同卷任务刚传的页图；原「途中的
    `cancelAndCleanup`」一条的结尾断言改成「任务已被停机摘出表，执行体停下后页图留着」。
    把 `start` 的复查与 `cancelAndCleanup` 的出表判断拿掉，这里 4 条变红。
- **备注**：
  - **真机复测未做，待补**（Android / iOS，本地模型）：整卷识别中点暂停后立刻点继续、以及取消后
    立刻对另一本点识别，量 ① 取消到旧 isolate 退出的时间（`manga_ocr_volume_job` isolate 消失）
    ② 这段时间的内存峰值（应只有一套模型）。尾巴多长此前没有实测数据；「暂停立即有反应」「被
    打断的那一页只识别一次」也只有自动化测试，没在设备上看过。
  - 副作用：所有 await `ocrFolder` 订阅取消的调用方现在都等到 isolate 退出，包括互联主机
    `fushi_manga_ocr_host.dart` 的 `cancelAndCleanup`（`disposeAll` 见下一条）。
    `cancelAndCleanup` 等是对的（它的串行队列原先有同一个问题：补完成信号时旧 isolate 还
    活着；页图也不该在旧 isolate 还在读时删），客户端的 DELETE 因此最多多等一页的识别时间。
  - **`disposeAll` 已修**（提交 `4e1d78fa2f8`）：它原先在 `for … in _jobs.values` 里逐个
    `await job.subscription?.cancel()`，而 `FushiSyncServer.stop()`（`fushi_sync_server.dart:1178`）
    顺序 await 它，其后才 dispose 屏幕 OCR / 主机任务 / 助手——主机代跑整卷 OCR 时关互联，
    `stop()` 要等 isolate 跑完当前页，原生推理卡死时不完成；等待期间别的路径改 `_jobs` 还会抛
    `ConcurrentModificationError`。现在它取任务快照、清表、逐个发取消就返回，中间没有 await。
    收尾仍排在各自执行体停下之后：串行队列的完成信号到那时才补（管理器仍被引用时，后面的任务
    不会在旧执行体还占着模型时起跑），途中的 `cancelAndCleanup` 等的是同一个取消 Future（它回来
    之后删不删页图见下一条）；执行体收尾抛的错记日志。顺带改掉一处：停机时还在排队的任务原先保持 `running`，
    轮到时会在停机之后起一个 isolate，现在标成已取消。要动任务根目录的调用方可等
    `whenExecutorsStopped`（目前没有这样的调用方，停机不删目录）。
  - 其他 await 取消的调用方核对过：`fushi_server` 的 `ocr` 命令是 `await for` 读到流结束，循环体
    不提前退出，走不到取消；向导、阅读器、管理页对 OCR 订阅的取消都是 `unawaited`。只有互联
    主机这两处在等。
  - **`disposeAll` 不再等之后跟着修的三处**（提交 `894f5205934`，都在 `fushi_manga_ocr_host.dart`）：
    - `start()` 在 `await service.modelStatus()` 期间任务被取消或遇上停机，回来后原先照样把状态
      覆写成 `running` 并排进队列——出了表的任务起了 isolate，停机后还在跑且没人能取消。现在
      await 之后复查：任务已是终态或已不在表里就回 `(409, 'bad_state')`。
    - 同一个窗口里两个 `start` 都在等模型状态时，原先两个都排进队列，同一个任务先后起两个
      执行体。现在后回来的那个看到任务已是 `running` 就按幂等返回。
    - 途中的 `cancelAndCleanup` 跨停机：`disposeAll` 不等之后，客户端的 DELETE 还在等执行体
      停下时用户可以关互联再开；app 每次开互联新建一个管理器（`fushi_server_controller.dart`），
      同卷的新任务落回同一个 `vol_<slug>` 并重新上传，旧执行体停下后旧的 `cancelAndCleanup`
      查的是旧管理器的空表，会把新任务的页图删掉。现在它等完之后发现任务已被 `disposeAll`
      摘出表就不删页图，留给孤儿清扫（与停机时别的任务一样）。
  - 「关互联后立刻再开」的窗口（路线图 #3722 c41 遗留，`pr/nmv-leftover-manga-misc` 修）：app 侧每次
    开互联新建管理器与服务，`fushi_server_controller.dart` 的 `_buildMangaOcrJobManager` 把新管理器的
    串行队列起点（`runAfter`）接在上一个管理器的 `whenExecutorsStopped` 后面。`whenExecutorsStopped`
    本身也并进了自己的 `runAfter`，链可以传递：连着开关三次、第二个管理器的任务还在排队没起执行体
    （它自己的在停集合是空的）时，第三个管理器照样等到第一个管理器那只还没停下的执行体。
    headless 服务端复用同一个管理器，没有这个窗口。
  - **已知局限**：原生推理卡死、旧执行体永远不停时，这条链永远不完成，之后每次开互联新建的管理器
    的任务都一直排在队里（状态是 `running`、`pagesDone` 不动），直到重启 app。这是有意的取舍——不加
    超时放行，否则卡死的旧 isolate 与新任务就是两套模型同时在内存；推理卡死本身要在执行体那一层
    修，不在队列这里掩盖。目前没有对客户端单独显示「在等旧执行体」的状态（要加 wire 状态，另议）。
  - 没动：Lens / 系统 OCR / 外部 mokuro / 配对主机的事件流也是 `async*` + `await for`，取消同样
    要等到下一个事件才生效（Lens 一页一次 HTTP、系统 OCR 一页一次平台调用，晚的是「当前这一页
    之后才停」；外部 mokuro 的 kill 要等它下一行输出）。它们不占模型内存，不在本条范围，另记。
  - 没覆盖：注册表之外的本地模型使用者（阅读器的页级会话 `openPageSession`）不占整卷名额，
    本条不涉及。
