## BUG-1299 · 视频页隐形chrome可聚焦致空焦点框
- **报告**：2026-08-01（用户：手柄看视频时，字幕「思うけど」附近凭空浮着一个空的浅色矩形框，截图为证；要求根本性修复）
- **真实性**：✅ 真 bug。视频页三处淡出型 chrome 隐藏态**留在树里**、只包 `IgnorePointer` 挡指针，但 `IgnorePointer` 挡不住焦点遍历/滞留：
  - 剧集横轨面板 `hibiki/lib/src/pages/implementations/video_hibiki/episode.part.dart:242`（`_episodeOverlayPanel`，卡片是 `InkWell(canRequestFocus: true)`，`hibiki/lib/src/media/video/video_episode_rail.dart:173`）；
  - 侧边沉浸锁按钮 `hibiki/lib/src/pages/implementations/video_hibiki/layout.part.dart`（`_buildSideLockButton`）；
  - on-rail 沉浸退出钮（`_withImmersiveLockAutoHide`，同文件）。
  手柄/键盘把焦点带进这些控件（dpad 浏览剧集轨、controller 未就绪时 dpad 落焦点兜底、Tab 遍历均可），面板淡出后焦点滞留在 opacity=0 的控件上；`HibikiFocusRing`（`hibiki/lib/src/utils/components/hibiki_focus_ring.dart:265`，traditional 高亮模式）按 primaryFocus 的 RenderBox 画 2.5px 空心框、全屏视频节点被 92% 规则抑制而小控件不被抑制 → 画面上凭空出现一个空焦点框。
- **[x] ① 已修复** — 根因修复：新增 `FadingChromeGate`（`hibiki/lib/src/utils/components/fading_chrome_gate.dart`），把「不可见 ⇒ 不可点 + 不可聚焦」做成结构不变量（`IgnorePointer + ExcludeFocus + AnimatedOpacity` 绑死同一 `visible` 判据）；`ExcludeFocus` 翻 excluding 时 Flutter 自动把已持焦子孙 unfocus 回 scope 上一个持焦者（`focus_manager.dart` `descendantsAreFocusable` setter），隐藏瞬间焦点自动撤离。三处调用点全部换用，视觉/动画时序不变。
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/fading_chrome_gate_test.dart`：①隐藏态子孙 requestFocus 不生效；②可见→隐藏时已持焦子孙被撤离、焦点回到门外上一个持焦者；③隐藏态指针穿透（旧行为保持）；④源码守卫：episode.part.dart / layout.part.dart 必须走 `FadingChromeGate`、禁止回退裸 `IgnorePointer(ignoring: !visible)`（守卫已做两组变异实测：剧集轨回退旧写法、layout 少一处 gate，均精确变红）。
- **备注**：`chapter.part.dart` 的常驻 `IgnorePointer` 是纯展示层（无可聚焦子孙、恒不拦指针），不在病灶列；media_kit fork 控制条淡出后 `mount=false` 整树卸载，无此问题。同 PR 顺带落地视频页手柄字幕选词查词（`videoEnterCaret`），入口见 PR 描述。
