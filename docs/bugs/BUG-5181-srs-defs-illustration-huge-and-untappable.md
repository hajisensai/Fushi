## BUG-5181 · 复习卡释义里的词典插图巨大且点不开
- **报告**：2026-11-22（用户：维护者，应用内反馈 qBykM9EeLw「雷霆大图片，而且没办法点击打开图片」，Android OnePlus，小学館例解学習国語「ネクタイ」）
- **真实性**：✅ 真 bug，三层根因（headless Chromium 按 Android WebView 默认最小字号 8px 复现，用词典原数据 images/700e5a6424.avif 239×320 + 原 styles.css）：
  1. **插图声明宽度放大 8 倍**（9bee91dbc6 引入）：`fushi/lib/src/srs/srs_card_defs_layout.dart` 旧 `kSrsDefsIllustrationScript` 的 `px()`（旧 :626）用「em 数 × `getComputedStyle(box).fontSize`」算导出图片盒 `font-size:1px; width:239em` 的宽度。Android WebView 的 `minimumFontSize`（默认 8）把计算字号报成 8px，排版里 em 仍按 1px，于是 `--fushi-srs-illus-w` 成了 1912px。
  2. **表格单元格里百分比循环**：该词典把插图和竖排图注放进两格表（`table-layout:auto`），旧 CSS 用 `max-width:100%` 拦不住 1912px 的链接（单元格按内容撑到 1920px），图片盒撑出栏外，屏幕上只露出放大后插图的左上角（白底 + 右缘头发的黑色模糊轮廓，即截图）；「放大」档的 `width:min(100%, calc(…))`（旧 :608）在这种单元格里直接被算成 0 宽，插图消失。
  3. **点不开**：`fushi/lib/src/pages/implementations/srs/srs_card_face.dart` 旧 `kSrsCardImageTapScript`（旧 :788 `closest('a.gloss-image-link[href]')`）与 `kSrsCardLinkScript` 只靠 class 认插图链接，而制卡导出（popup.js `inlineStructuredContentExportStyles`，BUG-2825 起）早把 `gloss-*` class 换成内联样式剥掉了，BUG-4734 的修复对 2026-10 后制的卡一直不生效：点击被当成查词链接 preventDefault 后无事发生。
  - 分诊推测「盒内 img / 遮罩没跟盒子缩放」不成立：导出的 img 本来就是绝对定位铺满盒子，实测 img 与盒子同尺寸；真正失控的是盒子本身的宽度。
- **[x] ① 已修复** —
  - `kSrsDefsIllustrationScript`：声明宽度改由盒子里一个不可见的绝对定位探针按同一长度排一次再量（`len()`，`srs_card_defs_layout.dart:646`），取排版本身的宽度；新增 `__fushiSrsSizeIllustrations` / `avail()`（:708）量每张插图能占的栏宽（穿过行内 / 表格结构到第一个块级容器，扣掉同一行其余单元格与本格内边距），写进 `--fushi-srs-illus-avail`；排版脚本在分列前后各调一次，插图载入、`<details>` 展开时补量。
  - `srsDefsIllustrationCss`：链接上限改成 `max-width:var(--fushi-srs-illus-avail, 100%)`，「放大」档宽度去掉 `min(100%, …)`，宽度里不再出现循环百分比。
  - 新增 `kSrsGlossImageLinkJs`（`srs_card_face.dart:786` `glossImageLink`）按导出结构认插图链接（相对文件名 href + 首个子元素是装着 img 的 span，旧版 class 照认），链接脚本与点图脚本共用。
- **[x] ② 已加自动化测试** —
  - `fushi/test/srs/srs_defs_illustration_chrome_test.dart` + `.js`：真 headless Chromium、最小字号 8px，模板 CSS + 释义插图样式 / 脚本 + 排版脚本 + 链接 / 点图脚本，三档图片大小 × 两种导出形态，断言声明宽度、图片在盒内、盒子与图注不出栏、各档宽度、点图 / 点盒内占位层交给宿主。还原修复后三档全红。
  - `fushi/test/srs/srs_defs_illustration_test.dart`：node 桩加长度探针，新增最小字号用例与载入后补量用例；`fushi/test/srs/srs_card_image_size_test.dart`：新增无 class 现行导出的点按用例。还原修复后均红。
- **备注**：未在真机复测（本轮无设备）；Android WebView 的最小字号行为由 Chromium 偏好 `minimum_font_size=8` 模拟。释义页与版式（narrow / wide）共用同一份页内脚本，非小说阅读器类修复，不涉及三种 view mode。
