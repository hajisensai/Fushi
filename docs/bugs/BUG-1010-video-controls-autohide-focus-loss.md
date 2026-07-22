## BUG-1010 · 视频控制条自动隐藏后键盘焦点疑似丢失
- **报告**：2026-07-22（来源：UI/UX 巡检，非用户报告）
- **真实性**：⏳ 待 Windows 真机复现（代码路径推理成立）。推理链：fork 的 media_kit 桌面控制条隐藏时把按钮子树整体 **unmount** 而非仅透明（`third_party/media_kit_video/lib/media_kit_video_controls/src/controls/material_desktop.dart:825` `if (mount) Padding(...)`）；桌面用户 Tab 把焦点移到控制条 `IconButton`（`MaterialDesktopCustomButton` 可聚焦，同文件 :1505）后 2s 自动隐藏将该按钮卸载，primary focus 落回路由 scope 而非 `_videoFocusNode`——挂在其下的快捷键 CallbackShortcuts 可能失效，直到用户点击画面触发 `_refocusVideo`。页内各关闭路径均有 `_refocusVideo` 收口，唯独「控制条自动隐藏」这条没有。
- **[ ] ① 未修复** — 候选修法：控制条 onHide 回调里若焦点在控制条子树内则先 `_refocusVideo()`；或隐藏改为 `Visibility(maintainState: true)` + IgnorePointer 不卸载子树。
- **[ ] ② 未加自动化测试** — 建议 Windows 离屏焦点驱动测试：Tab 至控制条按钮 → 等自动隐藏 → 发快捷键断言仍生效。
- **备注**：先 Windows 真机 Tab 复测取证再修；巡检报告 `docs/reviews/2026-07-22-ui-ux-survey.md` 视频模块。
