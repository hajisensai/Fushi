#include "fushidicts/query.hpp"
#include "fushidicts/media_path.hpp"

#include <ankerl/unordered_dense.h>
#include <xxh3.h>
#include <zstd.h>

#include "fushidicts/language_tag.hpp"
#include "fushidicts/platform.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <atomic>
#include <mutex>
#include <optional>
#include <ranges>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <vector>

#include "hash/dict_index.hpp"
#include "hash/hash.hpp"
#include "hash/union_filter.hpp"
#include "json/meta_record.hpp"
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

// 记录的读路径是同一条链：索引（key.index / hash.table，hash/dict_index.hpp）给出
// location → single 时就是那条记录，否则是 offset 表 [u32 count][u64 x count] → 记录
// （首字节 = 类型：0 term / 1 meta 原样 / 2 kanji / 3 meta 预解析）。下面的遍历器是
// 这条链的唯一实现，query_raw / query_kanji / enrich_freq / enrich_pitch / 整本扫描都经
// 它们走，边界处理（坏 count、截断表、越界记录）只写一次。visit 返回 false = 提前停止。

using hash::location;

// [at] 列出的记录里类型字节满足 [want] 的那些。visit(blob, rec, type)：blob 已越过类型
// 字节；rec 的 owner 撑着记录所在窗口（32 位窗口映射），要在 visit 之后继续引用记录的
// 调用方自己 pin。
template <typename Want, typename Visit>
void for_each_record_where(const memory::blob_file& blobs, location at, Want&& want, Visit&& visit) {
  hash::for_each_record_offset(blobs, at, [&](uint64_t offset) -> bool {
    const memory::blob_span rec = blobs.record(offset);
    if (!rec) {
      return true;
    }
    BlobReader blob(rec.data, rec.size);
    const uint8_t type = blob.read<uint8_t>();
    if (!want(type)) {
      return true;
    }
    return visit(blob, rec, type);
  });
}

template <typename Visit>
void for_each_record_of_type(const memory::blob_file& blobs, location at, uint8_t want, Visit&& visit) {
  for_each_record_where(
      blobs, at, [want](uint8_t type) { return type == want; },
      [&](BlobReader& blob, const memory::blob_span& rec, uint8_t) -> bool { return visit(blob, rec); });
}

// meta 记录（type 1 原样 / type 3 预解析，json/meta_record.hpp）里 expression 匹配的那些。
// visit(blob, mode, type)：blob 停在 mode 之后（载荷的开头）。
template <typename Visit>
void for_each_meta_record(const memory::blob_file& blobs, location at, std::string_view expression, Visit&& visit) {
  for_each_record_where(
      blobs, at, [](uint8_t type) { return type == meta_record::kRawType || type == meta_record::kParsedType; },
      [&](BlobReader& blob, const memory::blob_span&, uint8_t type) -> bool {
        auto expr_len = blob.read<uint16_t>();
        std::string_view expr = blob.read_str(expr_len);
        if (expr != expression) {
          return true;
        }
        auto mode_len = blob.read<uint8_t>();
        std::string_view mode = blob.read_str(mode_len);
        return visit(blob, mode, type);
      });
}

// 一次查库的键：XXH3 只算一次，逐词典复用（以前每本词典各算一遍）；有联合过滤器时
// 顺带取好键所在的那一块。key 是原文，核对记录时用。
struct KeyProbe {
  std::string_view key;
  uint64_t h;
  const hash::union_filter* filter;
  hash::union_filter::probe at;

  KeyProbe(std::string_view k, const std::shared_ptr<const hash::union_filter>& f)
      : key(k), h(XXH3_64bits(k.data(), k.size())), filter(f.get()) {
    if (filter) {
      at = filter->at(h);
    }
  }
};

