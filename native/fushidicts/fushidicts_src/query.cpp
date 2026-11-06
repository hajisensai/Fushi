#include "fushidicts/query.hpp"
#include "fushidicts/media_path.hpp"

#include <ankerl/unordered_dense.h>
#include <zstd.h>

#include "fushidicts/platform.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <ranges>
#include <string>
#include <string_view>
#include <vector>

#include "hash/hash.hpp"
#include "json/yomitan_parser.hpp"
#include "memory/memory.hpp"
#include "util/fs_utf8.hpp"
#include "util/redirect_glossary.hpp"
#include "util/term_rules_flag.hpp"

namespace {

struct BlobReader {
  const uint8_t* ptr;
  const uint8_t* end;

  BlobReader(const uint8_t* data, size_t size) : ptr(data), end(data + size) {}

  template <typename T>
  [[nodiscard]] T read() {
    if (ptr + sizeof(T) > end) {
      ptr = end;
      return T{};
    }
    T val;
    std::memcpy(&val, ptr, sizeof(T));
    ptr += sizeof(T);
    return val;
  }

  [[nodiscard]] std::string_view read_str(uint32_t len) {
    if (ptr + len > end || ptr + len < ptr) {
      ptr = end;
      return {};
    }
    std::string_view result(reinterpret_cast<const char*>(ptr), len);
    ptr += len;
    return result;
  }

  [[nodiscard]] bool has(size_t n) const { return ptr + n <= end; }
};

// 上游 8993838：thread_local 复用 DCtx——旧路径 ZSTD_decompress 每次内部新建
// 上下文，materialize 一次弹窗要解压几十条 glossary，复用是纯赚的速度优化。
ZSTD_DCtx* thread_dctx() {
  static thread_local std::unique_ptr<ZSTD_DCtx, decltype(&ZSTD_freeDCtx)> ctx(ZSTD_createDCtx(), ZSTD_freeDCtx);
  return ctx.get();
}

// blobs.bin 的读路径是同一条链：hash.table 槽位 → offset 表 [u32 count][u64 x count]
// → 记录（首字节 = 类型：0 term / 1 meta / 2 kanji）。下面三个遍历器是这条链的唯一实现，
// query_raw / query_kanji / enrich_freq / enrich_pitch / 两个整本扫描都经它们走，
// 边界处理（坏 count、截断表、越界记录）只写一次。visit 返回 false = 提前停止。

// offset 表里的每个记录偏移。
template <typename Visit>
void for_each_listed_offset(const memory::blob_file& blobs, uint64_t at, Visit&& visit) {
  const memory::offset_list list = memory::read_offset_list(blobs, at);
  if (!list.span) {
    return;
  }
  BlobReader idx(list.span.data, list.span.size);
  for (uint32_t i = 0; i < list.count; i++) {
    if (!idx.has(sizeof(uint64_t))) {
      return;
    }
    if (!visit(idx.read<uint64_t>())) {
      return;
    }
  }
}

// offset 表里类型字节等于 want 的记录。visit(blob, rec)：blob 已越过类型字节；rec 的
// owner 撑着记录所在窗口（32 位窗口映射），要在 visit 之后继续引用记录的调用方自己 pin。
template <typename Visit>
void for_each_record_of_type(const memory::blob_file& blobs, uint64_t at, uint8_t want, Visit&& visit) {
  for_each_listed_offset(blobs, at, [&](uint64_t offset) -> bool {
    const memory::blob_span rec = blobs.record(offset);
    if (!rec) {
      return true;
    }
    BlobReader blob(rec.data, rec.size);
    if (blob.read<uint8_t>() != want) {
      return true;
    }
    return visit(blob, rec);
  });
}

// meta 记录（类型 1，freq / pitch / ipa 共用布局）里 expression 匹配的那些。
// visit(blob, mode)：blob 停在 mode 之后的 u32 数据长度字段。
template <typename Visit>
void for_each_meta_record(const memory::blob_file& blobs, uint64_t at, std::string_view expression, Visit&& visit) {
  for_each_record_of_type(blobs, at, 1, [&](BlobReader& blob, const memory::blob_span&) -> bool {
    auto expr_len = blob.read<uint16_t>();
    std::string_view expr = blob.read_str(expr_len);
    if (expr != expression) {
      return true;
    }
    auto mode_len = blob.read<uint8_t>();
    std::string_view mode = blob.read_str(mode_len);
    return visit(blob, mode);
  });
}

// hash.table 每个非空槽位指向的 offset 表地址（整本扫描用；查询走 hash::linear）。
// hash.table : [u32 capacity][ slot{u64 hash, u64 offset} x capacity ]，hash 0 = 空槽；
// capacity 按文件实际能容纳的槽数截断。
template <typename Visit>
void for_each_hash_bucket(const memory::mapped_file& hash_table, Visit&& visit) {
  if (!hash_table || hash_table.size < sizeof(uint32_t)) {
    return;
  }
  uint32_t capacity = 0;
  std::memcpy(&capacity, hash_table.data, sizeof(uint32_t));
  const size_t slot_size = sizeof(uint64_t) * 2;
  const size_t max_slots = (hash_table.size - sizeof(uint32_t)) / slot_size;
  if (capacity > max_slots) {
    capacity = static_cast<uint32_t>(max_slots);
  }
  const uint8_t* slots = hash_table.data + sizeof(uint32_t);
  for (uint32_t i = 0; i < capacity; i++) {
    const uint8_t* slot = slots + static_cast<size_t>(i) * slot_size;
    uint64_t slot_hash = 0;
    std::memcpy(&slot_hash, slot, sizeof(uint64_t));
    if (slot_hash == 0) {
      continue;
    }
    uint64_t bucket = 0;
    std::memcpy(&bucket, slot + sizeof(uint64_t), sizeof(uint64_t));
    if (!visit(bucket)) {
      return;
    }
  }
}

}

