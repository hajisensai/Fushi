## BUG-4951 · 在线漫画取图失败后闪退：扩展拦截器抛非 IOException，OkHttp 异步线程重抛把进程带崩
- **报告**：2026-11-21（用户：应用内反馈 phQmmG1rje，Xiaomi 24129PN74C / Android SDK 37 / 3.3.0，11-11～11-18 至少 8 次闪退）
- **真实性**：✅ 真 bug。根因 `fushi/android/app/src/main/kotlin/eu/kanade/tachiyomi/network/interceptor/UncaughtExceptionInterceptor.kt:12-15`：
  宿主 NetworkHelper 把它装在拦截器链最外层（`NetworkHelper.kt:25`），扩展 client 是 `network.client.newBuilder().addInterceptor(...)`，
  扩展自己的拦截器都在它里面；但它被写成了纯透传（注释「intentionally preserves the exception」），而 Mihon 原版的语义是把非
  IOException 收成 `IOException(e)`。扩展 `getImage` 走 `Call.await()`（`OkHttpExtensions.kt` 的 `enqueue` 异步路径），OkHttp 5 的
  `RealCall.AsyncCall.run` 碰到非 IOException 时先回调 `onFailure(IOException("canceled due to $t"))`、再在调度线程上 `throw t`——
  Android 上即未捕获异常，进程被杀，ExitInfo 只记 `reason=CRASH description: crash`、没有 Dart 栈。
  - 证据：11-14 15:55:53.591 下载服务记下 `fetchImage failed: IOException: canceled due to 未知網路錯誤 (stream was reset: CANCEL) ← PlainTextException`
    （正是 AsyncCall 的包装文案，扩展拦截器把 StreamResetException 改抛成 RuntimeException），7ms 后 15:55:53.598 进程 CRASH。
  - 反馈里两次 `MangaFushiPage.openStreamingChapter` 记下首页 `InterruptedIOException: timeout ← StreamResetException: CANCEL` 后 1–10ms 崩：
    失败分支 `pendingSession.close()` → `cancelImageRequests` 取消同章其它在途取图，HTTP/2 流被 CANCEL 复位，扩展拦截器同样把它改抛成
    非 IOException，同一条重抛路径带崩进程。分诊里「取消 / 回复路径」与「Java 堆 OOM」两个猜测都不是根因：`cancel(true)` 与通道回复本身不抛。
- **[x] ① 已修复** — `UncaughtExceptionInterceptor` 恢复 Mihon 语义：`catch (Exception)`，IOException 原样抛，其它包成 `IOException(e)`。
  原因链保留（通道错误信息 `describeCauseChain`、`CloudflareChallengeRequiredException` 判定都沿 cause 读；后者本身就是 IOException，不被包）。
- **[x] ② 已加自动化测试** — `fushi/android/app/src/test/kotlin/eu/kanade/tachiyomi/network/interceptor/UncaughtExceptionInterceptorTest.kt`：
  自定义 Dispatcher 的线程装未捕获异常记录器，扩展拦截器抛 RuntimeException、经 `Call.await()` 异步执行，断言调度线程零未捕获异常且
  调用方拿到带原因链的 IOException；IOException 原样透传。
- **备注**：桌面 sidecar（`third_party/m_extension_server/.../UncaughtExceptionInterceptor.kt`）同为透传，但 JVM 上非主线程未捕获异常只打日志、
  不杀进程，不在本修复范围。真机复测原始失败路径（首页取图超时 / 流复位）未做。
