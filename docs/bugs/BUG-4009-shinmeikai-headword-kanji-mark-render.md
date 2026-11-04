## BUG-4009 · 新明解国語辞典词头表外字标注渲染异常
- **报告**：2026-11-04（反馈 #Xr7RRZ3zjm，QQ 群机器人代提交，Android 平板；「新明解国語辞典 第八版」词头「こい①(コヒ)【鯉】」处的生僻汉字标注与排版不正常，三省堂 / 明镜 / 新选 / 小学馆正常；无日志。截图第二轮单独导出）。
- **真实性**：✅ 真 bug。第一轮因截图未随导出判为未复现；第二轮拿到截图 `Xr7RRZ3zjm_s0.jpg`：【鯉】上方的表外字标记「︿」没有浮在汉字上方，而是压在汉字上半截。
  - **标记的结构**（据 jitenbot 源码，镜像 https://github.com/konstantindjairo/jitenbot ，新明解第八版 Yomitan 版由它转换）：表外字 / 表外音訓分别写成 `<ruby>鯉<rt><span style="font-size: 2em">︿</span></rt></ruby>` / `︽`。作者按**原生 ruby** 假设：rt 0.5em × 2em = 基字 1em。
  - **根因**：弹窗把 ruby 拆成 `.ruby-unit > .ruby-rt > rt` 三层手工模拟，`.ruby-rt` 盒 0.6em，`.ruby-unit` 预留带 `padding-top: 0.66em`（按一行注音字号定死）。BUG-1897 的归一规则 `fushi/assets/popup/popup.css:1764`（`:where(.glossary-group, .glossary-content) .ruby-rt rt { font-size: 1em !important }`）只归一了 `<rt>` 本身，**rt 的后代**仍按行内 2em 相乘，等于基字 1.2em，从带顶向下长出 0.54em 盖住汉字。
  - **实测**：Playwright WebKit webkit-2248 与 Chromium，真 popup.html/css/js，15px 正文。修前标记盒下沿压进基字 8.1px（zoom 1.5 时 12.15px）；修后为 -0.9px（zoom 1.5 时 -1.35px），与普通振假名一致，落在预留带内。
- **[x] ① 已修复**（见本条提交）— `fushi/assets/popup/popup.css:1778` 新增 `:where(.glossary-group, .glossary-content) .ruby-rt rt * { font-size: 1em !important }`，与 BUG-1897 同一原则：注音几何归弹窗所有，rt 内部的字号一并归一，颜色 / 字重等非几何声明不动。两份浏览器扩展 vendor `popup.css` 同步，`content.css` 由 `tools/browser-extension/scripts/generate-content-css.mjs` 重新生成。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_ruby_rt_descendant_scale_guard_test.dart`：三份 popup.css 都必须有该规则、是 `1em !important`、且不夹带颜色 / 字重 / 定位声明。布局只能在真引擎里量，单测环境没有，所以 CSS 守卫是最强可落地层；WebKit 探针结果记在上面。
- **备注**：同一根因也是 BUG-4010（【漁る】的「︽」）。未在 Android 真机复测（本轮没有设备），探针用的是与 Android WebView 同属 Blink 的 Chromium，以及 WebKit。