// [key] 在 [dicts] 里命中的词典及各自已核对的 location，按词典顺序、跳过 [excluded]。
// 逐本 DictionaryData::locate 的等价物，只是分遍走：
//
// 命中一本词典要连着读互不相邻的几处内存——索引的槽位 / 桶、blobs 里的 offset 表（single
// 时没有这一跳）、记录本身，每处都是缓存未命中。常用词在几十本词典里都有，逐本走到底
// 就是上百次未命中一个接一个地等内存。这里每一遍只做一件事并把下一遍要读的地址预取
// 出去，同一遍里各本词典的未命中同时在路上：
//   1. 过滤（联合过滤器 / 旧式词典自己的 bloom）+ 预取槽位或主桶；
//   2. 探测：旧式按 64 位哈希找槽位；key.index 读主桶得候选，主桶没有候选而带溢出位
//      的预取备桶、放到 2b 再读；候选的目标（记录或 offset 表）预取；
//   3. 读 offset 表、预取表里的记录（窗口映射下不预取记录，核对照常）；
//   4. 核对记录上的键。主桶的候选全部核对不上而带溢出位时再看备桶（只在 29 位 tag
//      撞车时发生，同步读即可）——保证无假阴性。
// 全落空的查库（绝大多数）第一遍就结束，不分配。
template <typename Dicts, typename Excluded>
auto locate_all(const Dicts& dicts, const KeyProbe& key, const Excluded* excluded) {
  using Dict = typename Dicts::value_type;
  struct Hit {
    const Dict* dict;
    location loc;
  };
  struct Pending {
    const Dict* dict;
    hash::key_index::candidates c;
    bool need_alternate = false;  // 主桶没有候选、带溢出位：2b 读备桶
    bool from_alternate = false;  // c 来自备桶（核对失败不必再看别处）
  };
  std::vector<Hit> hits;
  std::vector<Pending> pending;
  for (const auto& dict : dicts) {
    if (excluded && excluded->contains(dict.name)) {
      continue;
    }
    if (!dict.data->may_contain(key)) {
      continue;
    }
    const hash::dict_index& index = dict.data->index;
    if (const hash::key_index* keys = index.keys()) {
      keys->prefetch_primary(key.h);
    } else {
      index.table().prefetch(key.h);
    }
    pending.push_back({.dict = &dict, .c = {}});
  }
  if (pending.empty()) {
    return hits;
  }

  const auto prefetch_targets = [](const Pending& p) {
    const memory::blob_file& blobs = p.dict->data->index.blobs();
    for (uint32_t i = 0; i < p.c.count; i++) {
      blobs.prefetch(p.c.at[i].offset);
    }
  };

  // 2. 探测。
  size_t live = 0;
  bool any_alternate = false;
  for (Pending& p : pending) {
    const hash::dict_index& index = p.dict->data->index;
    if (const hash::key_index* keys = index.keys()) {
      p.c = keys->primary(key.h);
      if (p.c.count == 0) {
        if (!p.c.more) {
          continue;
        }
        keys->prefetch_alternate(key.h);
        p.need_alternate = true;
        any_alternate = true;
      }
    } else {
      const uint64_t offset_addr = index.table().find(key.h);
      if (offset_addr == 0) {
        continue;
      }
      p.c.count = 1;
      p.c.at[0] = {.offset = offset_addr, .single = false};
    }
    prefetch_targets(p);
    pending[live++] = p;
  }
  pending.resize(live);
  // 2b. 主桶没有候选的读备桶。
  if (any_alternate) {
    live = 0;
    for (Pending& p : pending) {
      if (p.need_alternate) {
        p.c = p.dict->data->index.keys()->alternate(key.h);
        p.from_alternate = true;
        if (p.c.count == 0) {
          continue;
        }
        prefetch_targets(p);
      }
      pending[live++] = p;
    }
    pending.resize(live);
  }

  // 3. 预取 offset 表里的记录。
  for (const Pending& p : pending) {
    const memory::blob_file& blobs = p.dict->data->index.blobs();
    if (blobs.windowed()) {
      continue;
    }
    for (uint32_t i = 0; i < p.c.count; i++) {
      if (p.c.at[i].single) {
        continue;
      }
      hash::for_each_record_offset(blobs, p.c.at[i], [&](uint64_t offset) -> bool {
        blobs.prefetch(offset);
        return true;
      });
    }
  }

  // 4. 核对。
  hits.reserve(pending.size());
  for (const Pending& p : pending) {
    const hash::dict_index& index = p.dict->data->index;
    const auto verified = [&](const hash::key_index::candidates& c) -> std::optional<location> {
      for (uint32_t i = 0; i < c.count; i++) {
        if (hash::location_has_key(index.blobs(), c.at[i], key.key)) {
          return c.at[i];
        }
      }
      return std::nullopt;
    };
    std::optional<location> loc = verified(p.c);
    if (!loc && !p.from_alternate && p.c.more) {
      loc = verified(index.keys()->alternate(key.h));
    }
    if (loc) {
      hits.push_back({.dict = p.dict, .loc = *loc});
    }
  }
  return hits;
}

}

