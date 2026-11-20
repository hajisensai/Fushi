#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>
#include <vector>

#if defined(__clang__) && defined(__APPLE__)
#define SWIFT_IMPORT_UNSAFE __attribute__((swift_attr("import_unsafe")))
#else
#define SWIFT_IMPORT_UNSAFE
#endif

struct Frequency {
  int value;
  std::string display_value;
};

struct DictionaryStyle {
  std::string dict_name;
  std::string styles;
};

struct ZSTD_DDict_s;

namespace hash {
class union_filter;
}

// 联合过滤器（hash/union_filter.hpp）的状态，见 DictionaryQuery::prepare_union_filter。
enum class UnionFilterState : int32_t {
  None = 0,      // 没有：查询逐本词典探各自的 bloom（旧路径）
  Building = 1,  // 后台正在装载 / 构建，期间查询仍走旧路径
  Ready = 2,     // 已就绪，查询先过联合过滤器
};

struct GlossaryEntry {
  std::string dict_name;
  std::string glossary;
  std::string definition_tags;
  std::string term_tags;
  const uint8_t* compressed_data = nullptr;
  uint32_t compressed_size = 0;
  // 压缩 blob 在 blobs.bin 里的身份（来源文件 + 偏移）：同一 blob 的判等用它，不用
  // compressed_data 指针——32 位进程按窗口映射 blobs.bin（BUG-4013），同一 blob 可能
  // 落在不同窗口 / 堆缓冲里。compressed_owner 撑住那份窗口直到懒解压完成；64 位整份
  // 映射时为空。
  const void* compressed_source = nullptr;
  uint64_t compressed_offset = 0;
  std::shared_ptr<const void> compressed_owner;
  // v2 词典的 term glossary 用训练字典压缩（上游 8993838）；v1 恒为 nullptr，
  // usingDDict(nullptr) 等价普通解压。
  const ZSTD_DDict_s* zstd_dict = nullptr;
  // 所属词典经 redirect_glossary.flag 确认不含任何纯重定向 glossary（见
  // util/redirect_glossary.hpp）。为真时 Lookup 不必在查询期逐条读帧头 / 解压判断
  // 重定向；默认 false = 照旧逐条检测（未知即不跳过，行为不变）。
  bool dict_redirect_free = false;
};

struct FrequencyEntry {
  std::string dict_name;
  std::vector<Frequency> frequencies;
};

// 上游 79c55c2：完整 pitch accent 规格。数字位 pattern 为空；pattern 位（"heiban"
// 等）position 保持 0。nasal/devoice 是鼻浊音/清化 mora 下标——数据模型收全，
// 当前文本形态 UI 只渲染 position/pattern（图形渲染是未来工作）。
struct Pitch {
  int position = 0;
  std::string pattern;
  std::vector<int> nasal;
  std::vector<int> devoice;
};

struct PitchEntry {
  std::string dict_name;
  std::vector<Pitch> pitches;
  std::vector<std::string> transcriptions;
};

struct TermResult {
  std::string expression;
  std::string reading;
  std::string rules;
  // 上游 909c854：Yomitan term score（v2 词典落盘，v1 恒 0）。仅参与 native 排序，
  // 不出 FFI 面。多词典同 (expr,reading) 合并时取 max。
  int score = 0;
  std::vector<GlossaryEntry> glossaries;
  std::vector<FrequencyEntry> frequencies;
  std::vector<PitchEntry> pitches;
};

struct KanjiResult {
  std::string character;
  std::string onyomi;
  std::string kunyomi;
  std::string radical;
  int strokes = 0;
  std::vector<std::string> meanings;
  // v2 词典的完整 stats 键值对（JLPT/grade/freq 等，bank 原始顺序，radical/strokes
  // 以外的条目；借鉴上游 64afa2f 的 stats 保留能力）。v1 存量记录恒为空。
  std::vector<std::pair<std::string, std::string>> stats;
  std::string dict_name;
};

// Probe a written dictionary directory's blobs.bin/hash.table to discover which
// record types it actually contains, independent of its declared classification.
// Returns a bitmask: bit0 (0x1) = has term records (type byte 0),
// bit1 (0x2) = has kanji records (type byte 2). Returns 0 on any read failure.
// Single source of truth for re-classifying a mixed dictionary that detect_type
// may have mislabeled, and for self-healing already-imported dictionaries.
int probe_dict_content(const std::string& dir);

// 已导入词典的 redirect_glossary.flag 一次性迁移（util/redirect_glossary.hpp）：
// sidecar 已有效就直接返回它；否则整本扫描一遍、写回 sidecar 再返回。1 = 含纯重定向
// glossary，0 = 不含（之后 add_term_dict 装载时查询期跳过逐条检测），-1 = 读不了。
// 扫描会读遍 blobs.bin（大词典百毫秒到秒级），只在后台线程 / isolate 上调；结果在
// 下一次 add_term_dict 装载该目录时生效。
int ensure_redirect_glossary_flag(const std::string& dir);

class DictionaryQuery {
 public:
  DictionaryQuery();
  ~DictionaryQuery();

  DictionaryQuery(const DictionaryQuery&) = delete;
  DictionaryQuery& operator=(const DictionaryQuery&) = delete;

  DictionaryQuery(DictionaryQuery&&) noexcept;
  DictionaryQuery& operator=(DictionaryQuery&&) noexcept;

  // [language]：这本词典词头的语言（BCP-47 / ISO 639 码，宿主给：用户手动指定的优先，
  // 其次包内 index.json 的 sourceLanguage）。空 = 未标注。标了语言的词典只接受本语言
  // 变形表还原出来的词形（Lookup::lookup 的语言把关），精确命中不受影响。
  void add_term_dict(const std::string& path, std::string_view language = {});
  void add_freq_dict(const std::string& path);
  void add_pitch_dict(const std::string& path);
  void add_kanji_dict(const std::string& path);