struct DictionaryQuery::DictionaryData {
  hash::linear table;
  hash::bloom bloom;
  // BUG-4013：映射经 map_rd_shared 按文件身份进程内共享——词典重载时 shadow 引擎与
  // 旧引擎 / 后台借用句柄同时在世，私有映射会让整套词典的虚拟地址占用翻倍，iOS 上把
  // 地址空间吃满后任何分配都 abort。
  // blobs.bin：64 位整份映射、32 位按窗口映射（memory::blob_file，BUG-4013）。
  memory::shared_blob_file blobs;
  memory::shared_mapping hash_table;
  memory::shared_mapping bloom_filter;
  memory::shared_mapping media_index;
  // media.bin 不映射（BUG-4013）：整套词典约 1.6 GB，只在弹窗显示图片 / 播音频时读，
  // 按请求用 file_reader 定位读取。media_size 是装载时的大小，读取时不符即视为文件
  // 已被替换（与 media.idx 不再配套），返回未命中。
  std::string media_path;
  uint64_t media_size = 0;
  int version = 1;                   // 磁盘格式版本（marker 文件名解析，见 dict_format_version）
  ZSTD_DDict* zstd_dict = nullptr;   // v2 + dict.zstd 存在时非空
  // 本词典没有任何 term 带词性（term_rules.flag = 0）：读侧把空 rules 当通配 "*"，
  // 否则 filter_by_pos 会把这种词典的每一个变形还原命中全部丢掉。
  bool rules_wildcard = false;
  // redirect_glossary.flag 确认本词典没有任何纯重定向 glossary（见
  // util/redirect_glossary.hpp）。false = 有，或未知（sidecar 缺失 / 失效）。
  bool redirect_free = false;

  ~DictionaryData() {
    ZSTD_freeDDict(zstd_dict);
  }
};

DictionaryQuery::DictionaryQuery() = default;
DictionaryQuery::~DictionaryQuery() = default;

DictionaryQuery::DictionaryQuery(DictionaryQuery&&) noexcept = default;
DictionaryQuery& DictionaryQuery::operator=(DictionaryQuery&&) noexcept = default;

DictionaryQuery::Dictionary::Dictionary() = default;
DictionaryQuery::Dictionary::~Dictionary() = default;

DictionaryQuery::Dictionary::Dictionary(Dictionary&&) noexcept = default;
DictionaryQuery::Dictionary& DictionaryQuery::Dictionary::operator=(Dictionary&&) noexcept = default;