struct DictionaryQuery::DictionaryData {
  // 索引（key.index 或旧式 hash.table + bloom.filter）与记录文件，hash/dict_index.hpp。
  // BUG-4013：映射经 map_rd_shared 按文件身份进程内共享——词典重载时 shadow 引擎与
  // 旧引擎 / 后台借用句柄同时在世，私有映射会让整套词典的虚拟地址占用翻倍，iOS 上把
  // 地址空间吃满后任何分配都 abort。记录文件 64 位整份映射、32 位按窗口映射
  // （memory::blob_file，BUG-4013）。
  hash::dict_index index;
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

  // [key] 在本词典里已核对的位置，nullopt = 没有。有联合过滤器时由它判「肯定不在」
  //（键所在的块已经取好，这里不再碰本词典的任何内存），否则用本词典自己的预筛（旧式
  // 的 bloom；key.index 没有）；放行之后都走同一个精确探测 + 核对，结果相同。
  std::optional<location> locate(const KeyProbe& key) const {
    return may_contain(key) ? index.locate(key.h, key.key) : std::nullopt;
  }

  // [locate] 的前半：false = 肯定不在。
  bool may_contain(const KeyProbe& key) const {
    if (key.filter) {
      return hash::union_filter::maybe(key.at, index.identity());
    }
    return index.own_filter_passes(key.h);
  }
};

// 联合过滤器的发布槽。epoch 在词典集合变化（add_dict）与每次 prepare 时推进：后台
// 构建线程发布前核对自己出发时的 epoch，对不上说明成果已经过时（集合变了 / 被更新的
// 一次 prepare 取代），直接丢弃。不变式：filter 非空 ⇒ 它覆盖引擎当前装载的每一本词典。
struct DictionaryQuery::UnionSlot {
  std::mutex mutex;
  std::shared_ptr<const hash::union_filter> filter;
  uint64_t epoch = 0;
  UnionFilterState state = UnionFilterState::None;
};

// 后台构建线程及其叫停标志。mutex 串行化 prepare / 叫停（FFI 在共享锁下调 prepare，
// 两个线程可能同时进来）；构建线程自己从不取这把锁，所以持锁 join 不会死锁。
struct DictionaryQuery::UnionBuilder {
  std::mutex mutex;
  std::thread thread;
  std::shared_ptr<std::atomic<bool>> cancel;

  // 叫停在飞的构建并等线程退出。调用方持有 mutex。
  void stop_locked() {
    if (cancel) {
      cancel->store(true, std::memory_order_relaxed);
    }
    if (thread.joinable()) {
      thread.join();
    }
    cancel.reset();
  }

  // 只置叫停标志、不等（成果反正会按 epoch 作废，线程留给下一次 prepare / 析构收）。
  void request_stop() {
    std::lock_guard<std::mutex> lock(mutex);
    if (cancel) {
      cancel->store(true, std::memory_order_relaxed);
    }
  }

  ~UnionBuilder() {
    std::lock_guard<std::mutex> lock(mutex);
    stop_locked();
  }
};

