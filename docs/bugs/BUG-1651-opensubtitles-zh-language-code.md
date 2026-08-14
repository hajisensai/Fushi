## BUG-1651 · OpenSubtitles 搜索传裸 zh 语言码，中文字幕永远搜不到
- **报告**：2026-08-15（用户：接入 OpenSubtitles 时自查发现，非用户报告）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/media/video/subtitle/open_subtitles_client.dart:503`
  （`'languages': request.languages.join(',')` 把 Hibiki 的大类语言码原样透传给 API）
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：

### 根因

Hibiki 内部的字幕语言值域是**大类码** `ja` / `zh` / `en` / `ko`
（`fushi/lib/src/media/video/jimaku_client.dart` 的 `kJimakuLanguageCodes`，Jimaku 侧靠文件名
启发式识别，只分到大类）。这套值域经设置项「默认字幕语言」
（`video.subtitle.jimaku_default_language`）流进下载流水线：

`app_model.dart` → `VideoDownloadPipelineService(preferredSubtitleLanguages: [...])`
→ `video_download_pipeline_service.dart:1711` `languages: preferredSubtitleLanguages`
→ `open_subtitles_client.dart:503` `'languages': request.languages.join(',')`

而 OpenSubtitles REST API v1 的语言值域是 **BCP-47**，其官方语言表
（`GET https://api.opensubtitles.com/api/v1/infos/languages`，无需 API key 即可读，实测
105 个码）**不存在裸 `zh`**，只有 `zh-cn` / `zh-tw` / `zh-ca`。

因此用户把默认字幕语言设成中文后，OpenSubtitles 这一路的搜索恒定拿不到中文结果。
`ja` / `en` / `ko` 都在表内，所以只有中文这一档坏——这也是它长期没被发现的原因。

实测确认（一手证据，2026-08-15）：语言表里带地区码的家族只有
`az-az` / `az-zb` / `pt-br` / `pt-pt` / `tm-td` / `zh-ca` / `zh-cn` / `zh-tw`；
`ja` `en` `ko` `es` `fr` `de` `it` `ru` `th` `vi` `id` `ar` `nl` `tr` 均有裸码。
对 Hibiki 现有值域只有 `zh` 需要映射（`pt` 目前不在字幕语言值域内，一并归一以防将来踩）。

### 影响范围

- 下载流水线自动配字幕阶段（既有路径，本 bug 早已存在）。
- 播放页新增的「在线获取字幕」入口（同一个 client，见同批次接入改动）。

不影响 Jimaku：它没有服务端语言过滤，语言是客户端按文件名识别的。

### 修复方向

在 `OpenSubtitlesClient` 内部做一次语言码归一（单一真相源，两个调用方都受益），而不是在
各调用方分别转换：client 最清楚自己 API 的值域。`zh` → `zh-cn,zh-tw`，`pt` → `pt-br,pt-pt`，
其余原样透传（未知码交给服务端裁决，不在客户端擅自丢弃）；结果去重并排序——API 对未规范化
的 query 会回 301 重定向到规范 URL，排序能省掉这次多余往返。
