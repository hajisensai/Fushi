## BUG-4220 · 内置播放器 YouTube 字幕残留 HTML 实体（&#39;）
- **报告**：2026-11-06（用户：内置播放器 / 内置浏览器播放 YouTube 时字幕没有做 HTML 转码，浏览器扩展里正常）
- **真实性**：✅ 真 bug，真实数据复现。2026-11-06 用同一条代码路径（`resolveYoutubeCaptionTracks` → 下载 `cueDownloadUrl` → `parseYoutubeTimedTextToCues`）抓 `dQw4w9WgXcQ` / `jNQXAC9IVRw` 的 en 轨：原文是 `We&amp;#39;re`（**双重转义**），解析出的 cue 是 `We&#39;re`；ja / de 轨原文没有要转义的字符所以看不出来。
- **根因**：YouTube timedtext XML 双重转义——字幕原文先 HTML 转义成 `&#39;`，写进 XML 时 `&` 再转义成 `&amp;`。`packages/fushi_engine/lib/media/video/youtube_source_resolver.dart` 的 `_parseSrv1TimedText` / `_parseFormat3TimedText` 用正则取文本（不经 XML 解码），只 `HtmlUnescape` 一次，只剥掉了 XML 那一层。浏览器扩展取 json3（`youtube-bridge.js` `parseJson3`，`segs[].utf8` 原文，无实体），所以只有 app 侧出错。测试 fixture 写的是单层转义 `&#39;`（与真实数据不符），所以一直绿。
- **[x] ① 已修复** — 新增 `_timedTextCueText`（`youtube_source_resolver.dart:322`）：剥内嵌标签后**固定解两层**（XML 层 + 字幕文本 HTML 层，与 youtube-transcript-api 的 ElementTree + `html.unescape` 同口径），两种格式共用。不解到不动点：第二层之后剩下的 `&...;` 是字幕作者写的字面文本。覆盖内置播放器、内置浏览器交给播放器的 YouTube、扩展的服务端字幕兜底（`resolveYoutubeCaptionsForExtension`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/youtube_source_resolver_test.dart` 组「double-escaped entities (BUG-4220)」：format 3 `<p>`、ASR `<s>` 拼接、srv1 `<text>` 三种形态用真实双重转义 fixture；另钉「三层转义只解两层、保留字面 `&amp;`」。
- **备注**：未在真机上肉眼复测播放器字幕（真实网络数据已对拍）。
