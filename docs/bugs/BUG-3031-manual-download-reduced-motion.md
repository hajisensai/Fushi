## BUG-3031 · 手动下载切换输入时零时长尺寸动画在布局中触发重入
- **报告**：2026-10-06（PR #1984 交叉审查，CC 提示同根因调用点）
- **真实性**：✅ 真 bug（静态路径确认，未做设备复现）。`fushi/lib/src/pages/implementations/manual_download_task_dialog.dart:926` 无条件将动效 token 的零时长传给 `AnimatedSize`。减弱动态效果或墨水屏下切换磁链 / 种子输入会改变子树尺寸；SDK `RenderAnimatedSize._layoutStable` → `_restartAnimation` → `forward(from: 0)` 同步通知 `markNeedsLayout`，在当前布局中触发重入断言，与下载任务卡的零时长修复同根因。
- **[x] ① 已修复** — 动效禁用时直接呈现当前输入子树；正常模式继续尺寸弹簧与交叉淡入。提交见本文件 Git 历史。
- **[x] ② 已加自动化测试** — `fushi/test/pages/manual_download_task_dialog_torrent_drop_test.dart`：正常 / 减弱动态效果分别双向切换输入；验证正常模式保留尺寸动画、降级模式一帧完成替换、没有框架异常。
- **备注**：按用户指令验证交 CI，不等待本机 heavy 队列；新增用例尚未执行，设备复测待补。未降低任何已有断言或添加 skip。
