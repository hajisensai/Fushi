## BUG-1279 · 浏览器扩展嵌套查词会关掉旧弹窗、跳位并重画原文高亮

- **报告**：2026-07-31（用户：浏览器嵌套查词有问题；补充「还有嵌套查词会把旧弹窗关掉」）
- **真实性**：✅ 真 bug，根因 `tools/browser-extension/content.js:1544`（修复前的 `__hibikiOnLinkClick` → `hibikiRender`）

### 症状

在浏览器扩展的查词弹窗里点释义中的词 / 词典交叉引用（嵌套查词）时：

1. 弹窗先整个消失一次再淡入——用户感知为「旧弹窗被关掉了」；
2. 弹窗先归零到屏幕左上角、再被搬回原文旁边（不是停在用户眼下的位置），且上次按「不遮被查词」夹出来的 `maxHeight` 被重置；
3. 宿主页原文上的高亮被撤掉重画，长度按**子词**的匹配长度重截（父词 3 字 → 高亮变 2 字）。

### 根因

嵌套查词复用了「首次查词」的完整渲染路径：`__hibikiOnLinkClick` 调 `hibikiRender(popupJson, termLen, theme)`（且不传 `anchorRect`）。而 `hibikiRender` 的职责不止「换内容」，它同时**建立弹窗几何**：

- `hibikiSelectionRects(termLen)`（`content.js:1218`）拿 `termLen` 去截 `hoshiSelection.selection`——那是**宿主页原文**的选区，点弹窗内的链接不会更新它。于是用**子词长度**截**父词选区**，得到一段与原文词无关的几何，`hibikiDrawHighlightOverlay` 按它重画原文高亮；
- 这段错误几何又当作锚点喂给 `place()`，把弹窗重新定位；定位前还会 `visibility:hidden` + `left/top = 0`（量尺寸用），定位后 `opacity` 压 0 再翻 1 重走入场淡入；
- `hibikiRender` 开头的主题分支无条件重写 host 尺寸盒（`width/maxWidth/maxHeight/zoom`），把上次 `place()` 夹的 `maxHeight` 冲掉。

数据层面的错误是：`result.bestLength` 是「**原文里**命中了几个字」的量，而嵌套查的词根本不在原文里，把它当原文选区的裁剪长度用，从一开始就是类型错配。

### 修复

把「换内容」与「建立几何」拆成两条路径，嵌套查词只走前者（语义与 yomitan 单弹窗内导航、与本实现「没有前进后退，就是嵌套查词」的既定设计一致）：

- 抽出 `hibikiRenderEntries(popupJson)`（只换内容）与 `hibikiApplyTheme(c, theme, applyBox)`（`applyBox=false` 时不碰 host 尺寸盒）；
- 新增 `hibikiRenderNested(popupJson, theme)`：只换内容 + 套颜色/行为类主题变量，不重算高亮、不重新 `place`、不重走淡入、不重写尺寸盒；
- `__hibikiOnLinkClick` 改走 `hibikiRenderNested`，并同步 `hibikiLastTerm = term`——去重状态跟着**弹窗当前显示的词**走，否则 `hibikiLastTerm` 停在父词，Shift 悬停回原词会被同词去重吞掉，用户从嵌套查词回不到原词；
- `hibikiRender` 改为复用同两个 helper，首查词行为不变。

- **[x] ① 已修复** — `tools/browser-extension/content.js`（+ `hibiki/assets/browser_extension/content.js` 镜像）
- **[x] ② 已加自动化测试** — `tools/browser-extension/nested-lookup.test.js`（5 条，vm 内真加载 `vendor/popup.js` + `bridge-shim.js` + `content.js`，带 shadow / composedPath / closest 真语义的 DOM shim）

### 测试判据与变异实测

守卫判据取「**有没有被重写**」而非「值等不等」——重新 `place()` 恰好算回同一坐标也是重新定位，值相等会假绿（首版就是这样假绿的，已堵死）。三次变异实测确认守卫有效：

| 变异 | 预期红 | 实测 |
|---|---|---|
| 去掉 `hibikiLastTerm = term` | 第 4 条 | ✅ 红 |
| 嵌套改回走 `hibikiRender` 完整路径 | 第 1/2/3 条 | ✅ 红 |
| `applyBox` 改回恒 `true`（尺寸盒仍被重写） | 第 2 条 | ✅ 红 |

### 备注

- 第 5 条守卫是**否定证据**：点 `.glossary-content` 里的 `a[href]` 走 `handleGlossaryAnchorClick` → `onLinkClick`，不会落到 `popup.js` document click 末尾的 `tapOutside` 关窗路径。也就是说「旧弹窗被关掉」不是真的走了关窗分支，而是上述「消失一次再淡入 + 跳位」造成的等效观感；这条守卫把真关窗路径一并钉死。
- 未改 `vendor/popup.js`，不涉及 popup 三镜像同步（`assets/popup` → 两处 `vendor/`）。
- 真机复测（真实浏览器里点释义里的词）尚未做，见 PR 说明。
