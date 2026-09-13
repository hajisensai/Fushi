## BUG-2486 · Windows集成测试按build目录误杀用户已运行的应用
- **报告**：2026-09-10（来源卡回跳的 Windows 集成验证期间，脚本输出 `reaped stale test-runner pid=9612`，将用户正在使用的 worktree Release Fushi 强制关闭）。
- **真实性**：✅ 真 bug。修复前 `fushi/tool/run_windows_itest.ps1:154-185` 仅凭 `build/windows/x64/runner` 路径前缀赋予 `isTestRunner`，包含同一 worktree 下的 Release 用户实例。旧 `379-400` 将运行前所有这种实例视作遗留测试进程并调用强制终止；同一错误标记还用于记录和窗口截图。build 目录不能证明进程归属，既有精确 Debug 产物也可能是用户手动运行的应用。
- **[x] ① 已修复** — 完全移除运行前自动终止流程。`fushi/tool/run_windows_itest.ps1:363-365,416-425` 对既有精确 Debug 产物冲突记录原因并返回失败，不启动构建、不终止进程；Release 与其他安装实例只记只读证据。`149-205` 将可处理测试进程收紧为预期 Debug exe 的大小写无关精确匹配、PID 不在启动前快照、父进程链属于本轮真实 launcher；父进程缺失或循环时拒绝归属。`521-528` 的截图和记录共用该判定，离屏环境变量只传给新启动子进程。与来源链接兼容修复同批提交。
- **[x] ② 已加自动化测试** — 更新 `fushi/test/tools/windows_itest_isolation_guard_test.dart` 的旧错误契约，不再强制脚本存在终止调用；要求无任何进程终止命令，并验证精确路径、启动前 PID 和父链归属。隔离 PowerShell fixture 通过 AST 只加载生产函数，模拟用户 Release、既有 Debug、其他新 Debug、本轮 launcher 直接/间接子孙、近似路径、无路径和缺失/循环父进程；只有本轮 Debug PID 12/16 可记录，截图选择对应窗口。模拟测试不枚举或操作真实进程。定向套件 **7/7 通过，退出码 0**；其中 fixture 同时完成 PowerShell 语法解析。`git diff --check` 通过。
- **备注**：本次验证没有运行完整 Windows itest 脚本，没有启停、移动或抓取用户应用窗口，没有操作当前测试进程。该修复防止测试工具再次误认既有应用，不恢复已关闭应用中尚未保存的状态。
