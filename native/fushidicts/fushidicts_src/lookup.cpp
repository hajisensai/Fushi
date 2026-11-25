#include "fushidicts/lookup.hpp"

#include <utf8.h>

#include <algorithm>
#include <climits>
#include <map>
#include <optional>
#include <ranges>
#include <unordered_map>

#include "scan/mixed_orthography.hpp"
#include "scan/ruby_reading.hpp"
#include "scan/word_scan.hpp"
#include "text_processor/text_processor.hpp"
#include "util/pos_required.hpp"
#include "util/redirect_glossary.hpp"

namespace {
// 上游 909c854 revert 了 4975788 的向量比较（作者自己否掉的实验：每次比较
// 分配+排序一个 vector，partial_sort 下纯浪费）；后随 bc62d2b 演化为 optional +
// 方向感知（Descending 时取该词典内最大值而非最小值）。
std::optional<int> get_freq_value_for_dict(const TermResult& term, std::string_view dictionary_name, bool descending) {
  std::optional<int> frequency;
  for (const auto& frequency_entry : term.frequencies) {
    if (frequency_entry.dict_name != dictionary_name || frequency_entry.frequencies.empty()) {
      continue;
    }

    for (const auto& candidate : frequency_entry.frequencies) {
      if (candidate.value < 0) {
        continue;
      }
      frequency = frequency.has_value() ? std::optional<int>(descending ? std::max(*frequency, candidate.value)
                                                                        : std::min(*frequency, candidate.value))
                                        : std::optional<int>(candidate.value);
    }
  }

  return frequency;
}

// Yomitan「词典自带变形」（dictionary deinflection）：term bank 里 glossary 项
// 除了文本 / structured-content，还可以是 `[formOf, [rule, ...]]`——「本词条是
// formOf 的一种形态，查它」。英语词典大量用它做短语重定向：LDOCE5++ 的
// `instead of` → `instead of somebody/something`、`brush off` →
// `brush somebody/something ↔ off`、`in fact` → `in (actual) fact`，一本 21.8 万条。
// Yomitan 的 translator（`_getDictionaryDeinflections`）把它当成一次额外的还原：
// 去查 formOf，命中的词条以原查询串的匹配长度入结果，rule 文本接在变形链后面。
//
// 只认**整条 glossary 都由这种项组成**的记录：它们没有任何可显示的释义，原样留着
// 只会在弹窗里变成被 isRedirectGlossary 滤空的卡片——这正是 BUG-2853 的症状（高亮
// 到了 `instead of`，卡片却只剩 `instead`）。与正文混排的自指标签（OALDPE10 的
// `["give up", ["Redirected from give up"]]` + 释义，BUG-2566）不动。
//
// Jitendex 的重定向词条（`怖気つく` → `怖気づく`）是同一回事的另一种写法：一张
// `data.content == "redirect-glossary"` 的「⟶ 目标词」链接卡，通常再跟一条 formOf
//（BUG-5272）。它同样整条没有释义，同样摘掉并跟随一层——效果与 HoshiDict 一致：
// 直接出目标词条。
//
// 判据（原始大小门槛 + 前置判据 + 整体解析）在 util/redirect_glossary.hpp 只写一次，
// 导入端打标与迁移扫描共用。所属词典经 sidecar 确认无重定向（dict_redirect_free）时
// 整条检测跳过：既不读帧头也不解压——冷页下这一步原本要把每个候选命中的每条
// glossary 所在页都缺页读进来，而它们大多数随后被去重 / 截断丢掉、根本不会 materialize。
bool redirect_check_needed(const GlossaryEntry& g) {
  return !g.dict_redirect_free && fushi::redirect_glossary::may_be_redirect(g.compressed_data, g.compressed_size);
}

bool matches_primary_reading(const TermResult& term, std::string_view primary_reading) {
  return term.reading == primary_reading;
}

// BUG-3212：关西方言变形跨词吞掉「ため / たび」的「た」。
//
// ja.json 的 kansai-ben -た 有一条与 Yomitan 上游逐字相同的 `うた → った`（用于
// 思うた / 言うた），于是「もらうためには」里的「もらうた」会被还原成 もらう；同一
// (expression, reading) 只保留最长匹配，结果高亮吞掉「ため」的「た」并挂上 -た /
// 关西方言标签。Yomitan 的 translator 同样按最长 transformedText 保留，上游大概率有
// 同样的问题——这里是有意偏离上游的窄修复，不改合并键、不改排序、不降方言权重。
//
// 同一 (expression, reading) 的长短两个候选竞争时，仅当下面四条**全部**成立才留短的：
//   1. 短候选无需变形即可直接命中（trace 为空）；
//   2. 长候选的变形链里有关西方言规则；
//   3. 从短候选的原文结束位置起，后续文本以保护结构开头；
//   4. 长候选的原文匹配确实越过了短候选的结束位置（即跨进了该结构）。
// 第一版保护结构只有下面六个；不保护所有「た / て」开头的词，也不凭出现「ため /
// たび」就截断。
constexpr std::string_view kKansaiBenGroup = "kansai-ben";
constexpr std::string_view kKansaiProtectedSuffixes[] = {
    "ために", "ためには", "ためにも", "ための", "たびに", "たびには",
};

bool has_kansai_rule(const std::vector<TransformGroup>& trace) {
  return std::ranges::any_of(trace, [](const TransformGroup& g) { return g.name == kKansaiBenGroup; });
}

// [window] 是本次查词的扫描窗口（lookup_string 的前 scan_length 个码点，UTF-8 字节
// 视图）；候选都是它的字节前缀（scan_candidates 保证），所以候选的原文结束位置就是
// `matched.size()` 这个**字节**偏移，不能拿还原后词条的长度去算。后缀检查只看窗口
// 内的文本：引擎结果因此只依赖前 scan_length 个码点，与 Dart 侧匹配长度缓存的键
// 覆盖范围一致（见 japanese_language.dart `_lookupMatchedLength`）。
bool protected_structure_follows(std::string_view window, std::size_t end_bytes) {
  if (end_bytes >= window.size()) return false;
  const std::string_view rest = window.substr(end_bytes);
  return std::ranges::any_of(kKansaiProtectedSuffixes,
                             [rest](std::string_view suffix) { return rest.starts_with(suffix); });
}

// 同一 (expression, reading) 的两个候选：短的原文匹配到字节 [short_end]、变形链
// [short_trace]，长的到 [long_end]、变形链 [long_trace]。四条都成立时返回 true，
// 表示应留短的。只做字符串比较，不访问词典。
bool kansai_short_match_wins(std::string_view window, std::size_t short_end,
                             const std::vector<TransformGroup>& short_trace, std::size_t long_end,
                             const std::vector<TransformGroup>& long_trace) {
  return short_trace.empty() && long_end > short_end && has_kansai_rule(long_trace) &&
         protected_structure_follows(window, short_end);
}

// 上游 hoshidicts ad0be91：还原形相对变体改写了多少个尾部码点——从两串第一个不同的
// 字节（退回到所在码点的首字节）数到变体末尾。只在尾部追加（食べ → 食べる）算 0。
// 与 TextVariant::min_rewrite / max_rewrite 比，见 text_processor.hpp。
size_t rewritten_chars(std::string_view variant, std::string_view deinflected) {
  auto it = std::ranges::mismatch(variant, deinflected).in1;
  while (it != variant.begin() && it != variant.end() && (static_cast<unsigned char>(*it) & 0xc0) == 0x80) {
    --it;
  }
  return utf8::distance(it, variant.end());
}

bool rewrite_allowed(const TextVariant& variant, const DeinflectionResult& deinflection) {
  const size_t rewritten = rewritten_chars(variant.text, deinflection.text);
  return rewritten <= variant.max_rewrite && (rewritten == 0 || rewritten >= variant.min_rewrite);
}

// 词条 rules 里去掉通配 "*" 之后剩下的词性标记。rules 是同一 (expression, reading) 在各
// 词典里的词性并起来的（query.cpp 的 query_raw 逐本追加）：无词性词典的记录贡献 "*"
// （见 Deinflector::pos_to_conditions），带词性的词典贡献真词性，所以一条词条可以同时
// 有两者——「要求词性」的还原只看真词性那部分，不能因为另一本词典给了 "*" 就整条丢掉。
// 切分口径与 rules_to_conditions 相同：C locale 的六个空白字符。
std::string explicit_rules(std::string_view rules) {
  constexpr std::string_view kSpace = " \t\n\v\f\r";
  std::string out;
  std::size_t pos = 0;
  while (true) {
    const std::size_t begin = rules.find_first_not_of(kSpace, pos);
    if (begin == std::string_view::npos) return out;
    std::size_t end = rules.find_first_of(kSpace, begin);
    if (end == std::string_view::npos) end = rules.size();
    const std::string_view token = rules.substr(begin, end - begin);
    if (token != "*") {
      if (!out.empty()) out += ' ';
      out += token;
    }
    pos = end;
  }
}

// 扫描窗口内紧跟在候选 [candidate_bytes] 之后的码点；候选到窗口末尾时为 0。只看窗口内
// 的文本，理由同 protected_structure_follows。已知限制：候选恰好到窗口末尾（窗口在片假名
// 词中间截断）时取不到下一个字，片假名词边界保护对这个候选不生效；通常还有更短的候选
// 兜底，且改成看窗口外会破坏「结果只依赖前 scan_length 个码点」的缓存前提。
char32_t next_char_in_window(std::string_view window, std::size_t candidate_bytes) {
  if (candidate_bytes >= window.size()) return 0;
  auto it = window.begin() + static_cast<std::ptrdiff_t>(candidate_bytes);
  return utf8::peek_next(it, window.end());
}

// 同匹配长度的两条命中，a 是否比 b 更「直接」：先比变形链长，再比文本预处理步数。
//
// Yomitan（translator.js `_sortTermDictionaryEntries`）的顺序相反——先比预处理链、再比
// 变形链——那样「My」会排出 M 在 my 前面：大小写折叠算 1 步预处理、0 步变形，而
// My 经英语 -y 规则还原成 M 是 0 步预处理、1 步变形（反馈 WIZUEQx1fY）。预处理只是
// 把同一个词换一种写法（大小写、全半角、假名种类、去变音符），变形还原则是猜一个
// **别的词**，所以写法归一后的精确命中应当排在靠猜的还原形前面。大小写完全一致的
// 命中仍然优先（March / march 两边变形链都是 0，再比步数）。
bool more_direct(std::size_t trace_a, int steps_a, std::size_t trace_b, int steps_b) {
  if (trace_a != trace_b) return trace_a < trace_b;
  return steps_a < steps_b;
}
}

