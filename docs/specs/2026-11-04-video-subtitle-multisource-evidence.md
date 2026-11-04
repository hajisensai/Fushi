# 视频字幕生成：多源证据融合 + 歌词补齐 + 通用联网搜索（2026-11-04）

接 [2026-10-19-video-asr-llm-subtitle-pipeline.md](2026-10-19-video-asr-llm-subtitle-pipeline.md)。

## 问题

现有管线（识别 → S0 专名表 → S3 校对 → S4 写法统一 → 歌曲判定 → 拆分 → 导出 SRT / 参考样式 ASS）
只把语音识别当唯一文字来源。同一视频身边经常已经有「不完全可用」的字幕：

- 同语言（日语）的图形字幕（PGS / VobSub / DVB）、残缺或时间轴错的 SRT / ASS / VTT；
- 其他语言（英 / 中 / …）的字幕组 ASS / SRT；

这些只被拿去借 ASS 样式，文字本身被丢掉。S3 的规则第 1、5 条早就写了「同时段的他言語字幕」，
但管线从来不提供。歌曲段（OP / ED / 插曲）只被判成「♪」或幻听清空，纯歌曲短片直接不导出。

## 方案总览

```
视频 ─┬─ 识别（不变）────────────────────────────▶ drafts
      └─ 证据收集 S1e（新）：外挂文字字幕 / 内嵌文字轨 / 图形轨 OCR（注入）
             │ 按语言、种类（对白 / 招牌 / 歌曲）分类
             │ 非内嵌来源按识别稿对时间轴（复用上游 decideSubtitleSync / retimeSubtitleBytes）
             ▼
         evidence.json（按来源指纹缓存）
             │
  S2e 缺口补齐（新，确定性）：同语言对白证据里识别稿没覆盖的行 → 插进 drafts
  S0  专名表：同语言证据文字一并作身份 / 写法样本
  S3  校对：每行附「同时段同语言字幕」「同时段他言語字幕」；同语言证据优先采用
  S4  写法统一（不变）
  S4s 歌词补齐（新，需 AI）：歌曲段 → 认歌（AI + 证据卡拉OK行）→ 查歌词（LRCLIB + 通用联网搜索）
       → AI 把歌词逐行对到识别稿的歌唱行 → 字面相似度校验 → 替换为正确歌词
  S5  拆分 / 导出：补齐过歌词的纯歌曲短片照常导出
```

## 1. 证据（`subtitle_evidence.dart`，纯函数）

- `SubtitleEvidenceTrack`：`label`、`language`（`ja` / `en` / `zh` / `ko` / … / null）、`kind`
  （`text` 人工字幕 / `ocr` 图形字幕识别）、`cues`。证据轨的时间轴一律可信（见 §2「对时间轴」），
  下游直接按时间取行。
- `SubtitleEvidenceCue`：`startMs` / `endMs` / `text` / `role`（`dialogue` / `sign` / `song`）。
  - ASS：带 `\pos` `\move` `\clip` 的事件、`\p` 绘图 → `sign`；样式名 / Name / Effect 命中
    OP / ED / song / 歌 / insert / karaoke，或正文带 `\k` 卡拉 OK 标签 → `song`。
  - 其他格式：全行 `♪` / `♫` 起头 → `song`。
- 语言：先看来源标签（外挂文件名后缀 `.en.ass`、内嵌轨 `language`，经
  `normalizeSubtitleLanguageCode`），没有再按文字的书写系统判（假名 → ja；谚文 → ko；只有汉字
  → zh；拉丁 → en）。标签与文字冲突时信文字（字幕组常把轨标错）。
- `SubtitleEvidenceIndex`：按时间重叠查询（某条识别稿同时段的同语言 / 他言語证据），每种
  语言最多取一条轨（同语言优先 `text` 再 `ocr`，再按对白行数多者）。

## 2. 证据收集（`subtitle_evidence_loader.dart`）

- 外挂：`listSidecarSubtitles` 列出的全部文字字幕（srt / ass / ssa / vtt），图形外挂
  （`.sup` / `.idx+.sub`）走 OCR 端口。
- 内嵌：`probeEmbeddedSubtitleTracks` 的文字轨（`extractEmbeddedSubtitleTrackFile`）与图形轨
  （OCR 端口）。网络路径不 demux 整片（同样式参考的规矩）。
- 排除本管线自己的产物（`isOwnOutput`）：内容仍是本管线上次写进去的那份（`state.json`
  `exports` 的哈希对得上），或是只有本管线会写的 `.asr` 退路名（`<视频名>.<后缀>.asr.srt` /
  `.asr.ass`，任务目录被清掉也认得出）。路径曾是导出、内容已被换掉的（用户改过 / 换成别的
  字幕）照常当证据。
- **OCR 端口** `SubtitleGraphicTrackRecognizer`：引擎不能用 Flutter OCR，由宿主注入（app 用现有
  整轨图形字幕 OCR；无头服务端暂不注入 = 跳过图形轨）。
