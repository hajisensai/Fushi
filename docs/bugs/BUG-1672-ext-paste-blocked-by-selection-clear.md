## BUG-1672 · 开着浏览器扩展时网页粘贴间歇性失效
- **报告**：2026-08-15（用户：shishamo 群报「开着插件的时候有可能不会让我粘贴」）
- **真实性**：✅ 真 bug。排查确认**不是吞按键**（全扩展无 paste/copy/cut 监听，按键表无 V 系绑定，Ctrl+V/Ctrl+Shift+V 均放行）——是**清宿主选区**害的，两条独立路径：
  1. `tools/browser-extension/content.js` 的 Shift 悬停扫描在 mousemove 时无差别 `fushiClearNativeSelection()`（TODO-1279 引入），对 input/textarea/contenteditable **零设防**。触发面：**Ctrl+Shift+V（粘贴为纯文本）按下期间 Shift 是按住态**，任何一次 mousemove 就清掉编辑器里的选区/插入点；富文本框架（Lexical/ProseMirror/Slate 等）靠 selectionchange 维护内部态，选区被 `removeAllRanges()` 抹掉后粘贴**静默丢弃**。contenteditable 的选区走 `window.getSelection()` 全裸暴露（input/textarea 不走、天然幸免）——正好解释「有可能」的间歇性；
  2. 查词弹窗开着时点输入框准备粘贴：document 级 mousedown 关窗路径 `fushiRemoveContainer` → `fushiSelection.clearSelection()` → `removeAllRanges()` 无 isCollapsed/可编辑守卫，把编辑器在自己 mousedown 里刚放好的 caret 抹掉 → 焦点在、caret 没了 → Ctrl+V 无效；右键粘贴同理（菜单按「无选区」构建）。
  3. 附带：扩展强制 DOM 包裹高亮（隔离世界 CSS Highlight 不绘制），查词兜底路径 `highlightSelection` 若落在 contenteditable 会 `extractContents/insertNode` 改写编辑器文本节点，打散其内部模型。
- **[x] ① 已修复** —（提交哈希：bf6fdce9d）新增 `fushiNodeInEditable`/`fushiSelectionInEditable`（input/textarea/isContentEditable/contenteditable 属性四判据的祖先链走查）：
  1. `fushiClearNativeSelection` 对可编辑区锚点的选区直接 no-op（普通页面清理行为不回退）；
  2. `fushiRemoveContainer` 的 `clearSelection` 调用加同守卫；
  3. DOM 包裹高亮兜底在被查词落在可编辑区时跳过；
  4. 顺带修 `video-shortcuts.js` 的 isEditable 用 `composedPath()[0]`（Shadow DOM 编辑器被 retarget 误判 → Ctrl+Shift+Z 等被快捷键抢走）。
- **[x] ② 已加自动化测试** — `tools/browser-extension/native-selection-clear.test.js` 新增：「选区落在 contenteditable 里绝不清」+「普通页面选区仍照常清理（TODO-1279 不回退）」。变异实测：去掉可编辑区守卫用例即红。
- **备注**：右键菜单/焦点抢占等次要候选未单独处理（主根因已除；复发再按档案里的排查法定位）。镜像由 sync-mirrors 同步。