namespace {

// 词典目录的「导入已完成」标记。
//
// 改名后**写入端**（importer.cpp）只产出 `.fushidicts_1`，但用户磁盘上存量词典
// 目录里全是导入当时写下的旧名 `.hoshidicts_1`。这里只认新名的后果不是「少一个
// 标记」——是 add_dict 直接 return，**一个词典都加载不进引擎**，表现为查词永远
// 零结果（用户实测：26 个词典全部失效，资源文件却完好无损）。
//
// 故读侧同时接受两个名字（新名优先）。这是「读旧数据的迁移代码」，不追改用户
// 磁盘上的存量文件——重命名用户数据既不可逆，也会让回退到旧版的用户反过来坏掉。
// marker 同时承担「导入已完成」与「格式版本」两个语义（对齐上游的版本阶梯）：
//   v2: .fushidicts_2 —— kanji 记录带 stats 追加段 + term glossary 可能使用
//       dict.zstd 训练字典（本批引入，fork 首个版本升级）。
//   v1: .fushidicts_1（当前 v1 写入端 write_simple_dict 仍产出）/
//       .hoshidicts_1（改名前的存量，冻结，只读不写）。
// 返回 0 = 无 marker（导入未完成/损坏），词典不加载。
int dict_format_version(const std::string& path) {
  if (std::filesystem::is_regular_file(fushi::fs_path(path + "/.fushidicts_2"))) {
    return 2;
  }
  if (std::filesystem::is_regular_file(fushi::fs_path(path + "/.fushidicts_1")) ||
      std::filesystem::is_regular_file(fushi::fs_path(path + "/.hoshidicts_1"))) {
    return 1;
  }
  return 0;
}

// 存量词典（term_rules.flag 缺失/失效）一次性扫描：任何 term 记录的 rules 非空即
// 返回 true。走 hash.table → offset-index → 记录 的同一条路径（与
// probe_dict_content 一样，记录区没有边界元数据、glossary blob 交错，不能顺序扫）。
// 带词性的词典（日语词典动词/形容词占三成）几个槽位就命中退出；只有真正无词性
// 的词典才付一次全扫，结果随后被 add_dict 写回 sidecar，下次启动不再扫。
bool scan_term_rules_present(const memory::mapped_file& hash_table, const memory::blob_file& blobs) {
  if (!hash_table || hash_table.size < sizeof(uint32_t)) {
    return true;  // 读不到就按 Yomitan 既有语义走，不放宽过滤。
  }
  bool present = false;
  for_each_hash_bucket(hash_table, [&](uint64_t bucket) -> bool {
    for_each_record_of_type(blobs, bucket, 0, [&](BlobReader& blob, const memory::blob_span&) -> bool {
      // 与 query_raw 逐字段同布局：expr, reading, glossary offset/size,
      // definition tags, rules。
      (void)blob.read_str(blob.read<uint16_t>());  // expression
      (void)blob.read_str(blob.read<uint16_t>());  // reading
      (void)blob.read<uint64_t>();                 // glossary offset
      (void)blob.read<uint32_t>();                 // glossary size
      (void)blob.read_str(blob.read<uint8_t>());   // definition tags
      present = blob.read<uint8_t>() > 0;
      return !present;
    });
    return !present;
  });
  return present;
}

}  // namespace

