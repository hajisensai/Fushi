#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <condition_variable>
#include <mutex>
#include <shared_mutex>  // std::shared_lock
#include <string>
#include <type_traits>
#include <utility>
#include <vector>
#include "fushidicts/platform.hpp"
#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/query.hpp"
#include "fushidicts/popup_json.hpp"
#include "fushidicts/tokenize.hpp"
#include <utf8.h>
#include <zstd.h>

// ── helpers ──────────────────────────────────────────────────────────
static char* dup(const std::string& s) {
  char* p = static_cast<char*>(malloc(s.size() + 1));
  if (p) memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

// ── FFI 边界异常闸门 ─────────────────────────────────────────────────
//
// `extern "C"` 边界不是异常边界：C++ 异常一旦从导出函数里逃出去，行为未定义，
// 实际表现是 `std::terminate` → SIGABRT → **进程当场消失**。Dart 侧的 try/catch、
// 错误屏、日志落盘在这种死法下全部够不着，用户看到的只是「转圈转一半 app 自己
// 退出，没有任何报错」。这条路径在本仓有前科（见 query.cpp `add_dict` 上方关于
// 上游 TestFlight 崩溃的注释），而词典越多、启动时经过这些入口的次数越多，撞上
// `bad_alloc` / `filesystem_error` 的概率就线性上升。
//
// 治法不是给每个导出各贴一段 try/catch（23 个入口，漏一个就复发），而是让**所有**
// 导出无例外地经过这一个闸门：异常在这里被吃掉并记日志，调用方拿到零值结果
// （count=0 / nullptr / 0），Dart 侧走既有的空结果分支。守卫测试
// `tests/ffi_guard_coverage_test.cpp` 扫本文件，任何没走闸门的导出都会让 CI 红，
// 所以「新增导出忘了防护」在结构上不可能再发生。
//
// 有返回值的入口用 [ffi_guard]（零初始化 fallback）；需要非零 fallback 的用
// [ffi_guard_or]（fallback **工厂**，只在真出异常时才构造——传现成的值会让正常
// 路径也构造一份没人释放的结果，那是每次调用一次的内存泄漏）；void 入口用
// [ffi_guard_void]。三者都是 noexcept：闸门自己绝不再抛。
template <typename F, typename R = std::invoke_result_t<F>>
static R ffi_guard(const char* tag, F&& fn) noexcept {
  try {
    return fn();
  } catch (const std::exception& e) {
    FUSHI_LOGE("%s threw: %s", tag, e.what());
  } catch (...) {
    FUSHI_LOGE("%s threw a non-std exception", tag);
  }
  return R{};
}

template <typename F, typename G, typename R = std::invoke_result_t<F>>
static R ffi_guard_or(const char* tag, F&& fn, G&& make_fallback) noexcept {
  try {
    return fn();
  } catch (const std::exception& e) {
    FUSHI_LOGE("%s threw: %s", tag, e.what());
  } catch (...) {
    FUSHI_LOGE("%s threw a non-std exception", tag);
  }
  return make_fallback();
}

template <typename F>
static void ffi_guard_void(const char* tag, F&& fn) noexcept {
  try {
    fn();
  } catch (const std::exception& e) {
    FUSHI_LOGE("%s threw: %s", tag, e.what());
  } catch (...) {
    FUSHI_LOGE("%s threw a non-std exception", tag);
  }
}

/// 结果数组分配：`malloc` 返回 null 时把 [count] 归零再返回 nullptr。
///
/// 闸门接得住 C++ 异常，接不住「malloc 失败后照样往 null 指针里写」——那是
/// SIGSEGV，同样是静默闪退，而低内存正是本类崩溃的现场条件。把 count 和缓冲区
/// 的分配收进同一个原语后，「count 说有 N 条但指针是 null」这个状态不可能再被
/// 构造出来：失败即 0 条，后续填充循环自然不跑，配套的 free 也照常安全
/// （`free(nullptr)` 是合法的）。
template <typename T>
static T* alloc_array(int32_t& count) {
  if (count <= 0) {
    count = 0;
    return nullptr;
  }
  auto* p = static_cast<T*>(malloc(sizeof(T) * static_cast<size_t>(count)));
  if (!p) {
    FUSHI_LOGE("out of memory allocating %d result item(s)", count);
    count = 0;
  }
  return p;
}

// ── flat C structs returned across FFI ──────────────────────────────
extern "C" {

struct FfiGlossary {
  char* dict_name;
  char* glossary;
  char* definition_tags;
  char* term_tags;
};

struct FfiFrequency {
  char* dict_name;
  int32_t* values;
  char** display_values;
  int32_t count;
};

struct FfiPitch {
  char* dict_name;
  int32_t* positions;
  int32_t count;
  char** transcriptions;
  int32_t transcription_count;
  // 79c55c2 二期：pattern 式 accent（"heiban" 等字符串位）单独成数组，positions
  // 仍只含数字位（既有消费方字节兼容）。Dart 绑定同 commit 镜像。
  char** patterns;
  int32_t pattern_count;
};

struct FfiTermResult {
  char* expression;
  char* reading;
  char* rules;
  FfiGlossary* glossaries;
  int32_t glossary_count;
  FfiFrequency* frequencies;
  int32_t frequency_count;
  FfiPitch* pitches;
  int32_t pitch_count;
};

struct FfiQueryResult {
  FfiTermResult* terms;
  int32_t count;
};

struct FfiTransformGroup {
  char* name;
  char* description;
};

struct FfiLookupResult {
  char* matched;
  char* deinflected;
  FfiTransformGroup* trace;
  int32_t trace_count;
  FfiTermResult term;
  int32_t preprocessor_steps;
};

struct FfiLookupResults {
  FfiLookupResult* results;
  int32_t count;
};

struct FfiImportResult {
  int32_t success;
  char* title;
  int32_t term_count;
  int32_t meta_count;
  int32_t freq_count;
  int32_t pitch_count;
  int32_t media_count;
  int32_t kanji_count;
  char* detected_type;
  char* error;
};

struct FfiDictStyle {
  char* dict_name;
  char* styles;
};

struct FfiDictStyles {
  FfiDictStyle* items;
  int32_t count;
};

struct FfiKanjiResult {
  char* character;
  char* onyomi;
  char* kunyomi;
  char* radical;
  int32_t strokes;
  char** meanings;
  int32_t meaning_count;
  // v2 词典的完整 stats 键值对（JLPT/grade 等；v1 记录恒为 0 条）。
  // keys/values 平行数组，长度均为 stat_count；Dart 绑定同 commit 镜像。
  char** stat_keys;
  char** stat_values;
  int32_t stat_count;
  char* dict_name;
};

struct FfiKanjiResults {
  FfiKanjiResult* results;
  int32_t count;
};

// ── conversion helpers ──────────────────────────────────────────────

static FfiTermResult convert_term(const TermResult& t) {
  FfiTermResult r{};
  r.expression = dup(t.expression);
  r.reading = dup(t.reading);
  r.rules = dup(t.rules);

  r.glossary_count = static_cast<int32_t>(t.glossaries.size());
  r.glossaries = alloc_array<FfiGlossary>(r.glossary_count);
  for (int i = 0; i < r.glossary_count; i++) {
    r.glossaries[i].dict_name = dup(t.glossaries[i].dict_name);
    r.glossaries[i].glossary = dup(t.glossaries[i].glossary);
    r.glossaries[i].definition_tags = dup(t.glossaries[i].definition_tags);
    r.glossaries[i].term_tags = dup(t.glossaries[i].term_tags);
  }

  r.frequency_count = static_cast<int32_t>(t.frequencies.size());
  r.frequencies = alloc_array<FfiFrequency>(r.frequency_count);
  for (int i = 0; i < r.frequency_count; i++) {
    auto& f = t.frequencies[i];
    r.frequencies[i].dict_name = dup(f.dict_name);
    // values 与 display_values 是平行数组，共用同一个 count：任一分配失败都必须
    // 把 count 归零并把两根指针都置空，否则 free 路径会按幸存的那个 count 去遍历
    // 已经归零的另一根。
    r.frequencies[i].count = static_cast<int32_t>(f.frequencies.size());
    int32_t value_count = r.frequencies[i].count;
    r.frequencies[i].values = alloc_array<int32_t>(value_count);
    r.frequencies[i].display_values = alloc_array<char*>(r.frequencies[i].count);
    if (value_count != r.frequencies[i].count) {
      free(r.frequencies[i].values);
      free(r.frequencies[i].display_values);
      r.frequencies[i].values = nullptr;
      r.frequencies[i].display_values = nullptr;
      r.frequencies[i].count = 0;
    }
    for (int j = 0; j < r.frequencies[i].count; j++) {
      r.frequencies[i].values[j] = f.frequencies[j].value;
      r.frequencies[i].display_values[j] = dup(f.frequencies[j].display_value);
    }
  }

  r.pitch_count = static_cast<int32_t>(t.pitches.size());
  r.pitches = alloc_array<FfiPitch>(r.pitch_count);
  for (int i = 0; i < r.pitch_count; i++) {
    r.pitches[i].dict_name = dup(t.pitches[i].dict_name);
    // 数字位与 pattern 位分流：positions 只装数字 accent（既有语义不变），
    // pattern accent 进 patterns（79c55c2 二期）。
    std::vector<int32_t> numeric;
    std::vector<const std::string*> pattern_refs;
    for (const auto& accent : t.pitches[i].pitches) {
      if (accent.pattern.empty()) {
        numeric.push_back(accent.position);
      } else {
        pattern_refs.push_back(&accent.pattern);
      }
    }
    r.pitches[i].count = static_cast<int32_t>(numeric.size());
    r.pitches[i].positions = alloc_array<int32_t>(r.pitches[i].count);
    for (int j = 0; j < r.pitches[i].count; j++) {
      r.pitches[i].positions[j] = numeric[j];
    }
    r.pitches[i].pattern_count = static_cast<int32_t>(pattern_refs.size());
    r.pitches[i].patterns = alloc_array<char*>(r.pitches[i].pattern_count);
    for (int j = 0; j < r.pitches[i].pattern_count; j++) {
      r.pitches[i].patterns[j] = dup(*pattern_refs[j]);
    }
    // transcriptions: char** array of IPA strings, mirroring frequency
    // display_values (malloc the pointer array, then dup each element).
    r.pitches[i].transcription_count = static_cast<int32_t>(t.pitches[i].transcriptions.size());
    r.pitches[i].transcriptions = alloc_array<char*>(r.pitches[i].transcription_count);
    for (int j = 0; j < r.pitches[i].transcription_count; j++) {
      r.pitches[i].transcriptions[j] = dup(t.pitches[i].transcriptions[j]);
    }
  }
  return r;
}

static void free_term(FfiTermResult& r) {
  free(r.expression);
  free(r.reading);
  free(r.rules);
  for (int i = 0; i < r.glossary_count; i++) {
    free(r.glossaries[i].dict_name);
    free(r.glossaries[i].glossary);
    free(r.glossaries[i].definition_tags);
    free(r.glossaries[i].term_tags);
  }
  free(r.glossaries);
  for (int i = 0; i < r.frequency_count; i++) {
    free(r.frequencies[i].dict_name);
    for (int j = 0; j < r.frequencies[i].count; j++) {
      free(r.frequencies[i].display_values[j]);
    }
    free(r.frequencies[i].values);
    free(r.frequencies[i].display_values);
  }
  free(r.frequencies);
  for (int i = 0; i < r.pitch_count; i++) {
    free(r.pitches[i].dict_name);
    free(r.pitches[i].positions);
    // double free: each transcription string, then the pointer array (mirrors
    // the frequency display_values free).
    for (int j = 0; j < r.pitches[i].transcription_count; j++) {
      free(r.pitches[i].transcriptions[j]);
    }
    free(r.pitches[i].transcriptions);
    for (int j = 0; j < r.pitches[i].pattern_count; j++) {
      free(r.pitches[i].patterns[j]);
    }
    free(r.pitches[i].patterns);
  }
  free(r.pitches);
}

// ── import ──────────────────────────────────────────────────────────

struct ImportThreadArgs {
  std::string zip_path;
  std::string output_dir;
  std::string breadcrumb_dir;
  FfiImportResult result;
};

#ifdef _WIN32
static unsigned __stdcall import_thread_fn(void* arg) {
#else
static void* import_thread_fn(void* arg) {
#endif
  auto* a = static_cast<ImportThreadArgs*>(arg);
  try {
    auto result = dictionary_importer::import(a->zip_path, a->output_dir, kFushiImportLowRam, a->breadcrumb_dir);
    a->result.success = result.success ? 1 : 0;
    a->result.title = dup(result.title);
    a->result.term_count = static_cast<int32_t>(result.term_count);
    a->result.meta_count = static_cast<int32_t>(result.meta_count);
    a->result.freq_count = static_cast<int32_t>(result.freq_count);
    a->result.pitch_count = static_cast<int32_t>(result.pitch_count);
    a->result.media_count = static_cast<int32_t>(result.media_count);
    a->result.kanji_count = static_cast<int32_t>(result.kanji_count);
    a->result.detected_type = dup(result.detected_type);
    std::string err;
    for (auto& e : result.errors) {
      if (!err.empty()) err += "\n";
      err += e;
    }
    a->result.error = dup(err);
  } catch (const std::exception& e) {
    a->result.success = 0;
    a->result.title = dup("");
    a->result.detected_type = dup("term");
    a->result.error = dup(e.what());
  } catch (...) {
    // A non-std exception leaving a thread's start routine is std::terminate,
    // i.e. the app dies mid-import (BUG-2952). Nothing may escape this frame.
    a->result.success = 0;
    a->result.title = dup("");
    a->result.detected_type = dup("term");
    a->result.error = dup("dictionary import failed (unknown native exception)");
  }
#ifdef _WIN32
  return 0;
#else
  return nullptr;
#endif
}

FUSHI_EXPORT
FfiImportResult fushidicts_import(const char* zip_path, const char* output_dir, const char* breadcrumb_dir) {
  // fallback 带真串而不是 nullptr：导入失败是 Dart 侧要读 title/error 展示给用户的
  // **正常**分支，空 error 会让用户只看到「导入失败」而拿不到任何线索。
  return ffi_guard_or(
      "fushidicts_import",
      [&]() -> FfiImportResult {
        ImportThreadArgs args;
        args.zip_path = zip_path;
        args.output_dir = output_dir;
        // breadcrumb_dir may be null (older callers / disabled); treat as "no breadcrumb".
        args.breadcrumb_dir = breadcrumb_dir ? breadcrumb_dir : "";
        args.result = {};

        FushiThread thread;
        bool ok = fushi_thread_create(thread, import_thread_fn, &args, 32 * 1024 * 1024);

        if (!ok) {
          args.result.success = 0;
          args.result.title = dup("");
          args.result.error = dup("Failed to create import thread");
          return args.result;
        }

        fushi_thread_join(thread);
        return args.result;
      },
      []() -> FfiImportResult {
        FfiImportResult fallback{};
        fallback.success = 0;
        fallback.title = dup("");
        fallback.detected_type = dup("term");
        fallback.error = dup("dictionary import failed (native exception)");
        return fallback;
      });
}

FUSHI_EXPORT
void fushidicts_free_import_result(FfiImportResult* r) {
  ffi_guard_void("fushidicts_free_import_result", [&]() {
    if (!r) return;
    free(r->title);
    free(r->detected_type);
    free(r->error);
  });
}

FUSHI_EXPORT
int32_t fushidicts_probe_dict_content(const char* dir) {
  return ffi_guard("fushidicts_probe_dict_content", [&]() -> int32_t {
    if (!dir) return 0;
    return static_cast<int32_t>(probe_dict_content(std::string(dir)));
  });
}

// 已导入词典的 redirect_glossary.flag 迁移（语义见 query.hpp
// ensure_redirect_glossary_flag）：1 含纯重定向 / 0 不含 / -1 读不了。不需要句柄；
// 整本扫描，宿主应在后台 isolate 调用。
FUSHI_EXPORT
int32_t fushidicts_ensure_redirect_flag(const char* dir) {
  return ffi_guard_or(
      "fushidicts_ensure_redirect_flag",
      [&]() -> int32_t {
        if (!dir) return -1;
        return static_cast<int32_t>(ensure_redirect_glossary_flag(std::string(dir)));
      },
      []() -> int32_t { return -1; });
}

// ── query handle ────────────────────────────────────────────────────

// 当前存活（尚未真正 delete）的句柄数；只给测试观测「退役后最后一次 release 才销毁、
// 且只销毁一次」用（fushidicts_live_handle_count）。
static std::atomic<int32_t> g_live_handles{0};

// ── 句柄生命周期：引用计数 + 退役（HBK-AUDIT-009） ──────────────────────
//
// 句柄以前只有「宿主（Dart 主 isolate 的 FushiDicts 实例）独占、destroy 直接 delete」
// 一种用法。后台 isolate 要拿同一个句柄的地址去分词时，这就成了释放后使用：词典重载
// （_applyTyped / loadPendingAsync / releaseAllMappings）会在后台调用还在跑时把旧句柄
// delete 掉，连同它的文件映射。
//
// 现在：
//   * create 出来的句柄带 1 个引用（宿主的那一个）。
//   * fushidicts_retain：借用方在**自己仍持有一个引用**（通常就是宿主实例还没
//     destroy）时加一个引用；句柄已退役时拒绝（返回 0），借用方不得使用它。
//   * fushidicts_release：还一个引用；最后一个引用归还时才真正 delete（解除映射）。
//   * fushidicts_destroy = 退役：标记 retired 并还掉宿主的那个引用。在飞的借用照常
//     跑完，最后一个 release 时销毁。借用期间重复 destroy 不会重复还引用；没有借用时
//     第一次 destroy 就已销毁，宿主不得再碰这个地址（Dart 侧 dispose 后把句柄置空）。
//
// 读写锁 rw：查询类导出（query / lookup / tokenize / match_length …）取共享锁，彼此
// 可以并发（查询路径只读，唯一的可变状态 match_cache 自带互斥）；改状态的
// add_*_dict / load_transforms 取独占锁，不会与任何在飞查询交错（以前对此没有任何
// 保证，add 时扩容 std::vector<Dictionary> 会让并发的遍历读到已释放的元素）。
// 锁只在导出层取一次，导出之间不互相调用，不存在重入（这是硬前提：写者优先的锁下，
// 同一线程重入共享锁会在有写者排队时自锁）。
//
// rw 不用 std::shared_mutex：libstdc++ 的实现是默认属性的 pthread_rwlock_t，glibc 默认
// PTHREAD_RWLOCK_PREFER_READER_NP——只要还有读者持锁，新读者照样进，排队的写者一直等。
// ≥2 个线程连续分词时读区间首尾相接，add_*_dict 永远拿不到独占锁（Linux GCC 下
// handle_lifecycle_concurrency_test 场景 3 挂死在这里；libc++ / MSVC 的实现恰好不饿写者，
// 所以只在 libstdc++ 平台——Linux 桌面 / 无头服务端——暴露）。改用下面这把写者优先锁：
// 写者一排队新读者就等，在飞读者跑完后写者必然拿到锁；语义不再依赖各平台标准库的实现细节。
//
// 匿名命名空间（内部链接）：fushidicts_jni.cpp 有一个布局不同的同名结构体，两者的
// 隐式成员函数若都以外部链接的弱符号导出，同进程里的两个 .so 可能被动态链接器解析到
// 同一份实现上（ODR）。
namespace {
// 写者优先的读写锁（只实现 std::shared_lock / std::unique_lock 用到的 SharedMutex 子集）。
// 写者只在加词典 / 变形表时出现，频率远低于查询，「写者连续排队饿读者」不是现实风险；
// 反过来读者饿写者是现实的（见上）。
class WriterPreferringSharedMutex {
 public:
  void lock_shared() {
    std::unique_lock<std::mutex> guard(mutex_);
    readers_cv_.wait(guard, [this]() { return !writer_active_ && waiting_writers_ == 0; });
    ++active_readers_;
  }

  void unlock_shared() {
    bool wake_writer = false;
    {
      std::lock_guard<std::mutex> guard(mutex_);
      wake_writer = --active_readers_ == 0 && waiting_writers_ > 0;
    }
    if (wake_writer) writer_cv_.notify_one();
  }

  void lock() {
    std::unique_lock<std::mutex> guard(mutex_);
    ++waiting_writers_;
    writer_cv_.wait(guard, [this]() { return !writer_active_ && active_readers_ == 0; });
    --waiting_writers_;
    writer_active_ = true;
  }

  void unlock() {
    bool writers_waiting = false;
    {
      std::lock_guard<std::mutex> guard(mutex_);
      writer_active_ = false;
      writers_waiting = waiting_writers_ > 0;
    }
    // 有写者排队就交给下一个写者（读者的谓词仍被 waiting_writers_ 挡着）；否则放行全部读者。
    if (writers_waiting) {
      writer_cv_.notify_one();
    } else {
      readers_cv_.notify_all();
    }
  }

 private:
  std::mutex mutex_;
  std::condition_variable readers_cv_;
  std::condition_variable writer_cv_;
  int32_t active_readers_ = 0;
  int32_t waiting_writers_ = 0;
  bool writer_active_ = false;
};

struct FushidictsHandle {
  FushidictsHandle() { g_live_handles.fetch_add(1, std::memory_order_relaxed); }
  ~FushidictsHandle() { g_live_handles.fetch_sub(1, std::memory_order_relaxed); }
  FushidictsHandle(const FushidictsHandle&) = delete;
  FushidictsHandle& operator=(const FushidictsHandle&) = delete;

  DictionaryQuery query;
  Deinflector deinflector;
  // 分词的匹配长度缓存。结果依赖词典集合与变形表，所以 add_*_dict /
  // load_transforms 都要清空它（见 tokenize.hpp）。
  MatchLengthCache match_cache;

  WriterPreferringSharedMutex rw;
  std::atomic<int32_t> refs{1};
  std::atomic<bool> retired{false};
};
}  // namespace

// 还一个引用；归零时销毁。acq_rel：最后一个归还者必须看见其它借用方的全部写入
// （match_cache 等）之后才 delete。
static void handle_release(FushidictsHandle* h) noexcept {
  if (h->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) delete h;
}

FUSHI_EXPORT
void* fushidicts_create() {
  return ffi_guard("fushidicts_create",
                   [&]() -> void* { return new FushidictsHandle(); });
}

FUSHI_EXPORT
void fushidicts_destroy(void* handle) {
  ffi_guard_void("fushidicts_destroy", [&]() {
    if (!handle) return;
    auto* h = static_cast<FushidictsHandle*>(handle);
    // 退役只发生一次：借用期间的第二次 destroy 不再还宿主的引用（否则会把借用方的
    // 引用还掉）。
    if (h->retired.exchange(true, std::memory_order_acq_rel)) return;
    handle_release(h);
  });
}

// 借用一个引用。返回 1 = 借到，调用方用完必须 fushidicts_release；0 = 句柄已退役
// （或 handle 为空），不得使用。前提：调用方此刻自己仍持有一个引用——对一个可能已经
// 被最后一个 release 销毁的地址调 retain 本身就是释放后使用，这里查不出来。
FUSHI_EXPORT
int32_t fushidicts_retain(void* handle) {
  return ffi_guard("fushidicts_retain", [&]() -> int32_t {
    if (!handle) return 0;
    auto* h = static_cast<FushidictsHandle*>(handle);
    if (h->retired.load(std::memory_order_acquire)) return 0;
    h->refs.fetch_add(1, std::memory_order_relaxed);
    return 1;
  });
}

FUSHI_EXPORT
void fushidicts_release(void* handle) {
  ffi_guard_void("fushidicts_release", [&]() {
    if (!handle) return;
    handle_release(static_cast<FushidictsHandle*>(handle));
  });
}

FUSHI_EXPORT
int32_t fushidicts_live_handle_count() {
  return ffi_guard("fushidicts_live_handle_count", [&]() -> int32_t {
    return g_live_handles.load(std::memory_order_relaxed);
  });
}

// 四个 add_*_dict 是本轮崩溃的第一现场：一次性导入很多词典后，启动要连着走这里
// N 遍，每遍都在读 index.json / styles.css、建映射、可能建 zstd 词典——任何一次
// bad_alloc 过去都会直接崩掉整个进程。现在单本失败只是这本不进引擎（native 侧
// 已按 return 处理），其余词典照常可用。
FUSHI_EXPORT
void fushidicts_add_term_dict(void* handle, const char* path) {
  ffi_guard_void("fushidicts_add_term_dict", [&]() {
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::unique_lock lock(h->rw);
    h->query.add_term_dict(path);
    h->match_cache.clear();
  });
}

FUSHI_EXPORT
void fushidicts_add_freq_dict(void* handle, const char* path) {
  ffi_guard_void("fushidicts_add_freq_dict", [&]() {
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::unique_lock lock(h->rw);
    h->query.add_freq_dict(path);
    h->match_cache.clear();
  });
}

FUSHI_EXPORT
void fushidicts_add_pitch_dict(void* handle, const char* path) {
  ffi_guard_void("fushidicts_add_pitch_dict", [&]() {
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::unique_lock lock(h->rw);
    h->query.add_pitch_dict(path);
    h->match_cache.clear();
  });
}

FUSHI_EXPORT
void fushidicts_add_kanji_dict(void* handle, const char* path) {
  ffi_guard_void("fushidicts_add_kanji_dict", [&]() {
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::unique_lock lock(h->rw);
    h->query.add_kanji_dict(path);
    h->match_cache.clear();
  });
}

FUSHI_EXPORT
void fushidicts_load_transforms(void* handle, const char* json) {
  ffi_guard_void("fushidicts_load_transforms", [&]() {
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::unique_lock lock(h->rw);
    h->deinflector.load_transforms_json(json);
    h->match_cache.clear();
  });
}

// ── query ───────────────────────────────────────────────────────────

FUSHI_EXPORT
FfiQueryResult fushidicts_query(void* handle, const char* expression) {
  return ffi_guard("fushidicts_query", [&]() -> FfiQueryResult {
    FfiQueryResult r{};
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::shared_lock lock(h->rw);
    auto& q = h->query;
    auto terms = q.query(expression);
    r.count = static_cast<int32_t>(terms.size());
    r.terms = alloc_array<FfiTermResult>(r.count);
    for (int i = 0; i < r.count; i++) {
      r.terms[i] = convert_term(terms[i]);
    }
    return r;
  });
}

FUSHI_EXPORT
void fushidicts_free_query_result(FfiQueryResult* r) {
  ffi_guard_void("fushidicts_free_query_result", [&]() {
    if (!r) return;
    for (int i = 0; i < r->count; i++) {
      free_term(r->terms[i]);
    }
    free(r->terms);
  });
}

// ── kanji query ─────────────────────────────────────────────────────

FUSHI_EXPORT
FfiKanjiResults fushidicts_query_kanji(void* handle, const char* character) {
  return ffi_guard("fushidicts_query_kanji", [&]() -> FfiKanjiResults {
    FfiKanjiResults r{};
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::shared_lock lock(h->rw);
    auto& q = h->query;
    auto kanji = q.query_kanji(character);
    r.count = static_cast<int32_t>(kanji.size());
    r.results = alloc_array<FfiKanjiResult>(r.count);
    for (int i = 0; i < r.count; i++) {
      const auto& k = kanji[i];
      auto& dst = r.results[i];
      dst.character = dup(k.character);
      dst.onyomi = dup(k.onyomi);
      dst.kunyomi = dup(k.kunyomi);
      dst.radical = dup(k.radical);
      dst.strokes = static_cast<int32_t>(k.strokes);
      dst.dict_name = dup(k.dict_name);
      dst.meaning_count = static_cast<int32_t>(k.meanings.size());
      dst.meanings = alloc_array<char*>(dst.meaning_count);
      for (int j = 0; j < dst.meaning_count; j++) {
        dst.meanings[j] = dup(k.meanings[j]);
      }
      // stat_keys / stat_values 是共用 stat_count 的平行数组，与 frequency 的
      // values/display_values 同理：任一失败就整对归零，不留「count 非零但有一
      // 根指针是 null」的状态给 free 路径。
      dst.stat_count = static_cast<int32_t>(k.stats.size());
      int32_t key_count = dst.stat_count;
      dst.stat_keys = alloc_array<char*>(key_count);
      dst.stat_values = alloc_array<char*>(dst.stat_count);
      if (key_count != dst.stat_count) {
        free(dst.stat_keys);
        free(dst.stat_values);
        dst.stat_keys = nullptr;
        dst.stat_values = nullptr;
        dst.stat_count = 0;
      }
      for (int j = 0; j < dst.stat_count; j++) {
        dst.stat_keys[j] = dup(k.stats[j].first);
        dst.stat_values[j] = dup(k.stats[j].second);
      }
    }
    return r;
  });
}

FUSHI_EXPORT
void fushidicts_free_kanji_results(FfiKanjiResults* r) {
  ffi_guard_void("fushidicts_free_kanji_results", [&]() {
    if (!r) return;
    for (int i = 0; i < r->count; i++) {
      auto& k = r->results[i];
      free(k.character);
      free(k.onyomi);
      free(k.kunyomi);
      free(k.radical);
      free(k.dict_name);
      for (int j = 0; j < k.meaning_count; j++) {
        free(k.meanings[j]);
      }
      free(k.meanings);
      for (int j = 0; j < k.stat_count; j++) {
        free(k.stat_keys[j]);
        free(k.stat_values[j]);
      }
      free(k.stat_keys);
      free(k.stat_values);
    }
    free(r->results);
  });
}

// ── lookup ──────────────────────────────────────────────────────────

static FfiLookupResults marshal_lookup_results(std::vector<LookupResult>& results) {
  FfiLookupResults r{};
  r.count = static_cast<int32_t>(results.size());
  r.results = alloc_array<FfiLookupResult>(r.count);
  for (int i = 0; i < r.count; i++) {
    auto& src = results[i];
    auto& dst = r.results[i];
    dst.matched = dup(src.matched);
    dst.deinflected = dup(src.deinflected);
    dst.preprocessor_steps = src.preprocessor_steps;
    dst.trace_count = static_cast<int32_t>(src.trace.size());
    dst.trace = alloc_array<FfiTransformGroup>(dst.trace_count);
    for (int j = 0; j < dst.trace_count; j++) {
      dst.trace[j].name = dup(src.trace[j].name);
      dst.trace[j].description = dup(src.trace[j].description);
    }
    dst.term = convert_term(src.term);
  }
  return r;
}

FUSHI_EXPORT
FfiLookupResults fushidicts_lookup(void* handle, const char* text, int32_t max_results, int32_t scan_length) {
  return ffi_guard("fushidicts_lookup", [&]() -> FfiLookupResults {
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::shared_lock lock(h->rw);
    Lookup lookup(h->query, h->deinflector);
    auto results = lookup.lookup(text, max_results, static_cast<size_t>(scan_length));
    return marshal_lookup_results(results);
  });
}

// 上游 bc62d2b/86c6e2f：带排序选项的 lookup。freq_order：0=Auto 1=Ascending
// 2=Descending 3=Disabled；freq_dict / primary_reading 传 NULL 或空串 = 未设置。
// 老导出 fushidicts_lookup 原样保留（Never break ABI），返回结构同一套，
// 释放同走 fushidicts_free_lookup_results。
// 查询标志位（fushidicts_lookup_with_flags）。
// bit0：查询语言为中文，额外尝试简体 → 繁體拼写（见 LookupOptions::chinese_simp_to_trad）。
// 老导出签名不动（Never break ABI），新增带 flags 的导出；未知位忽略。
static constexpr int32_t kLookupFlagChineseSimpToTrad = 1;

// 这些是 C++ 内部 helper：在 extern "C" 块里要显式切回 C++ 链接（返回 C++ 类型）。
extern "C++" {
namespace {
struct LookupOptionArgs {
  const char* freq_dict;
  int32_t freq_order;
  const char* primary_reading;
  int32_t flags;
};

LookupOptions make_lookup_options(const LookupOptionArgs& args) {
  LookupOptions options;
  if (args.freq_dict && args.freq_dict[0] != '\0') {
    options.frequency_dictionary = std::string(args.freq_dict);
  }
  switch (args.freq_order) {
    case 1: options.frequency_order = LookupFrequencyOrder::Ascending; break;
    case 2: options.frequency_order = LookupFrequencyOrder::Descending; break;
    case 3: options.frequency_order = LookupFrequencyOrder::Disabled; break;
    default: options.frequency_order = LookupFrequencyOrder::Auto; break;
  }
  if (args.primary_reading && args.primary_reading[0] != '\0') {
    options.primary_reading = std::string(args.primary_reading);
  }
  options.chinese_simp_to_trad = (args.flags & kLookupFlagChineseSimpToTrad) != 0;
  return options;
}

// with_options / with_flags 共用：查询类导出一律在共享锁下跑（与 add/remove 词典的
// 独占锁互斥，见 FushidictsHandle::rw）。
FfiLookupResults lookup_with_option_args(void* handle, const char* text, int32_t max_results,
                                         int32_t scan_length, const LookupOptionArgs& args) {
  auto* h = static_cast<FushidictsHandle*>(handle);
  std::shared_lock lock(h->rw);
  Lookup lookup(h->query, h->deinflector);
  auto results = lookup.lookup(text, max_results, static_cast<size_t>(scan_length), make_lookup_options(args));
  return marshal_lookup_results(results);
}
}  // namespace
}  // extern "C++"

FUSHI_EXPORT
FfiLookupResults fushidicts_lookup_with_options(void* handle, const char* text, int32_t max_results,
                                                int32_t scan_length, const char* freq_dict, int32_t freq_order,
                                                const char* primary_reading) {
  return ffi_guard("fushidicts_lookup_with_options", [&]() -> FfiLookupResults {
    return lookup_with_option_args(handle, text, max_results, scan_length,
                                   LookupOptionArgs{freq_dict, freq_order, primary_reading, 0});
  });
}

FUSHI_EXPORT
FfiLookupResults fushidicts_lookup_with_flags(void* handle, const char* text, int32_t max_results,
                                              int32_t scan_length, const char* freq_dict, int32_t freq_order,
                                              const char* primary_reading, int32_t flags) {
  return ffi_guard("fushidicts_lookup_with_flags", [&]() -> FfiLookupResults {
    return lookup_with_option_args(handle, text, max_results, scan_length,
                                   LookupOptionArgs{freq_dict, freq_order, primary_reading, flags});
  });
}

FUSHI_EXPORT
void fushidicts_free_lookup_results(FfiLookupResults* r) {
  ffi_guard_void("fushidicts_free_lookup_results", [&]() {
    if (!r) return;
    for (int i = 0; i < r->count; i++) {
      free(r->results[i].matched);
      free(r->results[i].deinflected);
      for (int j = 0; j < r->results[i].trace_count; j++) {
        free(r->results[i].trace[j].name);
        free(r->results[i].trace[j].description);
      }
      free(r->results[i].trace);
      free_term(r->results[i].term);
    }
    free(r->results);
  });
}

// ── styles ──────────────────────────────────────────────────────────

FUSHI_EXPORT
FfiDictStyles fushidicts_get_styles(void* handle) {
  return ffi_guard("fushidicts_get_styles", [&]() -> FfiDictStyles {
    FfiDictStyles r{};
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::shared_lock lock(h->rw);
    auto& q = h->query;
    auto styles = q.get_styles();
    r.count = static_cast<int32_t>(styles.size());
    r.items = alloc_array<FfiDictStyle>(r.count);
    for (int i = 0; i < r.count; i++) {
      r.items[i].dict_name = dup(styles[i].dict_name);
      r.items[i].styles = dup(styles[i].styles);
    }
    return r;
  });
}

FUSHI_EXPORT
void fushidicts_free_styles(FfiDictStyles* r) {
  ffi_guard_void("fushidicts_free_styles", [&]() {
    if (!r) return;
    for (int i = 0; i < r->count; i++) {
      free(r->items[i].dict_name);
      free(r->items[i].styles);
    }
    free(r->items);
  });
}

// ── media ───────────────────────────────────────────────────────────

struct FfiMediaFile {
  uint8_t* data;
  int32_t size;
};

FUSHI_EXPORT
FfiMediaFile fushidicts_get_media(void* handle, const char* dict_name, const char* media_path) {
  return ffi_guard("fushidicts_get_media", [&]() -> FfiMediaFile {
    FfiMediaFile r{};
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::shared_lock lock(h->rw);
    auto& q = h->query;
    auto data = q.get_media_file(dict_name, media_path);
    // size 与 data 同生共死：分配失败时 alloc_array 把 size 归零并返回 nullptr，
    // 于是「size>0 但 data==nullptr」这个状态压根构造不出来（Dart 侧对它另有一条
    // 判空分支，但让它永不发生更省事）。媒体文件可以很大，这里的失败很现实。
    r.size = static_cast<int32_t>(data.size());
    r.data = alloc_array<uint8_t>(r.size);
    if (r.data) {
      memcpy(r.data, data.data(), static_cast<size_t>(r.size));
    }
    return r;
  });
}

FUSHI_EXPORT
void fushidicts_free_media(FfiMediaFile* r) {
  ffi_guard_void("fushidicts_free_media", [&]() {
    if (!r) return;
    free(r->data);
  });
}

// ── popup JSON (single source of truth for both FFI and JNI) ───────

FUSHI_EXPORT
char* fushidicts_lookup_popup_json(void* handle, const char* text,
                                   int32_t max_results, int32_t scan_length,
                                   int32_t max_terms) {
  return ffi_guard("fushidicts_lookup_popup_json", [&]() -> char* {
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::shared_lock lock(h->rw);
    Lookup lookup(h->query, h->deinflector);
    auto results = lookup.lookup(text, max_results,
                                 static_cast<size_t>(scan_length));
    std::string json = build_popup_json(results, max_terms);
    return dup(json);
  });
}

FUSHI_EXPORT
void fushidicts_free_string(char* s) {
  ffi_guard_void("fushidicts_free_string", [&]() { free(s); });
}

// ── 分词 ──────────────────────────────────────────────────────────────
//
// 一次调用切完整段文本（Dart `JapaneseLanguage.textToWords` 以前是逐位置各调一次
// fushidicts_lookup 并把整条结果连释义一起搬过 FFI）。lengths[i] = 第 i 段的
// UTF-16 码元数；readings 仅 with_readings 时非空（与 lengths 等长）。语义见
// tokenize.hpp。
//
// [text] 不是 C 串：长度由 [text_bytes]（UTF-8 字节数，不含任何结尾 NUL）给出，
// 原生按这段带长视图处理整段。HBK-AUDIT-007：以前只收 `const char*` 再隐式构造
// std::string，Dart 字符串里合法的 U+0000（OCR / 网页文本 / 字幕都可能带）会让原生
// 只切到第一个 NUL 为止，Dart 侧发现各段总长 ≠ 原文后把**整段**降级成逐码元、读音
// 全空——连 NUL 之前本来能切对的词一起丢了。text_bytes < 0 视为非法输入，回空结果。

struct FfiTokenizeResult {
  int32_t* lengths;
  char** readings;
  int32_t count;
};

FUSHI_EXPORT
FfiTokenizeResult fushidicts_tokenize(void* handle, const char* text, int32_t text_bytes, int32_t scan_length,
                                      int32_t with_readings) {
  return ffi_guard("fushidicts_tokenize", [&]() -> FfiTokenizeResult {
    FfiTokenizeResult r{};
    if (!text || text_bytes < 0) return r;
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::shared_lock lock(h->rw);
    Lookup lookup(h->query, h->deinflector);
    // 显式长度构造：内嵌 NUL 是正文的一部分，不是终止符。
    const std::string text_utf8(text, static_cast<size_t>(text_bytes));
    TokenizeOutput out =
        tokenize(lookup, text_utf8, static_cast<size_t>(scan_length), with_readings != 0, &h->match_cache);
    r.count = static_cast<int32_t>(out.lengths.size());
    int32_t length_count = r.count;
    r.lengths = alloc_array<int32_t>(length_count);
    if (length_count != r.count) {
      r.count = 0;
      return r;
    }
    for (int32_t i = 0; i < r.count; i++) r.lengths[i] = out.lengths[i];
    if (with_readings != 0) {
      int32_t reading_count = r.count;
      r.readings = alloc_array<char*>(reading_count);
      if (reading_count != r.count) {
        free(r.lengths);
        r.lengths = nullptr;
        r.count = 0;
        return r;
      }
      for (int32_t i = 0; i < r.count; i++) r.readings[i] = dup(out.readings[i]);
    }
    return r;
  });
}

FUSHI_EXPORT
void fushidicts_free_tokenize_result(FfiTokenizeResult* r) {
  ffi_guard_void("fushidicts_free_tokenize_result", [&]() {
    if (!r) return;
    if (r->readings) {
      for (int32_t i = 0; i < r->count; i++) free(r->readings[i]);
    }
    free(r->readings);
    free(r->lengths);
    r->readings = nullptr;
    r->lengths = nullptr;
    r->count = 0;
  });
}

// 文本开头的最长匹配长度（UTF-16 码元；0 = 未命中）。wordFromIndex /
// getWordRange / 高亮预估这些单点调用用，与分词共用同一个缓存。
FUSHI_EXPORT
int32_t fushidicts_match_length(void* handle, const char* text, int32_t scan_length) {
  return ffi_guard("fushidicts_match_length", [&]() -> int32_t {
    if (!text) return 0;
    auto* h = static_cast<FushidictsHandle*>(handle);
    std::shared_lock lock(h->rw);
    Lookup lookup(h->query, h->deinflector);
    return match_length_utf16(lookup, text, static_cast<size_t>(scan_length), &h->match_cache);
  });
}

// ── 语料词元（native/fushi_corpus 的倒排键，见 tokenize.hpp 的 tokenize_corpus） ──
//
// 一次调用处理**一批**句子（一本书的一章 / 一集字幕 / 一首歌词），不逐句跨 FFI。线格式
// （全部小端，与 packages/fushi_dictionary 的 `FushiDicts.corpusTermsBorrowed` 和
// native/fushi_corpus/src/wire.rs 的 `TermsReader` 同一份约定）：
//
//   输入：u32 句数 N，然后 N 个 { u32 UTF-8 字节数, 字节 }
//   输出：N 个 { u32 词元数 M, M 个 { u32 起点(UTF-16), u32 长度(UTF-16), u32 词典形字节数, 字节 } }
//
// 输出缓冲区由 malloc 分配，调用方用 fushidicts_free_bytes 释放。返回 0 成功；-1 参数
// 非法 / 输入截断；-2 内存不足；异常经闸门回 -3。
static void put_u32(std::string& out, uint32_t v) {
  for (int k = 0; k < 4; k++) out.push_back(static_cast<char>((v >> (8 * k)) & 0xFF));
}

static bool read_u32(const uint8_t* data, size_t len, size_t& at, uint32_t& v) {
  if (at > len || len - at < 4) return false;
  v = static_cast<uint32_t>(data[at]) | (static_cast<uint32_t>(data[at + 1]) << 8) |
      (static_cast<uint32_t>(data[at + 2]) << 16) | (static_cast<uint32_t>(data[at + 3]) << 24);
  at += 4;
  return true;
}

FUSHI_EXPORT
int32_t fushidicts_corpus_terms(void* handle, const uint8_t* input, int32_t input_len, int32_t scan_length,
                                uint8_t** out, int32_t* out_len) {
  return ffi_guard_or(
      "fushidicts_corpus_terms",
      [&]() -> int32_t {
        if (!handle || !out || !out_len || input_len < 0 || (!input && input_len > 0)) return -1;
        *out = nullptr;
        *out_len = 0;
        const size_t len = static_cast<size_t>(input_len);
        size_t at = 0;
        uint32_t count = 0;
        if (!read_u32(input, len, at, count)) return -1;
        auto* h = static_cast<FushidictsHandle*>(handle);
        std::shared_lock lock(h->rw);
        Lookup lookup(h->query, h->deinflector);
        CorpusLemmaMemo memo;
        std::string buffer;
        for (uint32_t s = 0; s < count; s++) {
          uint32_t bytes = 0;
          if (!read_u32(input, len, at, bytes) || len - at < bytes) return -1;
          const std::string text(reinterpret_cast<const char*>(input + at), bytes);
          at += bytes;
          if (!utf8::is_valid(text.begin(), text.end())) {
            put_u32(buffer, 0);
            continue;
          }
          const std::vector<CorpusToken> tokens =
              tokenize_corpus(lookup, text, static_cast<size_t>(scan_length), &memo);
          put_u32(buffer, static_cast<uint32_t>(tokens.size()));
          for (const CorpusToken& t : tokens) {
            put_u32(buffer, static_cast<uint32_t>(t.start));
            put_u32(buffer, static_cast<uint32_t>(t.length));
            put_u32(buffer, static_cast<uint32_t>(t.lemma.size()));
            buffer += t.lemma;
          }
        }
        if (buffer.size() > static_cast<size_t>(INT32_MAX)) return -1;
        auto* bytes_out = static_cast<uint8_t*>(malloc(buffer.empty() ? 1 : buffer.size()));
        if (!bytes_out) return -2;
        if (!buffer.empty()) std::memcpy(bytes_out, buffer.data(), buffer.size());
        *out = bytes_out;
        *out_len = static_cast<int32_t>(buffer.size());
        return 0;
      },
      []() -> int32_t { return -3; });
}

FUSHI_EXPORT
void fushidicts_free_bytes(uint8_t* p) {
  ffi_guard_void("fushidicts_free_bytes", [&]() { free(p); });
}

// ── zstd 文件解压 ────────────────────────────────────────────────────
//
// Anki 2.1.50+ 的备份（.colpkg / .apkg）里 collection 是 zstd 压缩的
// `collection.anki21b`。Dart 侧的 archive 包没有 zstd，本库本来就静态链着
// libzstd（词典 v2 格式在用），所以在这里出一个流式的「文件 → 文件」解压，
// 不为这一处再引一个原生依赖。流式是必须的：collection 解压后几十到上百 MB，
// 不能整份读进内存。
//
// 返回 0 成功；1 输入打不开；2 输出打不开；3 zstd 解码错误；4 输入截断
// （帧没结束就到了 EOF）；5 写入失败。
FUSHI_EXPORT
int32_t fushidicts_zstd_decompress_file(const char* in_path,
                                        const char* out_path) {
  return ffi_guard_or(
      "fushidicts_zstd_decompress_file",
      [&]() -> int32_t {
        if (!in_path || !out_path) return 1;
        std::ifstream in(std::filesystem::u8path(in_path), std::ios::binary);
        if (!in) return 1;
        std::ofstream out(std::filesystem::u8path(out_path),
                          std::ios::binary | std::ios::trunc);
        if (!out) return 2;

        ZSTD_DCtx* dctx = ZSTD_createDCtx();
        if (!dctx) return 3;
        std::vector<char> in_buf(ZSTD_DStreamInSize());
        std::vector<char> out_buf(ZSTD_DStreamOutSize());
        size_t last_ret = 0;
        int32_t status = 0;
        while (status == 0) {
          in.read(in_buf.data(), static_cast<std::streamsize>(in_buf.size()));
          const size_t read = static_cast<size_t>(in.gcount());
          if (read == 0) break;
          ZSTD_inBuffer input{in_buf.data(), read, 0};
          while (input.pos < input.size) {
            ZSTD_outBuffer output{out_buf.data(), out_buf.size(), 0};
            last_ret = ZSTD_decompressStream(dctx, &output, &input);
            if (ZSTD_isError(last_ret)) {
              FUSHI_LOGE("zstd decompress failed: %s",
                         ZSTD_getErrorName(last_ret));
              status = 3;
              break;
            }
            out.write(out_buf.data(),
                      static_cast<std::streamsize>(output.pos));
            if (!out) {
              status = 5;
              break;
            }
          }
        }
        ZSTD_freeDCtx(dctx);
        if (status != 0) return status;
        // last_ret != 0：最后一帧还没解完就没输入了。
        if (last_ret != 0) return 4;
        out.flush();
        return out ? 0 : 5;
      },
      []() -> int32_t { return 3; });
}

} // extern "C"