DictionaryQuery::DictionaryQuery()
    : union_(std::make_shared<UnionSlot>()), union_builder_(std::make_unique<UnionBuilder>()) {}
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
// 返回 true。走 索引 → offset-index → 记录 的同一条路径（与
// probe_dict_content 一样，记录区没有边界元数据、glossary blob 交错，不能顺序扫）。
// 带词性的词典（日语词典动词/形容词占三成）几个槽位就命中退出；只有真正无词性
// 的词典才付一次全扫，结果随后被 add_dict 写回 sidecar，下次启动不再扫。
bool scan_term_rules_present(const hash::dict_index& index) {
  bool present = false;
  index.for_each_location([&](location bucket) -> bool {
    for_each_record_of_type(index.blobs(), bucket, 0, [&](BlobReader& blob, const memory::blob_span&) -> bool {
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

void DictionaryQuery::add_dict(const std::string& path, DictionaryType type, std::string_view language) {
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

  // 索引 + 记录文件（hash/dict_index.hpp）：key.index 合法就用它，否则旧式
  // hash.table + bloom.filter。只读，不在这里升级、不写盘（升级是 upgrade.hpp 的事）。
  if (!dict.data->index.open(path)) {
    return;
  }

  // 词性有无（util/term_rules_flag.hpp）：导入端写好的 sidecar 直接读；存量词典
  // 缺 sidecar 就扫一次记录并回填（回填失败只是下次再扫，不影响本次装载）。sidecar
  // 里记的是记录文件（blobs.bin / blobs3.bin）的大小。
  if (type == TERM) {
    const uint64_t blobs_size = dict.data->index.blobs().size();
    std::optional<bool> rules_present = fushi::term_rules_flag::read(path, blobs_size);
    if (!rules_present.has_value()) {
      rules_present = scan_term_rules_present(dict.data->index);
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
      dict.language = fushi::primary_language_tag(language);
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

  // 词典集合变了：现有的联合过滤器不覆盖这本新词典，作废；在飞的后台构建按 epoch
  // 丢弃自己的成果。宿主装完全部词典后重新 prepare_union_filter。
  if (union_) {
    std::lock_guard<std::mutex> lock(union_->mutex);
    union_->epoch++;
    union_->filter.reset();
    union_->state = UnionFilterState::None;
  }
  if (union_builder_) {
    union_builder_->request_stop();
  }
}

DictionaryQuery::QueryScope DictionaryQuery::make_scope(const ExcludedDictNames* excluded) const {
  QueryScope scope;
  scope.excluded = excluded;
  if (union_) {
    std::lock_guard<std::mutex> lock(union_->mutex);
    scope.filter = union_->filter;
  }
  return scope;
}

UnionFilterState DictionaryQuery::union_filter_state() const {
  if (!union_) {
    return UnionFilterState::None;
  }
  std::lock_guard<std::mutex> lock(union_->mutex);
  return union_->state;
}

void DictionaryQuery::prepare_union_filter(const std::string& cache_dir, bool wait) {
  if (!union_ || !union_builder_) {
    return;
  }
  // 同一时刻只有一份构建：先叫停上一份（它的成果已被这次取代）。
  std::lock_guard<std::mutex> builder_lock(union_builder_->mutex);
  union_builder_->stop_locked();

  // 构建线程自己撑着每本词典索引文件（key.index / hash.table）的映射，并持有 key_index
  // 视图的副本（本对象在别的线程上被 add_dict 改动也不影响它读到的那批）；本对象析构
  // 时由 UnionBuilder 叫停并等它退出。
  struct Input {
    uint64_t identity;
    memory::shared_mapping mapping;
    std::optional<hash::key_index> keys;
  };
  auto inputs = std::make_shared<std::vector<Input>>();
  for (const auto* dicts : {&term_dicts_, &freq_dicts_, &pitch_dicts_, &kanji_dicts_}) {
    for (const Dictionary& dict : *dicts) {
      const hash::dict_index& index = dict.data->index;
      std::optional<hash::key_index> keys;
      if (const hash::key_index* k = index.keys()) {
        keys = *k;
      }
      inputs->push_back({index.identity(), index.index_mapping(), keys});
    }
  }

  uint64_t epoch = 0;
  {
    std::lock_guard<std::mutex> lock(union_->mutex);
    epoch = ++union_->epoch;
    if (inputs->empty()) {
      union_->filter.reset();
      union_->state = UnionFilterState::None;
      return;
    }
    // 已有的过滤器（若有）对当前集合仍然有效，新的一份发布前继续用它。
    union_->state = union_->filter ? UnionFilterState::Ready : UnionFilterState::Building;
  }

  auto publish = [slot = union_, epoch](std::shared_ptr<const hash::union_filter> filter) {
    std::lock_guard<std::mutex> lock(slot->mutex);
    if (slot->epoch != epoch) {
      return;
    }
    if (filter) {
      slot->filter = std::move(filter);
    }
    slot->state = slot->filter ? UnionFilterState::Ready : UnionFilterState::None;
  };
  auto cancel = std::make_shared<std::atomic<bool>>(false);
  auto job = [inputs, cache_dir, publish, cancel]() {
    std::shared_ptr<const hash::union_filter> filter;
    try {
      std::vector<hash::union_filter::source> sources;
      sources.reserve(inputs->size());
      for (const Input& input : *inputs) {
        if (input.keys) {
          sources.push_back({.identity = input.identity, .keys = &*input.keys});
        } else {
          sources.push_back(
              {.identity = input.identity, .table = input.mapping->data, .table_size = input.mapping->size});
        }
      }
      filter = hash::union_filter::open_or_build(sources, cache_dir, cancel.get());
    } catch (const std::exception& e) {
      // 建不出来（内存不足 / 文件系统异常）：没有过滤器，查询照走各词典的 bloom。
      FUSHI_LOGW("union filter build failed: %s", e.what());
    }
    try {
      publish(std::move(filter));
    } catch (const std::exception&) {
      // 互斥量加锁失败：槽保持原状，查询不受影响。
    }
  };

  if (wait) {
    job();
    return;
  }
  try {
    union_builder_->thread = std::thread(job);
    union_builder_->cancel = std::move(cancel);
  } catch (const std::exception&) {
    // 起不了线程（系统线程数到顶 / 内存不足）：当作没建成。
    publish(nullptr);
  }
}

void DictionaryQuery::add_term_dict(const std::string& path, std::string_view language) {
  add_dict(path, DictionaryQuery::DictionaryType::TERM, language);
}

void DictionaryQuery::add_freq_dict(const std::string& path) { add_dict(path, DictionaryQuery::DictionaryType::FREQ); }

void DictionaryQuery::add_pitch_dict(const std::string& path) {
  add_dict(path, DictionaryQuery::DictionaryType::PITCH);
}

void DictionaryQuery::add_kanji_dict(const std::string& path) {
  add_dict(path, DictionaryQuery::DictionaryType::KANJI);
}

std::vector<TermResult> DictionaryQuery::query(const std::string& expression) const {
  const QueryScope scope = make_scope();
  auto results = query_raw(expression, scope);
  // query_raw() no longer enriches (BUG-1304); this single-expression entry
  // point does it itself so its contract is unchanged.
  for (auto& term : results) {
    enrich_freq(term, scope);
  }
  for (auto& term : results) {
    enrich_pitch(term, scope);
  }
  for (auto& term : results) {
    materialize(term);
  }
  return results;
}

std::vector<TermResult> DictionaryQuery::query_frequencies(const std::string& expression) const {
  const QueryScope scope = make_scope();
  auto results = query_raw(expression, scope);
  for (auto& term : results) {
    enrich_freq(term, scope);
    // query_raw 留下的是没解压的释义引用（词典名 / 标签 + 指向映射的压缩块）；不交出
    // 「看起来有释义、其实是空串」的条目。
    term.glossaries.clear();
  }
  return results;
}

std::vector<TermResult> DictionaryQuery::query_raw(const std::string& expression, const QueryScope& scope) const {
  const ExcludedDictNames* excluded = scope.excluded;
  const KeyProbe key(expression, scope.filter);
  std::map<std::pair<std::string_view, std::string_view>, TermResult> term_map;
  // term_map 的键是指向记录的 string_view：窗口映射（32 位）下要撑住这些窗口到函数
  // 返回；64 位整份映射时 owner 恒空、不进这里。
  std::vector<std::shared_ptr<const void>> pins;
  for (const auto& [dict, loc] : locate_all(term_dicts_, key, excluded)) {
    const auto& [name, styles, language, data] = *dict;
    const memory::blob_file& blobs = data->index.blobs();
    for_each_record_of_type(blobs, loc, 0, [&](BlobReader& blob, const memory::blob_span& rec) -> bool {
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
      memory::blob_span glossary = blobs.view(glossary_offset, glossary_size);
      entry.compressed_data = glossary.data;
      entry.compressed_size = static_cast<uint32_t>(glossary.size);
      entry.compressed_source = &blobs;
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
  const QueryScope scope = make_scope();
  const KeyProbe key(character, scope.filter);
  for (const auto& [name, styles, language, data] : kanji_dicts_) {
    const std::optional<location> loc = data->locate(key);
    if (!loc) {
      continue;
    }
    const memory::blob_file& blobs = data->index.blobs();
    for_each_record_of_type(blobs, *loc, 2, [&](BlobReader& blob, const memory::blob_span&) -> bool {
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
          meanings_size > 0 ? blobs.view(meanings_offset, meanings_size) : memory::blob_span{};
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
  const QueryScope scope = make_scope();
  for (auto& term : terms) {
    enrich_freq(term, scope);
  }
}

void DictionaryQuery::enrich_freq(TermResult& term, const QueryScope& scope) const {
  const ExcludedDictNames* excluded = scope.excluded;
  if (freq_dicts_.empty()) {
    return;
  }
  const KeyProbe key(term.expression, scope.filter);
  for (const auto& [dict, loc] : locate_all(freq_dicts_, key, excluded)) {
    const auto& [name, styles, language, data] = *dict;
    std::vector<Frequency> frequencies;
    for_each_meta_record(data->index.blobs(), loc, term.expression,
                         [&](BlobReader& blob, std::string_view mode, uint8_t type) -> bool {
      if (mode != "freq") {
        return true;
      }

      // type 1：载荷是原始 JSON，这里解析；type 3：导入期已解析好（json/meta_record.hpp）。
      ParsedFrequency parsed;
      if (meta_record::read_frequency(type, blob.ptr, blob.end, parsed)) {
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
  const QueryScope scope = make_scope();
  for (auto& term : terms) {
    enrich_pitch(term, scope);
  }
}

void DictionaryQuery::enrich_pitch(TermResult& term, const QueryScope& scope) const {
  const ExcludedDictNames* excluded = scope.excluded;
  if (pitch_dicts_.empty()) {
    return;
  }
  const KeyProbe key(term.expression, scope.filter);
  for (const auto& [dict, loc] : locate_all(pitch_dicts_, key, excluded)) {
    const auto& [name, styles, language, data] = *dict;
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

    for_each_meta_record(data->index.blobs(), loc, term.expression,
                         [&](BlobReader& blob, std::string_view mode, uint8_t type) -> bool {
      // Both pitch-accent ("pitch") and IPA transcription ("ipa") meta records
      // share this PITCH dict bucket / storage layout (upstream 918744d). The
      // data blob differs only in how the JSON is shaped; parse with the
      // matching parser and accumulate into the right vector. Anything else is
      // skipped.
      ParsedPitch parsed;
      if (mode == "pitch") {
        if (meta_record::read_pitch(type, blob.ptr, blob.end, parsed)) {
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
        if (meta_record::read_ipa(type, blob.ptr, blob.end, parsed)) {
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

  // resize_and_overwrite：缓冲区不先清零——一次查词解压约 1 MB 正文，先 memset 一遍
  // 再被解压结果整段覆盖是白写。失败时返回 0，串为空。
  // 解压上下文先取好：resize_and_overwrite 的回调不允许抛异常。
  ZSTD_DCtx* const dctx = thread_dctx();
  std::string result;
  result.resize_and_overwrite(static_cast<size_t>(decompressed_size), [&](char* buffer, size_t capacity) -> size_t {
    const size_t actual_size = ZSTD_decompress_usingDDict(dctx, buffer, capacity, data, size, dict);
    return ZSTD_isError(actual_size) ? 0 : actual_size;
  });
  return result;
}

void DictionaryQuery::materialize(TermResult& term) const {
  for (auto& g : term.glossaries) {
    g.glossary = decompress_glossary(g.compressed_data, g.compressed_size, g.zstd_dict);
  }
}

std::vector<char> DictionaryQuery::get_media_file(const std::string& dict_name, const std::string& media_path) const {
  const std::string normalized_media_path = fushidicts::normalize_media_path(media_path);
  for (const auto& [name, styles, language, data] : term_dicts_) {
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
  // sidecar 记的是记录文件（blobs.bin / 升级重写过的 blobs3.bin）的大小。
  hash::dict_index index;
  if (!index.open(dir)) return -1;
  const uint64_t blobs_size = index.blobs().size();
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
// Walk every index location (key.index slots or hash.table buckets, see
// hash/dict_index.hpp) -> record(s) -> record type byte. The on-disk format is
// the one query()/query_kanji() consume:
//   location   : single -> the record itself; otherwise an offset-index
//                [u32 count][u64 record_offset x count] in the record file.
//   record     : first byte = type (0=term, 1/3=meta, 2=kanji)
// All little-endian (write_val/BlobReader use memcpy). We cannot sequentially
// scan the record region (no boundary metadata, glossary blobs interleaved),
// so we must go through the index.
int probe_dict_content(const std::string& dir) {
  // map_rd_shared（BUG-4013）：已装载的词典复用引擎那份映射。
  hash::dict_index index;
  if (!index.open(dir)) {
    return 0;
  }
  const memory::blob_file& blobs = index.blobs();

  int mask = 0;
  index.for_each_location([&](location bucket) -> bool {
    hash::for_each_record_offset(blobs, bucket, [&](uint64_t offset) -> bool {
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
