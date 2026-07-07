## BUG-586 · 网飞扩展制卡队列句子一模一样重复
- **报告**：2026-07-07（用户）
- **真实性**：✅ 真 bug。根因 `tools/browser-extension/vendor/action-popup.js:15`（镜像 `hibiki/assets/browser_extension/vendor/action-popup.js:15`）。
- **根因说明**：Netflix/YouTube 扩展制卡队列（工具栏图标 popup `vendor/action-popup.html` + `action-popup.js`）每行标签 `hibikiQueueItemLabel(q)` 原本优先显示 `q.sentence`（整句），其次才是词字段。而入队去重键 `hibikiQueueKey`（`content.js:212`）= 词 + 句 + 站点 + 视频ID：同一条字幕行里查多个不同词各点一次「制卡」→ key 不同 → 各自入队成不同卡片（正确），但队列每行只显示句子 → 多行显示同一句「一模一样」，用户无法区分（用户原话「网飞制卡·哪有句子一模一样的」）。展示维度（句）与卡片身份维度（词）错位。
- **[x] ① 根因修复** — 提交 `<PENDING>`。`action-popup.js` 主标签改为优先「词」(expression/word/term)，句子降为主标签下方暗色上下文行 `hibikiQueueItemContext`（`.hp-row-sub`）。同句不同词的卡片靠「词」一眼可辨；纯展示层改动，不触碰去重键/生成/入队逻辑。两份 byte-identical 镜像同步（tools/ 与 assets/）。
- **[x] ② 自动化测试** — `tools/browser-extension/action-popup.test.js`（node，直接执行真实函数：同句不同词→不同标签、context 仅在有词时回显句子、截断边界）；`hibiki/test/lookup/browser_extension_icon_popup_guard_test.dart` 加 TODO-1270 源码扫描守卫（两镜像各守：标签词字段先于句子、存在 hibikiQueueItemContext 与 .hp-row-sub），防回退到句子优先。
- **备注**：用户同报的「底部生成条 / 左上返回 / 右上旗帜」中，左上返回与右上旗帜是 **Netflix 原生播放器控件**（旗帜 = `.watch-video--flag-container`，见 `content.js:662`），扩展源码内无对应元素、不由扩展绘制，不可/不应删除；「底部生成条」是扩展的制卡进度 toast（`content.js:47`，功能性反馈）或工具栏 popup 的「开始生成/录制」按钮（生成入口），均有功能，删除会破坏制卡流程——按用户要求已在报告中说明，等用户澄清具体要改哪个元素。
