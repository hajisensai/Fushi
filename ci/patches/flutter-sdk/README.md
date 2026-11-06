# Flutter SDK 框架补丁

`<frameworkVersion>/*.patch` 是相对 Flutter SDK 根目录的 unified diff（`-p1`），由
`ci/apply-patches.sh` 在 `flutter pub get` 之后打进**当前使用的 SDK**（`FLUTTER_ROOT`，
没设就取 PATH 上 `flutter` 的上两级）。框架 Dart 源码编进 app 快照，所以改
`packages/flutter` 就能改变发出去的 app，不需要重编引擎。

与 pub-cache 补丁的区别：

- **版本不符直接失败**。目录名必须等于 SDK 的 `frameworkVersion`（与 `fushi/.fvmrc` 同钉）。
  静默跳过框架补丁就等于把它修的崩溃放回来，所以升 Flutter 时必须回移或删掉这里的补丁。
- **SDK 收敛到「HEAD + 当前 checkout 的补丁集」（2026-11-05）**：一份 SDK 被同机所有
  worktree、dist_test worker 的所有槽位共用，而不同分支的补丁集不同（比如某分支在 0001 之上
  又加 0002 / 0003）。以前脚本只会「已打就跳过、没打就打」，SDK 被别的分支多打了补丁后，
  0001 正反都打不上，其它分支的 bootstrap / worker prepare 全部失败（Mac worker 就这样停过）。
  现在 SDK 是 git checkout 时，先把 `packages/` 下被改过的文件还原到 SDK 的 HEAD，再按顺序打本
  目录的补丁（`-F 0`，不容 fuzz，打不上就失败，绝不半打）。`bin/cache/fushi-sdk-patches.stamp`
  记下补丁集与打完后 `git diff` 的校验和，SDK 已经是目标状态时什么都不改（另一个 checkout
  可能正在用这些文件编译）。同一 SDK 的打补丁过程用 `bin/cache/fushi-sdk-patches.lock` 串行化。
  SDK 不是 git checkout 时退回旧做法（逐个判断已打 / 打上）。
- **仍然存在的限制**：同一台机器上两个 checkout 用不同补丁集**同时**跑测试时，后 prepare 的那个会
  改掉先跑的那个正在用的 SDK。只有碰 semantics 的测试受影响；补丁集分歧只在改 SDK 补丁的分支合入
  前短暂存在。
- 打之前把补丁点名的文件的 CRLF 规范成 LF（Windows 的 SDK checkout 是 CRLF）。
- 打补丁会**改本机全局 SDK**，同机所有项目都会用上；这里只放框架根因修复，优先回移上游（上游未合入或没有对应 PR 的，在条目里写明来历与删除条件）。
  对 SDK `packages/` 的手工改动会在下一次 apply-patches 时被还原。

## 3.47.6

### `0001-semantics-no-orphan-traversal-child.patch`（BUG-2839）

回移上游 flutter/flutter #193372（修 issue #190357），改
`packages/flutter/lib/src/semantics/semantics.dart` 并带上游测试
`test/semantics/semantics_update_test.dart`。

