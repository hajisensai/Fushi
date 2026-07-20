## BUG-919 · 番剧下载AniList搜索:带macron长音的罗马字全无结果
- **报告**：2026-07-19（用户：番剧下载搜索全是无结果，本机搜「Chūnibyō Demo Koi ga Shitai!」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/anilist_client.dart`（`searchAnime` 把用户原串直接当 `search` 变量发给 AniList）。
- **[x] ① 已修复** — `hibiki/lib/src/media/video/anilist_client.dart` 新增 `normalizeAniListSearch`，把 macron 长音符（ū ō ā ī ē，含预组合字母与 combining U+0304）按修正 Hepburn 展开成双元音（ū→uu、ō→ou…），`searchAnime` 发请求前先归一化。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/anilist_client_test.dart`（macron 展开纯函数单测，含预组合/combining/大小写/no-op；4 tests）。
- **备注**：

**根因（curl + live AniListClient 实证）**：番剧官方 romaji 常用 macron 转写（Wikipedia/官方，如「Chūnibyō」），用户会直接打或复制。但 AniList 的 GraphQL `search` 索引用**修正 Hepburn 双元音拼法**（「Chuunibyou」）且**不对 macron 做归一化匹配**：
- `Chūnibyō Demo Koi ga Shitai!`（带 ū ō）→ **0 结果**
- 简单去 macron 的 `Chunibyo Demo…`（单元音）→ **仍 0**（太短，AniList 模糊匹配也不命中完整串）
- 双元音 `Chuunibyou Demo…` → **命中**

原 `searchAnime` 把原串（带 macron）直接发出去 → 0 结果 → `catch(_) → 空列表` → UI 显示"无结果"。

**修复**：搜索前 `normalizeAniListSearch(query)` 把 macron 展开成双元音（ā→aa ī→ii ū→uu ē→ee ō→ou；combining U+0304 双写前一元音）。纯函数，无 macron 的输入 no-op，不降低正常命中。

**验证**：真实 `AniListClient.searchAnime('Chūnibyō Demo Koi ga Shitai!')` 修复后返回 **10 结果**（`Chuunibyou demo Koi ga Shitai!` 等），修复前 0。

**范围外（本 bug 不含，另议）**：`searchAnime` 的 `catch(_)→空列表` 把网络失败与真无结果混为一谈（用户网络访问不了 AniList 时也只看到"无结果"）——建议后续区分错误态给不同提示。
