## BUG-2148 · 韩语词形还原一条都点不着火：ko.json 用兼容字母而引擎不拆谚文，划词只剩 1 个音节

- **报告**：2026-09-05（用户截图：视频字幕点 `부드러운`，只划中 `부`，弹窗查到 KRDICT 的 `부`（部/不））
- **真实性**：✅ 真 bug。根因是**缺一对文本处理器**，不是某一行写错
  - 预处理缺口：`native/fushidicts/fushidicts_src/text_processor/text_processor.cpp:493 process()`（原实现无谚文拆字）
  - 后处理缺口：`native/fushidicts/fushidicts_src/lookup.cpp:60-67`（原实现**整个「后处理」阶段都不存在**）

### 现象与链路

字幕逐 grapheme 登记（`video_subtitle_overlay.dart:2006`）→ `onCharTap`
（`video_fushi_page.dart:4446`）→ `subtitleLookupSpan`（`video_fushi_page.dart:381`）。
谚文是 `Script=Hangul`，`_isLatinWordGrapheme`（`:344`）恒 false → 起点 = 被点音节、
终点 = 句尾，**Dart 侧没有任何按字符类切段的逻辑**（用户猜测的「按脚本切分」不存在）。

送 `FushiDicts.lookup`（`app_model.dart:5493`），`scanLength` 吃默认 16
（`lookup.hpp:35` / `fushidicts.dart:807`，全仓无调用点覆盖）。高亮长度回灌走
`language.dart:540 bestLength = matched.length` → `max(1, bestLength)`（`:344`）。
`matched = "부"` → 只亮 1 个音节。

### 根因

`fushi/assets/transforms/ko.json`（450 条 transform / 2682 条 rule）导自 Yomitan 的
`korean-transforms.js`，**整表用 Hangul 兼容字母书写**。实测该表的字符构成：

```
COMPAT_JAMO (U+3130..U+318F)      21177 个字符
PRECOMPOSED_SYLLABLE (U+AC00..)     257 个字符（只出现在 suffix 规则的 toSuffix，如 있다）
CONJOINING_JAMO (U+1100..U+11FF)      0
复合元音 ㅘㅙㅚㅝㅞㅟㅢ                 0 个        ← 表是「拆到简单字母」写的
复合终声 ㄳㄵㄶㄺㄻㄼㄽㄾㄿㅀㅄ           0 个
```

本 bug 直接对应的是 `-(으)ㄴ` 里那条 ㅂ 不规则：

```json
{"type":"suffix","fromSuffix":"ㅇㅜㄴ","toSuffix":"ㅂㄷㅏ","conditionsOut":["v","adj"]}
```

而 `Deinflector::deinflect_recursive`（`deinflector.cpp:244`）是**字节级精确查表**
（`suffix_transforms_` 是 `std::map`，`find(suffix)`）。预合成串 `부드러운`
（U+BD80 U+B4DC U+B7EC U+C6B4）里永远不存在 `ㅇㅜㄴ` 那三个码点 → **450 条 transform
一条都点不着火**。于是 `scan_candidates`（`word_scan.cpp:52`）逐码点降级
（谚文不在 `is_space_delimited_letter` 的任何一段里，切点恒合法）
`부드러운 갈색 / … / 부드러운 / 부드러 / 부드 / 부`，只有 `부` 在 KRDICT 里有词头。

上游靠**一对**处理器把两边编码对齐：`disassembleHangul`（预处理，拆字去匹配规则）
+ `reassembleHangul`（后处理，拼回音节去查索引，登记在 Yomitan `ko` 描述符的
`textPostprocessors` 槽位）。**我们两半都没有**，而且引擎连「后处理」这个阶段都没有
（`lookup.cpp` 是 扫描 → 预处理 → 还原 → 直接 `query_raw`）。

`native/fushidicts/tests/` 下**一条韩语用例都没有**（`grep "ko\.json\|한국"` 零命中），
所以这个洞从来没被验证过。

### 关于「点后面的音节还是只划 부」

代理把所有可能钉死起点的机制逐条排除：起点每次点击重算（`subtitleLookupSpan:392`
第一行就是 `int start = graphemeIndex;`）、字幕逐音节登记（谚文走
`_isCjkPerCharBreakable`，`video_subtitle_overlay.dart:3645`，逐字成组）、
去重键只服务悬停（`video_fushi_page.dart:4353` 注释明写点击不经此入口）、
缓存键含 term 全串（`app_model.dart:395`）、弹窗绝不与选区垂直重叠
（`dictionary_popup_layer.dart:74-95`，BUG-098）。