std::vector<LookupResult> Lookup::lookup(const std::string& lookup_string, int max_results, size_t scan_length,
                                         const LookupOptions& options) const {
  std::map<std::pair<std::string, std::string>, LookupResult> result_map;

  // 本次查词排除的词典（LookupOptions::excluded_dictionaries）：在查库层整本跳过
  //（query_raw / enrich_freq / enrich_pitch），所以它的释义、词性 rules、score、频率、
  // 音调都不进来，重定向也不跟随——不占 max_results 名额、不影响排序，与没装它逐字
  // 一致。空集时传 nullptr，查库路径与此前完全相同。
  const DictionaryQuery::ExcludedDictNames excluded_set(options.excluded_dictionaries.begin(),
                                                        options.excluded_dictionaries.end());
  const DictionaryQuery::ExcludedDictNames* excluded = excluded_set.empty() ? nullptr : &excluded_set;
  auto is_excluded = [excluded](std::string_view dict_name) { return excluded && excluded->contains(dict_name); };
  // 查库上下文：排除集 + 进入时取的联合过滤器快照（整次查词共用一份）。
  const DictionaryQuery::QueryScope scope = query_.make_scope(excluded);

  // 词典语言把关：标了语言的词典只接受**本语言**变形表还原出来的词形。变形表是所有
  // 语言一起装的，拉丁字母语言又共用后缀（阿尔巴尼亚语 -ur、拉丁语 -e），不把关的话
  // 英语词典会被别的语言的规则查到 Our → O、One → On（反馈 WIZUEQx1fY）。
  //
  //   * 精确命中（没经过任何规则，language == -1）照旧查全部词典——这不是按语言
  //     过滤词典，只是不拿 A 语言的语法去读 B 语言的词典；
  //   * 未标注语言的词典无从判断，照旧接受任何语言的还原链；
  //   * 把关落在查库层（复用排除集）：语言不符的词典整本跳过，它的词性 rules / score
  //     也不并进来，与 excluded_dictionaries 同一语义。
  //
  // allowed_languages：本次参与查词的词典**全都**标了语言时，没有任何词典会接受的
  // 语言不必展开还原（纯加速，结果不变）；只要有一本未标注就得全展开。
  struct LanguageScope {
    DictionaryQuery::ExcludedDictNames names;
    DictionaryQuery::QueryScope scope;
  };
  bool any_labeled = false;
  bool all_labeled = true;
  uint64_t allowed_languages = 0;
  for (const DictionaryQuery::Dictionary& dict : query_.term_dicts_) {
    if (is_excluded(dict.name)) continue;
    if (dict.language.empty()) {
      all_labeled = false;
      continue;
    }
    any_labeled = true;
    const int id = deinflector_.language_id(dict.language);
    if (id >= 0 && id < 64) allowed_languages |= uint64_t{1} << id;
  }
  if (!all_labeled) allowed_languages = Deinflector::kAllLanguages;
  std::unordered_map<int, LanguageScope> language_scopes;
  auto scope_for = [&](int language) -> const DictionaryQuery::QueryScope& {
    if (language < 0 || !any_labeled) return scope;
    auto [it, fresh] = language_scopes.try_emplace(language);
    LanguageScope& entry = it->second;
    if (fresh) {
      entry.scope = scope;
      const std::string& name = deinflector_.language_name(language);
      for (const DictionaryQuery::Dictionary& dict : query_.term_dicts_) {
        if (!dict.language.empty() && dict.language != name) entry.names.insert(dict.name);
      }
      if (!entry.names.empty()) {
        entry.names.insert(excluded_set.begin(), excluded_set.end());
        entry.scope.excluded = &entry.names;
      }
    }
    return entry.scope;
  };

  // BUG-3212：扫描窗口（前 scan_length 个码点）的字节视图，供关西方言保护结构判定。
  std::size_t window_bytes = 0;
  {
    auto it = lookup_string.begin();
    for (std::size_t n = 0; n < scan_length && it != lookup_string.end(); ++n) {
      utf8::next(it, lookup_string.end());
    }
    window_bytes = static_cast<std::size_t>(it - lookup_string.begin());
  }
  const std::string_view scan_window(lookup_string.data(), window_bytes);

  // BUG-3261：混写通路的本次查词内缓存。同一段汉字的读音、同一个候选读音的查库结果
  // 在 16 个前缀 × 文本变体 × 还原形里会反复出现，各查一次。
  std::unordered_map<std::string, std::vector<std::string>> run_readings_cache;
  std::unordered_map<std::string, std::vector<std::string>> mixed_candidates_cache;
  std::unordered_map<std::string, std::vector<TermResult>> mixed_reading_hits;
  const mixed_orthography::RunReadings run_readings = [&](const std::string& run) -> const std::vector<std::string>& {
    auto [it, inserted] = run_readings_cache.try_emplace(run);
    if (inserted) {
      // 按「多少本词典把它列为该表记的读音」降序：常用读音排前，组合截断时先保留它们。
      std::map<std::string, int> votes;
      for (const TermResult& term : query_.query_raw(run, scope)) {
        if (term.expression == run && !term.reading.empty()) {
          votes[mixed_orthography::to_hiragana(term.reading)] += static_cast<int>(term.glossaries.size());
        }
      }
      for (auto& [reading, _] : votes) it->second.push_back(reading);
      std::ranges::stable_sort(it->second, [&votes](const std::string& a, const std::string& b) {
        return votes[a] > votes[b];
      });
    }
    return it->second;
  };

  // 候选前缀由词边界感知的扫描器生成（对齐 Yomitan searchResolution）：
  // 空格分词语言不在单词中间切断，CJK 仍逐码点。详见 scan/word_scan.hpp。
  for (const std::string& search_str : scan_candidates(lookup_string, scan_length)) {
    auto processor_results = text_processor::process(search_str, options.chinese_simp_to_trad,
                                                     next_char_in_window(scan_window, search_str.size()));
    for (auto& variant : processor_results) {
      auto deinflection_results = deinflector_.deinflect(variant.text, allowed_languages);

      // 跟随重定向时要查的目标：(formOf, 变形链 + 词典 rule, 变形链的语言)。见
      // DictionaryRedirect。
      struct RedirectTarget {
        std::string form_of;
        std::vector<TransformGroup> trace;
        int language;
      };
      std::vector<RedirectTarget> redirect_targets;

      // 把查库命中并入 result_map：纯重定向 glossary 摘掉（记下目标，跟随时 [follow]
      // 为真才记——Yomitan 只跟一层），摘空的词条不入结果。
      auto merge_terms = [&](std::vector<TermResult>& terms, const std::string& query_text,
                             const std::vector<TransformGroup>& trace, int language, bool follow) {
        for (auto& term : terms) {
          std::erase_if(term.glossaries, [&](const GlossaryEntry& g) {
            if (!redirect_check_needed(g)) return false;
            auto redirects = fushi::redirect_glossary::parse(
                DictionaryQuery::decompress_glossary(g.compressed_data, g.compressed_size, g.zstd_dict));
            if (!redirects) return false;
            if (follow) {
              for (auto& redirect : *redirects) {
                if (redirect.form_of == term.expression) continue;
                std::vector<TransformGroup> chained = trace;
                for (auto& rule : redirect.rules) {
                  chained.push_back(TransformGroup{.name = std::move(rule), .description = {}});
                }
                redirect_targets.push_back({.form_of = std::move(redirect.form_of),
                                            .trace = std::move(chained),
                                            .language = language});
              }
            }
            return true;
          });
          if (term.glossaries.empty()) continue;

          // deduplicate glossaries
          auto key = std::make_pair(term.expression, term.reading);
          auto it = result_map.find(key);
          if (it != result_map.end()) {
            // BUG-3212：关西方言跨进「ため / たび」时留无需变形的短候选。扫描从长到短，
            // 通常是长候选先进来、短候选后到时替换；反过来（短的已在、长的后到）同一
            // 判据挡住长的。一旦留下短候选，后续更短的候选按下面的常规规则进不来，
            // 选定结果不会被再次覆盖。
            const LookupResult& held_result = it->second;
            if (kansai_short_match_wins(scan_window, search_str.size(), trace, held_result.matched.size(),
                                        held_result.trace)) {
              it->second = LookupResult{.matched = search_str,
                                        .deinflected = query_text,
                                        .trace = trace,
                                        .term = std::move(term),
                                        .preprocessor_steps = variant.steps};
              continue;
            }
            if (kansai_short_match_wins(scan_window, held_result.matched.size(), held_result.trace,
                                        search_str.size(), trace)) {
              continue;
            }
            // we only need the longest matched form
            const size_t incoming = utf8::distance(search_str.begin(), search_str.end());
            const size_t held = utf8::distance(it->second.matched.begin(), it->second.matched.end());
            // 同长时按**预处理步数更少**取胜。`process()` 的变体是 std::map，按码点
            // 字典序迭代，拆字形（首字 ㅂ U+3142）排在原形（부 U+BD80）之前，于是
            // 一个根本不需要变形的韩语词会先由拆字变体（steps=1）落进 result_map，
            // 原形变体（steps=0）随后长度相等、进不来——整批韩语结果的
            // preprocessor_steps 被无谓抬成 1。它是排序键（见下方 partial_sort）并经
            // FFI 出到 Dart，纯韩语结果集内部只是整体平移，但与其它语言混排时会把
            // 韩语的精确命中往后压（BUG-2148 审查发现）。
            //
            // 两个变体谁留下，与比较器同一口径：先比变形链长、再比预处理步数
            //（more_direct）。同一变体内（步数相同）仍是先到先得。
            if (incoming > held ||
                (incoming == held && variant.steps != it->second.preprocessor_steps &&
                 more_direct(trace.size(), variant.steps, it->second.trace.size(),
                             it->second.preprocessor_steps))) {
              it->second = LookupResult{.matched = search_str,
                                        .deinflected = query_text,
                                        .trace = trace,
                                        .term = std::move(term),
                                        .preprocessor_steps = variant.steps};
            }
          } else {
            result_map.emplace(key, LookupResult{.matched = search_str,
                                                 .deinflected = query_text,
                                                 .trace = trace,
                                                 .term = std::move(term),
                                                 .preprocessor_steps = variant.steps});
          }
        }
      };

      // 用一个还原形去查库并并入结果。`query_text` 未必等于 `deinflection.text`
      // ——见下面的谚文重组。
      auto merge_query = [&](const std::string& query_text, const DeinflectionResult& deinflection) {
        auto terms = query_.query_raw(query_text, scope_for(deinflection.language));
        filter_by_pos(terms, deinflection);
        merge_terms(terms, query_text, deinflection.trace, deinflection.language, /*follow=*/true);
      };

      for (auto& deinflection : deinflection_results) {
        // 上游 ad0be91：变形不得跨过预处理删掉的字符、不得只改写片假名词的一截。
        if (!rewrite_allowed(variant, deinflection)) continue;

        // 后处理（Yomitan `textPostprocessors`，本引擎此前完全没有这个阶段）：
        // 韩语的还原是在**兼容字母域**里做的（ko.json 整表这么写，预处理端由
        // text_processor::disassemble_hangul 拆字对齐），而词典索引的键是**预合成
        // 音节**，所以还原结果必须拼回音节才查得到（BUG-2148）。
        //
        // 两种形态都查而不是二选一：ko.json 有 116 条 rule 的 toSuffix 直接写着
        // 预合成音节（`있다`），还原输出本就可能是混合串；而对不含兼容字母的语言，
        // reassemble 恒等、一次字符串比较就跳过，既有结果集一个都不会变。
        // _utf8 版带字节级前置判据：不含兼容字母时原样返回、一次编码转换都不做
        // （一次日语查词的还原形有几十上百个，无条件往返是白烧 CPU）。
        const std::string reassembled = text_processor::reassemble_hangul_utf8(deinflection.text);
        merge_query(deinflection.text, deinflection);
        if (reassembled != deinflection.text) merge_query(reassembled, deinflection);

        // BUG-3261：汉字 + 假名混写（棚にあげる → 棚に上げる）。表记键与读音键都对不上，
        // 改用各汉字段的读音拼出候选完整读音去查读音索引，查回的词条逐字核对混写关系
        // 后才收录。deinflected 记查询里的混写形，排序比较器因此把它排在同长度的表记
        // 精确命中之后。
        if (mixed_orthography::is_mixed(deinflection.text)) {
          auto [cand_it, fresh] = mixed_candidates_cache.try_emplace(deinflection.text);
          if (fresh) cand_it->second = mixed_orthography::reading_candidates(deinflection.text, run_readings);
          // 读音查库的结果取决于语言把关后的词典集合：有标注词典时缓存键带上语言。
          const int scope_language = any_labeled ? deinflection.language : -1;
          for (const std::string& candidate : cand_it->second) {
            auto [hit_it, uncached] =
                mixed_reading_hits.try_emplace(candidate + '\x1f' + std::to_string(scope_language));
            if (uncached) hit_it->second = query_.query_raw(candidate, scope_for(deinflection.language));
            std::vector<TermResult> terms;
            for (const TermResult& term : hit_it->second) {
              if (mixed_orthography::matches_mixed_orthography(deinflection.text, term.expression, term.reading)) {
                terms.push_back(term);
              }
            }
            if (terms.empty()) continue;
            filter_by_pos(terms, deinflection);
            merge_terms(terms, deinflection.text, deinflection.trace, deinflection.language, /*follow=*/true);
          }
        }
      }

      // 词典重定向的目标不经词性过滤（Yomitan 给它的 deinflection 不带条件），
      // 也不再跟随第二层。匹配长度仍是本轮 search_str。
      for (RedirectTarget& target : redirect_targets) {
        auto terms = query_.query_raw(target.form_of, scope_for(target.language));
        merge_terms(terms, target.form_of, target.trace, target.language, /*follow=*/false);
      }
    }
  }

  auto results = result_map | std::views::values | std::views::as_rvalue | std::ranges::to<std::vector>();

  // BUG-1665: MDX/StarDict importers resolve redirects (@@@LINK= / .syn) by
  // copying the target's definition under the inflected key, so "belongs"
  // carries belong's bytes as its own entry. A lookup of "belongs" then
  // surfaces BOTH that alias exact hit and the deinflected lemma hit, and the
  // alias (0 transforms) sorts first — the popup header and the mined Anki
  // term become the inflected surface form instead of the lemma (Yomitan
  // mines the lemma). The importer dedupes identical definitions by hash into
  // ONE compressed blob, so within a dict an alias glossary and its lemma
  // glossary share the same blob pointer — a byte-exact redirect detector
  // that needs no re-import of already-imported dictionaries. For each
  // surface form, drop from the untransformed exact hit every glossary whose
  // blob also backs a lemma hit (a real transform whose result is the entry's
  // own expression) of the same surface; drop the result once empty. Spelling
  // variants (colour → color) have no deinflection rule and are untouched; a
  // dictionary with a genuinely distinct inflected entry keeps it (different
  // blob).
  auto same_blob = [](const GlossaryEntry& x, const GlossaryEntry& y) {
    // 按 blob 身份（来源文件 + 偏移）判等，不比指针：32 位窗口映射下同一 blob 可能
    // 落在不同窗口（BUG-4013）；64 位整份映射时两者等价。
    return x.compressed_source == y.compressed_source && x.compressed_offset == y.compressed_offset &&
           x.compressed_size == y.compressed_size && x.dict_name == y.dict_name;
  };
  for (auto& r : results) {
    // Only an untransformed direct expression hit can be a redirect alias.
    if (!r.trace.empty() || r.term.expression != r.deinflected) {
      continue;
    }
    for (const auto& lemma : results) {
      if (&lemma == &r || lemma.matched != r.matched) continue;
      if (lemma.trace.empty() || lemma.term.expression != lemma.deinflected) continue;
      std::erase_if(r.term.glossaries, [&](const GlossaryEntry& g) {
        return std::ranges::any_of(lemma.term.glossaries,
                                   [&](const GlossaryEntry& lg) { return same_blob(g, lg); });
      });
    }
  }
  std::erase_if(results, [](const LookupResult& r) { return r.term.glossaries.empty(); });

  // BUG-1304: frequency enrichment happens ONCE here, on the deduplicated set,
  // instead of inside every query_raw() call above (which runs once per
  // scan-candidate x text-variant x deinflection -- ~69 times per user lookup,
  // measured, each one hitting every frequency dictionary with its own JSON
  // parse, for results that the dedup/sort/resize below mostly discard).
  // Measured effect: 9.4 -> 3.2 enrichments per lookup, ~5-9% end to end.
  // It must precede the sort because the comparator ranks by frequency.
  // Enriching per (expression, reading) is what query_freq did all along, so
  // the surviving results carry byte-identical frequency data.
  for (auto& r : results) {
    query_.enrich_freq(r.term, scope);
  }

  // 原文振假名一致度每条只算一次（比较器里会被反复比较）。
  const ruby_reading::Matcher ruby_matcher(options.ruby_readings);
  if (!ruby_matcher.empty()) {
    for (auto& r : results) {
      r.ruby_agreement = ruby_matcher.agreement(r.matched, r.term.expression, r.term.reading);
    }
  }

  // 上游 bc62d2b：排序选项解析。Auto = 既有比较器（按注册顺序遍历全部 freq 词典，
  // 零行为变化）；显式指定词典 + 升/降序时只按该词典排（找不到词典名则静默退回，
  // 不排序也不报错——与上游一致）。
  std::vector<std::string> auto_frequency_dictionaries;
  std::optional<std::string_view> frequency_dictionary;
  bool frequency_descending = false;
  switch (options.frequency_order) {
    case LookupFrequencyOrder::Auto:
      auto_frequency_dictionaries = query_.get_freq_dict_order();
      // 被排除的频率词典不进比较器的词典序（它的条目本来也没被富化进来）。
      std::erase_if(auto_frequency_dictionaries, [&is_excluded](const std::string& name) { return is_excluded(name); });
      break;
    case LookupFrequencyOrder::Ascending:
    case LookupFrequencyOrder::Descending:
      if (options.frequency_dictionary.has_value()) {
        const auto selected =
            std::ranges::find(query_.freq_dicts_, *options.frequency_dictionary, &DictionaryQuery::Dictionary::name);
        // 指定的排序词典被排除 = 当作找不到（与上游「找不到则静默不排」同一语义）。
        if (selected != query_.freq_dicts_.end() && !is_excluded(selected->name)) {
          frequency_dictionary = selected->name;
          frequency_descending = options.frequency_order == LookupFrequencyOrder::Descending;
        }
      }
      break;
    case LookupFrequencyOrder::Disabled:
      break;
  }
  std::string_view primary_reading;
  if (options.primary_reading.has_value()) {
    primary_reading = *options.primary_reading;
  }

  auto middle_iter = std::ranges::next(results.begin(), max_results, results.end());
  std::ranges::partial_sort(
      results, middle_iter,
      [&auto_frequency_dictionaries, frequency_dictionary, frequency_descending, primary_reading](const auto& a,
                                                                                                  const auto& b) {
        // 上游 86c6e2f：primary_reading 精确匹配者排最前（截断前生效）。
        if (!primary_reading.empty()) {
          const bool primary_a = matches_primary_reading(a.term, primary_reading);
          const bool primary_b = matches_primary_reading(b.term, primary_reading);
          if (primary_a != primary_b) {
            return primary_a;
          }
        }

        auto len_a = utf8::distance(a.matched.begin(), a.matched.end());
        auto len_b = utf8::distance(b.matched.begin(), b.matched.end());
        if (len_a != len_b) {
          return len_a > len_b;
        }

        // 原文 ruby：只在同匹配长度之内起作用（最长匹配决定高亮与制卡词形，ruby 不跨
        // 长度挪结果），压过变形步数与频率——`<ruby>忙<rt>せわ</rt></ruby>しい` 的
        // せわしい 排在高频的 いそがしい 前面。无 ruby 时两边恒 0，此档恒平。
        if (a.ruby_agreement != b.ruby_agreement) {
          return a.ruby_agreement > b.ruby_agreement;
        }

        // 变形链长先于预处理步数（与 Yomitan 相反，见 more_direct）。
        if (a.trace.size() != b.trace.size() || a.preprocessor_steps != b.preprocessor_steps) {
          return more_direct(a.trace.size(), a.preprocessor_steps, b.trace.size(), b.preprocessor_steps);
        }

        auto match_a = a.term.expression == a.deinflected;
        auto match_b = b.term.expression == b.deinflected;
        if (match_a != match_b) {
          return match_a > match_b;
        }

        for (const auto& dictionary_name : auto_frequency_dictionaries) {
          const int freq_a = get_freq_value_for_dict(a.term, dictionary_name, false).value_or(INT_MAX);
          const int freq_b = get_freq_value_for_dict(b.term, dictionary_name, false).value_or(INT_MAX);
          if (freq_a != freq_b) {
            return freq_a < freq_b;
          }
        }

        if (frequency_dictionary.has_value()) {
          const auto freq_a = get_freq_value_for_dict(a.term, *frequency_dictionary, frequency_descending);
          const auto freq_b = get_freq_value_for_dict(b.term, *frequency_dictionary, frequency_descending);
          if (freq_a.has_value() != freq_b.has_value()) {
            return freq_a.has_value();
          }
          if (freq_a.has_value() && *freq_a != *freq_b) {
            return frequency_descending ? *freq_a > *freq_b : *freq_a < *freq_b;
          }
        }

        // 上游 909c854：Yomitan score 降序（v2 词典落盘；v1 恒 0 = 此档恒平）。
        if (a.term.score != b.term.score) {
          return a.term.score > b.term.score;
        }

        auto a_reading_expr_match = a.term.expression == a.term.reading;
        auto b_reading_expr_match = b.term.expression == b.term.reading;
        return a_reading_expr_match > b_reading_expr_match;
      });

  if (results.size() > static_cast<size_t>(max_results)) {
    results.resize(max_results);
  }

  // Pitch is not read by the comparator, so it waits until after the resize:
  // only the <=max_results terms the user actually receives get enriched
  // (BUG-1304).
  if (!options.materialize) return results;
  for (auto& r : results) {
    query_.enrich_pitch(r.term, scope);
    query_.materialize(r.term);
  }

  return results;
}

void Lookup::filter_by_pos(std::vector<TermResult>& terms, const DeinflectionResult& d) const {
  if (d.conditions == 0) {
    return;
  }
  // 还原链用过要求词性的规则（ja.json 的歴史的仮名遣い规则，见 util/pos_required.hpp）：
  // 只认词条自带的真词性，通配 "*" 不算数；其余位照常做词性匹配。
  const bool requires_pos = (d.conditions & fushi::kRequiresPartOfSpeechBit) != 0;
  const uint64_t pos_conditions = d.conditions & ~fushi::kRequiresPartOfSpeechBit;
  std::erase_if(terms, [&](const TermResult& term) {
    if (requires_pos) {
      const std::string own = explicit_rules(term.rules);
      if (own.empty()) return true;
      return pos_conditions != 0 && (deinflector_.rules_to_conditions(own) & pos_conditions) == 0;
    }
    auto dict_conditions = deinflector_.rules_to_conditions(term.rules);
    return (dict_conditions & pos_conditions) == 0;
  });
}
