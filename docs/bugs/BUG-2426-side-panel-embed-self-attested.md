## BUG-2426 · 扩展 side-panel 的「是否被嵌入」由 URL 参数自证，省略参数即可绕过 #1295 全部加固
- **报告**：2026-09-10（合并 PR #1372 时核对两套实现差异发现）
- **真实性**：✅ 真 bug，根因 `tools/browser-extension/side-panel.js:39`（镜像 `fushi/assets/browser_extension/side-panel.js` 同处）

  审计报告 #1295 那一批把嵌入态下的两个信任根都收紧了：宿主 origin 与目标 tabId
  一律不许写在 URL 里自证，改由 SW 按 `sender.tab.url` / `sender.tab.id` 背书。
  但**进不进这个嵌入分支**，判据仍是 `/[?&]fushiEmbed=1/.test(location.search)`
  —— 那同样是嵌入方说了算的。

  `side-panel.html` 是 `web_accessible_resources`（抽屉要嵌它），所以任何站点都能
  用同一个 URL 把这份持完整扩展权限的文档嵌进自己的页面。攻击者只要**不加**
  `?fushiEmbed=1`，`EMBED` 就是 `false`，`queryActiveTab()`
  （`side-panel.js:712`）落回 `chrome.tabs.query({active: true, currentWindow: true})`，
  面板于是绑定「用户此刻真正在看的那个标签页」。跨源读不到内容，但面板本身的
  选轨 / 跳转 / 制卡按钮全在攻击者页面里，点击劫持足以借用户的手驱动受害标签页。
  换句话说：#1295 把「进门之后不许自证身份」堵死了，却把「要不要进门」留给了来客。

- **[x] ① 已修复** — `EMBED` 改由帧嵌套这一浏览器事实判定
  （`window.top && window.top !== window.self`，跨源比较被拒时 fail-closed 取 true），
  URL 参数降级为兼容合法抽屉路径的回退，不再是唯一来源。
  提交见本条目所在合并批次（`tools/browser-extension/side-panel.js` +
  `fushi/assets/browser_extension/side-panel.js` 两份镜像同改）。
- **[x] ② 已加自动化测试** — `tools/browser-extension/side-panel-embed-token.test.js`
  新增两条：「被嵌入但 URL 不带 fushiEmbed：仍须走嵌入分支，绝不回落 tabs.query」
  与顶层页负向对照。装载器新增 `embeddedFrame` 选项造帧嵌套。
  变异实测：把判据还原成旧的 `/[?&]fushiEmbed=1/` 后第一条立刻变红（9 pass / 1 fail），
  负向对照仍绿。
- **备注**：PR #1372 用另一套「SW 一次性票据」实现同一目标，其 `EMBED` 判据
  （`window.top !== window.self`）正确；该 PR 的其余三条修复 develop 已由 #1295
  等价落地，故合并时内容收敛到 develop 实现，只把这条真差异提成本修复。
  这批 JS 测试**不在任何 CI 门内**（见 `docs/agent/fast-workflow.md`），改扩展必须本地跑
  `node --test`。