  void query_freq(std::vector<TermResult>& terms) const;
  void query_pitch(std::vector<TermResult>& terms) const;

  std::vector<TermResult> query(const std::string& expression) const;
  // 只要词频的 query()：同一批 (expression, reading) 词条、同样的 rules 与 frequencies，
  // 但不富化音调、不解压释义——glossaries 与 pitches 恒为空。给「拿一个词形去查它的
  // 词频」的调用方（Anki 卡组按词频重排：几千张卡各查一次）：释义解压是 query() 的
  // 大头，而它们一个字也不读。
  std::vector<TermResult> query_frequencies(const std::string& expression) const;
  std::vector<KanjiResult> query_kanji(const std::string& character) const;

  std::vector<char> get_media_file(const std::string& dict_name, const std::string& media_path) const;
  std::vector<DictionaryStyle> get_styles() const;
  std::vector<std::string> get_freq_dict_order() const;

  // 为当前装载的全部词典准备联合过滤器（一条缓存行判定「这个键可能在哪几本词典里」，
  // 见 hash/union_filter.hpp）。[cache_dir] 非空时过滤器落盘在该目录、下次直接映射
  // （目录由宿主给，引擎自己建）；空串 = 只在内存里建。[wait] 为真时同步建完才返回
  // （测试 / 基准 / 批处理宿主）；否则立刻返回、在后台线程里建，建好前查询照走旧路径，
  // 结果不变。之后再 add_*_dict 会作废这份过滤器（在飞的后台构建成果也一并丢弃），
  // 要重新调用。纯加速：有没有它查词结果逐字节相同。
  void prepare_union_filter(const std::string& cache_dir, bool wait);
  UnionFilterState union_filter_state() const;

 private:
  friend class Lookup;

  // BUG-1304: query_raw() returns terms WITHOUT frequency/pitch enrichment.
  // Lookup::lookup() calls it once per (scan candidate x text variant x
  // deinflection) -- ~69 times per user lookup, measured, not the ~1600 the
  // first draft of BUG-1304 extrapolated from the loop bounds -- and enriching
  // inside it meant every intermediate term hit every frequency and pitch
  // dictionary (each with its own JSON parse), only for most of that work to be
  // thrown away by the dedup + partial_sort + resize that follow.
  // The enrichment now happens once, on the surviving set, in lookup.cpp.
  //
  // Measured magnitude (Release, 7 term dicts x 150k entries, 3 freq dicts,
  // 2 pitch dicts, max_results=200): enrichment count 9.4 -> 3.2 per lookup
  // (2.94x), end-to-end 0.182 ms -> 0.173 ms per lookup (~5-9%). This is a real
  // but SMALL win -- do not cite it as a cause of seconds-scale lookup latency.
  // The public query_freq/query_pitch keep enriching a whole vector so
  // query() -- the single-expression entry point -- is unchanged.
  //
  // [excluded]：本次查词排除的词典名（LookupOptions::excluded_dictionaries 的查找表）。
  // 名列其中的词典整本跳过——不读记录、不并入 rules / score、不出频率 / 音调，
  // 与「没装这本词典」逐字一致。nullptr = 不排除（默认，行为不变）。
  using ExcludedDictNames = std::unordered_set<std::string_view>;
  // 一次查词（Lookup::lookup）/ 一次 query() 内共用的查库上下文：排除集，加上进入时
  // 取的联合过滤器快照——整次查词用同一份，后台构建中途发布不会让同一次查词前后
  // 走两条路径。默认构造 = 不排除、无过滤器（逐本探 bloom）。
  struct QueryScope {
    const ExcludedDictNames* excluded = nullptr;
    std::shared_ptr<const hash::union_filter> filter;
  };
  QueryScope make_scope(const ExcludedDictNames* excluded = nullptr) const;

  std::vector<TermResult> query_raw(const std::string& expression, const QueryScope& scope) const;
  void enrich_freq(TermResult& term, const QueryScope& scope) const;
  void enrich_pitch(TermResult& term, const QueryScope& scope) const;
  void materialize(TermResult& term) const;

  struct DictionaryData;
  struct Dictionary {
    Dictionary();
    ~Dictionary();

    Dictionary(const Dictionary&) = delete;
    Dictionary& operator=(const Dictionary&) = delete;

    Dictionary(Dictionary&&) noexcept;
    Dictionary& operator=(Dictionary&&) noexcept;

    std::string name;
    std::string styles;
    // 归一后的词头语言（fushi::primary_language_tag），空 = 未标注。只有 term 词典填。
    std::string language;
    std::unique_ptr<DictionaryData> data;
  };
  enum DictionaryType : uint8_t { TERM, FREQ, PITCH, KANJI };

  void add_dict(const std::string& path, DictionaryType, std::string_view language = {});

  // 联合过滤器的发布槽：后台构建线程与本对象共同持有（本对象析构后线程把成果发布进
  // 一个没人读的槽，随线程结束释放）。定义在 query.cpp。
  struct UnionSlot;
  std::shared_ptr<UnionSlot> union_;
  // 联合过滤器的后台构建线程，本对象独占：析构 / 被移动赋值覆盖时叫停并等它退出
  //（毫秒级），所以本对象没了之后不会有线程还撑着词典文件的映射。
  struct UnionBuilder;
  std::unique_ptr<UnionBuilder> union_builder_;

  static std::string decompress_glossary(const void* data, size_t size, const ZSTD_DDict_s* dict);
  std::vector<Dictionary> term_dicts_;
  std::vector<Dictionary> freq_dicts_;
  std::vector<Dictionary> pitch_dicts_;
  std::vector<Dictionary> kanji_dicts_;
};
