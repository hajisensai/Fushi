## BUG-1864 · 视频字幕列表持焦后整张快捷键表失效

- **报告**：2026-08-25（用户：打开右侧字幕列表后快捷键用不了）
- **真实性**：✅ 真 bug。字幕列表、剧集轨和侧栏是 `AdaptiveVideoControls` 的兄弟子树；`PanelFocusScope` 把焦点领进面板后，挂在 media_kit controls 子树里的 `CallbackShortcuts` 不再位于事件祖先链上。原 PR #1007 只合入了裸空格兜底；完整的整表修复提交 `bd8701bb2c` 是在 PR 合并后才追加到原分支，因此从未进入 `develop`。
- **[x] ① 裸空格兜底已修复** — `f99c4bd1d0` / `3804f11820` 把空格处理上提到窗口与全屏共用的 `_wrapVideoGamepadControls`，并让文本输入框获得空格。
- **[x] ② 已加空格拓扑回归测试** — `f99c4bd1d0` / `34bdc5b74f` 覆盖独立全屏路由、真实 `PanelFocusScope` 抢焦和无路由级通道的负向对照。
- **[x] ③ 整张视频快捷键表改为页级 press-time 单通道** — 每次按键由 `resolveVideoKeyboardShortcut` 读取当前注册表，并在窗口/全屏唯一共同祖先 `_wrapVideoGamepadControls` 派发。media_kit controls 显式接收空表，避免同一按键双通道执行。文本框持焦时整条视频通道让位；面板持焦时裸方向键让位给焦点遍历，带修饰键的字幕/视频动作仍执行；Enter 在控制条或面板持焦时继续作为焦点确认键；按住倍速保留 key-up 边沿。
- **[x] ④ 已加整表与边界测试** — 覆盖视频/通用 scope 解析、IME 物理键回退、弹窗优先级、字幕光标优先级、面板方向键导航、全屏路由挂载点，以及 media_kit 内层快捷键表必须为空。
- **验收边界**：静态与定向测试不能替代 Windows 实机。真机应复验：窗口和全屏分别打开字幕列表，确认 Space、F、L、B、Ctrl+←/→ 等绑定生效；裸 ↑/↓ 仍移动列表焦点；Enter 激活列表行；文本框可以正常输入空格。
