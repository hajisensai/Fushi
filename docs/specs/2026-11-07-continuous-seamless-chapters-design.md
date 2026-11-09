# 连续模式章节无缝衔接（设计）

反馈 R7k887yaJI 的第③条：滚动（continuous）模式下章与章之间是割裂的，滚到章末必须「拉过边界 → 整章重载」才能看到下一章。PR #3036 已经做了①斜滑和②切章阻尼，并在 PR 描述里给出了③的拆解。本文是③的落地设计。功能以设置开关形式提供（默认关），**关闭时的行为与现在逐字一致**，翻页（paginated）和 VN 模式完全不受影响。

## 0. 约束与现状

- 现在是**一章一个文档**：跨章走 `_navigateToChapter*` → `loadUrl`。引擎（`buildNodeOffsets`、`_textIndex`、字符偏移、`ReadUnitLedger`、句音频 cue、查词选区、收藏 / 搜索高亮、`ReaderPosition{chapter, charOffset}`）都默认「当前文档 = 当前章」。页面里读 `_currentChapter` 的地方超过 100 处。
- 引擎里的 TreeWalker 一律以 `document.body` 为根（`reader_pagination_scripts.dart` 15 处、`reader_selection_scripts.dart` 22 处，caret / 高亮 / 有声书桥也各有几处）。如果把邻章正文直接塞进 body，这些 walker 全都要改成跳过邻章，漏一处偏移就会错。
- 章节 HTML 由拦截器（`_chapterHtmlBytes`）现场净化后交给 WebView，同源 `fetch(chapterUrl)` 拿到的就是 WebView 加载时用的同一份字节（带 `#fushi-reader-style` 与 cloak）。

## 1. 核心模型：活动章在 light DOM，邻章在 Shadow DOM

文档里同时挂最多 3 章：`[上一章, 活动章, 下一章]`。

- **活动章**的正文留在 `document.body` 的 light DOM 里，引擎的所有索引只覆盖这一章。所以 `charOffset`、进度、可见区间、学习单位、查词选区、高亮、cue 依然是**活动章的章内坐标**，现有 100 多处 `_currentChapter` 的语义不用改。
- **邻章**挂在 body 里的宿主元素 `<fushi-seamless-chapter data-chapter="k">` 的 **shadow root** 里。它跟正文一起排版、一起滚动，但 `document.body` 上的 TreeWalker、`textContent`、`querySelectorAll`、`getElementById` 都看不到 shadow 里的内容。所以邻章不会混进引擎的任何索引，也不会和活动章的 id 冲突。这是选 Shadow DOM 而不是「所有 walker 加过滤」的原因：边界由平台保证，而不是靠几十处代码各自记得排除。
- **带章号的位置坐标** = `(活动章号, 活动章内 charOffset)`。JS 侧 `__fushiSeamless.activeChapter` 与 Dart 侧 `_currentChapter` 由「晋升」协议同步（§3）。

### 1.1 邻章样式

shadow root 不继承文档里的样式表，只继承可继承属性（writing-mode、字体、字号、行高、颜色、CSS 变量都能穿透）。宿主内部结构：

```
<fushi-seamless-chapter data-chapter=k>  #shadow-root
  <style>  邻章自己的 EPUB 样式（<link> 拉取文本 + 内联 <style>，url() 改绝对）
  <style>  当前 #fushi-reader-style 的文本（与 head 里实时同步）
  <style>  宿主复位规则
  <div class="fushi-seamless-html"><div class="fushi-seamless-body …原 body class">…正文…</div></div>
```

- 选择器改写走 CSSOM（插入后遍历 `sheet.cssRules`，递归 `@media` / `@supports`）：`html` / `:root` → `.fushi-seamless-html`，`body` → `.fushi-seamless-body`。不对 CSS 文本整体做正则替换。
- 复位规则把 body 专属的版式属性还原：`padding / margin / height / min-height / width / clip-path / position / overflow` 归零或 auto，`::after`（BUG-2015 的章末留白）不显示。邻章与活动章之间只留一个 `2em` 的章间距。
- 阅读器样式变化（`beginStyleReanchor` 换 `#fushi-reader-style`）时同步刷新所有宿主里的副本，然后由原有的 commit 按活动章字符锚复位，几何与邻章无关。
- shadow root 里的 `@font-face` 在 Chromium 不生效。阅读器字体都声明在文档 head 里，可以穿透；邻章 EPUB 自带的字体在晋升前可能回落，晋升后（§3 把它的样式表接进 head）恢复，位移由锚点补偿吸收。

### 1.2 邻章内容准备

