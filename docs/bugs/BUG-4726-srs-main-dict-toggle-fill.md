## BUG-4726 · 复习卡背面主词典收起按钮带底色并顶出词典卡圆角
- **报告**：2026-11-16（维护者应用内反馈 3bYq5GDy80，Android OnePlus CPH2747，复习卡背面「主词典的缩小有个莫名的背景」）
- **真实性**：✅ 真 bug。混合渲染释义页的宿主 CSS 给主词典收起 / 展开按钮写了 `background:var(--fc-surface-2)` 与 `margin:-3px -6px -3px 0`（`fushi/lib/src/srs/srs_card_defs_layout.dart:194-199`，修复前）：主词典分组 `.fc-dict` 顶部内边距为 0（模板 `styling.css` `.fc-dict{padding:0 var(--fc-pad)}`），40px 圆底被负外边距往上、往右推出 3px / 6px，顶出词典卡的圆角；样式也与「其他词典」行尾的纯箭头（同文件 `.fushi-srs-more-toggle`，`background:none`）不一致。
- **[x] ① 已修复** — 主词典按钮改成与「其他词典」同一套纯箭头：去掉底色与负外边距，颜色 `--fc-fg-muted`、箭头 `opacity:0.8`，只在悬停时给 `--fc-surface-2` 底色，40px 命中区不变。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_card_defs_layout_harness.mjs`（`main toggle` 用例，真实 headless Chrome）：按钮计算底色必须透明、按钮盒子不得越出主词典卡的上 / 右 / 下边。
- **备注**：同一条反馈里的「主词典收起卡住 / 词典没法缩小」「左右滑动失效」本条未修：桌面 Chrome 里收起 / 展开路径正常（同一 harness 的 `main toggle` 用例点按后主词典变矮、重排后保持收起），疑点只在 Android 平台视图的触摸投递 / 页内手势脚本，需要真机复现取证后另开 bug。设备肉眼复测待补。
