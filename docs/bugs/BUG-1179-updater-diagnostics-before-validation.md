## BUG-1179 · Windows 更新器在校验安装包前就全机枚举进程，坏包也要等十几秒
- **报告**：2026-07-28（用户：）
- **真实性**：✅ 真 bug（**产品缺陷**，不只是测试问题）。根因 `hibiki/lib/src/utils/misc/platform_updater.dart:516-534`（原）：`WindowsInstaller.runAndExit()` 在函数最开头无条件收集诊断——`collectDiagnostics == null` 且 `Platform.isWindows` 时走 `collectWindowsInstallerDiagnostics()`，它真起 4~5 个外部进程：`Process.run('reg')` ×2（`:852`）、`powershell Get-CimInstance Win32_Process`（`:947`）、`tasklist /M libmpv-2.dll`（`:962`，要枚举全机进程的模块表）、再一次 powershell CIM 补 PID（`:999`）。而安装包的存在性检查（`:563`）与 MZ 头校验（`:567`）排在**这之后**。结果：代理返回 HTML 的损坏下载，用户要先干等十几秒全机进程枚举，才被告知「更新失败」；顺带 `hibiki/test/utils/misc/platform_updater_test.dart:426-456` 两个 `runAndExit` 用例（不注入 seam，直接调真实实现）在忙机器上会顶到 `test` 包默认 30s 超时而红。Linux CI 走 `:524-534` 的合成分支不碰进程，所以只在本机 Windows 表现为 flaky。
- **与「定时假设」模式的关系**：**不同族**，如实记录。这里没有 `sleep` / `Future.delayed` / 轮询去猜 I/O 完成——`Process.run` 的 `exitCode` 本来就是被正确 await 的真实完成信号。真实机制是「产品代码在必然失败的路径上先做不可控的重活，而把固定 30s 测试预算当成了它的上界」。
- **[x] ① 已修复** — 把存在性 + MZ 头校验整块上提到诊断收集**之前**（`platform_updater.dart` 中 `hasInjectedDiagnostics` 之后紧接的新 try 块）。坏包/缺包立刻抛 `UpdateInstallerException`，一个外部进程都不起；顺带 handoff marker 也不再为一个根本起不来的安装器写 pending 记录。失败仍走 `_markLaunchFailed`（该函数对 `handoffMarkerFile == null` 与写入异常都已容错），行为兼容。
- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/platform_updater_test.dart::never collects diagnostics for a download that fails validation`：注入计数版 `collectDiagnostics`，对「损坏下载」与「文件不存在」两条路径都断言 `diagnosticsCalls == 0`。这是最强可落地层——直接钉住「校验先于枚举」这个顺序契约。
- **验证**：修复后 `platform_updater_test.dart` 整文件跑 22 次全绿。负向验证：`git apply -R` 撤掉这次产品侧改动后，新守卫用例立刻红在 `Expected: <0> Actual: <1>`（诊断确实在校验前被调用），恢复后转绿。
- **备注**：与 BUG-1177 / BUG-1178 同批。诊断顺序修正同时消除了生产路径上「坏包也要等 tasklist」的真实卡顿，不只是让测试变快。
</content>