挂载前在脱离文档的宿主里准备好内容：

1. `fetch(章 URL)` → `DOMParser` 解析。
2. 所有 URL 属性（`img[src]`、`image[href|xlink:href]`、`a[href]`、`source[src]`、`video/audio[src|poster]`）按**该章自己的 URL** 改成绝对地址。活动章晋升后文档 URL 仍是最初加载的那一章，相对地址如果不先改写就会解析错目录。
3. 跑与 `_sharedInitImages` 同一份的图片归类与遮罩（`block-img-wrapper`、`blurred`），根节点换成邻章容器。
4. **等所有图片解码完成**（`img.decode()`）再插入文档。上方邻章如果先插入、图片后加载，视口内容会被往下推，所以先解码，插入后的几何就是最终几何。

## 2. 挂载窗口、卸载与滚动补偿

- 窗口固定为活动章 ±1，**同时挂载上限 3 章**（活动章 + 2 个邻章）。活动章每变一次就重算窗口：缺的邻章异步挂载，窗口外的同步卸载。
- 章序取 Dart 下发的 `seamlessChapterOrder`：全书章号去掉被「图片合并」吸收的单图章（它们的图已内联在宿主文本章顶部，与 `_resolveNavChapter` 同口径）。
- **滚动补偿**用一个原语 `preserveViewport(fn)`：执行 DOM 变更前，取视口中心处最深的元素（遇到宿主就进它的 shadowRoot 再取一次），记下它主轴起边的坐标；执行变更后再量一次，按差值 `scrollBy`。横排按 `top`、竖排按 `left`。在锚点之前插入 / 删除内容、晋升时节点在 shadow 与 light 之间搬家、head 样式表切换，都走这同一个原语。原语只依赖「锚点元素的身份不变」，不依赖具体是哪种变更，所以横竖排、上下方向都不需要分别推导滚动量。
- 挂载 / 卸载 / 晋升在 `_reanchorPending`（恢复 / 换样式 / 缩放重锚在飞）期间推迟到落定之后再做。

## 3. 晋升（活动章切换）协议

### 3.1 触发

- 视口中心沿书写轴越过邻章宿主边界 24px（迟滞带，来回抖动不会反复切换）时，晋升该邻章。
- **只认用户驱动的滚动**：用户输入（wheel / touchmove / 方向键 / 按在滚动条上）记一个时间戳，程序化滚动（恢复、`scrollToTarget` 跟读、`scrollToCharOffset`、跳转定位）也记一个。只有最近一次视口移动来自用户时才判晋升。这样有声书跟读把句子滚到视口上方时，即使中心落进了下一章也不会切章；跨章跟读仍走原来的整章导航。
- 轻点（位移 < 12px）落在邻章宿主里时，在 capture 阶段先同步晋升，然后照常交给查词。晋升前后布局不变，同一个坐标落在同一个字上，查词第一次点就生效。

### 3.2 JS 侧（同步、一个任务内完成）

1. 清活动章的章内状态：`resetSentenceAudioCues()`（拆掉 cue 包裹）、`__fushiApplyHighlights([])`、`clearSearchHighlight()`、清选区、清图片迟到锚与恢复字符锚。
2. 在 `preserveViewport` 里搬节点：活动章正文节点搬进一个新宿主（变成邻章），目标邻章 shadow 里的节点搬回 body；head 里的 EPUB 样式表切换到目标章（原有的不删，改 `disabled`；缺的插到 `#fushi-reader-style` 之前，保持阅读器样式最后生效）；body 上属于章节的 class 换成目标章的；顺带卸载窗口外那章。
3. 引擎重建索引：`buildNodeOffsets()`，作废 `_textIndexCache` / `paginationMetrics`。
4. `activeChapter = 目标章`，`seq++`，进入「待确认」状态：这期间 `fushiProgressDetails()` 返回 `null`（所有调用方本来就把 null 当「未落定」处理）。
5. `callHandler('onSeamlessChapterActivated', 目标章, 原章, seq)`。

### 3.3 Dart 侧（`_onSeamlessChapterActivated`）

同步部分（第一个 `await` 之前，保证之后到达的任何 JS 回调都看到新章号）：

- 校验 `from == _currentChapter`、目标章合法、开关与连续模式仍有效；不满足就整章重载到目标章（自愈，不静默丢掉）。
- `_flushReadingStats()`、`_readLedger.leave()`（把离开那章的当前单元结算进账本，与 `_beginNavigation` 同一个采样点）。
- `_navigateGeneration++`（旧章在飞的进度 / 高亮 / 收尾回调按代际作废）、`_currentChapter = 目标章`、`_lastProgressSection`、`_chapterAdvanceDirection`，作废 `_jumpTargetSpan`、精确定位队列、翻页队列；`_audiobookController?.noteManualReaderNavigation()`（与手动翻章同语义）。