按代码点 `드` 只会查 `드`。最可能的实情是：这个词里只有 `부` 在 KRDICT 有词头，
点其它音节弹「无结果」、高亮被清（`lookup_favorite.part.dart:92` `graphemeCount == 0`
→ `nextHighlight = null`），用户压缩成了「还是只有 부」。不改变根因判定。

### [x] ① 已修复

1. **拆字预处理**：`text_processor.cpp` 新增 `disassemble_hangul`
   （U+AC00–D7A3 → 兼容字母，复合元音 ㅘ→ㅗㅏ / 复合终声 ㄺ→ㄹㄱ **拆到简单字母**，
   与 ko.json 实测的书写法对齐），注册为 `get_korean_processors()` 的一个
   `{0,1}` 处理器。对不含谚文的文本是恒等变换，变体表按结果去重，**日/英查询
   不会因此多出任何变体**。
2. **合字后处理**（新增阶段）：`text_processor.cpp` 新增 `reassemble_hangul`；
   `lookup.cpp` 把「查库并并入结果」抽成 `merge_query` lambda，对每个还原形**同时查
   原形与重组形**。两种都查而不是二选一：ko.json 有 116 条 rule 的 `toSuffix` 直接写
   预合成音节，还原输出本就可能是混合串；对不含兼容字母的语言 `reassemble` 恒等、
   一次字符串比较就跳过，既有结果集一个都不变。
3. **高亮坐标系不用动**：`lookup.cpp:76` 存的 `matched` 是 `search_str`——
   `scan_candidates` 从**原始预合成文本**切出的前缀，不是预处理后的变体。所以拆字只
   发生在管线内部，`bestLength` 天然是原文长度，字幕自动划成 4 个音节。

「终声还是下一个音节的初声」的唯一判据：**后面不跟元音才收作终声**。
`ㅂㅜㄷㅡㄹㅓㅂㄷㅏ` 里第二个 ㅂ 后面是 ㄷ → 收进 러 得 럽 → `부드럽다`；
`ㅎㅏㄱㅗ` 里 ㄱ 后面是 ㅗ → 不收，另起音节 → `하고`。

修复前先用 Python 原型在真数据上验证过：18 个真实韩语词（含 괜찮아요/왔다/쉬웠어/
의사/읽다/값/닭 与中英混排）**拆合往返 100% 无损**，且喂真 ko.json 规则确实得到
`disassemble(부드러운)` = `ㅂㅜㄷㅡㄹㅓㅇㅜㄴ` → 命中 `ㅇㅜㄴ→ㅂㄷㅏ` →
`reassemble` = `부드럽다`。

### [x] ② 已加自动化测试

`native/fushidicts/tests/korean_hangul_lookup_test.cpp`（已注册进 `tests/CMakeLists.txt`）：

1. 拆合互逆：14 个样本覆盖无终声/单终声/复合终声（ㄺ ㅄ）/复合元音（ㅙ ㅢ ㅘ ㅟ ㅝ）/
   谚文与汉字拉丁混排/空串；并钉住「非谚文拆字后一字不变」（否则日/英查询白白扇出变体）。
2. 拆到简单字母：`읽 → ㅇㅣㄹㄱ`、`왔 → ㅇㅗㅏㅆ`。
3. 终声判据两个方向 + 散字母透传（`ㄱ` 单独出现时不得被吞进音节）。
4. 端到端：词典里**同时**放 `부드럽다` 和 `부`（后者正是用户看到的那个短匹配），
   用真 ko.json 规则形状查 `부드러운 갈색`，断言命中 `부드럽다`、
   `matched == "부드러운"`（原始预合成串）、最长匹配 ≥ 4 个码点。

Red/green：把 `get_korean_processors` 从处理器链摘掉，或去掉 `lookup.cpp` 的 reassemble
那一路，第 4 组立刻红。

### 备注

`dictionary_page_mixin.dart:1097` 的 `lookupHighlightCharCount(..., language:
JapaneseLanguage.instance)` 对所有语言硬编码日语 `Language` 实例。对韩语恰好走对分支
（`isSpaceDelimited: false` → `max(1, bestLength)`），但这是巧合不是设计——哪天韩语要按
空格分词处理，这里会静默算错。不在本次范围，记在这里。
