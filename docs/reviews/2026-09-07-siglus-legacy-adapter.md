# 剩余 Siglus 原始路径适配

## Scope

用户在四部验收及 PR #1293 后要求继续剩余游戏，并明确使用 Fushi 已有转区能力。独立 codex/siglus-legacy-adapter 分支基线 4e03a79626；目标为 Rewrite trial 2.00、Angel Beats! trial 1.10、月の彼方で逢いましょう trial，仅 Windows。既有四部验收分支未修改。

## Proved

2026-09-07 23:54:53 原始 Rewrite Start.exe 经 Fushi --japanese-locale 启动为进程 35728；23:54:54 系统错误记录 C0000005、LE 偏移 001b52d0。实际首根因是 BUG-2232 初始化模块链表 sentinel 误作模块，早于 Fushi Hook 注入。已整合源码修复 779ebdcf0e 与真实 x86 ABI 回归。

使用固定官方 LE 源码 ae7160dc5deb97947396abcd784f9b98b6ee38b3、哈希固定 WDK/Libs、微软正式 v140 19.00.24247.2 及 LLVM 22.1.6 完成本地构建。v140 将旧 /GL 库生成为普通 IOBJ，LLVM 最终链接保留 kernel32 真正延迟导入；首阶段 DLL 不使用、不分发。未执行上游修改过的 _Compilers。修补 sentinel 后，自有 CP932 探针和普通 CreateProcessW 子孙进程均正常退出，ACP/OEM 932、User/System LCID 0411。

随后原始路径分别复现系统版本资源语言（BUG-2246）及本地化时区名称（BUG-2247）两道检查。中间运行库 B3D3824A26BE4E6D2D3A3F4367A72B26F060AF41360BD30DDA1933DF2CFCFCF1、自有版本探针 26364 返回 Translation 0411/04b0。修正 Fushi 时区显示字段后，2026-09-08 00:40:38 helper 65888 → 原始 Start.exe 74636 → 官方 StartMenu 50052 → SiglusEngine 70100，00:41:06 起出现 Key 标志及标题菜单。helper SHA-256 为 2CC72C7ADD22709ECE87D1FD5DDB0AA253155253841B1F4EB9B47BFD17F6374B。

Rewrite 原始 Start.exe SHA-256 24B396B22A177F6573C787161099D2B378F5F02FDEAFE2BBED0B5936C798343A；实际 SiglusEngine.exe 1.0.4.0 x86，SHA-256 6E01827E8D9427D0CF5FB4933224865E8CFF22BC78AE8264C15CDD5584F77253。游戏未复制至其他启动目录，未改写游戏、系统区域或安全设置。

最终候选 v5 SHA-256 `8DF7A41BE6AE8C6920CB06C05C60DAEFDA9D330A0212A1CC036DE9B877CA9079` 已通过生产 PE 契约，自有探针 26152 退出 0，ACP/OEM 932、LCID 0411、kernel32 Translation 0411/04b0。手工 SelfShadow 映射与正常 DllMain 映射有明确所有权；VERSION 安装前固定目标模块，失败清理保留仍可达 trampoline。

2026-09-08 01:08:31，私有测试 helper 25012 → 原始 Start.exe 71692 → 官方 StartMenu 64428 → SiglusEngine 46800（01:09:09）。helper 自动发现真实子进程，Fushi Hook LoadLibraryW wait=0、base=6B6B0000；helper ready、IPC v24 可读。helper SHA-256 `112DEDBC0DBF3738DCBC1ECC24C2577F5A5BF1DF499589B0A6C861E15F47F533`，Hook DLL `ECAB5F5BC0AB673314B2127464E45AB86EE4BAC8E229AB804FEEBE576CB7CE71`。组件位于本机 `.codex-test/siglus-engine-adapter/locale-lineage-v5-helper`，没有覆盖已验收 bundle。

载入原游戏存档后，原生 resolver 未匹配，既有 120 秒有界探测正常转为 LunaAllowed，并非永久 pending。Luna 在换句前只见标题；换句后 lane 4181100848359650377、seq 186、UTF-16 36 bytes 与当下旁白一致。仅记录元数据，不保存游戏正文。

本轮 native 完整构建与 CTest x86 87/87、x64 86/86 通过；版本 Hook 断言启用后定向重建双架构再次通过（各 15 组内部检查）。manifest/profile 生成检查、manifest 22、结构 48、workflow 6、PE 21、断言存活守卫 2 均通过。显式生产 workflow replay 退出 0，覆盖资源优先、PCM、显式 loopback、线程过滤、去重与会话清理。

统一私有测试 bundle 后，Fushi 63356 于 01:40:27 经正常 UI 使用 `--japanese-locale --launch <original Start.exe>` 启动 helper 48940；游戏 64432（父进程 13040）于 01:40:28 出现。实际运行组件落于 Fushi 自有 `voice_hook_runtime/9a932157bb92de5c/x86`，helper/Hook/LE 摘要与上述候选一致。01:44:09 推进正文，生产 UI 选中 SiglusEngine VA 482130 的干净线程：lane 3668595790166304498、seq 77、48 UTF-16 bytes，画面与工作台一致。`selected_text_thread_id` 回读匹配，`text_ready` 通过。

构建脚本审查修复 PowerShell location 与 .NET cwd 不同导致相对输出检查错位；统一 FileSystem 路径解析后检查及写入。直接执行生产 AST 函数的 8 条测试通过，含相对/绝对、现存拒绝、括号字面量及非文件系统拒绝，已登记守卫入口。

## Not proved

原始启动、自动跟随、注入和选定正文线程已经通过。此前原验收 bundle 附着私有 DLL 正确返回 residentHookMismatch；统一组件后从原始入口重启已消除该测试配置问题，没有绕过身份检查。原生内嵌几何未匹配，resource/pcm_ready、paired、e2e_verified 尚未通过；clip/PCM 为零，已有 loopback 不能当作原音捕获。Angel Beats! 与月彼本轮尚未运行。未升级 engine-support.yaml，未更新既有 PR 或正式随包运行库。

源码准备及正式工具构建脚本已维护，最终候选重建与 PE 契约自动校验均通过。上游仍含预编译 MyLib；当前源码补丁和依赖说明不宣称其完整对应源码，也不宣称已满足修改 DLL 的正式分发条件。

## Next gate

验证旧版 glyph 的栈参数调用约定、当前对白调用来源及坐标字段，再接入内嵌查词。后续逐句原音与真卡仍须逐门实测。
