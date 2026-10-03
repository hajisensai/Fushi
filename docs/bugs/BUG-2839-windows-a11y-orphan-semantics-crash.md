## BUG-2839 · Windows 外部 UIA 查询打到 AX 树失效节点崩溃（孤儿语义节点致桥失步）
- **报告**：2026-10-01（用户：QQ 反馈「老崩溃，感觉每次跳更新的时候」，附 10 个 `fushi.exe` minidump）
- **真实性**：✅ 真 bug。10 个 dump 里 7 个是本条（另 3 个是 [BUG-2838](BUG-2838-windows-toast-ffi-exception-crash.md)）。用与 dump 时间戳一致的本机 SDK release PDB（Flutter 3.44.0，engine `4c525dac`）符号化：6 个崩在 `FlutterPlatformNodeDelegateWindows::HitTestSync+0xd1`（`weak_ptr::lock` 解引用失效控制块，调用方 `AXPlatformNodeWin::accHitTest` ← `oleacc`/`UIAutomationCore`），1 个崩在 `FlutterPlatformNodeDelegate::GetParent+0x34`（`AXNode::id` 读已释放节点，调用方 `get_accParent`）。无符号时 cdb 把前者误标成 `user32!GetAltTabInfoA+0x2f`。
- **[x] ① 已修复** — 框架层根因修复：`ci/patches/flutter-sdk/3.44.0/0001-semantics-no-orphan-traversal-child.patch`（回移上游 flutter/flutter #186118 / #186826 / #193372，issue #190357），由 `ci/apply-patches.sh` 新增的 flutter-sdk 段打进构建所用 SDK（版本不符硬失败、幂等、BSD/GNU 工具通用）。见本分支提交。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/semantics_update_no_orphan_nodes_test.dart`：截获发往引擎的 `SemanticsUpdateBuilder.updateNode`，按引擎 `AXTree` 的累计语义建模，逐帧断言每个下发节点都能从根沿 traversal / hit-test 两条链到达且两链同集；场景为 MaterialPageRoute 与 showDialog 的推入/弹出转场，内含 Slider / Tooltip / MenuAnchor。还原 SDK 原文件时红、打补丁后绿。上游测试随补丁进入 SDK 的 `test/semantics/semantics_update_test.dart`。
- **备注**：与 [BUG-2337](BUG-2337-windows-uia-flutter-host-crash.md)、[BUG-2345](BUG-2345-flutter-child-at-index-null.md) 同根（都是 bridge 映射与 AX 树脱节后的不同解引用点）。

### 根因链

1. **框架下发孤儿节点**：OverlayPortal 的 traversal child（`traversalParentIdentifier` 指向锚点）在锚点被排除出语义树的帧里仍被序列化下发。Material 3 的 Slider 数值气泡、Tooltip、MenuAnchor、DropdownMenu 都走 OverlayPortal；路由 / 对话框转场首帧 `FadeTransition` opacity 为 0，锚点正好被排除——「跳更新」弹出的对话框就是这条路径。旧 `packages/flutter/lib/src/semantics/semantics.dart` 的 `SemanticsOwner.sendSemanticsUpdate` 没有按「从根可达」过滤脏节点。
2. **引擎半应用**：`third_party/accessibility/ax/ax_tree.cc:969` `AXTree::Unserialize` 遇到不连通的更新在 `:1069`~`:1078` 返回 false，但此前已删除 / 重挂了一部分节点；observer（`AccessibilityBridge::OnAtomicUpdateFinished`，`shell/platform/common/accessibility_bridge.cc:194`）只在成功末尾 `:1201` 才被通知，于是 bridge 的 `id_wrapper_map_` 留着指向已删节点的 delegate。
3. **外部 UIA 客户端引爆**：屏幕阅读器、输入法 / 触控键盘、讲述人、部分翻译与辅助工具会调用 `accHitTest` / `get_accParent`。`shell/platform/windows/flutter_platform_node_delegate_windows.cc:71` 对 `GetFlutterPlatformNodeDelegateFromID(child->id()).lock()` 的结果只有 release 下不生效的 `FML_DCHECK`，于是解引用失效对象崩溃。同类崩溃只出现在装了这类工具的用户机器上。

### 为什么修在框架而不是引擎

引擎侧空指针兜底需要重编 `flutter_windows.dll`，而且只挡住症状——树仍然失步，后续查询拿到的是错的节点。框架修复从源头不再产生孤儿节点，`Unserialize` 不再失败，bridge 不再失步，是上游采用的修法。框架 Dart 编进 app 快照，打 SDK 源码补丁即可随包生效。

### 删除条件

Flutter 升到包含 #193372 的版本时删掉 `ci/patches/flutter-sdk/3.44.0/`（`apply-patches.sh` 遇到版本不符的补丁目录会直接失败，升级时不会漏掉），并确认上面的回归测试仍绿。
