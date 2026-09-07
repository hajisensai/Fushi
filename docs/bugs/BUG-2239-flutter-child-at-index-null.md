## BUG-2239 · Windows Flutter ChildAtIndex 枚举空子节点时访问冲突
- **报告**：2026-09-07，Windows Siglus 验收期间，宿主 PID 24584 非主动退出。Windows 事件与原始转储确认真实 native 崩溃；此记录只处理宿主可访问性子节点枚举路径。
- **真实性**：✅ 真 bug。匹配当前 Flutter engine 的私有 PDB 与源码行表后，异常线程定位到 `flutter::FlutterPlatformNodeDelegate::ChildAtIndex+0x3f`，`shell/platform/common/flutter_platform_node_delegate.cc:90`：直接解引用 `GetUnignoredChildAtIndex(index)` 的空返回值。现场 `rax=0`，`mov edx,[rax+48h]` 读取 `0x48` 触发访问冲突。空解引用已确认，导致子节点枚举与 count 不一致的上游生命周期机制尚未确认。
- **[ ] ① 未修复** — 只完成只读诊断与缺陷登记；未升级 SDK、重建或替换 Flutter DLL、修改应用/游戏代码、关闭无障碍或用 SEH 吞异常。需要先完成下述 engine 契约回归，再验证有界空返回处理及真实树更新顺序。
- **[ ] ② 未加自动化测试** — 原始转储可重复符号化，但尚无确定性 UI 操作复现或 engine 回归测试。文档索引校验不等于崩溃回归通过。
- **备注**：本问题与 [BUG-2231](BUG-2231-windows-uia-flutter-host-crash.md) 属于同一 Windows 可访问性域，但崩点与失效对象不同，不能合并为同一已知根因。

### 事件与二进制身份

两条 Application Event 1000 均来自同一宿主 PID 24584、异常线程 63960，模块 `flutter_windows.dll+0x3e735`。时间为本机 UTC+08:00：

| Record ID | 时间 | 异常码 | 解释边界 |
|---|---|---|---|
| 11062 | 2026-09-07 17:11:31.8930623 | `c0000005` | 读取 `0x48` 的访问冲突 |
| 11064 | 2026-09-07 17:11:37.6004933 | `c000041d` | 同位置的用户回调异常；不是第二个独立根因 |

- 本机 SDK 报告 Flutter 3.44.0，`engine.stamp` 为 `4c525dac5ebe5971c5708ef73558ed8edcf4a362`。
- `flutter_windows.dll` SHA-256：`3168C546AEB0B0E6A77ABC97E0DE95B45D13ADA150FAAAD6DE75E79ACAF3B050`。
- 匹配 release PDB SHA-256：`60C1E584E462A98D3C047F31E111D1C02F3E9BE775BA1A222A514BC4CF809B56`；RSDS GUID `B97F462F-3431-49FC-A61E-A9DFED8E059C`，age 1。CDB `!lmi` 确认加载 private symbols & lines，没有强制使用不匹配符号。
- 原始 AV dump：52,703,763 字节，SHA-256 `E6E9C5B7DA56A2B542435706EA2443A21A4E896A38B274106F63CE8D0BBA8923`；回调异常 dump：51,966,335 字节，SHA-256 `0DC210EFFE366B1BFF53375913F6A599BB776C3D6100D3D618405307EB17D80D`。仅在本机原路径读取，未复制或上传。

### 已确认的调用与失败条件

异常链从 Windows 消息回调进入 `UIAutomationCore`、`oleacc!AccessibleChildren`，再进入 Flutter 的 `ui::AXPlatformNodeWin::get_accChild` → `GetTargetFromChildID` → `FlutterPlatformNodeDelegate::ChildAtIndex`。最后内联到 `ui::AXNode::id`（`third_party/accessibility/ax/ax_node.h:110`）读取空对象字段。

对应 engine 源码：

- `shell/platform/common/flutter_platform_node_delegate.cc:83–90`：`GetChildCount` 读取未忽略子节点计数，`ChildAtIndex` 未检查查找结果是否为空就调用 `id()`。
- `third_party/accessibility/ax/platform/ax_platform_node_win.cc:5427–5440`：`GetTargetFromChildID` 先检查 `child_id` 在 `1..GetChildCount()` 内，再以 `child_id - 1` 调用 `ChildAtIndex`。因此并非任意外部索引完全未经校验。
- `third_party/accessibility/ax/ax_node.cc:47–55`：`GetUnignoredChildAtIndex` 遍历实际未忽略子节点，找不到对应位置时返回 `nullptr`。

