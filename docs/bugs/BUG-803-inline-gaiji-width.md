## BUG-803 · 词典行内外字图标撑开相邻链接

- **报告**：2026-07-14（用户截图：明镜国語辞典第三版「以外」释义中的「以内」链接被推到右侧）。
- **真实性**：✅ 真 bug。沿用户本机真实词典数据解析到该行由无尺寸 SVG 外字
  `gaiji/対義語.svg` 和紧随其后的「以内」交叉引用组成；词典 `styles.css` 对外字容器声明
  `width: 15em !important; margin-inline-end: 2em`。渲染器在
  `hibiki/assets/popup/popup.js:1049-1054` 虽把无尺寸 SVG 识别为 1.2em 行内图标，但原来的
  普通内联 `width:auto` 无法胜过词典的 `!important`，容器被撑到约 15em，链接随之右移。
- **[x] ① 已修复** — 仅对带 `gaiji` 结构化标记的无尺寸 SVG，把渲染器已经选定的
  `width:auto` 提升为内联 important，守住“行内字形”的尺寸契约；普通图片、显式尺寸 SVG
  和词典其余自定义样式保持原行为。三份 popup JS 镜像同步更新（本提交）。
- **[x] ② 已加自动化与真实引擎测试** —
  `hibiki/test/utils/misc/popup_asset_behavior_test.js` 锁定外字宽度优先级，并覆盖现有图片行为；
  `hibiki/integration_test/desktop_reader_css_dom_test.dart` 在真实 Windows WebView2 中加载生产
  `dict-media.js`、`popup.js`、`popup.css` 和明镜原样的 15em 规则。实测图标宽度 24px、
  「以内」距行首 64px、内联优先级为 important，目标内全部通过。
- **备注**：Windows 隔离测试使用独立测试根，与用户运行中的 Hibiki、用户词典数据完全隔离。