void DictionaryQuery::add_dict(const std::string& path, DictionaryType type) {
  const int version = dict_format_version(path);
  if (version == 0) {
    return;
  }

  Dictionary dict;
  {
    std::ifstream index_in(fushi::fs_path(path + "/index.json"), std::ios::binary);
    if (!index_in) {
      return;
    }
    std::string index_buf((std::istreambuf_iterator<char>(index_in)), {});
    Index index;
    if (glz::read_json(index, index_buf)) {
      return;
    }
    // Index::title is a std::string_view into index_buf (glaze parses strings
    // zero-copy). It MUST be copied into the owned dict.name *before* index_buf
    // leaves this scope. Reading index.title after the buffer was freed was a
    // use-after-free: the recycled heap chunk had its leading bytes overwritten
    // by an allocator free-list pointer, so dict.name became
    // "<garbage prefix> + <tail of title>" — rendered as U+FFFD (garbled
    // dictionary labels in the popup). Keep the copy inside the buffer's scope.
    dict.name = index.title.empty()
                    ? fushi::fs_to_utf8(fushi::fs_path(path).stem())
                    : std::string(index.title);
  }
  if (std::filesystem::exists(fushi::fs_path(path + "/styles.css"))) {
    std::ifstream f(fushi::fs_path(path + "/styles.css"));
    dict.styles = std::string(std::istreambuf_iterator<char>(f), {});
  }

  dict.data = std::make_unique<DictionaryData>();
  dict.data->version = version;

  dict.data->hash_table = memory::map_rd_shared(path + "/hash.table");
  if (!dict.data->hash_table) {
    return;
  }
  dict.data->table.load(dict.data->hash_table->data, dict.data->hash_table->size);

  // 上游 d4183d4 删掉了「bloom.filter 缺失时现场重建」的 migration：fork importer
  // 从第一天就写 bloom.filter，migration 是死代码，且 build_to_file 失败会 throw
  // 并穿过无 try/catch 的 FFI 入口（上游 TestFlight 崩溃同款路径）。缺失/损坏时
  // bloom 保持置空（contains 恒真穿透），词典照常可查，只失去 bloom 加速。
  dict.data->bloom_filter = memory::map_rd_shared(path + "/bloom.filter");
  if (dict.data->bloom_filter) {
    dict.data->bloom.load(dict.data->bloom_filter->data, dict.data->bloom_filter->size);
  }
  dict.data->table.set_bloom(&dict.data->bloom);

  dict.data->blobs = memory::open_blob_file(path + "/blobs.bin");
  if (!dict.data->blobs) {
    return;
  }

  // 词性有无（util/term_rules_flag.hpp）：导入端写好的 sidecar 直接读；存量词典
  // 缺 sidecar 就扫一次记录并回填（回填失败只是下次再扫，不影响本次装载）。
  if (type == TERM) {
    const uint64_t blobs_size = dict.data->blobs->size();
    std::optional<bool> rules_present = fushi::term_rules_flag::read(path, blobs_size);
    if (!rules_present.has_value()) {
      rules_present = scan_term_rules_present(*dict.data->hash_table, *dict.data->blobs);
      fushi::term_rules_flag::write(path, *rules_present, blobs_size);
    }
    dict.data->rules_wildcard = !*rules_present;

    // 纯重定向 glossary 的有无（util/redirect_glossary.hpp）：只读导入端 / 迁移扫描
    // 写好的 sidecar，**不在这里扫**——add_*_dict 跑在调用方（Dart UI isolate）上，
    // 整本扫描是百毫秒到秒级。缺 sidecar 就保持未知，查询期照旧逐条检测。
    const std::optional<bool> redirects_present = fushi::redirect_glossary::read_flag(path, blobs_size);
    dict.data->redirect_free = redirects_present.has_value() && !*redirects_present;
  }

  {
    std::error_code ec;
    const std::string media_path = path + "/media.bin";
    const uintmax_t media_size = std::filesystem::file_size(fushi::fs_path(media_path), ec);
    if (!ec && media_size > 0) {
      dict.data->media_index = memory::map_rd_shared(path + "/media.idx");
      if (dict.data->media_index) {
        dict.data->media_path = media_path;
        dict.data->media_size = static_cast<uint64_t>(media_size);
      }
    }
  }

  // dict.zstd 是可选产物（训练样本不足时导入端不写），存在才挂 DDict；
  // 缺失/空文件 → DDict 保持 null → usingDDict(nullptr) 普通解压。
  if (version >= 2) {
    std::ifstream f(fushi::fs_path(path + "/dict.zstd"), std::ios::binary);
    if (f) {
      const std::string blob((std::istreambuf_iterator<char>(f)), {});
      if (!blob.empty()) {
        dict.data->zstd_dict = ZSTD_createDDict(blob.data(), blob.size());
      }
    }
  }

  switch (type) {
    case TERM:
      term_dicts_.push_back(std::move(dict));
      break;
    case FREQ:
      freq_dicts_.push_back(std::move(dict));
      break;
    case PITCH:
      pitch_dicts_.push_back(std::move(dict));
      break;
    case KANJI:
      kanji_dicts_.push_back(std::move(dict));
      break;
  }
}

void DictionaryQuery::add_term_dict(const std::string& path) { add_dict(path, DictionaryQuery::DictionaryType::TERM); }

void DictionaryQuery::add_freq_dict(const std::string& path) { add_dict(path, DictionaryQuery::DictionaryType::FREQ); }

void DictionaryQuery::add_pitch_dict(const std::string& path) {
  add_dict(path, DictionaryQuery::DictionaryType::PITCH);
}

void DictionaryQuery::add_kanji_dict(const std::string& path) {
  add_dict(path, DictionaryQuery::DictionaryType::KANJI);
}

std::vector<TermResult> DictionaryQuery::query(const std::string& expression) const {
  auto results = query_raw(expression);
  // query_raw() no longer enriches (BUG-1304); this single-expression entry
  // point does it itself so its contract is unchanged.
  query_freq(results);
  query_pitch(results);
  for (auto& term : results) {
    materialize(term);
  }
  return results;
}

