# 音乐库生成日语字幕与歌词搜索（2026-11-06）

起因：Feedback `QAondMh4M5`。纯音频从视频库迁进音乐库（#2977）之后，广播剧 CD / ASMR 这类没有歌词的音频没法再生成字幕。用户拍板：「正常应该支持的就支持，支持生成字幕，记得支持搜索」。

## 生成

- 复用视频字幕服务 `AppVideoSubtitleService` 和 `VideoSubtitlePipeline`，不复制。服务把「落点」抽成 `AppSubtitleOutputSink`，涉及导出目录、样式参考、远控镜像种类与主体、额外证据和登记。视频的实现是 `VideoBookSubtitleSink`（原逻辑），音乐的实现是 `MusicAsrSubtitleSink`。两者共用同一把「单任务」互斥锁。
- 产物统一导出到 `<support>/asr_jobs/music_subtitles/out/<videoSubtitleJobId(音频)>/`，不写在音频旁边。这有两个原因：音乐目录常是只读的，或者属于别的播放器；而 `<主名>.ja.srt` 会被 sidecar 规则认成翻译文件。音乐不传样式参考，只生成 SRT。
- 登记方式：给每首曲目写一条 `music_lyrics` 行，`source='asr'`。主键是 `trackUid + source`，所以 schema 不用变，曲目重扫后这一行还在。CUE 虚拟曲目调用 Rust `ffm_lyrics_slice` 按 `[cueStartMs, cueEndMs)` 截取并平移时间，原文存成 TTML；普通曲目整份存 SRT。
- 优先级：用户指定 > sidecar > 内嵌 > asr > 插件 > LRCLIB > 歌词插件。语料对账和歌词解析共用 `preferredMusicLyricRow`。在歌词页的「来源」里可以和在线歌词互相切换。
- 入口有四处：歌词页（没歌词时给一个按钮，「来源」菜单里也有）、曲目详情页、专辑页（整张批量）、本地音乐来源行菜单（整个来源批量）。批量时跳过已经有 `asr` 行的曲目。插件曲目和远端曲目算作不可用。所有入口都受 `isAsrSupported` 门控，不支持的平台不显示入口。
- 迁移补漏：`migrateAudioOnlyVideoBooksToMusic` 按路径识别旧视频管线的产物（`isDefaultVideoSubtitlePipelineOutput`：文件名为 `.ja.asr.*`，或者 `state.json` 记录写过），转成 `asr` 行。用户在视频行上选过、但不在音频旁边的字幕，转成 `user` 行。带走失败的那一行这次不删，下次再试。

## 搜索

- 曲内搜索：歌词页工具栏「在本曲中搜索」，和有声书歌词模式用同一个 `searchLyricsCueTextsOffUi`。点结果跳到该行，时间会按整首偏移折算回音频时间。
- 曲库搜索：搜索页单独有一段「歌词命中」，异步加载，不阻塞其他结果。走 Rust `fushi_corpus` 索引（复用「我库里的例句」的音乐文档）。查询词先分词，`match_all` 要求整句包含全部词。结果只保留还在曲库里的曲目。点一条会单曲开播，并 seek 到那一行。

## 已知缺口

- 曲库歌词搜索依赖语料索引已开启、词典已加载（分词器）。
- 扫描时不把 sidecar / 内嵌歌词预先写进 `music_lyrics`。只有播放过或解析过的曲目才进语料。
- 生成没有 ctl 路由。
