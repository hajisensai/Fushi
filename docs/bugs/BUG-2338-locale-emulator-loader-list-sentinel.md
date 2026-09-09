## BUG-2338 · Locale Emulator在早期模块初始化链表头上解引用导致Rewrite启动崩溃
- **报告**：2026-09-07，扩展 Siglus 官方试用版验证时，在原始 Rewrite 启动路径复现。
- **真实性**：✅ 真 bug。上游固定提交 `ae7160dc5deb97947396abcd784f9b98b6ee38b3` 的 `LocaleEmulator/ml.h:22173`，`GetKernel32Ldr()` 遍历循环未排除 `InInitializationOrderModuleList` 链表头，将其当作 `LDR_MODULE` 解引用。真实调用为 `LocaleEmulator/LocaleEmulator.cpp:628` 的早期初始化；此时 kernel32 可以尚未初始化。仓库 `native/galgame_hook/tools/build_distribution.ps1:155` 仍分发含该循环的 2.5.0.1 DLL。
- **[x] ① 根因修复并完成本地回测** — 最小 LGPL 源码补丁和共享 header 已提交 `779ebdcf0e`；正式 v140/LLVM 工具链重建运行库，2026-09-08 从原始 Start.exe 进入游戏并完成自动注入。正式分发尚未接入，已安装旧运行库仍有此问题。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/locale_emulator_module_list_test.cpp`，通过同目录第三方工具 `third_party/locale_emulator/test_module_list.ps1` 使用正式 MSVC x86 `/W4 /WX /O2` 执行，4 组通过。测试调用补丁所用的真实 helper，覆盖空链表、ntdll-only、存在 kernel32、缺席与短/空名称；x86 偏移由静态断言锁定。源码准备脚本成功应用精确补丁，并拒绝二次应用修改已存在的源码。
- **备注**：构建脚本、工具哈希及 PE 验证位于 `native/galgame_hook/third_party/locale_emulator/`。后续版本语言、时区名称和启动器谱系分别记录 BUG-2246、BUG-2247、BUG-2248；没有修改游戏或全局系统区域。

### Proved

原路径 `D:/galgame-tests/siglus/rewrite-trial/RewriteTE_Ver200/Start.exe` 普通启动可进入 StartMenu 并启动引擎，但非日语环境拒绝继续。使用现有 x86 injector 的 `--japanese-locale` 路径，launcher PID 19576 已由 LE 创建并恢复主线程，在 2026-09-07 14:59:44（本地时间）以 `C0000005` 退出；直接 LE 启动引擎 PID 5348 在 15:00:47 同样退出。两次都发生在 Fushi Hook DLL 注入前，之后的 attach 错误/窗口等待超时是结果，不能把它们当作首根因。

| 故障时实际文件 | SHA-256 |
|---|---|
| Rewrite `Start.exe`，1.0.0.4，x86 | `24B396B22A177F6573C787161099D2B378F5F02FDEAFE2BBED0B5936C798343A` |
| `StartData/GameData/SiglusEngine.exe`，1.0.4.0，x86 | `6E01827E8D9427D0CF5FB4933224865E8CFF22BC78AE8264C15CDD5584F77253` |
| 随包 x86 `LocaleEmulator.dll` | `C79C175FDAD174AA46A72197D148316299A56F950AAAB1B84930D09EE1084A88` |
| 随包 x86 `LoaderDll.dll` | `82FAE0F44F4CA0C9C37907DF74CEF2415EEB5FAE1CF8D4F36F34FFCAF7E3CC0C` |
| 本地 `Start.exe.19576.dmp` | `EB4DD96D092281BED0388F2631E6C94D77FB19550D504C4DAAD8D91CE589FF07` |
| 本地 `SiglusEngine.exe.5348.dmp` | `EBC7D39138F899638EC1D1D4562FCB8C82F0A352A4B99C8D1181479E4D738A8F` |

两个本地 minidump 都给出故障指令地址 `0x001B52D0`、读取地址 `0x1000`。上下文显示遍历得到的伪模块 `EAX=0x77A872EC`，其 `+0x10` 链接回到真实首模块的初始化链接，其 `+0x30` 被错读为 `BaseDllName.Buffer=0x1000`。故障前 37 字节与上述实际 `LocaleEmulator.dll` 的文件偏移 `0x44B0` / RVA `0x52B0` 唯一匹配，定位到模块遍历函数。LE 尚在 loader 初始化中，模块清单未登记它并不代表它尚未执行。

只保留诊断元数据；dump、游戏 exe、脚本、图像、台词和其它可还原载荷均未入库。运行日志仍在本地 `.codex-test/siglus-engine-adapter/rewrite-locale-launch.log` 与 `rewrite-direct-locale-launch.log`。

### Not proved

现代 MSVC 无法直接消费旧 /GL 依赖；现已使用哈希固定的微软正式 v140 和 LLVM 完成本地重建，未执行上游 modified VS2015 编译器。最终候选 SHA-256 `8DF7A41BE6AE8C6920CB06C05C60DAEFDA9D330A0212A1CC036DE9B877CA9079` 在原始启动链 71692 → 64428 → 46800 进入正文。MyLib 仍为上游预编译依赖，完整对应源码及正式分发条件尚未解决；本地启动回测不证明内嵌查词、语音或制卡通过。

### Next gate

启动崩溃边界已通过。游戏适配下一门见 `docs/reviews/2026-09-07-siglus-legacy-adapter.md`；正式分发仍须完成对应源码与依赖条件，不能把本地实验 DLL 当作已随包发布。