std::vector<TermResult> DictionaryQuery::query_raw(const std::string& expression) const {
  std::map<std::pair<std::string_view, std::string_view>, TermResult> term_map;
  // term_map 的键是指向记录的 string_view：窗口映射（32 位）下要撑住这些窗口到函数
  // 返回；64 位整份映射时 owner 恒空、不进这里。
  std::vector<std::shared_ptr<const void>> pins;
  for (const auto& [name, styles, data] : term_dicts_) {
    uint64_t offset_addr = data->table(expression);
    if (offset_addr == 0) {
      continue;
    }
    for_each_record_of_type(*data->blobs, offset_addr, 0, [&](BlobReader& blob, const memory::blob_span& rec) -> bool {
      auto expr_len = blob.read<uint16_t>();
      std::string_view expr = blob.read_str(expr_len);

      auto reading_len = blob.read<uint16_t>();
      std::string_view reading = blob.read_str(reading_len);

      if (expr != expression && reading != expression) {
        return true;
      }

      auto glossary_offset = blob.read<uint64_t>();
      auto glossary_size = blob.read<uint32_t>();

      auto def_tags_size = blob.read<uint8_t>();
      std::string_view definition_tags = blob.read_str(def_tags_size);

      auto rules_size = blob.read<uint8_t>();
      std::string_view rules = blob.read_str(rules_size);
      if (rules.empty() && data->rules_wildcard) {
        // 整本词典没有词性：空 rules 不是「非变形词」，而是「转换器没写」。与
        // write_simple_dict 的存储规则对齐成通配，filter_by_pos 不再丢它。
        rules = "*";
      }

      auto term_tag_size = blob.read<uint8_t>();
      std::string_view term_tags = blob.read_str(term_tag_size);

      // v2 term 记录在 term_tags 之后追加 i32 score（上游 909c854）；v1 记录到
      // term_tags 就结束，版本门控不读。
      int score = 0;
      if (data->version >= 2) {
        score = static_cast<int>(blob.read<int32_t>());
      }

      GlossaryEntry entry;
      entry.dict_name = name;
      entry.definition_tags = definition_tags;
      entry.term_tags = term_tags;
      memory::blob_span glossary = data->blobs->view(glossary_offset, glossary_size);
      entry.compressed_data = glossary.data;
      entry.compressed_size = static_cast<uint32_t>(glossary.size);
      entry.compressed_source = data->blobs.get();
      entry.compressed_offset = glossary_offset;
      entry.compressed_owner = std::move(glossary.owner);
      entry.zstd_dict = data->zstd_dict;
      entry.dict_redirect_free = data->redirect_free;

      if (rec.owner) {
        pins.push_back(rec.owner);
      }
      auto [it, inserted] = term_map.try_emplace({expr, reading});
      if (inserted) {
        it->second = {.expression = std::string(expr),
                      .reading = std::string(reading),
                      .rules = std::string(rules),
                      .score = score,
                      .glossaries = {},
                      .frequencies = {}};
      } else {
        if (!rules.empty()) {
          if (!it->second.rules.empty()) {
            it->second.rules += " ";
          }
          it->second.rules += rules;
        }
        // 多词典/多记录合并：score 取 max（上游 909c854）。
        it->second.score = std::max(it->second.score, score);
      }
      it->second.glossaries.push_back(std::move(entry));
      return true;
    });
  }

  // BUG-1304: deliberately NOT enriched here. See the note on query_raw() in
  // query.hpp -- Lookup::lookup() calls this ~69 times per user lookup
  // (measured), and frequency/pitch enrichment belongs on the surviving set.
  return term_map | std::views::values | std::views::as_rvalue | std::ranges::to<std::vector>();
}

std::vector<KanjiResult> DictionaryQuery::query_kanji(const std::string& character) const {
  std::vector<KanjiResult> results;
  for (const auto& [name, styles, data] : kanji_dicts_) {
    uint64_t offset_addr = data->table(character);
    if (offset_addr == 0) {
      continue;
    }
    for_each_record_of_type(*data->blobs, offset_addr, 2, [&](BlobReader& blob, const memory::blob_span&) -> bool {
      auto char_len = blob.read<uint16_t>();
      std::string_view ch = blob.read_str(char_len);
      if (ch != character) {
        return true;
      }

      auto ony_len = blob.read<uint16_t>();
      std::string_view onyomi = blob.read_str(ony_len);
      auto kun_len = blob.read<uint16_t>();
      std::string_view kunyomi = blob.read_str(kun_len);
      auto rad_len = blob.read<uint8_t>();
      std::string_view radical = blob.read_str(rad_len);
      auto strokes = blob.read<uint16_t>();
      auto tags_len = blob.read<uint8_t>();
      (void)blob.read_str(tags_len);  // tags: reserved (consume to keep cursor aligned)

      auto meanings_offset = blob.read<uint64_t>();
      auto meanings_size = blob.read<uint32_t>();

      KanjiResult result;
      result.character = std::string(ch);
      result.onyomi = std::string(onyomi);
      result.kunyomi = std::string(kunyomi);
      result.radical = std::string(radical);
      result.strokes = static_cast<int>(strokes);
      result.dict_name = name;

      // v2 stats 追加段（版本门控：v1 记录到 meanings 对就结束，不读此段）。
      if (data->version >= 2) {
        auto stat_count = blob.read<uint8_t>();
        for (uint8_t s = 0; s < stat_count; s++) {
          if (!blob.has(sizeof(uint8_t))) {
            break;
          }
          auto key_len = blob.read<uint8_t>();
          std::string_view stat_key = blob.read_str(key_len);
          auto val_len = blob.read<uint16_t>();
          std::string_view stat_value = blob.read_str(val_len);
          if (stat_key.empty()) {
            break;  // 越界被 BlobReader 钉空 → 停止而不是灌入空对
          }
          result.stats.emplace_back(std::string(stat_key), std::string(stat_value));
        }
      }

      const memory::blob_span meanings =
          meanings_size > 0 ? data->blobs->view(meanings_offset, meanings_size) : memory::blob_span{};
      if (meanings) {
        // kanji meanings 恒为普通 zstd 帧（训练字典只用于 term glossary）。
        std::string joined = decompress_glossary(meanings.data, meanings.size, nullptr);
        size_t start = 0;
        while (start <= joined.size()) {
          size_t nl = joined.find('\n', start);
          if (nl == std::string::npos) {
            if (start < joined.size()) {
              result.meanings.emplace_back(joined.substr(start));
            }
            break;
          }
          result.meanings.emplace_back(joined.substr(start, nl - start));
          start = nl + 1;
        }
      }

      results.push_back(std::move(result));
      return true;
    });
  }
  return results;
}

