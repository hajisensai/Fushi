# Locale Emulator 维护补丁与本地构建

本目录复用 Fushi 的 Windows x86 日语转区链路，保存模块链表修复、版本资源兼容和可重建运行库的脚本。2026-09-08 已使用正式工具链构建并通过自有运行时探针；尚未接入正式分发，也未据此升级游戏支持状态。

上游为 [Locale-Emulator-Core](https://github.com/xupefei/Locale-Emulator-Core)，固定提交
`ae7160dc5deb97947396abcd784f9b98b6ee38b3`。修改日期：2026-09-08，Hibiki。
上游 LoaderDll、LocaleEmulator 按 LGPL-3.0 发布；本目录新增源码、脚本及测试按 LGPL-3.0-or-later 发布，保留 GPL/LGPL 原文。

## 修改契约

- BUG-2232：初始化模块链表以独立 sentinel 为边界，无 kernel32 时返回空，等待原有 DLL 通知。真实 x86 loader ABI 回归覆盖空表、首节点、后继节点、短名和 sentinel 无效名称指针。
- BUG-2246：VERSION.dll 的 GetFileVersionInfoW/ExW 成功后，在调用者缓冲内原子更新首个 Translation 及匹配 StringTable；保留 codepage、字符串和其他语言项。畸形资源、缺表与键冲突不修改任何字节。不启用上游旧的 TLS 资源改写函数。
- 新 VERSION 跳转的生命周期：明确 SelfShadow 手工映射入口由进程持有；正常 DllMain 加载必须成功固定自身。两种入口均固定 VERSION 后才安装跳转。部分安装失败回滚，恢复失败保留 trampoline、global 和 ml 上下文；进程终止交操作系统释放。该修改不宣称上游所有旧 Hook 的任意卸载安全。
- Fushi 的日语时区名称在 injector/locale_emulator_launch.h 修复（BUG-2247）；不改变系统全局区域或时区。

## 源码准备

从官方仓库取得干净、固定提交的独立 checkout，然后运行：

```powershell
powershell -ExecutionPolicy Bypass -File native/galgame_hook/third_party/locale_emulator/prepare_source.ps1 -SourceRoot <checkout>
```

脚本拒绝受控文件修改和已有辅助文件，一次检查两份补丁后应用，不执行上游 _Compilers。

## 正式工具链的本地构建

```powershell
powershell -ExecutionPolicy Bypass -File native/galgame_hook/third_party/locale_emulator/build_runtime.ps1 -SourceRoot <checkout> -VcBin <official-v140-bin> -LldLink <official-lld-link.exe> -OutputDirectory <new-directory> -Python <python.exe>
```

脚本从固定 Git commit 重新导出白名单源码，因此 SourceRoot 的本地修改不会进入构建。精确校验 v140 19.00.24247.2 编译器组件、LLVM LLD 22.1.6，以及上游 WDK/Libs 压缩包的 SHA-256。微软官方下载 URL、大小与 SHA 位于 official-v140-inputs.json；本机仅管理解包 MSI/CAB，未运行上游改过的编译器。工具不满足哈希时拒绝构建。

原始 MyLib 含旧 /GL 对象，现代 MSVC 无法直接链接。正式 v140 先将精确十个编译单元及原依赖生成 native.iobj，LLVM 再链接最终 DLL，显式保留入口、导出、节权限及延迟导入。首阶段 codegen-only.dll 的 Kernel32 延迟导入被微软 linker 忽略，禁止使用或分发；最终产物必须通过 verify_runtime_pe.py 的 x86 PE32、入口、导出、普通导入仅 ntdll 和四组延迟导入契约。编译器隐式环境 CL/_CL_/LINK 在构建期间清空并恢复。

输出只写入新目录，不替换 Fushi 已安装组件。当前候选 SHA-256：
`8DF7A41BE6AE8C6920CB06C05C60DAEFDA9D330A0212A1CC036DE9B877CA9079`。
原有上游源码警告仍会报告，不能把本地构建描述为整个第三方项目零警告。

## 验证与分发边界

native CTest 包括模块链表、版本资源真实 Windows API 查询和集成 Hook 故障注入测试；PE 合成测试已登记 tools/run_guards.ps1。2026-09-08 自有 LE 探针进程 26152 正常退出，ACP/OEM 932、LCID 0411、kernel32 版本语言 0411。

当前候选已与新 launcher lineage helper 从原始 Rewrite Start.exe 重跑：2026-09-08 01:08:31 helper 25012 → Start 71692 → 官方 StartMenu 64428 → SiglusEngine 46800（01:09:09）；自动注入成功并进入正文。LunaHook 在换句后取得画面对应正文；内嵌几何、语音与真卡仍未通过。源码/探针测试不是完整游戏支持证据。

正式分发尚未接入。上游 _Libs 中的 MyLib 仍为预编译依赖，本目录不将其称作完整对应源码；修改运行库的对应源码、依赖许可和分发流程仍需解决，当前构建产物保持本地实验用途。不会把官方工具链或游戏载荷入库。
