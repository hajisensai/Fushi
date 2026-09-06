# 2026-09-06 网飞制卡三件套：单词音频 / 外字 alt 重叠 / 扩展多句合一

用户报告（附 AnkiDroid 截图，卡片 note 1788020800232，MiscInfo=Netflix）：
1. 网飞制卡少了单词音频；
2. 卡片释义里「参考」两字与其他文字重叠；
3. 浏览器扩展要支持和本地一样的多句合一制卡。

真卡取证（AnkiConnect `notesInfo`）：`ExpressionAudio` 空；`MainDefinition` 含
`<span class="gloss-image">［参考］</span>`（无 `<img>`）；`Sentence` =
`雛宮の地下牢ちかろう は<b>ネズミ</b>や虫が這は い回って`（读音混进正文，顺带发现）。
无头 Chrome + 用户实际 Lapis CSS 量得：alt 文本墨迹 80px 宽塞在 24px 宽、`line-height:0`
的图片容器里 → 溢出压住后文。

## 根因

| # | 根因 | 位置 |
|---|---|---|
| BUG-2189 | 扩展入队时把 `/api/lookup/audio/file?id=` **5 分钟短命 token URL** 冻进 `fields.audio`；批量生成在几十分钟后 → 404 → 卡建好音频空。服务端 `/api/mine` 全链路从不重解析单词音频 | `yomitan_api_server.dart` `_pruneAudioTokens`；`fushi_remote_api_handlers.dart` `buildRemoteMineResponse` |
| BUG-2190 | ① popup.js 导出路径 `window.embedMedia` 为假时把外字 alt 文本塞进**图片盒**（`width:auto!important;height:1.2em;line-height:0`）→ 文本溢出压正文；② 扩展从不设 `window.embedMedia`，服务端远程制卡也从不 `writeDictionaryMediaCache` → 外字永远退化 alt | `popup.js` `createDefinitionImage` exporting 分支；`content.js` `fushiRenderEntries`；`app_model.dart` `_AppModelRemoteLookupService.mineEntry/mineImmersion` |
| BUG-2191 | `parseTtml` 只认 HTML `<rt>`，不认 IMSC `tts:ruby="text"` span → 读音拼进 cue.text | `subtitle-adapters.js` `parseTtml` |
| 多句合一 | 扩展只取一条 cue 窗；popup.js 的「调整上下文」按钮/handler 都在，只是宿主没接 | `content.js` `fushiMineContext`/`fushiEnqueue`；`bridge-shim.js` |

## 方案

1. **单词音频**（服务端，两个 server 共享 handler）：`buildRemoteMineResponse` 新增可选
   `wordAudio` 解析器；本机 token URL → token 仍活取字节、否则按 `expression+reading` 重走
   `lookupAudio` → 一律改写成自包含 `data:<mime>;base64,` URI（与 app 内本地音频库同形，
   `AnkiAudioRef.dataUri` 两个 repo 都认）。非本机 token 引用原样透传。
2. **外字**：popup.js 无媒体文件时 alt 直接作为行内文本 `<span class="gloss-image-alt">`
   输出（不再套图片盒）；扩展 `fushiRenderEntries` 设 `window.embedMedia = true`；服务端
   远程 `mineEntry` / `mineImmersion` 制卡前 `writeDictionaryMediaCache(fields.dictionaryMedia)`
   （与 overlay_bridge_handlers 同一步骤）。
3. **TTML ruby**：`parseTtml` 先把 `tts:ruby="text|delimiter"` span 转成 `<rt>`/删除、
   `base` 解包，再走既有 `stripCueTags`；同时 `cue.ruby` 挂分段供面板画振假名。
4. **多句合一**：`subtitle-providers.js` 加 `fushiFullTrackCueAt()`（cues+idx）与纯函数
   `fushiComposeCueContext(cues, idx, prevN, nextN)`（`'\n'` 连接、min/max 并集，逐字对齐
   Dart `joinMinedSentences` / `mergeMiningAudioRanges`）；content.js 持 `{prev,next}` 计数，
   `fushiMineContext` 回 `contextSentence` + `contextWindow`；`fushiEnqueue` 与 bridge-shim 立即
   出卡都消费之；bridge-shim 接 `setSentenceContext` / `clearSentenceDraft` /
   `sentenceContextPreview` / `openSentenceContextModal`；content.js 画顶层 shadow 模态
   （镜像 `SentenceContextDialog`：前文/当前/后文 + 四个 ± + 取消/确认制卡）。
   `cueStartV`/`mineAtV`/`cueEndV` 仍指当前句（帧定位与 `{clip-timestamp}` 语义不变）。
   服务端零改动。

## 验证

- Dart：`test/sync/yomitan_api_server_extension_endpoints_test.dart`（token 过期→data URI、
  token 活→data URI、非 token 原样）+ sync server 同款；源码守卫（远程制卡写词典媒体缓存、
  扩展 embedMedia）。
- JS：`tools/browser-extension` 下 `node --test *.test.js`（新增 sentence-context / ttml ruby /
  bridge-shim 新 case）；`fushi/test/pages` 相关 popup 导出测试。
- `sync-mirrors.mjs` 三镜像同步 + parity 守卫；`flutter analyze`；定向 `flutter test`。
- 真机：网飞批量制卡需用户在 Chrome 真机复测（DRM 本机无法自动化），标 implemented_unverified。