void DictionaryQuery::query_freq(std::vector<TermResult>& terms) const {
  for (auto& term : terms) {
    enrich_freq(term);
  }
}

void DictionaryQuery::enrich_freq(TermResult& term) const {
  for (const auto& [name, styles, data] : freq_dicts_) {
    uint64_t offset_addr = data->table(term.expression);
    if (offset_addr == 0) {
      continue;
    }
    std::vector<Frequency> frequencies;
    for_each_meta_record(*data->blobs, offset_addr, term.expression, [&](BlobReader& blob, std::string_view mode) -> bool {
      if (mode != "freq") {
        return true;
      }

      auto freq_data_size = blob.read<uint32_t>();
      std::string_view freq_data = blob.read_str(freq_data_size);

      ParsedFrequency parsed;
      if (yomitan_parser::parse_frequency(freq_data, parsed)) {
        if (!parsed.reading.empty() && parsed.reading != term.reading) {
          return true;
        }
        frequencies.emplace_back(
            Frequency{.value = parsed.value, .display_value = std::string(parsed.display_value)});
      }
      return true;
    });
    if (!frequencies.empty()) {
      term.frequencies.emplace_back(FrequencyEntry{.dict_name = name, .frequencies = std::move(frequencies)});
    }
  }
}

void DictionaryQuery::query_pitch(std::vector<TermResult>& terms) const {
  for (auto& term : terms) {
    enrich_pitch(term);
  }
}