3.44.0 时这份补丁还合并了 #186118 / #186826；二者已进 3.47.6（`gh api
repos/flutter/flutter/compare/<merge_sha>...3.47.6` 为 ahead），升级时只保留 #193372
（截至 2026-10-05 仍 open，head `c0c4d54eb5`），由 PR diff 对 3.47.6 的 LF 源重新生成，
`-F 0` 零 fuzz 可打。

修的问题：OverlayPortal 的 traversal child（Slider 数值气泡 / Tooltip / MenuAnchor /
DropdownMenu 都走它）在锚点被排除出语义树时（例如路由转场首帧 opacity 0）仍被下发，
成了引擎眼里的孤儿节点。Windows 引擎 `AXTree::Unserialize` 拒绝这份更新时已改了一半树，
又不通知 `AccessibilityBridge`，id→delegate 映射从此脱节，外部 UIA 客户端
（屏幕阅读器 / 输入法 / 触控键盘）一做命中测试或焦点查询就在 `flutter_windows.dll` 里崩。

app 侧回归测试：`fushi/test/widgets/semantics_update_no_orphan_nodes_test.dart`。

**删除条件**：Flutter 升到已包含 #193372 的版本时删掉本目录，并确认上面那条回归测试仍绿。

### `0002-semantics-no-merge-distinct-traversal-parents.patch`（BUG-4073）

移植上游 flutter/flutter #190344（修 issue #182444；该 PR 因作者未签 CLA 被机器人按「21 天无更新」
关闭、未合入，修法本身没有被评审否定），只改 `SemanticsConfiguration.isCompatibleWith` 一处：两份
configuration 各自锚定**不同**的 traversal parent（相邻两个 `OverlayPortal`，例如并排的两个
`Tooltip`）时不许合并。旧逻辑只拦 `traversalChildIdentifier`，`absorb` 又用 `??=` 只留第一个
`traversalParentIdentifier`，第二个锚点的身份被丢掉。`ListView` 条目的 `IndexedSemantics` 会把条目
里互不冲突的 configuration 并成一个节点，所以「列表条目里并排两个 Tooltip / OverlayPortal」必中：
第二个 overlay 子节点找不到 traversal parent，被 0001 的跳过逻辑整棵丢掉，无障碍树里没有它。

**必须与 0003 一起打**：分开之后锚点各自成节点，在 `MergeSemantics` 里就成了「被并进祖先的
traversal parent」，只打 0002 会让 `MergeSemantics(Row(Tooltip, Tooltip))` 悬停时下发孤儿节点。

### `0003-semantics-skip-children-of-merged-traversal-parent.patch`（BUG-4073）

本仓自修（上游无对应 PR）。traversal parent 自己 `isMergedIntoParent`（被并进 `MergeSemantics` /
`mergeAllDescendants` 祖先）时，它从不单独下发，graft 到它身上的 traversal child 没有任何节点在
`childrenInTraversalOrder` 里列它，却照样被下发——桌面引擎 `AXTree::Unserialize` 报
「N will not be in the tree and is not the new root」整份拒收，框架以为已发过，下一帧增量更新
撞上「Nodes left pending by the update」半应用，bridge 与 AXTree 从此失步（与 0001 同一失步模型，
崩点见 BUG-4073 / BUG-2345 / BUG-2337）。**不依赖 0002 也能触发**：`MergeSemantics` 里两个带
tooltip 的 `IconButton`（两个 tap 动作冲突、各自成节点再被并进祖先），鼠标悬停任一个就中。

修法沿用 0001 的「缺 traversal parent 就跳过」：`_shouldSkipInHitTest` 把「traversal parent 被并进
祖先」同样视为找不到 parent（tooltip 文案本来就作为 `tooltip` 属性并进了合并节点，不丢信息）；
`isMergedIntoParent` 翻转时把这些 traversal child、它们的 hit-test parent 与未合并的后代标脏重发，
与 `sendSemanticsUpdate` 里「traversal parent 新注册」的处理一致，避免翻回未合并时子树缺数据。

补丁按序叠在 0001 / 0002 之上（由打完前序补丁的 3.47.6 LF 源生成，`-F 0` 零 fuzz）。

app 侧回归测试（0002 / 0003 共用）：`fushi/test/widgets/semantics_update_ax_tree_contract_test.dart`
逐帧按引擎 `AccessibilityBridge` 两步提交 + `AXTree::Unserialize` 的判定核对下发的语义更新；契约模型
在 `fushi/lib/src/utils/misc/semantics_ax_tree_contract.dart`（生产路径同一份模型做失步哨兵
`A11y.axTreeDesync`），模型自身的判定对照测试在 `fushi/test/utils/misc/semantics_ax_tree_contract_test.dart`。

**删除条件**：Flutter 升到修了 #182444 且处理了「被合并的 traversal parent」的版本时删掉 0002 / 0003，
并确认上面的回归测试仍绿。
