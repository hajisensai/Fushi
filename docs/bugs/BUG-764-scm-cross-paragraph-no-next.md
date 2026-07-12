## BUG-764 · 制卡「后加一句/前退一句」跨段落无反应（不支持跨 `<p>`）
- **报告**：2026-07-12（用户：qqbotxiaoxiao，原话「有时候按下句没反应，是不支持跨行吗」）
- **真实性**：✅ 真 bug（用户「不支持跨段」的怀疑成立）。根因 `hibiki/lib/src/reader/reader_selection_scripts.dart` 的 `charAt`（原 :968）与对称的 `charBefore`（原 :953）：二者用 `findParagraph(node)`（当前 `<p>`/块级元素）作 `createTreeWalker` 的 root 容器，`walker.nextNode()`/`previousNode()` 被限制在当前块子树内、走不出 `<p>`。当上下文尾部到达段末，`charAt` 返回 `null` → `getSurroundingSentences` 的 next 循环 `break` → 跨段落取不到下一句。宿主每次整体重解析、`renderPreview` 又把镜像重置回真实句数 → 点「后加一句」计数与预览不变 → 感知「没反应」。（段**内** `<br>`/空白节点由 createWalker REJECT 能跳过，真正卡住的是跨 `<p>`。）
- **[x] ① 已修复** — `charAt`/`charBefore` 的 walker 根改用 `document.body`（与 `collectRangeBetween` 同一套 document 级 walker，同样 REJECT 振假名/空白），故「相邻句种子字符」能跨块。句子自身仍由 `getSentenceContext` 的 `findParagraph` 限定在其块内，只放宽「找相邻句起点」到跨段。配套 UX：`assets/popup/popup.js` `renderPreview` 在宿主返回句数 < 请求数（到边界）时禁用对应「+」，给出诚实反馈（三镜像同步）。提交：<待填>
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_surrounding_sentences_cross_block_guard_test.dart`（源码扫描守卫：`charAt`/`charBefore` 用 `createWalker(document.body)` 而非 `findParagraph`）+ `sentence_context_modal_guard_test.dart` 补 popup.js 边界禁用「+」。
- **备注**：真机验证待用户（跨段落连续「后加一句」能加到下一段的句子；到真正文尾时「+」置灰）。
