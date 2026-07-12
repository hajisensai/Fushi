## BUG-999 · app外查词第二张卡永远不可见——滑出class泄漏在复用根壳上
- **报告**：2026-07-12（用户：「0.6s的弹窗我还看不见吗，他根本没出现在屏幕上」「我现在看不见弹窗，除了第一次」，build 7532）
- **真实性**：✅ 真 bug（根因 `hibiki/assets/popup/global_lookup_host.js`：`dismissRootWithSlide` 只 `classList.add('global-lookup-dismissing')`，全文件无任何 remove；根壳跨查词复用（TODO-1095 stable root id））
- **[x] ① 已修复** — `beginLookup` 对复用根壳 `classList.remove('global-lookup-dismissing')` + 复位 `dismissingRoot` 锁（分支 worktree-fix-lookup-gap-clickthrough，与 BUG-744 同 PR#51）
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/global_lookup_host_test.mjs` R4（复现下毒→断言 beginLookup 解毒→新渲染不复发）
- **编号**：原始修复以 BUG-745 提交（分支 worktree-fix-lookup-gap-clickthrough）；745 号在 develop 已被 BUG-745-merge-import-deleted-book-empty-orphan 占用，补合时顺延至 999（代码/测试注释保留 BUG-745 作原始修复标识）。
- **备注**：与 [BUG-744](BUG-744-lookup-window-floor-region-eats-clicks.md) 是同一次真机现场分出的两个独立根因；两者叠加才是完整症状。

### 根因

TODO-890（86be9b6b4，6-27）给根卡加了滑出关闭动画：`dismissRootWithSlide` 往根壳
`classList.add('global-lookup-dismissing')`（CSS：`translateX(120%)` + `opacity:0`），
等 transitionend 再 post dismiss。**但这个 class 从来没有任何代码移除**，而根壳是
跨查词复用的（TODO-1095：root iframe/shell 稳定 id、只复用不重建）。

于是会话内第一次走 JS 滑出路径关卡之后：

- 之后每一次查词，Dart/native 全部正常（lookupText → searched → showAt →
  popupRendered → overlaySize → reveal 日志齐全），
- 但卡片渲染在一个「已滑出窗外 120% + 全透明」的壳里——**屏幕上永远什么都没有**。

触发面被 TODO-1345（BUG-744 的全屏 floor 窗）放大成必现：窗口≈全屏后所有
点外关卡都落在窗内 → 全走 JS 滑出路径 → 会话第一次关卡即「下毒」。7-9 之前
窗口只有卡片大小，点外多走 native 钩子 Hide（不加 class），所以极少复现。

用户描述的「闪一下消失/不在正常位置」= 那 200ms 横向滑出动画本身；
「除了第一次全都看不见」= 下毒后的必然结果。

### 修复

`global_lookup_host.js` `beginLookup`（每次新查词、renderStack 之前必经的
复位点）：对复用根壳 `classList.remove('global-lookup-dismissing')`，并复位
`dismissingRoot` 锁（防被新查词打断的滑出留下卡死的 latch）。窗口此刻还在
屏外/隐藏，摘 class 无可见副作用。

### 待验证（真机）

- 面板点词 → 卡片出现；点外关掉；**再点词 → 第二张卡正常出现**（原来必黑）。
- 连续查 N 次全部可见；关闭动画（滑出）本身仍正常播放。