异步部分（每个 `await` 之后按代际复检）：

- `__fushiSeamless.ack(seq, generation)`：JS 把 `C.navigationGeneration` 改成新代际，解除待确认。
- 按章重新下发章内数据：句音频 cue（`_prepareSentenceAudioCuesJson` → `applySentenceAudioCues`）、有声书桥与控制器章节 cue（`_injectAudiobookBridge`）、收藏高亮（`_applyChapterHighlights`）、落点标记、有声书图片暂停锚复位；阅读光标在正文上时重新落位。
- `notifySectionRestoreCompleted(currentReaderSection: 目标章)`、`_ensureStudyClock()`、`_refreshProgress()`、`_startProgressPoll()`、预热下一章 HTML 与插图。

**进度 / 阅读位置 / 统计 / 学习单位**全部继续由 `_refreshProgress` 按 `(_currentChapter, charOffset)` 计算。两道闸保证不会把一章的偏移记到另一章：Dart 的代际 + 章号快照（已有），以及 JS 的待确认闸（新增）。

## 4. 恢复与跳转

- 打开书 / 目录 / 书签 / 搜索 / 收藏 / 内链 / 有声书跨章仍走 `_navigateToChapter*` → `loadUrl`，复用现有的 restore 状态机（`_readerContentReady` / `_restoreInFlight` / 代际）。目标章即使已作为邻章挂载也照样重载：这些跳转都要精确定位到章内某个字符或 fragment，重载路径已经过大量回归验证；在挂载态里另写一套定位，等于给同一件事造第二条路径。
- 初次恢复落定（`notifyRestoreComplete`）之后，JS 才启动无缝模块、挂载邻章。挂载走 `preserveViewport`，恢复落点不会被挤走；重锚在飞时推迟。
- `scrollToChapterStart` / `scrollToChapterEnd` / `isAtEnd` / `getFirstVisibleCharOffset` 在无缝模式下以**活动章正文的边界**为准，而不是文档的物理首尾（上一章挂在上方时，章首不再是 scroll 0）。图片迟到重锚走的就是这几条路径。
- 滚动到物理边界时（全书首尾章，或邻章挂载失败 / 还在加载）照旧由原来的拉动跨章 / 滚轮跨章接管，即退回整章重载。

## 5. 开关

- 设置项 `continuous_seamless_chapters`（bool，默认 false），在「翻页与手势」组，只在滚动模式显示；改值走 `notifyReaderLayoutChanged` 整章重载。
- 引擎配置 `C.seamlessChapters` 只在「连续模式 + 开关开 + 非双页文档」时为 true；同时下发 `C.seamlessChapterOrder`（章号 + URL）与 `C.seamlessChapterIndex`。
- 模块只在连续 shell 里、`C.seamlessChapters === true` 时安装 `window.__fushiSeamless`。所有接入点都写成 `if (window.__fushiSeamless) …`。开关关闭时这个对象不存在，每个接入点都退回原分支，行为不变。分页 / VN shell 的源码里没有这个模块（守卫测试断言）。

## 6. 已知取舍

- 邻章是「预览」：在它晋升之前，不画收藏高亮、不挂 cue、不参与查词（轻点会先晋升）。长按拖选如果从邻章起手，要等它晋升（滚过一半或轻点一下）之后才生效。
- 跳转到已挂载的邻章仍然整章重载，见 §4。
- 比现在多挂两章 DOM。超长章节的内存开销会成倍，所以上限固定为 3 章，不做「多挂几章」的配置项。
- 这是 WebView DOM 编排逻辑，不是计算型子系统，按现有阅读器引擎的分工放在 JS 里（不进 Rust 胖核心）。

## 7. 验证

- Dart 单测 / 守卫：配置序列化、开关默认关、分页 / VN 引擎源码不含模块、连续 shell 的接入点都以 `window.__fushiSeamless` 为前提、开关关闭时 `C.seamlessChapters` 恒为 false。
- 真 Chromium 探针 `tool/reader_pitch_headless/continuous_seamless_chapters_probe.mjs`：完整引擎产物 + 3 章同源服务，横排 / 竖排各跑一遍：挂载后视口不跳，滚过边界后晋升并回调宿主、索引只覆盖新活动章、待确认期间进度为 null，卸载上方章节时视口不跳，开关关闭时没有宿主。
