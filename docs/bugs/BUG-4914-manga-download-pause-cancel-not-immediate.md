## BUG-4914 · 漫画下载的暂停 / 取消传不到在途请求，失败不分型一律退避
- **报告**：2026-11-20（来源：路线图 #3722 manga-12，代码审读 + 复核成立）
- **真实性**：✅ 真 bug。
  - 根因 1：`fushi/lib/src/media/manga/download/manga_download_service.dart` 的中止令牌 `_CancelToken` 只有三个布尔标志、没有可等待的信号。章节任务按页轮询标志，`_ActiveJob.abort` 只给 mokuro 卷挂了钩子（原 `:205-207`），在飞的 `resolveChapterPages` / `fetchChapterPage` / sidecar 没法打断；`pause()` 却 `await active.done`（原 `:594`），于是暂停要等在飞的取页自己走完（Android 运行时侧 OkHttp callTimeout 最长 2 分钟），取消同理要等到 worker 收尾才删半成品；运行时侧的取图线程也一直被旧请求占着（适配器有 `OnlineMangaPageCancellable.cancelChapterPages`，下载服务从没调过）。
  - 根因 2：同文件 `_run` 的退避 `await _wait(...)`（原 `:808-813`）不看令牌，暂停 / 取消要等最长 20 秒。
  - 根因 3：同文件 `_run` 的 `on Object catch`（原 `:784-800`）对所有失败一律退避重试三次：书已出库 / 章已下架这类前置条件（原 `:836-853` 抛的是 `StateError`）、要用户亲自过 Cloudflare 验证、源已停用，都要白等 2s + 8s 才落 `failed`，一串这样的章节每章白等一轮。
- **[x] ① 已修复** — 令牌加一次性完成信号 `tripped`，标志只经 `cancel()` / `pause()` / `stop()` 置位；页表解析、取页、sidecar 都经 `_untilTripped` 与它赛跑，中止后晚到的字节丢弃、不写盘（已落地的页照旧留给续跑，语义不变）；章节任务的 `abort` 钩子把在飞的页交给 `OnlineMangaPageCancellable.cancelChapterPages`；退避与令牌信号 `Future.any` 赛跑（`wait` 注入口保留）。失败分型：前置条件改抛专用类型 `MangaDownloadPreconditionFailed`，`isPermanentMangaDownloadFailure` 认它、按类型认 Cloudflare 挑战（`mihonCloudflareChallenge`，从 widget 文件挪进适配器契约文件，原处转出口）、认 `OnlineMangaUnavailable` 的 `sourceDisabled` / `platformUnsupported`，这些直接 `failed` 不退避；其余（网络 / 运行时一般失败，分不出瞬时与否）照旧退避重试。
- **[x] ② 已增加自动化测试** — `fushi/test/media/manga/manga_download_service_test.dart`「中止立即生效与失败分型（BUG-4914）」组 7 例：取页卡住时暂停 5 秒内返回、在飞请求被取消、晚到字节不落盘、恢复后补齐；取页卡住时取消立即收尾；退避中暂停立即生效；Cloudflare（包在 cause 链里）与源已停用直接 `failed` 且零退避；章已下架直接 `failed`；一般运行时失败仍照退避表重试。
- **备注**：用户可见变化——暂停 / 取消按下即生效；要过 Cloudflare 验证、源已停用、章已下架的下载任务立刻显示失败（以前要等十秒级退避后才失败）。真机「边整章下载边在线读另一章、暂停立即生效」本轮未做设备验证。
