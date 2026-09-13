## BUG-2244 · 浏览器嵌套查词点击泄漏给播放器导致查词窗关闭
- **报告**：2026-09-07（用户：截图中浏览器嵌套查词会关闭查词弹窗）
- **真实性**：✅ 真 bug。`fushi/assets/popup/popup.js:5824` 的正文点击委托原本挂在共享 document，`tools/browser-extension/content.js:1543` 创建的 ShadowRoot 宿主没有鼠标事件隔离，点击会传到站点播放器；播放事件经 `fushiArmPlayDismiss` 关闭查词窗。此外 `vendor/selection.js:487` 发出的 textSelected 在 `bridge-shim.js:140` 没有处理，正文嵌套查词链中断。
- **[x] ① 已修复** — 共享正文点击/Shift 取词委托绑定到扩展 ShadowRoot 并截住冒泡，App 仍使用 document；宿主隔离鼠标/指针/触摸事件，保留按钮默认行为；textSelected 与交叉引用共用原地嵌套查词入口。提交见本文件所在提交。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/popup_asset_behavior_test.js` 验证共享 ShadowRoot 交互；`tools/browser-extension/side-panel-lookup-on-page.test.js` 验证宿主隔离及真实桥 textSelected → lookup，保留原宿主、坐标、字幕来源且不发送关闭回执。
- **备注**：扩展全部 477 项 Node 测试、共享 popup 行为脚本通过（退出码 0），包含站点 document 点击监听保持零触发；镜像同步。用户实际视频网站端到端复测未完成；需在更新后的浏览器扩展确认原始路径，代码和自动化测试不能替代现场验收。
- **后续纠正**：用户要求 App 同款父子栈；本条中“原地重查”不满足要求，已由 BUG-2245 移除。事件隔离修复继续保留。
