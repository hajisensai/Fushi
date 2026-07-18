## BUG-898 · 移动端 ffmpeg 超时用 FFmpegKit.cancel() 误杀全部并发会话
- **报告**：2026-07-19（用户：）
- **真实性**：✅ 真 bug（沿真实代码路径定位）。根因见下。
- **[x] ① 已修复** — 见下方修复
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/ffmpeg_backend_precise_cancel_guard_test.dart`（源码扫描守卫）
- **备注**：FFmpegKit 是原生插件，Dart 侧无法直测取消语义，故用源码扫描守卫锁死「不再出现无参 `FFmpegKit.cancel()`」。真机复测原始失败路径待做。

### 现象
偶发丢内封字幕：并发跑字幕抽取 / 制卡时，某一路 ffmpeg 任务超时后，另一路无关任务被连带取消，表现为字幕列表偶尔缺内封轨。串行调用时不复现，只有会话重叠才触发。

### 根因
移动端后端 `KitFfmpegBackend`（`hibiki/lib/src/media/video/ffmpeg_backend.dart`）两处超时路径用**无参** `FFmpegKit.cancel()`，其语义是**取消所有会话**：

- `run()` 的 `on TimeoutException` → `FFmpegKit.cancel()`
- `runProbe()` 的 `on TimeoutException` → `FFmpegKit.cancel()`

类文档注释更以「调用方串行，cancel-all 安全」为由背书这一写法——脆弱假设。一旦有并发会话（同时字幕抽取 / 制卡），任一会话超时就会 cancel-all 掉无关会话。

更麻烦的是旧写法用同步的 `executeWithArguments(args).timeout(timeout)`：该 Future 直到会话**结束**才 resolve 出 session，超时触发时 `session` 变量根本没赋值，catch 里拿不到 sessionId，无法精确取消——这才是被迫用 cancel-all 的结构性原因。

### 修复
改用异步启动 + 精确取消（`ffmpeg_kit_flutter` API 已确认：`session.getSessionId()` 返回 `int?`；`FFmpegKit.cancel([int? sessionId])` 传 id 只取消该会话，传 null 才取消全部）：

- `run()`（`ffmpeg_backend.dart:627`）：`FFmpegKit.executeWithArgumentsAsync(args, (_) => done.complete())` 立即返回本次 `session`，用 `Completer<void>` + `.timeout(timeout)` 等完成回调；超时时 `final int? sessionId = session.getSessionId(); if (sessionId != null) FFmpegKit.cancel(sessionId);`（`:641`）——只取消本次会话。
- `runProbe()`（`:664`）：同款 `FFprobeKit.executeWithArgumentsAsync` + 精确 `FFmpegKit.cancel(sessionId)`（`:678`）。
- 类文档（`:617`）去掉「串行所以 cancel-all 安全」，改成「只精确取消本次 session，不碰并发会话」。
- sessionId 判空后才取消，杜绝退回 cancel-all（`getSessionId()` 为 null 时不误伤全局）。

正常成功路径行为不变（回调 resolve → 读 `getReturnCode` / `getOutput`），仅超时取消范围从「全部」收窄到「本次」。
