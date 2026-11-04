## BUG-4011 · macOS 查词弹窗右上角调节按钮被右边缘裁掉一半
- **报告**：2026-11-04（反馈 #SwFjAzjBqq，QQ 群机器人代提交，macOS 调试版（版本未提供）：阅读器竖排小说里查词弹窗右上角收藏 / 添加 / 调节三颗按钮中，最右的调节（「高级制卡」`.ctx-adjust-button`）只露出左半；截图未随导出，窗口宽度是否有关未确认）。
- **真实性**：❌ 未复现（页内布局层面已排除）。用 Playwright WebKit（webkit-2248，与 macOS WKWebView 同引擎）加载真 `fushi/assets/popup/popup.html` + `popup.css` + `popup.js`，注入 `advancedMiningEnabled` 与音频源让按钮组凑齐 6 颗，分别在基础层 / `html.fushi-m3e` / `html.fushi-glass-host.fushi-apple` 三套样式、视口宽 220–420px、`documentElement.style.zoom` 1 与 1.25 下测：每个 `.header-buttons` 最后一颗按钮的右缘都等于词头行右缘（视口宽 − body 右内边距 10px），`scrollWidth == clientWidth`，没有任何横向溢出；Chromium 结果一致。即弹窗页面自身不会把按钮排出视口。剩下的可能都在宿主侧（macOS 平台视图的 frame 比 Flutter 外壳宽 / 外壳裁剪 / 覆盖在右上角的 Flutter 部件），需要 macOS 真机与截图才能定位，不在页面 CSS 上硬改。
- **[ ] ①** —
- **[ ] ②** —
- **备注**：需要截图原图、窗口尺寸、界面大小 / 词典字号设置。下一步应在 macOS 上对比 `DictionaryPopupLayer` 外壳 rect 与 WKWebView 的 frame。探针脚本思路：WebKit 下渲染 `kDictStylePreviewEntries` 同形样例后量 `.header-buttons:lastElementChild.getBoundingClientRect().right` 与 `documentElement.clientWidth`。
