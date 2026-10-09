## BUG-3212 · もらうた 被推断成 もらう + 关西方言 -た
- **报告**：2026-10-09（用户截图：「誓ってもらうためには」点「も」查出 もらう，标签「-た」«「关西方言」，高亮 もらうた）
- **真实性**：✅ 真 bug（所有者 2026-10-09 认定，「估计 Yomitan 也有 bug」，同意偏离上游）。规则来自 `fushi/assets/transforms/ja.json` 的
  `kansai-ben -た`：`うた → った`（再经 `-た` 的 `った → う` 回到 もらう），与 Yomitan 上游 `japanese-transforms.js` 逐字相同；
  `native/fushidicts/fushidicts_src/lookup.cpp` 的候选合并对同一 (expression, reading) 只留最长匹配，于是「もらうた」胜过「もらう」，
  高亮吞掉「ため」的「た」并挂上 -た / 关西方言标签。Yomitan `translator.js` `_findTermsInternal` 同样按最长 transformedText 保留，**与 Yomitan 上游行为不同是有意的**，上游大概率有同样的问题。
- **[x] ① 已修复** — `lookup.cpp` 候选合并（`kansai_short_match_wins` / `protected_structure_follows`）：合并键 (expression, reading) 不变、排序不变、不降方言权重、不加二次查词。
  同一键长短竞争时，**四条全成立**才留短候选：① 短候选无需变形（trace 为空）；② 长候选变形链含 `kansai-ben`；③ 短候选原文结束处（`matched.size()` 字节偏移，候选是原文的字节前缀）起，扫描窗口内的文本以保护结构开头；④ 长候选原文匹配越过了短候选结束处。
  保护结构只有 ために / ためには / ためにも / ための / たびに / たびには。长候选先到（扫描从长到短的常态）时短候选替换它；短候选已在时长候选进不来；选定后更短的候选按原规则进不来。
  缓存：引擎结果只依赖查询串前 scan_length（16）个码点（候选在窗口内，保护结构判定也只读窗口内文本）；`packages/fushi_dictionary/lib/src/language/implementations/japanese_language.dart` 的匹配长度缓存键由「前 20 个 UTF-16 单元」改为「前 `FushiDicts.defaultScanLength` 个码点」（`matchLengthCacheKey`），键恰好覆盖判定依赖的范围（旧键在窗口含增补平面字时盖不满）。
- **[x] ② 已加自动化测试** — `native/fushidicts/tests/ja_kansai_ta_boundary_test.cpp`（真 ja.json + 三本带词性 / 重定向的 Yomitan 测试词典跑真实 Lookup）：
  修复用例（ために / ためには / ためにも / ための / たびに / たびには，maxResults=1，结果变形链为空）、真方言（買うたんや / 会うて話す / 言うたらあかん / 单独 もらうた）、标准语（買った / 会って / 食べました）、名单外（買うためだ / 買うたら 保持原行为）、
  小补丁方案的反例（またびっくりした → また、あなためがけて → あなた）、假名原文对汉字词条（かうために → 買う）、扫描窗口边缘（窗口 6 码点生效、5 码点结构被截断保持原行为）、多词典释义保留、词典重定向（もらう → 貰う 跟随照旧且同一判据生效）。
  改动前 10 条失败（F1–F7、R1、W1、D1），改动后全过；全量 ctest 37/37 绿。`fushi/test/dictionary/japanese_match_length_cache_key_test.dart` 钉缓存键按码点覆盖窗口。
- **性能**（同一词典：明鏡第三版 + 三省堂第八版 + Weblio大阪弁 + JPDBv2 频率；327 条输入 = 16 条规格用例 + 10 个长句逐字起查；基线 f99100aa15 与修改版各自编 bench，交替运行）：
  每轮 query_raw 次数 13281 vs 13281、最终候选总数 2429 vs 2429（逐条一致），顶条结果只有含保护结构的 9 条变化。耗时受本机并发负载影响很大（同一版本轮间中位数 325–472 µs）；
  9 对安静轮（p95 < 1.5 ms）里全体中位数的成对差中位 +0.7%（范围 -7.7% ~ +14.7%），p95 +2.9%，未测出超出噪声的差异。
- **备注**：小补丁方案（「た」结尾且后接「め / び」就排除）已否决：误伤 また / あなた 后接「び / め」开头的词。
