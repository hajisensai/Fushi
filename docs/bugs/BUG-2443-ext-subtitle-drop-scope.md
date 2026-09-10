## BUG-2443 · 浏览器扩展：任何网页拖文件都弹整屏「松开以加载字幕」
- **报告**：2026-09-11（用户：拖放导入字幕的范围太大，影响正常使用）
- **真实性**：✅ 真 bug。根因两处，都在拖放导入路径上：
  - `tools/browser-extension/subtitle-panel.js:540/551` — `dragover`/`drop` 的门控只看
    「拖的东西里有 Files」，不看这一页有没有 `<video>`。内容脚本 `matches: ["<all_urls>"]`，
    于是网盘上传、邮箱附件、图床等任意网页拖文件都被 capture 阶段 `preventDefault` 接管，
    并把 `dropEffect` 改成 copy。
  - `tools/browser-extension/scripts/content-css-overlay.css` — `#fushi-subtitle-drop-hint`
    用 `inset: 24px` 的整屏虚线框，一拖就糊住半个屏幕。
- **[x] ① 已修复** — 门控收成单一判据 `dragDropActive() = st.dragDropEnabled && !!videoEl()`，
  无视频的页面连 `preventDefault` 都不做（宿主页拖放行为零改动）；提示改成右上角
  `top/right: 16px` 的限宽小角标（`max-width: min(60vw, 320px)`，`pointer-events: none` 不变）。
  CSS 真源是 `scripts/content-css-overlay.css`，改后跑 `generate-content-css.mjs` + `sync-mirrors.mjs`
  重生成 `vendor/content.css` 与 `fushi/assets/browser_extension/` 镜像。
- **[x] ② 已加自动化测试** — `tools/browser-extension/subtitle-panel.test.js` 三条：
  无视频页 dragover/drop 均不 `preventDefault` 且不挂提示；有视频页接管并挂唯一提示、dragleave 即摘；
  CSS 守卫钉住「右上角锚点 + 限宽 + 不得再出现 inset/left/bottom」。
- **备注**：node 测试不在 CI 真单测门内，改扩展必须本地跑 `node --test tools/browser-extension/subtitle-panel.test.js`。
