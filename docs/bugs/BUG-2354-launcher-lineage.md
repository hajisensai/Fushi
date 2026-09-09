## BUG-2354 · 启动器退出后丢失已确认的游戏进程谱系
- **报告**：2026-09-08（继续 Siglus 原版游戏适配，使用 Fushi 转区启动）
- **真实性**：✅ 真 bug。原始 Rewrite 体验版入口 `Start.exe` 经 Fushi `--japanese-locale` 启动，实测进程链为 74636 → StartMenu 50052 → SiglusEngine 70100。两层启动器先后退出，游戏已到标题，helper 却未发现游戏。修复前 `native/galgame_hook/injector/injector_main.cpp:2332` 的 `FindGameChildProcess` 每次只用当前 Toolhelp 快照重新计算 `DescendantDepth`，导致已退出中间节点的因果关系被丢弃。
- **[x] ① 根因修复** — `ChildProcessLineage` 持久化本次启动会话中已验证的进程身份与生命周期；Windows 层保留查询句柄，通过 creation time 与父进程存活/退出时间验证每条边。PID 复用、未知父节点、循环、超深度和超容量均失败关闭。模块及引擎目录检查只作用于已确认且仍存活的后代。发现结果携带 creation time，在取得注入句柄后再次验证身份，避免发现与打开之间换成复用 PID 的进程。提交见本文件同一提交。
- **[x] ② 自动化测试** — `native/galgame_hook/tests/child_process_policy_test.cpp` 直接运行生产谱系 helper，覆盖两层父进程退出、多代、父 PID 复用、根 PID 复用、出生先后关系、未知后代、循环、16 层与 256 项边界；保留原有引擎签名/FFmpeg/Python 选择测试。
- **验证**：2026-09-08，Windows MSVC x86/x64 Release 全部构建退出 0，两架构 CTest 各 84/84；manifest 22/22、结构 48/48、workflow（含生产 replay）6/6，manifest/profile 生成检查通过。`bug.dart check` 本地不变式通过，跨工作区原有 84 组撞号警告不涉及 BUG-2354。未运行非 Windows 构建。
- **备注**：不按全机镜像名或目录认领游戏，不改变等待时长，不改变转区运行库。未观察到的中间进程无法凭空补齐；缺少身份/时间证据时仍拒绝认领。整合回测：2026-09-08 01:08:31 helper 25012 → 原始 Start 71692 → 官方 StartMenu 64428 → SiglusEngine 46800（01:09:09），自动跟随并注入成功、IPC 可读。后续线程选择、内嵌查词、音频及制卡分别验收，不升级引擎支持声明。
