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
- 打补丁会**改本机全局 SDK**，同机所有项目都会用上；这里只放上游已合入的修复的回移。
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