void DictionaryQuery::enrich_pitch(TermResult& term) const {
  for (const auto& [name, styles, data] : pitch_dicts_) {
    uint64_t offset_addr = data->table(term.expression);
    if (offset_addr == 0) {
      continue;
    }
    std::vector<Pitch> pitches;
    std::vector<std::string> transcriptions;

    // BUG-2152: one dict contributes ONE PitchEntry, and every meta record it
    // holds for this expression is flattened into the two vectors below. A
    // headword the dictionary splits into several entries (English `spoke` =
    // the noun + the past tense of `speak`) therefore hands us the SAME
    // notation once per entry, and the consumer renders it once per element:
    // `[/spəʊk/][/spəʊk/]` on the Anki card, two identical rows in the popup.
    //
    // The three downstream dedups cannot help — Dart `buildPopupJsonFromLookup`
    // (pKey), the native popup_json mirror and popup.js
    // `mergeIdenticalPitchGroups` all key on the WHOLE entry (dict name +
    // positions + patterns + transcriptions), so a single entry carrying a
    // duplicate inside itself is seen once and kept whole. Deduping has to
    // happen here, where the flattening happens.
    //
    // Order is preserved (first occurrence wins) — the dictionary's own order
    // is the only meaningful one, and callers render these as an ordered list.
    // Linear scans are fine: a headword has a handful of notations, not
    // thousands.
    const auto same_pitch = [](const Pitch& a, const Pitch& b) {
      return a.position == b.position && a.pattern == b.pattern &&
             a.nasal == b.nasal && a.devoice == b.devoice;
    };

    for_each_meta_record(*data->blobs, offset_addr, term.expression, [&](BlobReader& blob, std::string_view mode) -> bool {
      // Both pitch-accent ("pitch") and IPA transcription ("ipa") meta records
      // share this PITCH dict bucket / storage layout (upstream 918744d). The
      // data blob differs only in how the JSON is shaped; parse with the
      // matching parser and accumulate into the right vector. Anything else is
      // skipped.
      ParsedPitch parsed;
      if (mode == "pitch") {
        auto pitch_data_size = blob.read<uint32_t>();
        std::string_view pitch_data = blob.read_str(pitch_data_size);
        if (yomitan_parser::parse_pitch(pitch_data, parsed)) {
          if (!parsed.reading.empty() && parsed.reading != term.reading) {
            return true;
          }
          for (auto& accent : parsed.pitches) {
            Pitch pitch{.position = accent.position,
                        .pattern = std::move(accent.pattern),
                        .nasal = std::move(accent.nasal),
                        .devoice = std::move(accent.devoice)};
            if (std::none_of(pitches.begin(), pitches.end(),
                             [&](const Pitch& seen) {
                               return same_pitch(seen, pitch);
                             })) {
              pitches.push_back(std::move(pitch));
            }
          }
        }
      } else if (mode == "ipa") {
        auto transcriptions_data_size = blob.read<uint32_t>();
        std::string_view transcriptions_data = blob.read_str(transcriptions_data_size);
        if (yomitan_parser::parse_ipa(transcriptions_data, parsed)) {
          if (!parsed.reading.empty() && parsed.reading != term.reading) {
            return true;
          }
          for (std::string_view transcription : parsed.transcriptions) {
            if (std::find(transcriptions.begin(), transcriptions.end(),
                          transcription) == transcriptions.end()) {
              transcriptions.emplace_back(transcription);
            }
          }
        }
      }
      return true;
    });
    if (!pitches.empty() || !transcriptions.empty()) {
      term.pitches.emplace_back(PitchEntry{
          .dict_name = name,
          .pitches = std::move(pitches),
          .transcriptions = std::move(transcriptions),
      });
    }
  }
}

std::string DictionaryQuery::decompress_glossary(const void* data, size_t size, const ZSTD_DDict_s* dict) {
  if (!data || size == 0) {
    return "";
  }

  unsigned long long decompressed_size = ZSTD_getFrameContentSize(data, size);
  if (decompressed_size == ZSTD_CONTENTSIZE_ERROR || decompressed_size == ZSTD_CONTENTSIZE_UNKNOWN) {
    return "";
  }

  static constexpr size_t kMaxGlossarySize = 64 * 1024 * 1024;  // 64 MB
  if (decompressed_size > kMaxGlossarySize) {
    FUSHI_LOGW("glossary decompressed size %llu exceeds limit",
               static_cast<unsigned long long>(decompressed_size));
    return "";
  }

  std::string result;
  result.resize(decompressed_size);

  size_t actual_size = ZSTD_decompress_usingDDict(thread_dctx(), result.data(), result.size(), data, size, dict);
  if (ZSTD_isError(actual_size)) {
    return "";
  }

  result.resize(actual_size);
  return result;
}

void DictionaryQuery::materialize(TermResult& term) const {
  for (auto& g : term.glossaries) {
    g.glossary = decompress_glossary(g.compressed_data, g.compressed_size, g.zstd_dict);
  }
}

