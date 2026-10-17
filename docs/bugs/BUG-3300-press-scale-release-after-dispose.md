## BUG-3300 · FushiPressScale 松手路径读已销毁 State.context（文件选择器闪退）
- **报告**：2026-10-13（反馈 ufzhkidhLr，Windows：已导入字幕的书重新选字幕，点开文件选择器闪退）
- **真实性**：✅ 真 bug。日志首错 `Null check operator used on a null value` @ `State.context` ← `_FushiPressScaleState._release`（原 `fushi/lib/src/utils/components/fushi_press_scale.dart:80` 的 `context.fushiMotion`）← `Listener.onPointerUp`。指针事件按 hit-test 时记下的渲染对象路径派发，与 widget 生命周期无关：点击回调里开模态 / 原生文件选择器（Windows 在指针事件派发途中泵消息、跑帧）把本卡拆掉后，迟到的 pointerUp 仍落到已销毁的 State。「更新流程 Overlay.of」在日志里不存在（只有 Client is closed 的下载中断），与本崩溃无关。
- **[x] ① 已修复** — 松手路径不再碰 context：按下时缓存弹簧，`_downPosition` 成为唯一按压状态源，dispose 清空它，销毁后的 pointerUp / Cancel 直接返回。提交 7eac5e2617。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_motion_redesign_test.dart`「按下后本卡被拆掉，迟到的 pointerUp 不抛（ufzhkidhLr）」（变异实测：还原旧实现即红 `Expected: null`）。
- **备注**：Windows 真机文件选择器路径未复测（本批不跑真机）；根因链路由日志栈 + 测试复现。
