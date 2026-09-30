## BUG-2799 · Mac/iOS 分页段落之间列距/行距比段内窄（振假名页顶预留被书样式压掉一半）
- **报告**：2026-09-29（用户：「振假名的问题修复了后现在行高之间不一致了」，截图为 iOS 竖排分页：同一段落内列距一致，段落交界处（「…思案顔になる。」→「「雪ノ下は…」）明显变窄）
- **真实性**：✅ 真 bug（WebKit 分页专属，取决于书的 CSS）。根因 `fushi/lib/src/reader/reader_content_styles.dart` 的 `_webKitPaginatedRubyReserveCss`（BUG-2761）：页顶注音预留由两半组成——`p { padding-block-start: R }` 与 `p::after { margin-block-end: -R }`，页中两者相抵。阅读器样式表注在章节 `<head>` 末尾（书样式之后），但正的一半没有 `!important`，书里更高权重的 reset（`.main p { padding: 0 }`、`p.class`、inline style 等）会把它压掉；负的 `p::after` 书几乎不碰、照常生效——每个段落边界净少 R。
  - 截图量值：段内列距约 155–160px、段落交界约 125px，比例 0.80；行高 1.65 时 R = 0.325em，(1.65 − 0.325) / 1.65 = 0.803，吻合。
  - 复现（headless Chrome，Blink 与 WebKit 边距折叠规则一致；书样式 `.main p { margin:0; padding:0 }` + 生产预留 CSS，竖排 20px、行高 1.65）：修前段内列距 33px、段落交界 26.5px（0.80）；两半都 `!important` 后全部 33px。
  - 排除项：阅读器自身 CSS 无任何针对 `p` 的 padding 规则；负边距与下一段上边距的折叠只影响「书的段落边距为负」的少见情形，与本截图不符。
- **[x] ① 已修复** — 预留两半都 `!important`（`padding-block-start`，`p::after` 的 `content` / `display` / `margin-block-end`），同进同退；代价是书给 `p` 的块首 padding（极少见）在 Apple 分页下被 R 取代。
- **[x] ② 已加自动化测试** — `fushi/test/reader/vertical_ruby_line_box_contain_guard_test.dart`「BUG-2799」：iOS / macOS × 横排 / 竖排分页生成的正文 CSS 里，块首预留与 `p::after` 的三个声明都必须带 `!important`。变异验证：去掉 padding 的 `!important` 该用例变红。
- **备注**：用户那本书的 CSS 本机没有，未逐字确认是哪条书规则压掉了 padding；比例吻合与 headless 复现支持这一根因。未在 iOS 真机 / 模拟器阅读器本体复测。
