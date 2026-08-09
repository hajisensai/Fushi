## BUG-1478 · 捕获工作台只能点整词、点不了单个字；加载更多按 glossary 行递增上限
- **报告**：2026-08-09（用户本人 + 「某猿。」的 A1）
  - 原话：「提前被分好词了。没办法点击单个文字，只能点击单词。」
  - 同轮：「最大词条数应该改一下，往下滚动支持继续加载。」
- **真实性**：✅ 真 bug，两处。
  - **① 命中粒度被分词器绑死**：`fushi/lib/src/pages/implementations/texthooker_page.dart`
    的正文是 `Wrap` + 逐**词** `InkWell`（`_WordSpan`），查询串直接就是分词器切出来的
    那个词。于是「永遠」只能整体查，想单独查「遠」无从下手。
    分词只该决定**看起来**怎么断，不该决定**点得到**什么粒度。
  - **② 加载更多的递增单位错了**：三处 load-more 都写
    `newMax = result.entries.length + maximumTerms`，而 `entries.length` 是 **glossary
    注释行数**、`newMax` 是**词头**预算 —— [[BUG-1472]] 那个「同一个数字被两层当两种
    语义用」的老毛病在分页这一处的残留。一个词头带十几条注释时上限会一次暴涨十几倍，
    等于每次下滚都把整本词典往回捞。
    （滚动接线本身是好的：`onScrolledToBottom` 三处都在，`allLoaded` 也已在 BUG-1472
    改成读显式 `truncated`。）
- **[x] ① 已修复**
  - `_WordSpan` 改成渲染整词、但按**字素簇**逐个建命中区（`_CharSpan`）。用字素簇不用
    UTF-16 code unit：绝不劈开代理对 / 浊点 / 组合字。词间不插任何间距，视觉上仍是
    原来那一串分好词的正文。
  - 查询串改成「**从命中的那个字到行尾**」截断到 24 字符，**不是**分词器切的那个词：
    引擎本来就按查询串做最长匹配并回报 `bestLength`（弹窗据此高亮整词跨度），
    所以点「永」照样命中「永遠」，点「遠」能单独查到「遠」。这与浮窗 / 歌词 / 阅读器
    的字级模型一致，也是引擎本来就为之设计的用法。
  - 词首偏移由 `_indexedWords` 按前缀长度累加得到，**不在原文里搜索** —— 搜索会在
    重复词上给出错误位置。依赖既有不变式：`textToWords` 是切分不是改写，拼回即原文。
  - load-more 三处（`base_source_page` / `dictionary_page_mixin` / `home_dictionary_page`）
    改按词头递增；为此给 `DictionarySearchResult` 加 `headwordCount`（构造方直接算，
    随 `toJson`/`fromJson`/`withKanjiResults` 传播），不再让消费方从 `entries.length` 反推。
- **[x] ② 已加自动化测试** — 见提交内的测试改动；`flutter analyze`（含 test）零问题。
- **备注**：`maximumTerms` 的**默认值维持 10** —— 在 BUG-1472 把预算单位改成词头之后，
  「10」终于名副其实（10 个词头），不再是「10 条注释行 ≈ 1~2 个词头」。真正让用户看到
  更多结果的是那次单位修正 + 本次 load-more 单位修正，而不是把默认值调大。
