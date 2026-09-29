## BUG-2763 · 浏览器扩展嵌套查词子层内容只占外框 1/zoom，底部右侧留大块空白
- **报告**：2026-09-29（用户：「浏览器嵌套查词有问题」，附录屏：bookmeter.com 上查「勘ぐる」后在弹窗里再查「ぐる」，子层外框随内容长高，但词条区只占上面约 80%、右侧也短一截，下方一大块黑底空白）
- **真实性**：✅ 真 bug（根因 `tools/browser-extension/nested-popup.js` render：`host.style.zoom = zoom` 后又写 `host.style.width/height = (100 / zoom) + '%'`。百分比尺寸按包含块解析、**不乘 zoom**——Chrome 154 headless 实测父盒 400×300、`zoom:1.25` 下 `80%` 渲染为 320×240、`100%` 渲染为 400×300。外框由 `nested-popup-host.js` `place()` 按渲染尺度（基准 × zoom）定好，内容却只剩 1/zoom：用户 zoom≈1.25 时正好剩 80%，与录屏第 9/10 帧的外框/内容比吻合）
- **[x] ① 已修复** — `b89df531f21`：host 宽高改回 `100%`（zoom 只负责把基准尺寸放大，填满外框靠百分比本身）；`tools/` 与 `fushi/assets/browser_extension/` 镜像同步
- **[x] ② 已加自动化测试** — `tools/browser-extension/nested-popup-frame.test.js`「render forwards shared CSS…」断言 zoom 1.25 时 host 宽高为 `100%`（原先钉死的 `80%` 正是缺陷本身）
- **备注**：同一 PR 顺带让扩展弹窗跟随 app「词典字体」设置（用户同时提的需求，不是本 bug 的一部分）。
