## BUG-4791 · 应用外查词取跨应用语音快照时，跨进程 RPC 与约 2.9MB 写盘压在查词窗平台主线程上
- **报告**：2026-11-17（#3621 合入后的只读核实遗留项）
- **真实性**：✅ 真 bug。`fushi/android/app/src/main/java/app/fushi/reader/CrossAppAudioChannel.java:69-93`（修前）的 MethodCallHandler 跑在平台主线程，`status` / `stop` / `snapshot` 直接调 `callProvider`（同文件 :171-180，`ContentResolver.call` 同步 Binder 往返）；`snapshot` 在 Provider 端 `CrossAppAudioProvider.java:117-145` 持 `SNAPSHOT_LOCK` 拷 PCM 环并同步写文件（30 s 回看约 2.9MB）。`:popup` 进程的查词窗主线程要等跨进程往返 + 整段写盘，主进程被冷启动或存储忙时卡顿，极端情况 ANR（推测，未实测）。
- **[x] ① 已修复** — 新增纯判定 `CrossAppAudioPolicy.callsProviderOffMain`（`CrossAppAudioPolicy.java`），通道入口据此把 `status` / `stop` / `snapshot` 投到单线程执行器 `PROVIDER_IO`（`CrossAppAudioChannel.java:67-78`，保序；与编码线程分开，快照不排在编码后面），在后台 `runProviderCall`（`CrossAppAudioChannel.java:160-188`）里做 RPC，再 `MAIN.post` 回结果；判定与分支漏配直接抛 `IllegalStateException`，不静默回 null。Provider 端写盘逻辑不变。
- **[x] ② 已加自动化测试** — `fushi/android/app/src/test/kotlin/app/fushi/reader/CrossAppAudioPolicyTest.kt` 的 `providerRpcMethodsRunOffMain` / `localMethodsStayOnMain`（JVM 单测，CI 由 `main.yml` 新加的 `:app:testDebugUnitTest` 步骤执行）。线程投递本身需要 Robolectric / 设备才能测，没有可落地的更强层。
- **备注**：未做真机验证；本机只用 javac 验了语法（Gradle 不在本机跑）。