- **对时间轴**：内嵌轨与视频同一容器，视为已同步；外挂文件把识别稿的开始时刻当参考轨，
  调上游 `decideSubtitleSync` → `retimeSubtitleBytes`（不在本仓写新对齐算法）。**只收判
  `autoApply` 的外挂轨**（按对齐结果改写时间）；`needsConfirmation` / `refused`、识别稿不足
  `kMinReferenceCues` 行判不了、或字幕读不出可对齐的行，整条丢掉（只记诊断日志）——缺口补齐、
  校对的同时段原文、歌词段检测都按时间取行，时间轴不可信的轨会把别处的台词插进字幕稿。
- 缓存：`<任务目录>/evidence.json`，键 = 收集规则版本 + 各来源（路径 + 字节数 + mtime）+
  识别器 id 的指纹（收集规则改了，旧缓存作废）。

## 3. 缺口补齐（`subtitle_evidence_fusion.dart`）

同语言 `dialogue` 证据行与所有识别稿行的时间重叠 < 20% 时插入为新的稿行（识别漏掉的
小声台词、BGM 下的台词）。`SubtitleDraftCue.origin` 记来源标签，S3 照常校对它。AI 关闭时
同样生效（人工字幕 / OCR 比空白强）。

## 4. S3 校对带证据

- 每行在候选稿之后追加：`同言語字幕[<label>]: …`、`他言語字幕(<lang>): …`（同时段重叠的
  证据行拼接，`sign` / `song` 行不给）。
- 有证据的集才在稳定前缀后追加一段补充规则：同语言字幕与台词吻合时优先采用其写法（OCR
  有字形近似误读，人工字幕可能删减口癖，口癖照规则 3 保留）；他言語只作判断依据（规则 1、5
  不变）。
- 缓存失效：证据指纹写进 `state.json`，变了就从 S3 起重跑（插行会让批起点错位）；`final.json`
  也记指纹。

## 5. 歌词补齐（`subtitle_song_lyrics.dart`）

1. **歌曲段**：S4 后带 `♪` 的连续行 + 证据里的 `song` 行，间隔 < 8 s 合并，≥ 3 行才算。
2. **认歌**：一次 AI 请求：作品名、段落时刻、识别稿歌唱行、证据里的卡拉 OK / 翻译歌词 →
   `title<TAB>artist` 或 `UNKNOWN`。
3. **查歌词**（`SubtitleLyricsFinder`）：
   - LRCLIB（`LrclibClient` 从 app 搬进引擎，app 原路径 re-export）按 歌名 + 歌手 查；
   - 通用联网搜索（§6）：`<歌名> <歌手> 歌詞` / 认不出歌时 `"<识别稿一句>" 歌詞`，取前几页
     正文，AI 抽出歌词原文（只抽页面里有的，不许补写）。
4. **对齐**：AI 把歌词逐行对到识别稿的歌唱行（行协议 `<id><TAB><歌词>`，TV size 剪掉的段落
   不对），时间轴仍来自识别稿。
5. **校验**：被替换行的 识别稿 ↔ 歌词 字符二元组 Dice 均值 ≥ 0.3 且覆盖 ≥ 50% 的歌唱行，
   否则整段不替换（宁可不补，也不贴错歌）。
6. 产物：替换后的行保留 `♪` 前缀；纯歌曲短片补齐成功则照常导出（不再 `skippedSong`），
   `≥60% ♪` 的不导出规则对已补齐的歌词行不计。
7. 缓存：`<任务目录>/lyrics.json`。

注音：只保留来源自带的；机器推断读音的振假名仍在功能黑名单里（无法保证 100% 准确），
SRT / ASS 也没有 ruby 载体，本次不做。

## 6. 通用联网搜索（`packages/fushi_engine/lib/ai/web_search.dart`）

`WebKnowledgeClient` 只查固定站点（MediaWiki / ANN / TVMaze）。新增通用搜索：

- `WebSearchConfig`：`kind`（`searxng` 自建 / 公共实例，`brave` Brave Search API）、`endpoint`、
  `apiKey`；JSON 存偏好（app，key 与 `ai_providers` 同口径存 base64 `apiKeyB64`，旧明文
  `apiKey` 启动时迁移）/ 配置文件 `ai:` 段（服务端）。
- `WebSearchClient.search(query)` → 标题 / URL / 摘要；`fetchPage(url)` 取页面正文（HTML 去标签、
  4 MB 上限、走全应用代理）。抓页按已校验的公网 IP 建连；走代理时自己向代理发
  `CONNECT <IP>:<端口>`，代理拿不到可重新解析的主机名（DNS rebinding）。
- `AiSettingsSource.aiWebSearch` 暴露给 AI 功能；设置页在「联网资料」旁加一节。
- 抓前 3 页交给 AI 前首次确认（`ai_web_search_page_fetch`，开 AI 生成字幕点「开始」前问一次，
  设置里可改）：没答过 / 不允许时 app 的 `aiWebSearch` 为 null。说明里写明部分 AI 提供商自带
  联网搜索（有的收费），可以不配置这里。服务端由管理员亲手写 `web_search:` 即视为同意。
- 首个消费者是歌词补齐；之后其它 AI 功能可直接复用。

## 不做 / 留后

- 机器推断注音（黑名单）。
- 在线字幕站（Jimaku / OpenSubtitles）自动下载当证据：需要账号与配额，留后。
- mkv 章节名（Opening / Ending）当歌曲段信号：引擎目前没有章节探测，留后。
