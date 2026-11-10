## BUG-4337 · 游戏发现页搜索结果混入大量无关条目（真红小站模糊搜索透传）
- **报告**：2026-11-09（开发者自提，应用内反馈 80S7Esbdec，Windows 3.3.0-debug.24790，附截图）
- **真实性**：✅ 真 bug，已沿代码路径确认。游戏发现页搜「ユリアリス」，只有 AList（erogame）那一条真命中，真红小站返回的「天文時計のアリア」「ユニオリズム」「デリシャスらんちぱっく」等 6 条以上都与查询无关。
  - 根因：`fushi/lib/src/media/discovery/sources/shinnku_discovery_source.dart:56-140` `ShinnkuDiscoverySource.search` 把站点 `/search?q=` RSC `answer` 数组逐条原样转成 `DiscoveryResourceItem`，不过滤也不排序；站点后端是字符级模糊匹配，零散命中 リ / ア / ス 的条目都会返回。聚合层 `fushi/lib/src/media/discovery/media_discovery_service.dart`（`load` → `_invoke` → `_assemble`）与发现页 `media_discovery_page.dart` 的 `_visible` 都没有任何相关度判据，于是最松的那个源的噪声整页透出。不是 shinnku 一家的问题：Nyaa / AList / OPDS / Audiobookshelf 的后端口径同样不可控。
- **[x] ① 已修复** — 在聚合层加统一的相关度判据，不给 shinnku 打特例。
  - 新增纯函数 `fushi/lib/src/media/discovery/discovery_search_relevance.dart`：标题 / 源标注 / 直链文件名与查询词都过 `normalizeMediaSearchText`（全半角、大小写、片假名→平假名、去空白标点，与库页搜索同一口径）；整条查询作为连续子串出现 = 命中；否则按空白分词、按字符数加权算覆盖率，≥ `kDiscoveryTokenCoverageThreshold`（0.6，来由见常量注释）也算命中。
  - `MediaDiscoveryService.load` 对搜索请求的每个分片按相关度稳定重排（命中在前，同档保持源原序；不删条目、不跨源混排），发现页 / AI 下载 / ctl 三个消费方同一口径。
  - 发现页 `_visible` 源内先按相关度、再按做种排序；不相关条目**折叠**进已有的「已隐藏 N 条…」计数行（新 key `discovery_hidden_irrelevant_count`），点开即显示，不重新请求。选折叠而非删除：源可能按作者 / 系列这类聚合层看不到的字段命中。下钻目录（浏览）时不判相关度。
- **[x] ② 已加自动化测试** — `fushi/test/media/discovery/discovery_search_relevance_test.dart`（反馈正反例 ユリアリス 命中 / 天文時計のアリア 等不命中、假名与全半角折叠、拉丁标题、词序颠倒、带副标题、阈值边界、条目文字来源、稳定重排）；`fushi/test/media/discovery/media_discovery_service_test.dart`（搜索分片内重排、不删、不跨源；浏览不重排）；`fushi/test/pages/media_discovery_page_test.dart`（不相关条目折进计数行、点开显示且命中仍在前、不重新请求；既有用例的搜索词改成与 fixture 标题相关）。
- **备注**：测试未在本分支运行，统一在合并后验证。未做真机复测（本批次按要求不做）。
