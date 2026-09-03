## BUG-1941 · 点字幕行内空白不跳转只弹未识别提示
- **报告**：2026-08-29（用户：截图，点击空白位置不会跳转到这句，只出现「未识别到可查词文字」）
- **真实性**：✅ 真 bug。根因 `tools/browser-extension/side-panel.js` 字幕行的 click 处理：
  `.subtitle-text` 是块级元素、占满整行宽度，点文字右侧的空白同样命中它；而处理器**先无条件
  `stopPropagation()`** 再去取词——行的「点空白=跳转」就在被吞掉的冒泡路径上。取词失败只剩
  一条 toast，于是那一击既查不了词也跳不了。次因：`lookupAtPointer` 把「显式手势」与「取不到
  词要提示」压在同一个参数上，点击被迫两者都要。
- **[x] ① 已修复** — `side-panel.js:756`：取到词才 `stopPropagation`（`lookupAtPointer` 返回
  是否真发起查词），取不到就把这一击让回给行的 seek；`lookupAtPointer(pointer, {explicit,
  announceMissing})` 拆成两个开关，点击只要 `explicit`。
- **[x] ② 已加自动化测试** — `side-panel-lookup-on-page.test.js`「点行内空白（取不到词）跳转
  到这句」+「点文字仍是查词，且不冒泡成跳转」；`side-panel-performance.test.js` 的源码守卫同步
  更新。变异实测：把 `if (started)` 去掉即变红。
- **备注**：Shift 悬停路径仍保留「未识别到可查词文字」提示（那时没有跳转语义可让）。
