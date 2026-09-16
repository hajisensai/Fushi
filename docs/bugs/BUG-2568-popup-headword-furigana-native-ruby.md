## BUG-2568 · 查词弹窗词头振假名未与基字居中对齐（应与 hoshi 一致）
- **报告**：2026-09-16（用户：对比截图，hoshi reader vs Fushi，词 `入寮` / `にゅうりょう`）
- **真实性**：✅ 真 bug。根因 `fushi/assets/popup/popup.css:1219`（修前的
  `:where(.glossary-group, .glossary-content, .expression) ruby` 起的那组共享规则）
  + `fushi/assets/popup/popup.js:4475`（修前 `postProcessRuby` 的
  `querySelectorAll('.glossary-content ruby, .expression ruby')`）。

  **根因**不是「少了一条对齐样式」，而是词头**借用了释义体有意为之的紧凑基字方案**。
  BUG-1098 当年把 `.expression ruby` 一并塞进 `postProcessRuby` 与那组 `:where(...)`
  规则，目的是蹭到 glossary 的 em 纵向预留（这半边是对的，必须保住）。但同一组规则
  还带着 BUG-345/1778 刻意保留的紧凑：每个基字被包进 `.ruby-unit`，读音是
  `position:absolute; left:0; right:0` 的 `.ruby-rt` 盒，**宽度恒等于基字宽**，读音更宽
  时只能悬出基字。`text-align: center` 对溢出的行盒不生效，Blink 把悬出锚在基字的
  **起始边**。

  用本仓 popup.css 在无头 Blink 实测（26px 词头，`入寮`/`にゅうりょう`）：
  基字 `[10.0, 62.0]`，读音 `[10.0, 73.8]` —— 左边齐平、右侧挂出 11.8px。整词一段是
  常态（`segmentFurigana` 无法把 `にゅうりょう` 拆给 `入`/`寮`），所以这是词头的日常
  形态，不是边角。hoshi 的词头走的是浏览器**原生 `<ruby>`**：引擎把基字串撑到注音宽度
  并让两者互相居中。

- **[x] ① 已修复** — 词头换回原生 `<ruby>`，释义体保持紧凑：
  - `popup.css`：那组 `:where(...)` 规则（7 处）的作用域收回 `.glossary-group,
    .glossary-content`，不再含 `.expression`；新增 `.expression ruby { display: ruby }`
    与 `.expression ruby > rt { font-size: 0.6em }`；BUG-1098 的纵向预留改挂到
    `.expression { padding-top: 0.66em }` 自己身上（仍是 em，仍 zoom 免疫）。
  - `popup.js`：`postProcessRuby` 的选择器收回 `'.glossary-content ruby'`，词头保留
    `buildFuriganaEl` 产出的裸 `<ruby>/<rt>`；`wrapExpressionInlineKanji`（逐汉字点击
    目标）不变，仍在同一 post-pass 尾部跑。
  - 三镜像 + 两份生成的 `content.css` 同步（`sync-mirrors.mjs` + `generate-content-css.mjs`）。

  修后同一探针：基字串与读音同为 `[10.0, 73.8]`，**中心差 0.00px**，`入` `寮` 分摊读音
  宽度；`将棋`/`食べる`/`体`/`大丈夫`/`登場人物` 五例中心差均 ≤0.01px。纵向：注音落在
  预留带内 3.2px（修前的裸原生 ruby 会向上溢出 4.0px 被 `.expression-scroll` 裁掉；实测
  `line-height: 1.7` / `2.0` 都顶不住，只有 em padding 行）。振假名字号不变（0.6em =
  26px 词头下的 15.6px）。

  提交：`83f079b0b6d`

- **[x] ② 已加自动化测试** —
  - `fushi/test/pages/popup_headword_native_ruby_bug2568_test.dart`（新增）：词头声明
    `display: ruby`；`:where(...)` 共享作用域不得再含 `.expression`；`postProcessRuby`
    不得再扫词头 ruby；词头注音字号用 `ruby > rt` 子代组合器限定（与注音盒结构互斥，
    不会与 `.ruby-rt` 的 em 相乘）且与释义体同值。
  - `fushi/test/pages/popup_headword_ruby_reserve_bug1098_test.dart`（改写）：BUG-1098 的
    **不变量**（词头有 em 纵向预留、预留带 ≥ 注音字号、注音字号非硬编码 px、
    `user-select:none` 保住、三镜像与 content.css 同步）按新机制重新守，不再钉死当年
    那一种实现。

- **备注**：
  - 影响面仅**查词弹窗词头**（`.expression`）。释义体逐字 ruby 的紧凑基字
    （BUG-345/722/850/1778/1898）与其守卫**原样保留**——两个面要的几何本来就不同。
  - 附带效果：`登場人物` 这类相邻两段注音在原生 ruby 下各自把基字撑开，BUG-850 的
    「相邻读音糊成一团」在词头上结构性不可能发生。
  - 未覆盖：悬浮词典页 `dictionary_popup_native.dart` 的 `_FuriganaText`（Flutter 渲染，
    不是本次截图里的表面）。它本来就是「读音居中于基字之上」，只是不撑开基字。
  - WebKit（iOS/macOS WKWebView）未在本机实测；原生 `<ruby>` 正是 hoshi 在 iOS 上的
    渲染路径（用户截图即 iPhone），而 BUG-1487 记录的 WebKit 坑（把 `<rt>` 的
    `position` 强制重置为 `static`）恰恰只影响**绝对定位**方案，原生 ruby 不碰它。