按实际机器码的函数序言及保存槽恢复，本次 `index=1`（第二个子节点），保存的 RDI 位于异常 RSP+0x28；优化后的 `dv` 无法直接给出 `index`/`this`，故不以其 unavailable 值作推断。源码与现场共同表明：调用方 count 检查允许了该索引，但实际遍历没有返回子节点。缓存过期、树更新重入或失效节点生命周期仍需分别验证；相关 heap 页未完整进入 minidump，进一步节点读取失败，不能将竞态或 UAF 写成已证根因。

旧 PID 73368 的转储使用同一匹配 PDB 复核后，崩点为 `AXNodeData::GetStringAttribute`（`ax_node_data.cc:345`，内联比较器 `:79`），经 `GetString16Attribute` → `AXPlatformNodeBase::GetString16Attribute` → `AXPlatformNodeWin::GetValueAttributeAsBstr` → `get_accValue`。它读取 `0xffffffffffffffff`，偏移为 `+0x8e50da`；本条是子节点枚举读取 `0x48`。本条的空返回处理不能据此宣称修复旧属性访问崩溃。BUG-2231 最初缺 PDB 的诊断限制已在这次只读复核中解除，但其根因仍未确认。

### 最小回归与后续修复范围（尚未执行）

1. 在匹配的 Windows engine 源码测试层验证合法子节点索引、负索引/越界查找，以及获取 count 后子节点被删除、忽略或重排时的过期索引；不得用人为 sleep 制造或掩盖窗口。
2. 验证 `ChildAtIndex` 查找结果为空时安全返回不可用节点，且 MSAA `get_accChild` 仍遵守既有失败返回契约；正常子节点枚举和无障碍访问保持可用。单纯添加空判断只能关闭已知解引用点，不能证明底层生命周期已修复。
3. 用 Windows UIA 枚举与动态 semantics 子树变更复现完整调用契约，定位 count 与实际枚举失配来源；若证实树更新发布顺序或重入问题，应修复该生命周期，再进行相容的 engine 构建及原始宿主路径回归。

本轮只读上游核对没有找到可确认已合入并覆盖本崩点的修复。曾检查的 [Flutter 主干 delegate 源码](https://github.com/flutter/flutter/blob/main/engine/src/flutter/shell/platform/common/flutter_platform_node_delegate.cc) 仍有直接解引用；这是当次检查结果，不是“已找到修复”的证据，也不能保证所有分支或未来版本没有修复。[PR 190507](https://github.com/flutter/flutter/pull/190507) 修改 enabled/read-only 状态传播，[issue 192180](https://github.com/flutter/flutter/issues/192180) 描述 `HitTestSync` 的另一路径，均不能作为本条修复依据。

### 本机脱敏证据与验证

只读诊断目录为 `D:/codehibiki/.codex-test/siglus-engine-adapter/host24584-crash/`，本仓不收录 dump、进程内存、游戏正文或资源载荷。目录内 `findings.md` 记录诊断演进；早期“缺 PDB”段落已由后续准确符号化段落明确更正。

- `application-events.json`、`dump-metadata.json`：两个事件及转储身份。
- `cdb-local-symbols.log`、`cdb-callback-symbols.log`：官方 CDB 只读原始两转储，加载本机 release PDB；未启用外部符号服务器或转储传输。
- `cdb-child-abi.log`、`cdb-child-state.log`：现场空值及有界参数恢复；`cdb-child-node.log` 保留节点 heap 不可读的限制，不隐藏此失败。
- `cdb-previous73368-comparison.log`：旧 BUG-2231 的准确属性访问栈，作为区别证据。

本次登记仅运行 `dart run tool/bug.dart new/reindex/check` 和 `git diff --cached --check`；命令退出码留存在同一本机证据目录。`reindex/check` 均退出 0，校验 2069 条，本地号唯一且索引同步；跨源检查的历史同号警告保留在 `bug2239-check.log`，不涉及新号 2239。没有新增或运行崩溃自动化测试，没有以宿主重启后可用代替修复验收。
