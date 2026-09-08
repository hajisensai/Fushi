## BUG-2261 · Siglus启动器子进程绕过延迟附着并抢先LE初始化
- **报告**：2026-09-08（继续原始月彼路径适配时实测发现）
- **真实性**：✅ 真 bug。`native/galgame_hook/injector/injector_main.cpp:2916` 只按外层 Start.exe 计算 delayed attach；跟随后没有为真实 Siglus 子进程重新应用窗口就绪门，直接进入 RunInjection/远程 LoadLibrary。原始 CP932 会话 PID 22472 的 LE 报 kernel32 已在其初始化之前加载，随后日语系统检查失败。模块表中已有本次 Fushi Hook；具体指令级交错没有采集，不能由此归因 LE 自身传播错误。
- **[x] ① 代码修复** — `4e168b8a01`：最终子进程身份确认后接入同一 Siglus 延迟附着条件，普通 PID 附着也通过此门，避免 `injectionFailed` 触发消费端自动恢复后绕过等待。附着句柄复用带 `SYNCHRONIZE` 的 `kInjectionProcessRights`；实机结果仍待原始路径复验。
- **[x] ② 自动化测试** — `25811f7b1e`、`ffe027adb5`：`native/galgame_hook/tests/siglus_child_readiness_test.cpp` 直接执行生产等待块，并检查真实调用位置；双架构各 42 checks 通过，覆盖失败启动后普通附着重试仍不注入、就绪后顺序、非 Siglus 不受影响、句柄清理及 SYNCHRONIZE 权限。删除附着门的可编译负对照退出 91。根工作区 Release 全构建退出 0，完整 CTest x86 103/103、x64 99/99 通过。
- **备注**：跟随与附着门只对已确认的 Siglus 目标启用；非 Siglus 早注入、直启的现有窗口门保持原样。窗口未就绪时不注入、不恢复启动器主线程、不结束已运行的游戏。复用既有窗口条件，没有添加固定延迟或放宽 LE 初始化检查。原条件只检查同 PID 可见且有标题的窗口，并排除 Enigma 标题；游戏自己的错误对话框仍可能满足条件，因此窗口就绪不能单独证明 LE 初始化或游戏可用。Steam 启动入口不在本次 Start/LE 修复范围。
