## BUG-2543 · 英语无词性 Yomitan 词典的变形还原全部失效，且不规则形无还原规则
- **报告**：2026-09-14（用户：「英语查词还不支持各种形态的变形，支持一下」）
- **真实性**：✅ 真 bug，两条独立断链，用真 DLL + 用户真词典（OALDPE10 / OALDPE En-Cn）复现：
  1. **`native/fushidicts/fushidicts_src/lookup.cpp:275` `filter_by_pos` + `query.cpp` 空 rules**：Yomitan 契约「term 的
     `rules` 为空 = 非变形词」，所以每个变形还原命中都要求词典词条的词性位与规则的 `conditionsOut` 相交，空 rules 交集恒 0
     → 整条命中被 `erase_if` 丢掉。OALDPE10 是转换器没写词性的 Yomitan 词典（~86 万条 rules 全空），结果
     walked / running / studies 这类**规则形**也一个都还原不到（探针实测只命中同形词条本身）。MDX 转的 En-Cn 因为
     `write_simple_dict` 存的是通配 `*`（`importer.cpp` SimpleEntryAccumulator）才没事。
  2. **`fushi/assets/transforms/en.json` 0 条 `wholeWord`**：Yomitan 英语规则表本来就没有替补形/不规则形，
     went / took / taken / was / been / children / mice / geese / better / best 在两部词典上全部还原不到原形
     （better 只会被 comparative 拆成 bett / bet；children→child 仅靠撞上阿尔巴尼亚语 Genitive 规则的巧合）。
- **[x] ① 已修复** — 提交 `9ccb3bb76e`
  - 引擎：新增 sidecar `term_rules.flag`（`native/fushidicts/fushidicts_src/util/term_rules_flag.hpp`，内容
    `<0|1> <blobs.bin 大小>`，大小不符视为失效）。`importer.cpp` 的 Yomitan 导入在 term bank 写入时累计
    `ImportResult::term_rules_present` 并于 marker 之前落盘；`write_simple_dict` 恒写 `1`。`query.cpp::add_dict`
    读 sidecar，缺失/失效时经 `scan_term_rules_present` 走 hash.table→记录 扫一次（带词性的词典几个槽位即命中退出，
    真无词性才全扫）并回填；`DictionaryData::rules_wildcard` 为真时 `query_raw` 把空 rules 当 `*`。
    带词性的词典（日语 JMdict 系）语义零变化：名词仍不会被拿去当动词变形的原形。
  - 数据：新增 `fushi/assets/transforms/en_irregular.json`（`language: en`，conditions 逐字复制自 en.json 以免条件位错位；
    8 组 399 条：不规则过去式 / 过去分词 / 过去式兼分词 / be·have 现在时 / 否定缩约 n't·can't·won't / 不规则复数
    （含 -men/-children/-mice 等可作用于复合词的后缀规则）/ 不规则比较级 / 最高级），`manifest.json` 加 `en_irregular`，
    `assets/transforms/i18n/zh-CN.json` 补 8 条说明译文。
  - 真机数据复测（clang 编的 `fushidicts_ffi.dll` + 用户 OALDPE10 / En-Cn）：walked→walk、went→go、took/taken→take、
    was→be、children→child、mice→mouse、geese→goose、better→good/well 在两部词典上均命中，OALDPE10 sidecar 为 `0`，En-Cn 为 `1`。
- **[x] ② 已加自动化测试** —
  - `native/fushidicts/tests/en_inflection_lookup_test.cpp`（ctest 注册，读真 en.json + en_irregular.json）：
    A 组 simple dict 上 20 条不规则/链式还原（含 `children's`、`didn't`、大写 `Went`）；B 组 Yomitan 无词性词典的
    还原 + sidecar 写入 / 存量扫描回填 / 失效 sidecar 重扫；C 组带词性词典 Yomitan 语义不变（空 rules 名词不被当动词原形）。
    变异校验：把 en_irregular.json 换成 en.json 跑出 24 条 FAIL。
  - `fushi/test/dictionary/en_irregular_transforms_guard_test.dart`：manifest 含 `en_irregular`、conditions 与 en.json
    逐字节相同（条件位顺序无关的前提）、规则全小写 ASCII / 非恒等 / 不重复 / 只用已知条件名、用户报的形态在表内。
  - 既有 `fushi/test/dictionary/transform_description_i18n_test.dart` 守卫新 description 的中文译文。
- **备注**：`*` 通配词典（MDX 转的、以及现在的无词性 Yomitan 词典）仍会吃到其它语言规则表的噪声命中
  （cats→care 走西语规则、took→too 走巴斯克语规则），修前即如此，属另一题（按词典语言限制规则表）。
  存量无词性词典首次加载会付一次记录全扫（OALDPE10 95 MB blobs 量级，秒级），之后读 sidecar。
