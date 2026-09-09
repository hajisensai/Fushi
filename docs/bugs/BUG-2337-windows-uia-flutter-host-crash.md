## BUG-2337 · Windows宿主在UIAutomation回调进入Flutter时访问冲突退出
- **报告**：2026-09-07，Windows Siglus 适配验收中发现。宿主 PID 73368 导入词典成功后，从设置返回游戏首页、准备打开工作台时退出；当时尚未附着任何游戏。
- **真实性**：✅ 真 bug（Windows Event1000/1001 与两份本地转储确认）。14:26:59 记录 `c0000005`，14:27:05 记录 `c000041d`；同一 PID、开始时间、线程 72760、同一 `flutter_windows.dll+0x8e50da`。首个异常是读取 `0xffffffffffffffff` 引起的访问冲突。通过转储与时间戳匹配的本地 PE unwind 信息恢复出相同的 24 帧调用栈：Flutter `+8e50da → +8e5163 → +8dcfa0 → +9166b0 → +916121`，其调用方为 `oleacc` / `UIAutomationCore`，下层为 Windows 消息回调与 `GetMessageW`。确认走可访问性/UIAutomation 路径，但尚未确认具体失效对象或根因源码行，不能归属到注入器、Siglus adapter 或词典业务。
- **[ ] ① 未修复，2026-09-08 同属性路径再次崩溃** — 初次诊断缺 PDB 的限制已解除：匹配本机私有符号后确认 `AXNodeData::GetStringAttribute` 属性读取路径，见下文及 [BUG-2239 的旧转储对照](BUG-2239-flutter-child-at-index-null.md)。DLL 时间戳 `0x6a07c2d0`，SHA-256 `3168C546AEB0B0E6A77ABC97E0DE95B45D13ADA150FAAAD6DE75E79ACAF3B050`，PDB GUID `B97F462F-3431-49FC-A61E-A9DFED8E059C`、age 1；本机 SDK 为 Flutter 3.44.0、engine `4c525dac5ebe5971c5708ef73558ed8edcf4a362`。底层失效对象的生命周期根因仍未确认，尚未修复；不修改 Flutter engine、不关闭可访问性、不添加绕过。
- **[ ] ② 未加自动化测试** — 已有真实异常与有界线程栈证据，但尚无确定性触发条件或根因层测试。不能把一次重新启动成功当作回归测试通过。
- **备注**：重启宿主 PID 36616 后，主代理确认游戏页面、两款原版游戏附着、Anemoi 实际查词均正常；这是后续正向验证，不能说明本崩溃已修复。此项独立于 BUG-2230 的快照读取契约缺口；没有证据建立二者因果关系，也不能把此前纹理桥 UAF 记录直接套用到本事件。

本地证据仅留在未入库的 `.codex-test/siglus-engine-adapter/host73368-crash/`：`findings.md`（边界说明）、`application-events.json`（WER 元数据）、`stack-av.txt` / `stack-callback.txt`（仅异常线程模块栈）、`binary-hashes.json`（构建身份）以及有限栈提取工具源码。诊断过程没有改动用户数据、注册表或进程；仓库不提交转储、游戏载荷或用户内存。两份原始转储仅本机留存，不随此记录发布。

### 2026-09-08：PID 69880 的异常长度分配

**Proved**：03:36:00（UTC+08:00）Application Event 1000 记录宿主 PID `69880` 在 `ucrtbase.dll+0xb156e` 以 `c0000409` 退出，Report ID 为 `bf3797b4-dcd4-4765-ac09-9b210fa76050`。宿主镜像为本机私有测试包 `legacy-fushi-v5/fushi.exe`，版本 `2.2.4.1244`，时间戳 `0x6a9ea1eb`。原始 Start 链后续游戏 PID `48540` 在 03:36:21 才出现；不能将本次宿主退出归因于该游戏已进入查词，也不能将整段原始流程记为 E2E 通过。

只读打开本地 `CrashDumps/fushi.exe.69880.dmp`（48,562,428 字节；SHA-256 `2EBCEE7034CB77A036B6EE8882B9BFC0B635B2BE7171F6E75FC7C8BE932303E1`）。转储异常子码为 **7 / FAST_FAIL_FATAL_APP_EXIT**，实际终点为 `abort → terminate`，不能根据 Windows 通用错误标签判成栈缓冲区溢出。

同一匹配 release PDB（GUID/age 如上）由 CDB `!lmi` 确认成功加载 **private symbols & lines**，未使用强制不匹配符号。准确调用链是：

`GetMessageW → UIAutomationCore → oleacc → AXPlatformNodeWin::get_accValue → GetValueAttributeAsBstr → AXPlatformNodeBase::GetString16Attribute → AXNodeData::GetString16Attribute → AXNodeData::GetStringAttribute+0x48 → std::string::_Reallocate_for → operator new → __scrt_throw_std_bad_alloc → _CxxThrowException → terminate`。

`operator new` 栈帧的 PDB 局部变量 `size` 为 **`0x63222c008f85e3e7` 字节**。机器码与保存寄存器共同显示，字符串重分配请求长度为 `0x63222c008f85e3b7`，经容量对齐及分配器开销形成上述请求；`GetStringAttribute` 从命中的 AX 属性字符串长度字段取值并调用 `assign`。这是异常字符串长度进入分配器的直接证据，不能用普通宿主内存不足解释，也不能以捕获 `bad_alloc` 代替根因修复。

**Not proved**：此例与 PID 73368 的旧崩溃落在同一 `AXNodeData::GetStringAttribute` 路径，但前者是异常长度导致分配失败，旧例是在遍历属性时读取 `0xffffffffffffffff`。仅凭共同路径不能确定是相同对象、UAF、树更新重入或另一处内存破坏；minidump 未包含完整堆，底层生命周期未得到证明。这也不是 BUG-2239 的 `ChildAtIndex` 空返回解引用。主线程栈没有 Siglus Hook 调用，尚无证据把 adapter、转区运行库或词典业务定为损坏来源。

**Next gate**：在匹配 Flutter engine 的 Windows 属性读取与 semantics 树更新边界复现对象/属性失效，验证节点和属性容器的实际存活及发布顺序。保留真实 MSAA/UIA 查询，不通过禁用可访问性、静默异常或字符串长度截断绕过。没有新增或运行崩溃自动化测试；宿主重启及后续游戏附着成功都不能将本条标为修复。

本次仅在本机记录 `D:/codehibiki/.codex-test/siglus-engine-adapter/debugger/fushi69880-symbols.log`（匹配符号栈）与 `fushi69880-allocation-metadata.log`（有界栈帧变量及机器码）。WER ReportArchive 读取被权限拒绝，未改变权限；改用当前用户可读的原始 dump，未复制或上传转储，未操作 UI、改动进程或生产源码。本轮文档按 `bug.dart reindex/check` 验证；此检查不算崩溃回归测试。