std::vector<char> DictionaryQuery::get_media_file(const std::string& dict_name, const std::string& media_path) const {
  const std::string normalized_media_path = fushidicts::normalize_media_path(media_path);
  for (const auto& [name, styles, data] : term_dicts_) {
    if (name != dict_name) {
      continue;
    }

    if (data->media_path.empty() || !data->media_index) {
      return {};
    }

    BlobReader idx_hdr(data->media_index->data, data->media_index->size);
    auto count = idx_hdr.read<uint32_t>();

    const size_t idx_entry_end = sizeof(uint32_t) + static_cast<size_t>(count) * sizeof(uint64_t);
    if (idx_entry_end > data->media_index->size) {
      return {};
    }

    // media.bin 记录：u16 path_len | path | u32 blob_size | blob。按请求打开、定位读
    // （BUG-4013）——二分 ~log2(N) 次小读走页缓存，相对图片解码可忽略。
    const memory::file_reader media(data->media_path);
    if (!media || media.size() != data->media_size) {
      return {};
    }

    std::string path_buf;
    auto find_by_indexed_path = [&](std::string_view requested_path) -> std::vector<char> {
      size_t left = 0;
      size_t right = count;
      while (left < right) {
        const size_t mid = left + (right - left) / 2;
        uint64_t record_offset;
        std::memcpy(&record_offset, data->media_index->data + sizeof(uint32_t) + mid * sizeof(uint64_t),
                    sizeof(uint64_t));

        uint16_t path_size = 0;
        if (!media.read_at(record_offset, &path_size, sizeof(path_size))) {
          return {};
        }
        path_buf.resize(path_size);
        if (path_size > 0 && !media.read_at(record_offset + sizeof(uint16_t), path_buf.data(), path_size)) {
          return {};
        }
        const std::string_view indexed_path = path_buf;
        if (indexed_path < requested_path) {
          left = mid + 1;
        } else if (indexed_path > requested_path) {
          right = mid;
        } else {
          const uint64_t size_offset = record_offset + sizeof(uint16_t) + path_size;
          uint32_t blob_size = 0;
          if (!media.read_at(size_offset, &blob_size, sizeof(blob_size)) || blob_size == 0) {
            return {};
          }
          std::vector<char> blob(blob_size);
          if (!media.read_at(size_offset + sizeof(uint32_t), blob.data(), blob_size)) {
            return {};
          }
          return blob;
        }
      }
      return {};
    };

    std::vector<char> found = find_by_indexed_path(normalized_media_path);
    if (!found.empty()) {
      return found;
    }

    std::string legacy_media_path = normalized_media_path;
    std::ranges::replace(legacy_media_path, '/', '\\');
    if (legacy_media_path != normalized_media_path) {
      return find_by_indexed_path(legacy_media_path);
    }
    return {};
  }
  return {};
}

std::vector<DictionaryStyle> DictionaryQuery::get_styles() const {
  return term_dicts_ | std::views::filter([](const auto& d) { return !d.styles.empty(); }) |
         std::views::transform([](const auto& d) { return DictionaryStyle{d.name, d.styles}; }) |
         std::ranges::to<std::vector>();
}

std::vector<std::string> DictionaryQuery::get_freq_dict_order() const {
  return freq_dicts_ | std::views::transform([](const auto& d) { return d.name; }) | std::ranges::to<std::vector>();
}

int ensure_redirect_glossary_flag(const std::string& dir) {
  std::error_code ec;
  const uint64_t blobs_size = std::filesystem::file_size(fushi::fs_path(dir + "/blobs.bin"), ec);
  if (ec) return -1;
  if (const std::optional<bool> known = fushi::redirect_glossary::read_flag(dir, blobs_size)) {
    return *known ? 1 : 0;
  }
  const std::optional<bool> present = fushi::redirect_glossary::scan_dict_dir(dir);
  if (!present.has_value()) return -1;
  // 写回失败（只读卷）不影响本次结论，下次再扫。
  fushi::redirect_glossary::write_flag(dir, *present, blobs_size);
  return *present ? 1 : 0;
}

// ── dictionary content probe (TODO-622) ─────────────────────────────
// Walk hash.table buckets -> offset-index -> record type byte. The on-disk
// format is stable and identical to what query()/query_kanji() consume:
//   hash.table : [u32 capacity][ slot{u64 hash, u64 offset} x capacity ]
//                empty slot == hash 0; offset points into the offset-index
//                region of blobs.bin.
//   offset-idx : [u32 count][u64 record_offset x count]
//   record     : first byte = type (0=term, 1=meta, 2=kanji)
// All little-endian (write_val/BlobReader use memcpy). We cannot sequentially
// scan the record region (no boundary metadata, glossary blobs interleaved),
// so we must go through the hash table. bloom.filter is not needed here.
int probe_dict_content(const std::string& dir) {
  // map_rd_shared（BUG-4013）：已装载的词典复用引擎那份映射。
  const memory::shared_mapping hash_owner = memory::map_rd_shared(dir + "/hash.table");
  if (!hash_owner || hash_owner->size < sizeof(uint32_t)) {
    return 0;
  }
  const memory::shared_blob_file blobs_owner = memory::open_blob_file(dir + "/blobs.bin");
  if (!blobs_owner) {
    return 0;
  }
  const memory::mapped_file& hash_table = *hash_owner;
  const memory::blob_file& blobs = *blobs_owner;

  int mask = 0;
  for_each_hash_bucket(hash_table, [&](uint64_t bucket) -> bool {
    for_each_listed_offset(blobs, bucket, [&](uint64_t offset) -> bool {
      // Only the type byte is needed: a 1-byte view, not a whole record.
      const memory::blob_span rec = blobs.view(offset, 1);
      if (rec) {
        if (rec.data[0] == 0) {
          mask |= 0x1;  // has term
        } else if (rec.data[0] == 2) {
          mask |= 0x2;  // has kanji
        }
      }
      return mask != 0x3;
    });
    return mask != 0x3;
  });
  return mask;
}
