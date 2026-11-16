## BUG-4734 · 复习页 Fushi 卡片释义里的词典插图点按不能放大
- **报告**：2026-11-16（用户：维护者，应用内反馈 w4RAto8R0x「复习页释义里的图片过小且点击不能放大」）
- **真实性**：✅ 真 bug，两层根因叠在一起：
  1. **释义面没装点图脚本**：复习页给整面卡传了 `onImageTap: _viewCardImage`（`fushi/lib/src/pages/implementations/srs/srs_review_page.dart`），但 Fushi 卡片的释义区在 `fushi/lib/src/pages/implementations/srs/srs_fushi_card_view.dart` 的 `_defsFace` 另建一面 `SrsCardFace`，逐字段手抄宿主回调时漏了 `onImageTap`（还漏了 `onZoomWheel`：Ctrl+滚轮落在释义 WebView 上不缩放卡面）；`srs_card_face.dart` 只在 `onImageTap != null` 时注入 `kSrsCardImageTapScript`。
  2. **页内判据不认词典插图**：BUG-2825 起导出照上游 `_setImageData` 把插图写成 `<a class="gloss-image-link" href="<媒体文件名>"><span class="gloss-image-container">…<img class="gloss-image"></a>`（`fushi/assets/popup/popup.js` 导出分支 `node.setAttribute('href', filename)`）。点它时 `kSrsCardLinkScript` 在捕获阶段把它当查词链接：`preventDefault()` 后按链接文字查词，文字为空就返回；随后冒泡阶段的 `kSrsCardImageTapScript` 因 `e.defaultPrevented` / `closest('a[href]')` 直接不收。所以光补第 1 层，BUG-2825 之后制的卡点插图仍没反应，只有旧版导出成 `<span>` 的卡和裸 `<img>` 有效。
- **[x] ① 已修复** —
  - `SrsCardFace.derived(...)`：派生面只按 required 参数给页面自身的内容 / 版式 / 度量 / 宿主样式 / 自动播放 / 选区 / 发音上报，键盘桥、页面缩放与 Ctrl+滚轮缩放、来源链接、发音、卡面手势、点图放大一律沿用整面卡；`_defsFace` 改用它，不再逐字段手抄。
  - `kSrsCardLinkScript`：`a.gloss-image-link` 只拦默认导航（href 是媒体文件名，放行会把卡面外壳导航走），不查词。
  - `kSrsCardImageTapScript`：点在 `a.gloss-image-link[href]` 图片盒里任何位置（img、底色层、占位层）都认作点这张图，取盒里 `<img>` 的 `currentSrc` 交给复习页的全屏查看；其他链接里的图、`onclick` / `button` 里的图、右键照旧不收。
- **[x] ② 已加自动化测试** —
  - `fushi/test/srs/srs_card_image_size_test.dart`「词典插图链接（a.gloss-image-link）点按放大」：node 里同时跑生产常量 `kSrsCardLinkScript`（捕获）+ `kSrsCardImageTapScript`（冒泡），按 popup.js 导出结构搭最小 DOM，一次点击走完两段：点 img / 底色层都回传图片地址且拦导航；查词链接里的图仍查词，onclick 里、卡外、右键不收。修复前红（无回传）、修复后绿。
  - `fushi/test/srs/srs_fushi_card_view_test.dart`「窄 / 宽版式释义面沿用复习页的点图放大与 Ctrl+滚轮缩放回调」：修复前 `onImageTap` / `onZoomWheel` 为 null 必红。
- **备注**：
  - 真机 / 模拟器上没有复测原始失败路径（本轮不做真机验证）；三种版式（narrow / wide / 整面 WebView auto）共用同一份页内脚本，判据与版式无关，已由 node 双脚本测试覆盖。
  - 「图片过小」部分没改默认尺寸：插图大小是词典自己写的（结构化内容 `preferredWidth`，制卡导出时内联成图片盒的 px / em 宽，与查词弹窗同尺寸），补上点图放大后与查词弹窗一致（原尺寸 + 点按放大）。「卡面图片大小」设置的 `.card img` 规则（`srsReviewImageSizeCss`）压不动词典图片盒的内联宽度，`large` 档的 `width:100%` 还会把释义里的行内小图标撑满栏宽。要不要让词典插图默认放大是 UI 取舍，已写进拍板台（条目 `w4RAto8R0x`，建议「以后」，见 docs/agent/decision-board.md）。
