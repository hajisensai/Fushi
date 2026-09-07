# Locale Emulator 模块链表源码补丁（未接入分发）

本目录保存 BUG-2232 的最小源码修复和 Windows x86 回归测试。**当前没有构建成功的新运行库；随包 LocaleEmulator.dll 仍是上游 2.5.0.1，游戏启动尚未修复。**

上游为 [Locale-Emulator-Core](https://github.com/xupefei/Locale-Emulator-Core)，固定提交
`ae7160dc5deb97947396abcd784f9b98b6ee38b3`。修改日期：2026-09-07，Hibiki。
上游 `LoaderDll`、`LocaleEmulator` 按 LGPL-3.0 发布；本目录新增源码/脚本/测试按 LGPL-3.0-or-later 发布，随附上游原始 GPL/LGPL 文本。

## 根因与修改

上游 `LocaleEmulator/ml.h:22173` 的 `GetKernel32Ldr()` 以首个真实模块为终止条件，先前进再读取模块名称。在 kernel32 尚未初始化时，循环会把 `InInitializationOrderModuleList` 的独立链表头转换为 `LDR_MODULE`，读取不属于模块的 `BaseDllName.Buffer`。

补丁将这个循环替换为 `kernel32_module_list.h` 中的单一实现：从 `head->Flink` 开始，遇到 `head` 立即终止，再转换真实节点。无 kernel32 时返回空；保留原有 `KERNEL32.` 大小写不敏感前缀语义，同时在访问前检查名称长度。它只处理合法 OS loader 链表的 sentinel 契约，不增加重试、改写目标进程或更换转区实现。

## 可重复的源码准备与测试

先从上述官方仓库取得独立、干净的固定提交 checkout，再运行：

```powershell
powershell -ExecutionPolicy Bypass -File native/galgame_hook/third_party/locale_emulator/prepare_source.ps1 -SourceRoot <Locale-Emulator-Core-checkout>
powershell -ExecutionPolicy Bypass -File native/galgame_hook/third_party/locale_emulator/test_module_list.ps1
```

准备脚本校验完整 commit、拒绝已有修改、检查并应用补丁、复制共享 header；不会运行上游编译器或生成 DLL。测试脚本通过 `vswhere` 找本机正式 MSVC，使用 `vcvars32.bat`、`/W4 /WX /O2 /DNDEBUG` 构建并运行测试。测试显式恢复 assertions，静态断言 x86 `LDR_MODULE` 相关偏移为 `+0x10` / `+0x30`。输出默认放入本地 `.codex-test/locale-module-list/`。

已通过 4 组行为测试：空链表；只有 ntdll 且 sentinel 伪名称指针为真实故障的 `0x1000`；kernel32 位于首节点或 ntdll 之后；kernel32 缺席且名称过短/为空。测试使用补丁实际调用的 header，不证明当前随包 DLL 已修复。

## 当前构建边界

2026-09-07，本机正式 MSVC `14.44.35207` / Windows SDK `10.0.22621.0` 对原始和应用补丁后的 `LocaleEmulator.cpp` 均未通过编译：

- 上游重复声明 `_InterlockedExchange8` / `_InterlockedCompareExchange64`，与现代 SDK 签名冲突。
- `RtlRaiseException` 返回类型与现代 SDK 冲突。
- 缺少旧 WDK 私有头 `ntnls.h`；原工程还指定 `MyLib.lib`、`undoc_ntdll.lib`、`undoc_k32.lib`。

上游 README 要求解压 `_Compilers`、`_WDK`、`_Libs`，并明确 `_Compilers` 含修改过的 VS2015 工具链。本轮没有运行该工具链，也没有把未验证的源码构建接入 `tools/build_distribution.ps1`。当前官方 MSVC 失败日志仅留本地 `.codex-test/locale-core/locale-modern-msvc-patched.log`。

下一门是用可维护、来源清楚的正式 Windows x86 工具链完成 **原 LE core** 构建。完成后才可接入分发指纹/自动构建，并随修改 DLL 提供完整对应源码（固定上游源码、补丁、构建脚本、必要依赖来源和完整许可证），再从用户原始 Rewrite `Start.exe` 路径复测。当前目录只有补丁，不能单独充当未来修改 DLL 的完整对应源码。
