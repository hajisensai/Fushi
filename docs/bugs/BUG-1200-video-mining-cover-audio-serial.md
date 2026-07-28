## BUG-1200 · 视频制卡封面与句子音频串行且失败来源靠调用顺序区分
- **报告**：2026-07-28（用户：视频制卡很慢）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/mining/immersion_mining_engine.dart`（改前 L152-242）：
  封面阶梯 `await tryGif()` 跑完才开始抽句子音频，两条**互不依赖**的 ffmpeg 抽取被串成
  一条，耗时直接相加。用户把「图片/GIF 清晰度」调到最高档时尤其明显——BUG-1039 注释里
  的实测：1080p、4 秒字幕区间，标准档 GIF 1.5 秒 / 1.5 MB，最高档 6 秒 / 7.7 MB，音频
  再串在后面。
  第二处根因 `hibiki/lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart`
  （改前 L385-388）：调用点用**同一个 onFailure 的调用顺序**区分两个语义不同的摘要
  （`gifFailure ??= summary` 取首个当封面失败、`lastFailure` 取末个当音频失败）。这是
  靠时序承载语义的脆弱设计——并行化后顺序不再确定，OSD 的失败原因必然串味。
- **[x] ① 已修复** — 音频抽取抽成 `_resolveAudioPath`（逐行原样搬，零策略改动），在封面
  阶梯**之前**启动、末尾才 await，两条重叠执行，总耗时从 `封面+音频` 变成
  `max(封面,音频)`；封面阶梯内部的优先级顺序（GIF→起点帧→当前帧，真依赖）完全不动。
  在途 Future 用 catchError 暂存异常、末尾重抛，避免封面先抛时留下 unhandled async
  error，抛出语义与串行版逐字一致。
  失败摘要改按**来源**分流：新增 `onCoverFailure` / `onAudioFailure`，`onFailure` 保留
  为合流回调故既有调用点（app_model 的 YouTube/Netflix、gal coordinator）零改动。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/immersion_mining_parallel_test.dart`：
  ①「封面不被音频阻塞」——让音频假件挂住、断言封面已开工，串行实现会挂死超时红（已实测
  反向验证：临时把 await 移回封面之前，该用例 20s 超时失败）；②「失败摘要按来源分流」
  断言封面通道不含音频摘要、反之亦然，合流回调仍收全部。既有
  `immersion_mining_engine_test.dart` 20 个用例全绿，无回归。
- **备注**：方向很关键——反过来写（挂住 GIF、断言音频已开工）是**假绿**：`_resolveAudioPath`
  是 async 函数，`audioFuture` 一创建就同步跑到内部首个 await，哪怕退回串行也照样"已开工"，
  断言恒真。第一版守卫正是这么写的，实测串行仍全绿才发现，已改为现在的方向并在注释里记下。
