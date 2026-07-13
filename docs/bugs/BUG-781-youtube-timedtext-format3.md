## BUG-781 · YouTube 字幕失效: androidVr 返回 timedtext format3 <p t d> 而解析器只认 srv1 <text>
- **报告**：2026-07-13（用户：网页/app 上 YouTube 字幕抓不到）
- **真实性**：✅ 真 bug（真网络 + youtube_explode androidVr 内部符号路径复现）。根因 `hibiki/lib/src/media/video/youtube_source_resolver.dart:214`（旧 `parseYoutubeTimedTextToCues`）。
  - 字幕轨**列表**抓取仍活（`_fetchCaptionTracks` androidVr `getPlayerResponse` OK，6 轨含 auto/manual），但 **cue 正文**下载回来是 `<timedtext format="3">` 的 `<p t="毫秒" d="毫秒">`（ASR 轨文本还拆进内嵌 `<s>` 词级片段），**即使显式 `fmt=srv1`/`srv3`/无 三种都被 YouTube 无视、一律回 format 3**。
  - 旧解析器正则只认 srv1 `<text start="秒" dur="秒">` → 对 format-3 body 匹配 0 → 返回 0 cue → **字幕静默消失**（BUG-602/629 修的是「轨列表」，罐装 srv1 fixture 测不到活契约的 format-3 body，故账面绿仍失效）。
  - 探测证据：rickroll `dQw4w9WgXcQ` 英文人工轨 body 3877 字节、`<text>`=0、`<p>`=61；ASR 轨 `<p ...><s>词</s>...</p>` 285 个 `<s>`。
- **[x] ① 已修复** — `hibiki/lib/src/media/video/youtube_source_resolver.dart`：`parseYoutubeTimedTextToCues` 改为**按内容自适应**——先跑 srv1（有 `<text>` 命中即返回，旧行为不变），无命中才按 format 3 解析 `<p t d>`：t/d 已是毫秒直用、内嵌 `<s>` 经剥标签自然拼接、含 `a="1"` 的空白滚动占位 `<p>` 与 `<w>` 元素天然跳过。拆出 `_parseSrv1TimedText` / `_parseFormat3TimedText` 两纯函数。不动 resolver 网络路径 / `cueDownloadUrl`（`fmt=srv1` 被无视故无害保留），最小改动、向后兼容。提交 `c55ca4f2a`。
  - 端到端验证：真 body（0 个 `<text>`）经新逻辑 → 61 cue，首句 `[♪♪♪]`（`hibiki/tool/yt_caption_probe.dart` 探测，不入库）。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/youtube_source_resolver_test.dart` 新增 group `parseYoutubeTimedTextToCues format 3 (BUG-781)`：① 人工轨 `<p t d>text</p>` 毫秒直用（含 endMs=t+d）；② ASR 轨拼接 `<s>` 词级片段 + 跳空白滚动占位 `<p a="1">` 与 `<w>` 元素；③ 无 `d` 属性时 endMs 退回 startMs 不崩。fixtures 用探测抓下来的**真实 format-3 结构**（正是旧 srv1-only 测试漏掉的缝）。旧 2 个 srv1 测试保留做向后兼容守卫。全 12 测试绿。
- **备注**：字幕依赖 `youtube_explode_dart 2.5.x` + androidVr 内部符号，属外部反爬契约（YouTube 可再改格式）；本次把「cue 正文格式」纳入守卫。BUG-781 号由 `dart run tool/bug.dart new` 分配。此修复同时是「浏览器扩展→server 抓 YouTube 真字幕」（复用 `resolveYoutubeCaption*`）的地基。
