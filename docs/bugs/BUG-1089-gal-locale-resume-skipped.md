## BUG-1089 · galgame 启动后留下永久挂起的僵尸进程：窗口永不出现，injector 却报 OK hooked
- **报告**：2026-07-25（用户：「点启动游戏没反应，游戏没打开」。同一轮报告里「没有报错提醒」记 [BUG-1087](BUG-1087-gal-launch-silent-no-feedback.md)，「事件乱码」记 [BUG-1088](BUG-1088-gal-injector-diagnostics-mojibake.md)）
- **样本**：`屋上の百合霊さんフルコーラス.exe`，x86 Unity，SHA-256 `F460F9DEB9B4A8C1132CDCFC99D107C66360AEAEB42F9ADED7EF9F8A80B35760`，614400 字节。走日语 locale（Locale Emulator）路径。用户 helper 组件均为 2026-07-25 21:48 安装，injector SHA-256 前缀 `928266015AE21744`。
- **真实性**：✅ 现象真实（**两次独立实证**），但**产生路径未复现**，根因未完全定死。
  - **已实证的现象**：两个游戏进程（pid 138556 @07-25 13:37、pid 53332 @07-26 09:58）长时间存活，`MainWindowHandle=0`、仅 4 线程、主线程 `WaitReason=Suspended`。对主线程外部调用一次 `ResumeThread` 后线程转 `UserRequest`、窗口立即出现 → 进程确实卡在挂起态，游戏代码从未运行。
  - 🔴 **未能复现产生路径**：三次真机运行——① 用户机器上的原版 injector、② 本轮修复版、③ 与 Hibiki 完全一致的参数（`--launch … --hold --wait-ms 30000 --japanese-locale --luna-hook-profile <store>`）——**游戏每次都正常启动**，窗口出现、22 线程、`responding=True`、`[luna] connected`。也就是说原版 injector 在这条路径上**会**正确 resume。
  - **前一轮结论已被证伪，此处修正**：曾据「外部对僵尸主线程调一次 `ResumeThread` 返回 1」推断「挂起计数从未被减过、LE 未回填 `hThread`、resume 被静默跳过」。实测日志为 `[resume] post-injection primary thread resumed (initial suspend count=1, resume calls=1)` → **LE 确实回填了有效句柄，计数就是 1，单次 resume 足够**。那个返回 1 是 injector 已经减过一次之后的残值。同样被排除的假说：guarded-luna 挂起窗口——用户的 `luna_hook_profiles.tsv` 只有注释头+表头、**零条目**，`blocked_hook_codes` 为空，该路径不进入。
  - **定位到的两个结构性缺陷**（确定成立，与能否复现无关，见下）：
    1. **挂起窗口与宿主超时同源、同时到期**：Hibiki 的 `buildEngineHookInjectorArguments` 把 `--wait-ms` 与自身 `_readyTimeout` 同源下发（都是 30000ms），而 injector 又拿同一个值作为「让游戏停在挂起态等 startup audio hook 就绪」的上限。两侧同时到期：Dart 侧 `EngineHookGalAudioSource.stop()` 里 `_injector?.kill()` 一超时就杀 injector，而 injector 可能恰好还停在那个等待里、尚未执行 `ResumeThread` → `CREATE_SUSPENDED` 的游戏被永久留在挂起态。**被外部杀死时 BUG-1066 那套 `DecideLaunchedProcessDisposition` 根本没有代码会执行**，指望它兜底是错的。这是本现象目前最强的候选路径。
    2. **恢复动作过于脆弱且会说谎**：`ResumeThread` 只把挂起计数 -1，旧实现只调一次并把「返回值非 -1」当成功；整个 resume 块由 `resume_thread != nullptr` 把门，而这个 `nullptr` 同时承载「本策略不需要 resume」（Siglus/follow-child）与「本该 resume 但句柄没拿到」两种互斥含义，后者被静默当成前者跳过，而 `OK hooked` 的 printf 就在该块**外面** → injector 报成功、游戏永久挂起。
- **[x] ① 已修复（native，独立仓 PR hajisensai/hibiki-hook#7，分支 `fix/locale-resume-not-applied`，commit `e2ebde4`）** — 关闭上述两个缺陷：
  - 新增纯函数 `SuspendedStartupWaitBudgetMs`：挂起窗口只取总预算 1/4、上限 5s，绝不与宿主超时同时到期（启动期 hook 由注入线程装、与游戏主线程是否运行无关，正常几百毫秒就绪）。
  - 新增 `ResumeLaunchedGame`：循环 resume 到挂起计数归零（不假设计数恒为 1）、记录**首次**计数与调用次数、句柄无效时退到进程级 `NtResumeProcess`、两者都失败才 `kResumeFailed`，**绝不静默跳过**；三个 resume 点（pre-discovery / post-injection / degraded）统一走它。
  - 新增纯函数 `LaunchedProcessIsSuspended` / `MustResumeAfterInjection`：用显式的 `created_suspended` 表达「是否必须恢复」，句柄降级为首选手段，消掉 `nullptr` 的二义性。顺带修正 `created_suspended` 口径——旧算法漏了 locale 路径（LoaderDll 无条件叠加 `CREATE_SUSPENDED`，所以只要走 locale 就一定是挂起态，即使 `creation_flags` 为 0）。
- **[x] ② 已加自动化测试** — `tests/launch_failure_policy_test.cpp` 新增断言：locale 挂起事实（`LaunchedProcessIsSuspended(false, true)` 必须为真——旧算法漏的那一半）、恢复责任的三种组合、预算不变式（`SuspendedStartupWaitBudgetMs(30000)==5000`，且 0–60000 全域扫描 `budget <= total`）、以及 locale 挂起 + 注入失败 + 未恢复必须判 `kResumeDegraded`。x86 `ctest` **21/21 通过**；x64 两个策略测试构建并运行 **exit=0**。
- **备注 / 未验证项（如实记录）**：
  - **僵尸产生路径未复现**，故根因未定死；上面缺陷 1 是最强候选但缺直接证据。若现象复发，关键证据是新日志里的 `[resume] … (initial suspend count=N, resume calls=M)` 与 `startup audio hook readiness timed out after X ms (total wait budget Y ms)`。
  - **x64 完整 `cmake --build` / `ctest` 被环境阻断**：`unity_audio_extract` 要求 `net8.0`，本机只有 .NET SDK 6.0.428（`NETSDK1045`）。已确认该阻断在干净的 `origin/main` 上同样存在，与本改动无关。装上 .NET 8 SDK 即可补齐这道门。
  - `tools/generate_luna_profiles.py --check` **exit=1**，同样在干净 `origin/main` 上复现 → 预先存在，与本改动无关。
  - **未从 Hibiki app UI 走完整 E2E**（台词 → 对应语音 → 画面 → 真卡写入）；真机验证是命令行直调 injector。按 galgame SOP 状态为 `implemented_unverified`。
  - 修复要用户拿到必须**重新构建并发布 helper release**（合并 main 后 CI 自动重建）。真机验证期间曾临时换入自建 injector，**结束时已恢复用户原文件并校验 SHA 一致（`928266015AE21744`）**，备份已删除，无残留游戏进程。
  - BUG-1087 的修复已让这种情况至少**明确提示**「游戏进程已启动，但窗口一直没有出现」，不再静默。
