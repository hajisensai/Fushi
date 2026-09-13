## BUG-2196 · 阅读器把源码换行当句子分隔符，制卡拿到半截句、音频漏词
- **报告**：2026-09-06（用户：制卡「选择句子上下文」对话框截图，「当前句」是
  `shepherds abiding in the field,` —— 以逗号结尾；原话「这里加个试听？有时候断句在
  很奇怪的地方，可能会漏词，制卡压没念」）
- **真实性**：✅ 真 bug，且**已用真实 JS 逐字复现用户那一句**。
  - 根因：`fushi/lib/src/reader/reader_selection_scripts.dart` 的
    `sentenceDelimiters: '。！？.!?\n\r'` 把 `\n` / `\r` 算作句子分隔符。
  - 而 `getSentenceContext` 读的是**文本节点的 `textContent`**（`:706` / `:731`），
    它逐字保留 XHTML 源码里的换行；全文件没有一处 `innerText`，阅读器 CSS 里也没有
    `white-space: pre`。EPUB 正文普遍在源码里硬换行，于是
    `...in the field,\n keeping watch...` 被切在**逗号后的那个换行**处。
  - 唯一的减震器是 `createWalker` 的 `/^[\s　]*$/` 过滤（`:497`），它只挡**纯空白
    文本节点**（`</p>\n<p>` 之间那种），挡不住「既有可见文字又有换行」的节点——
    正是 bug 现场。
  - **复现（实测）**：用仓库既有的 node fake-DOM harness 执行真实抽取的 JS，注入
    单个 `<p>` 文本节点 `"...shepherds abiding in the field,\n keeping watch over
    their flock by night."`，在 `abiding` 上取句 →
    `"And there were in the same country shepherds abiding in the field,"`，
    **与用户截图逐字一致**。
- **为什么会「制卡压没念」**：`getSurroundingSentences` 的 `describe()`
  （`:862-866`）把句边界 `sStartOffset/sEndOffset` 转成 `normOffset/normLength`，
  这对偏移正是喂给 `miningSentenceAudioRange` 的输入。句子被切成半句 ⇒ 区间是半句 ⇒
  `CollectionAudioMatcher.findPlaybackRange` 只与更少的 cue 相交 ⇒ 裁出来的音频只有
  半句。cue 本身一直是对的（`asr_cue_builder` / `audiobook_bridge` 都只按标点切，
  不含 `\n`），错的自始至终只有 reader 这一侧。
- **仓库内部的两个反证**（说明「换行不是句边界」才是本仓库的既定语义）：
  - `reader_visual_novel_scripts.dart` 的同名表**本来就不含** `\n\r`；
  - `reader_pdf_page.dart` 早就在分句前把 `\n`/`\r` **等长**换成空格，注释原文写着
    「换行是分句符——直接分句会把每个视觉行切成一句，制卡拿到半截话」。
    也就是说同一个 bug 在 PDF 那条路上被局部绕开过，EPUB 这条没有。
- **谁依赖「换行是句边界」**：全仓逐条查过，**阅读器这条链上一个都没有**
  （歌词模式每条 cue 是独立 `.cue` 块；`text_to_epub` 把行内换行变成 `<br/>`、
  段落变成 `<p>`，DOM 文本节点里根本没有 `\n`；有声书 cue 对齐与 ASR 造 cue 都只按
  标点）。**唯一真实依赖是 Windows UIA 全局查词**（`lookup/sentence_extraction.dart`）
  —— 它拿到的是没有块级结构的裸串，galgame / 聊天窗里一行就是一句、行间常常没有
  句末标点。两侧输入模型不同，本来就不该同表。
