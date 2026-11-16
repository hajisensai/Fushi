## BUG-4711 · srs-fushi-defs-image-tap
- **报告**：2026-11-16（用户：维护者，应用内反馈 w4RAto8R0x「复习页释义里的图片过小且点击不能放大」）
- **真实性**：✅ 真 bug。复习页给整面卡传了 `onImageTap: _viewCardImage`（`fushi/lib/src/pages/implementations/srs/srs_review_page.dart:2696`），但 Fushi 卡片的释义区在 `fushi/lib/src/pages/implementations/srs/srs_fushi_card_view.dart:1331`（`_defsFace`）另建一面 `SrsCardFace`，逐个抄字段时漏了 `onImageTap`；`srs_card_face.dart:2513` 只在 `onImageTap != null` 时注入点图脚本 `kSrsCardImageTapScript`，所以释义 WebView 里的词典插图（导出的 `<a>` 无 href，脚本本可接住）点了没反应。BUG-3703 只处理了原生 `_MediaImage` 与整面 WebView 卡。
- **[x] ① 已修复** — `_defsFace` 带上 `onImageTap: widget.face.onImageTap`：词典插图点按走复习页同一个可缩放的全屏查看。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_fushi_card_view_test.dart`「窄 / 宽版式释义面带上复习页的点图放大回调」：断言两种版式的释义面都带回调且调用落到复习页。修复前红、修复后绿。
- **备注**：「图片过小」部分没改默认尺寸：插图大小是词典自己写的（结构化内容 `preferredWidth`，制卡导出时内联成图片盒的 px / em 宽，与查词弹窗同尺寸），补上点图放大后与查词弹窗一致（原尺寸 + 点按放大）。「卡面图片大小」设置的 `.card img` 规则（`srsReviewImageSizeCss`）没接进释义面：它压不动词典图片盒的内联宽度，`large` 档的 `width:100%` 还会把释义里的行内小图标撑满栏宽，`75vh` 在跟内容等高的窄版式释义 WebView 里也不是屏高。要让词典插图默认放大需另定规则（按图片盒而非 `img`），属于 UI 取舍。
