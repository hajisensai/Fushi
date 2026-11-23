## BUG-5350 · Android 用 Mihon 在线源时闪退：扩展抛 Error（LinkageError 等）漏过宿主拦截器，经 OkHttp 异步线程重抛带崩进程
- **报告**：2026-11-24（用户：应用内反馈 1bEcu3KqEx、C0jP7bW1ev，同一台 Xiaomi 2410FPCC5G / Android SDK 36 / 3.3.0，11-22～11-23 共 6 次 `reason=CRASH description: crash`）
- **真实性**：✅ 真 bug（3.3.0 没有 Java 栈，确切的崩溃线程无法从日志证实；以下是沿代码确认仍然存在的崩溃路径）。根因在 `fushi/android/app/src/main/kotlin/eu/kanade/tachiyomi/network/interceptor/UncaughtExceptionInterceptor.kt`：
  BUG-4951 把它恢复成 Mihon 原版语义 `catch (Exception)` → `IOException(e)`，但扩展是独立编译的 APK，按宿主 kotlin-stdlib / okhttp / extension-lib 的 ABI 链接，
  宿主少一个类或签名对不上抛的是 `NoClassDefFoundError` / `NoSuchMethodError`（`LinkageError`，**不是 Exception**），扩展递归过深是 `StackOverflowError`。
  这些 Error 从扩展拦截器（或它调的代码）抛出时漏过 `catch (Exception)`；扩展走 `Call.await()`（`enqueue`）时 OkHttp 5 的 `RealCall.AsyncCall.run`
  对任何 `Throwable` 都先回调 onFailure、再在 Dispatcher 线程 `throw t`，Android 上即未捕获异常、进程被杀。
  - 证据：两条反馈的日志里同一时段 `getSearchManga` 反复报 `NoClassDefFoundError: Failed resolution of: Leu/kanade/tachiyomi/AppInfo;`（BUG-4695 的缺类），
    `getDetailsManga` 连报 `NoSuchMethodError: No static method toJavaInstant(...)`（BUG-5273 的 desugar ABI 错位）——这台设备上的扩展确实在抛 LinkageError；
    走同步通道路径时被 `MihonChannelHandler` 的 `catch (Throwable)` 收成错误回报，走拦截器 + 异步路径时就是上面的崩溃路径。崩溃进程的 CPU 统计里有
    `OkHttp Dispatch×2` 线程（异步调用在跑）。
  - 已修的两个具体诱因（AppInfo 缺类 BUG-4695 / 27015b4584，desugar ABI BUG-5273）与 RuntimeException 那一类（BUG-4951 / 85de09c127）都不在 v3.3.0 里；
    本条补的是这一类错误本身：之后任何新的 ABI 缺口不再能把进程带崩。
- **[x] ① 已修复** — `UncaughtExceptionInterceptor` 在 IOException 原样抛之外，把 `Exception`、`LinkageError`、`StackOverflowError` 等一切非 VM 致命的 Throwable 收成
  `IOException(e)`（原因链保留，通道错误信息照旧沿 cause 读出 `NoClassDefFoundError ...`）；只有 `VirtualMachineError`（OOM / InternalError，StackOverflowError 除外）原样抛。
- **[x] ② 已加自动化测试** — `fushi/android/app/src/test/kotlin/eu/kanade/tachiyomi/network/interceptor/UncaughtExceptionInterceptorTest.kt`：
  扩展拦截器分别抛 NoClassDefFoundError / NoSuchMethodError / ExceptionInInitializerError / StackOverflowError，经 `Call.await()` 异步执行，
  断言 Dispatcher 线程零未捕获异常、调用方拿到带原错误的 IOException；OOM 原样抛出、不被包。
- **备注**：桌面 sidecar 的同名拦截器同为透传，但 JVM 上非主线程未捕获异常只打日志、不杀进程，不在本修复范围。同为 3.3.0 `reason=CRASH` 无栈的
  wpmekgCOnN（Xiaomi IN）、9uOX_Y_mRk（华为，本地漫画阅读器内崩）证据不足以并入。新版本已有 JavaCrashCapture（f9c96c5b07）落盘 Java 栈，若仍崩可据栈再查。真机复测未做（无法复现该用户的扩展组合）。
