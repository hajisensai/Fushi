## BUG-1610 · Bangumi 搜索候选评分恒空：映射器读扁平 score，真实响应只有嵌套 rating.score
- **报告**：2026-08-14（用户：测试刮削/发现/下载）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/scraper/bangumi_client.dart:516`（修前）——
  `_mapBangumiSubject` 读 `subject['score']`，而 `/v0/search/subjects` 的真实响应**没有**顶层
  `score` 键，评分只在嵌套的 `rating: {score, total}` 里。
- **[x] ① 已修复** — `9b1345cd3b` 之后本轮提交；`bangumi_client.dart` 新增 `_bangumiRating()`
  作为 Bangumi 评分的唯一读取点（嵌套 `rating.score`/`rating.total` 优先、扁平 `score` 回退），
  `_mapBangumiSubject` 改用它并补写 `rating` / `ratingCount`；删掉
  `parseBangumiSubjectDetailAsCandidate` 里已多余的评分 pre-normalize。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/scraper/bangumi_client_test.dart`
  （夹具改为真实嵌套形态 + 断言 `rating`/`ratingCount`，新增 4 条：无 rating 节点 / 扁平回退 /
  嵌套优先于扁平 / 0 分按缺失）与 `bangumi_subject_test.dart`（详情候选补断言数值字段）。
  变异实测：把 `_bangumiRating` 退回只读扁平 `score` → 3 条测试红。

### 症状

Bangumi 刮出来的条目**永远没有评分**：

1. 候选选择对话框（`cover_match_dialog.dart:616` 读 `candidate.ratingText`）里，TMDB / AniList /
   MAL 候选都带评分 chip（`TMDB 8.5` / `AniList 9.1` / `MAL 8.4`），唯独 Bangumi 候选没有 ——
   用户在多源候选列表里少了一个判断"哪个才是对的条目"的维度。
2. `cover_scraper_service.dart:708-709` 把 `candidate.rating` / `candidate.ratingCount` 写进落库的
   ScrapeMeta，于是详情弹窗（`scrape_info_dialog.dart:138/190`）的「评分 / 评分人数」区块对
   Bangumi 刮的条目恒不显示。

### 根因

`_mapBangumiSubject` 有两处独立缺陷，叠加成"整条评分链路对 Bangumi 恒失效"：

**① 读错字段。** 代码读扁平 `subject['score']`。文件里 `parseBangumiSubjectDetailAsCandidate`
的注释白纸黑字写着前提「评分在 `rating.score`（**搜索是扁平 `score`**）」，并据此在详情调用方
做了一次 pre-normalize。实测这个前提对真实 API 从来不成立 —— 搜索端点返回的也是嵌套形态：

```
POST https://api.bgm.tv/v0/search/subjects   {"keyword":"葬送のフリーレン","filter":{"type":[2]}}
→ 5 条候选全部 flat_score=None，评分都在 rating:{score,total}
  id=400602 rating.score=8.5 total=35890
  id=459283 rating.score=6.8 total=1249
  id=515759 rating.score=7.5 total=12009
```

于是搜索路径拿到 `null` → `score = 0.0` → `score > 0` 为假 → `ratingText` 也是 `null`。

**② 只填展示文本、不填数值。** 即便归一化跑到（详情路径），`_mapBangumiSubject` 也只设
`ratingText`，从不设 `rating` / `ratingCount`。这直接违反 `ScrapeCandidate` 自己的契约
（`scraper_types.dart:137`：「评分数值 0~10 与评分人数（`ratingText` 是它的展示化文本，
**二者不重复解析**）」）。对照组：TMDB（`tmdb_client.dart:568`）、Jikan（`jikan_client.dart:146`）、
AniList（`anilist_client.dart:211`）三个源都正确填了 `rating`。Bangumi 是唯一的例外。

### 为什么测试没抓住

`bangumi_client_test.dart` 的夹具**伪造了一个真实 API 里不存在的扁平 `"score":8.1`**，解析器读扁平键
就"通过"了；而 `bangumi_subject_test.dart:206` 的详情候选用例只断言 `ratingText`，没断言
`rating` / `ratingCount`。两个缺口正好各自遮住一个缺陷，测试全绿而生产恒空 —— 典型的
「mock 夹具与真实 API 漂开」假绿。修复同时把夹具换成真实形态。

### 修法（消除特殊情况）

不是在调用方再补一次归一化，而是把「Bangumi 评分住在哪」收进**一个**函数：

```dart
({double? score, int? votes}) _bangumiRating(Map<String, Object?> subject)
```

嵌套 `rating.score` / `rating.total` 优先，扁平 `score` 保留为回退（兼容旧缓存与既有夹具）；
`score == 0` 按「暂无评分」处理，与 `parseBangumiSubjectResponse` 同规则。两个调用方
（搜索 / 详情）从此都不需要 pre-normalize，`parseBangumiSubjectDetailAsCandidate` 里那三行
评分归一化随之删除，只剩话数一处真实的端点差异。

### 验证

真实网络活体验证（生产装配 `BangumiClient().search()`）：

```
修前： id=400602 ... rating=null   id=459283 ... rating=null   id=515759 ... rating=null
修后： id=400602 ... rating=8.5    id=459283 ... rating=6.8    id=515759 ... rating=7.5
```

逐条与 curl 抓到的 `rating.score` 一致。

### 备注：同批查到但**未改**的两处

- **`platform: "WEB"` → `ScrapeEntryType.unknown`**（`_typeFromPlatform`）。WEB 是 Bangumi 上很常见的
  平台值（网络放送番剧，实测 5 条候选里占 2 条）。但 `unknown` 在 `match_scorer.dart:130` 是
  **中性不参与**打分、在 `cover_scraper_service.dart:788` 的 `isTv` 判断里也按 TV 处理，实际只在
  「文件名显式带剧场版标记」时才与 `tv` 有差别。收益边缘、且 Bangumi platform 值域掌握不全，不改。
- **同一条目两条路径给出不同集数**：`parseBangumiSubjectDetailAsCandidate` 走 `eps` 优先
  （`total_episodes` 仅在 `eps<=0` 时回退），`parseBangumiSubjectResponse` 走 `total_episodes` 优先。
  实测 subject 400602 是 `eps=28` / `total_episodes=36`（36 含 SP），两条路径分别得 28 和 36。
  这大概率是**有意**的语义差（候选的 `episodeCount` 注释说是"用于集数一致性校验"，该用正片数；
  ScrapeMetadata 的是展示用，该用完整数），但两个函数在同一文件里对同一概念做了相反的优先级选择、
  注释又没点明，容易被后来者当 bug 改。改动会动匹配打分，本轮不动。