- **[x] ① 已修复** — `worktree-fix-dict-download-error-anki-parallel`：
  - `reader_selection_scripts.dart`：`sentenceDelimiters` 去掉 `\n\r`。
  - 同一函数收尾把句子文本里的换行做**等长**替换成空格
    （`.replace(/[\n\r]/g, ' ')`）。**必须等长**：`beforeText.length` /
    `sentenceOffset` / `sStartOffset` / `sEndOffset` / `getNormalizedOffset` 的下标
    全都建立在这个字符串上，用 `\s+` 折叠会整体打乱偏移，进而毁掉喂给
    `miningSentenceAudioRange` 的 `normOffset/normLength`——那会把这个 bug 换成一个
    更难查的。手法照抄 `reader_pdf_page.dart` 的先例。
  - 三份 `selection.js` 镜像（`assets/popup/`、`assets/browser_extension/vendor/`、
    `tools/browser-extension/vendor/`）同步去掉 `\n\r`：浏览器 DOM 与 EPUB 同语义。
  - **`lookup/sentence_extraction.dart` 刻意不动**（扁平 buffer 那条路必须保留换行）。
  - 漂移守卫 `sentence_extraction_test.dart` 原本要求两张表**逐字节相等**，是过约束
    （它对本 bug 完全不敏感：两边一起错也算过）。改成「差集恰好是 `\n\r`、且方向
    固定」：reader 侧不得含 `\n`、扁平侧必须含 `\n`、除此之外任何字符不一致立刻红。
- **[x] ② 已加自动化测试**（定向批 13 文件 **105 条全绿**）：
  - `reader_get_sentence_context_boundary_test.js` 新增 **CASE 11**：用用户那句原文，
    在换行**前**（`abiding`）和**后**（`watch`）各取一次句，断言两次结果相同、都
    包含 `keeping watch`、句中不含裸 `\n`，且 `field,` 与 `keeping` 之间是**两个**
    空格——这两个空格就是「等长替换」的证据（折叠式替换只会留一个，并把后面每一个
    偏移都挪位）。Dart 驱动侧同步断言整句原文。
  - 原有 10 个特征化用例**逐字节不变**（实测：ORIGINAL 与修复后输出完全相同）。
    那些用例里的 `makeText('\n  ', …)` 看似依赖换行，其实都是纯空白节点、被
    `createWalker` 先 REJECT 掉，走不到分隔符判断。
  - **变异实测**：把 `\n\r` 加回 `sentenceDelimiters` → CASE 11 与漂移守卫当场红；
    还原后 sha256 与变异前逐字节一致。
- **[x] ② 之二：加了用户要的「试听」**（BUG-2196 ②，定向批 10 文件 **119 条全绿**）
  - `SentenceContextDialog` 底部新增试听/停止按钮（i18n × 17 语言）。
  - **播的是「这次制卡真正会写进卡片的那段音频」**：区间取
    `_miningDraft.composeAudioRange(_currentSentenceAudioRange())`，
    **与 `_prepareMiningContext` 里喂给 ffmpeg 的是同一个表达式**，所以听到什么就
    压出什么。刻意不播「当前句的 cue」——那只能证明这句有音频，证明不了裁出来的
    那段念全了，而用户报的正是后者。
  - 每次点都**重新求一次**区间：用户在这个对话框里加减上下文句的目的就是改变它，
    缓存会让试听放上一次的范围。
  - 宿主不支持（视频页等没有句级音频区间的表面）时整颗按钮不渲染；
    宿主说「这句没音频」时按钮弹回并提示，不留一个「像在放但没声音」的状态；
    取消 / 确认制卡都停播（对话框关了之后用户没有任何入口能停）。
  - 新增 `fushi/test/pages/sentence_context_dialog_preview_test.dart`（8 条）。
    **变异实测**：删掉确认路径上的 `unawaited(_stopPreview())` → 当场红；
    还原后 sha256 逐字节一致。
- **未做 / 已知缺口**：
  - **cue 内没有插值**，需要单独立案。`findPlaybackRange` 与 `_expandAroundCue`
    全程只做**整 cue 命中**（直接抄 `cue.startMs` / `cue.endMs`）。句边界修正后，
    「压到隔壁句 / 压掉一半」这类会大面积消失，但两种形态仍在：① 粗对齐（后挂音频）
    下一条 cue 可能覆盖一整段，此时无论句边界多准，拿到的都是那一整条的时间窗；
    ② cue 比句短时，`normOffset` 与 `SubtitleRematchFragment.normCharStart` 在换行
    字符上的**计数口径**是否一致尚未验证，不一致会让区间整体漂移。这两条要动的是
    `packages/fushi_audio` 的匹配层，与本条不同域，另案。
  - **真机复测未做**：本机无 Android 设备/有声书素材接入本次会话。断句这一段由
    真实 JS 执行 + 用户原句钉住，试听那一段由 widget 行为测试钉住，但「在真书上点
    试听真的出声、且与压出来的卡片音频一致」尚待用户实测。
