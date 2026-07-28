## BUG-1203 · 视频制卡封面与句子音频串行且失败来源靠调用顺序区分
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
  ①「封面与音频真并行」——**两条都挂住**，要求 `audioStarted` 与 `gifStarted` 同时亮才放行；
  ②「失败摘要按来源分流」断言封面通道不含音频摘要、反之亦然，合流回调仍收全部。另把
  `video_mining_context_guard_test.dart` 的 engine 侧断言从「两个 token 在全文件里各自存在」
  的无锚 AND 改为锚进 `_gif(` / `_audio(` 调用块内。变异实测（退回实现、看断言是否真转红）：
  退回**原始 cover-first 串行** → 红；`tryGif` 的上报口改回 `onFailure: onFailure` → 红。
- **备注**：**审查中更正了一条错误的验证结论**。第一版守卫只挂音频、断言「音频在途时封面
  已开工」，并声称「已反向验证：把 await 移回封面之前 → 超时红」——那验证的是 *audio-first*
  串行，而代码里**从未存在过**那种形态。改造前的真实串行是**封面在前、音频在后**：GIF 先跑完
  （gifStarted 早已亮）、音频随后开工（audioStarted 也亮），两个 await 都立即返回，断言恒真。
  变异实测证实那一版在原始串行下全绿，等于没守住这条 perf 修复。现改为两边都挂住，对
  cover-first / audio-first 两个方向都确定性转红。
- **已知窗口（本次未修，如实记录）**：封面阶梯若先抛异常（`_writeBytes` 磁盘满、`stillFallback`
  抛），`mine()` 直接抛出，末尾那句 `if (audioError != null)` 到不了，在途音频 Future 的异常
  只进闭包变量就消失（`catchError` 已挂上，不会成 unhandled，但也不再被报出）；同时那条
  ffmpeg 仍会跑到自己结束、继续往 tempDir 写。串行版下音频压根没启动，故这是并行引入的
  新窗口。判断：触发面只有磁盘满/截图抛这类边缘，且现有调用点的 tempDir 要么不删
  （`getTemporaryDirectory()` / `systemTemp`）、要么那条路径不走 ffmpeg（gal 是 provided-bytes），
  实际影响低，为它加取消/收尾逻辑不值当，故留记录不改代码。
- **[ ] 未做真机复测（如实留空）**：本条只有单测证明「两条确实重叠在跑」，**没有**在真机上
  跑一次真实制卡、拿前后耗时对比。收益量级仍是推算，且分场景差别很大：本地文件源下音频
  抽取（`-vn -c:a aac -ac 1 -b:a 64k` 裁几秒人声）本身就是几百毫秒级，而 GIF 最高档要数秒，
  并行省下的是那几百毫秒，不是「腰斩」；真正显著的是远端路径（YouTube 分片物化 +
  ffmpeg-over-URL，代码注释里记着 googlevideo 会 stall 到 120s 超时）。另有两点未验证的
  反向风险：① 移动端两个 ffmpeg-kit 会话同时抢 CPU，各自 120s 超时预算变紧，低端机上
  边缘 case 可能从「慢」变成「超时失败」；② YouTube 路径下 GIF 与音频**同时**对
  googlevideo 建连，有可能更容易触发 TODO-1314 的限速 stall。并发 ffmpeg 会话本身是既有
  设计（`ffmpeg_backend.dart` 的 BUG-905 注释明写「绝不碰并发会话」，超时只精确取消本
  session），这一点不构成新风险。
