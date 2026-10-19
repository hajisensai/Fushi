## BUG-3560 · srs-review-top-band-and-phone-dict-tabs
- **报告**：2026-10-19（用户：群反馈，iPhone 复习页截图）——手机卡片背面「全部释义」里几十部词典平铺成一大片 pill，要求改成查词弹窗那样的可折叠样式；往下滑时顶栏收起了但顶上留一条白色空带不收；右上角封面被截断。
- **真实性**：✅ 真问题，三处：
  - 空带：`FushiPageScaffold` 收起页头只做位移 + 淡出、让位高度恒定（`fushi_floating_page_chrome.dart` 的 BUG-2975 设计），复习页又在卡面外套了固定 `Padding(top: 状态栏 + 页头)`（`srs_review_page.dart` body builder），页头收起后那段让位留成空带。原生 Fushi 卡面本是 Flutter `SingleChildScrollView`，完全能滚到页头底下，被「卡面是 WebView」的整体让位一并处理了。
  - 词典 pill：`compactPhone`（默认开）在窄屏触发 back.html 的页签模式 `setTabs`，把逐部折叠卡换成一排词典名 chip。
  - 封面：原生 `_MediaImage` 窄屏 84×84 `BoxFit.cover`、模板 `.fc-picture img { object-fit: cover }` 固定正方形裁切。
- **[x] ① 已修复** — 原生卡面铺到页头底下，让位高度作滚动内边距（`SrsFushiCardView.topInset`，整面 WebView 卡面仍整体让位）；删掉窄屏页签模式，窄屏统一用与查词弹窗同形的逐部 `<details>` 折叠卡（`compactPhone` 只剩长主释义收起，文案同步）；窄屏封面两侧都改为按原比例完整显示（限宽 1.5×、限高 1.4× 缩略图边长）。分支 `pr/srs-mobile-card-collapsible`。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_fushi_card_view_test.dart`：「铺到浮动页头底下」（滚动内边距 = topInset、卡面顶端无固定让位、下拉后内容进入让位区）与「窄屏封面按原比例完整显示」（320×200 样例保持 1.6 宽高比且在缩略图框内）。
- **备注**：未在 iPhone 真机 / Mac WebKit 上复测，Chromium headless 下验过模板折叠卡。
