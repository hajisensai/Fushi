## BUG-718 · VN模式按字符偏移恢复时FOUC遮罩未移除致整页空白
- **报告**：2026-07-10（用户：Windows 桌面，视觉小说/VN 模式「遮罩没去掉、一直没画面」）
- **真实性**：✅ 真 bug（Windows 桌面离屏真机复现 + uncloak 因果实验坐实，非假设）。根因 `hibiki/lib/src/reader/reader_visual_novel_scripts.dart`（VN shell boot 块调用晚定义的 `restoreToCharOffset` shim）。

### 症状
VN（视觉小说）模式下，凡是**有保存阅读进度**的书（几乎所有读过的书，恢复走 `restoreToCharOffset`），一进 VN 就整页空白（奶油色背景，无文字无图）。冷开在第 0 章（`restoreProgress(0)`）则正常——这是判据的关键 A/B。

### 根因（决定性证据）
空白 = 注入在 `<head>` 的 FOUC 遮罩 `<style id="hoshi-cloak">body{visibility:hidden!important}</style>`（`hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:309`）**从未被移除**。它本应在 reader setup 脚本尾部移除（`webview.part.dart:1278-1279` 的 `var cloak=document.getElementById('hoshi-cloak'); if(cloak)cloak.remove();`）。

因果链（`reader_visual_novel_scripts.dart` 生成的 VN shell 内嵌在 `_buildReaderSetupScript` 的外层 setup IIFE 的 `$paginationJs` 处，`webview.part.dart:547`）：
1. `window.hoshiReader = {…}` 对象字面量**只定义了 `restoreProgress` / `jumpToFragment`，没有 `restoreToCharOffset`**。
2. boot 块的 `if (document.readyState === 'complete') { … $initialRestoreScript }` 在 setup 脚本注入（`onLoadStop`，此时 readyState 恒为 complete）时**同步**执行；对有进度的书 `$initialRestoreScript` = `window.hoshiReader.restoreToCharOffset(<offset>);`。
3. 但 `restoreToCharOffset` 只由**其后的独立 host-compat shim IIFE** 挂上（原 `reader_visual_novel_scripts.dart` boot 块之后）。同步调用时它 **undefined → TypeError**。
4. 该同步抛错沿栈上抛，**中断整个外层 setup IIFE**，使其后的 `$caretJs` / `$furiganaJs` / 手势注册 / **尾部的 `cloak.remove()` 全部不执行** → body 保持 `visibility:hidden` → 整页空白。

`initialize()` 在抛错前已被调用，其异步链用 `initialProgress`（≈0.85）渲染出正确屏（复现里 `currentScreenIndex=582`、`screenTextLen>0`、图片都加载成功、`notifyRestoreComplete` ~1s 清了 Dart 侧遮罩）——所以内容其实**已渲染**，只是被没清掉的 cloak 罩住。**决定性因果实验**：`[VN-UNCLOAK]` 单独 `document.getElementById('hoshi-cloak').remove()` → 正文 innerText `0→35`、body `hidden→visible`、截图从纯空白→竖排文字全显。证明空白与 init/图片/渲染全无关，纯粹 cloak 未移除。

冷开第 0 章走 `restoreProgress(0)`（对象字面量真方法，不抛）→ setup IIFE 走到尾、cloak 正常移除 → 正常，与 A/B 完全吻合。注意此路径连 caret/振假名/手势也一并被抛错毁掉，不只 cloak。

### 修复（根因层，消除特殊情况）
把 VN shell 的 boot 块（`window.addEventListener('load', …)` + `if (document.readyState==='complete') …`）**移到 host-compat shim IIFE 之后**，使 `restoreToCharOffset`（及其余 shim）在 boot 调用它之前就已定义 → 不再抛错 → 外层 setup IIFE 走到尾、cloak 正常移除。并给 boot 的 restore 调用套 `try/catch`（记录 `[HoshiVN] boot restore failed`），防止未来任何 restore 错误再次连累后续 setup 与 cloak 移除。仅 VN 模式改动，分页/连续零变化。

- **[x] ① 已修复** — `hibiki/lib/src/reader/reader_visual_novel_scripts.dart`：boot 块移至 shim IIFE 之后 + try/catch 包裹。提交哈希见分支 `worktree-vn-mask-stale-restore`。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/vn_shell_smoke_test.dart`：新增 `BUG-718`——断言（含 `initialCharOffset>=0` 的 shell）里 `restoreToCharOffset` 的 shim 定义（`vn.restoreToCharOffset = `）出现在 boot 的 `window.hoshiReader.restoreToCharOffset(<offset>)` 调用**之前**，且 boot restore 被 `try {` 包裹。源码/生成器守卫层（headless WebView 跑不到真实 cloak 移除时序）。
- **备注**：真机 Gate 已在 Windows 桌面离屏复现并（待）复测——读到一半的书切 VN，应立即显文字/图片，无常驻空白、无需 uncloak。与 [BUG-516](BUG-516-vn-mode-mask-tiny-image.md)（VN initialize fail-open）同属 VN 遮罩家族但根因不同（本条是 restoreToCharOffset shim 定义时序 → cloak 未移除）。
