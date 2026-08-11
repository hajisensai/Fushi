## BUG-1570 · 远端查词响应的 truncated/headwordCount/kanjiResults 被 client 丢弃
- **报告**：2026-08-12（用户：互联健壮性审计——「服务端发了 client 不读」验真）
- **真实性**：✅ 真 bug（验真结论：该消费，不是冗余字段）。host 侧
  `fushi/lib/src/sync/fushi_remote_api_handlers.dart`（`buildRemoteDictionaryLookupResponse`
  的 `'result': jsonDecode(result.toJson())`）下发完整
  `DictionarySearchResult.toJson()`（含 truncated / headwordCount / kanjiResults）；
  client `fushi/lib/src/sync/fushi_remote_lookup_client.dart` `_parseDictionaryResult`
  （修复前 ~97 行）只取 searchTerm/bestLength/scrollPosition/entries 四字段。
  remote-first 语义（`app_model.dart` `searchDictionary` 远端结果直接返回、不走本地
  富化）下的后果：truncated 恒 false → 消费方（`base_source_page.dart:314/392`、
  `dictionary_page_mixin.dart:904/998`、`home_dictionary_page.dart:726`）判
  `allLoaded=true`，「加载更多」在远端路径永不出现（BUG-1472 失效）；headwordCount
  恒 0 → 分页基数错（BUG-1478 失效）；kanjiResults 恒空 → 远端结果永远没有汉字卡，
  且 `searchDictionary` 把 kanji-only 命中（entries 空）当「无结果」丢给本地兜底——
  瘦 client 本地根本没有汉字词典。
- **[x] ① 已修复** — `_parseDictionaryResult` 补齐三字段解析（老 host 缺字段时
  保默认 false/0/[]，行为不变）；`searchDictionary` 的「无结果」判据改为
  entries 与 kanjiResults 双空（kanji-only 远端结果与本地 kanjiOnly 分支同语义）。
- **[x] ② 已加自动化测试** —
  `fushi/test/sync/fushi_remote_lookup_result_fields_test.dart`：三字段透传（用
  host 侧真实序列化形状 `DictionarySearchResult.toJson()` 构造响应）、kanji-only
  不再判无结果、老 host 缺字段兼容。变异实测：还原 `_parseDictionaryResult` 丢字段
  → 透传用例红。
- **备注**：同轮验真的另一条「hostFingerprint 回执解析后无人消费」结论为**冗余回执、
  不接线**：两条配对入口（手动 IP `_attemptManualPair` / LAN 发现 `_connectToDevice`）
  都在配对前经 TOFU 探测/发现广播拿到指纹并用于 pinned TLS，钉扎握手本身已验证证书；
  明文 http 会话 host 无 TLS 时该字段根本不发（`fushi_sync_server.dart:904` 仅
  `_securityContext != null` 才带）。回执与已钉扎指纹恒等，接线只会增加一条
  永假分支。
