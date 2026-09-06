#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
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
    auto result = dictionary_importer::import(a->zip_path, a->output_dir, false, a->breadcrumb_dir);
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

// ── query handle ────────────────────────────────────────────────────

struct FushidictsHandle {
  DictionaryQuery query;
  Deinflector deinflector;
};

FUSHI_EXPORT
void* fushidicts_create() {
  return ffi_guard("fushidicts_create",
                   [&]() -> void* { return new FushidictsHandle(); });
}

FUSHI_EXPORT
void fushidicts_destroy(void* handle) {
  ffi_guard_void("fushidicts_destroy",
                 [&]() { delete static_cast<FushidictsHandle*>(handle); });
}

// 四个 add_*_dict 是本轮崩溃的第一现场：一次性导入很多词典后，启动要连着走这里
// N 遍，每遍都在读 index.json / styles.css、建映射、可能建 zstd 词典——任何一次
// bad_alloc 过去都会直接崩掉整个进程。现在单本失败只是这本不进引擎（native 侧
// 已按 return 处理），其余词典照常可用。
FUSHI_EXPORT
void fushidicts_add_term_dict(void* handle, const char* path) {
  ffi_guard_void("fushidicts_add_term_dict", [&]() {
    static_cast<FushidictsHandle*>(handle)->query.add_term_dict(path);
  });
}

FUSHI_EXPORT
void fushidicts_add_freq_dict(void* handle, const char* path) {
  ffi_guard_void("fushidicts_add_freq_dict", [&]() {
    static_cast<FushidictsHandle*>(handle)->query.add_freq_dict(path);
  });
}

FUSHI_EXPORT
void fushidicts_add_pitch_dict(void* handle, const char* path) {
  ffi_guard_void("fushidicts_add_pitch_dict", [&]() {
    static_cast<FushidictsHandle*>(handle)->query.add_pitch_dict(path);
  });
}

FUSHI_EXPORT
void fushidicts_add_kanji_dict(void* handle, const char* path) {
  ffi_guard_void("fushidicts_add_kanji_dict", [&]() {
    static_cast<FushidictsHandle*>(handle)->query.add_kanji_dict(path);
  });
}

FUSHI_EXPORT
void fushidicts_load_transforms(void* handle, const char* json) {
  ffi_guard_void("fushidicts_load_transforms", [&]() {
    static_cast<FushidictsHandle*>(handle)->deinflector.load_transforms_json(json);
  });
}

// ── query ───────────────────────────────────────────────────────────

FUSHI_EXPORT
FfiQueryResult fushidicts_query(void* handle, const char* expression) {
  return ffi_guard("fushidicts_query", [&]() -> FfiQueryResult {
    FfiQueryResult r{};
    auto& q = static_cast<FushidictsHandle*>(handle)->query;
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
    auto& q = static_cast<FushidictsHandle*>(handle)->query;
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
    Lookup lookup(h->query, h->deinflector);
    auto results = lookup.lookup(text, max_results, static_cast<size_t>(scan_length));
    return marshal_lookup_results(results);
  });
}

// 上游 bc62d2b/86c6e2f：带排序选项的 lookup。freq_order：0=Auto 1=Ascending
// 2=Descending 3=Disabled；freq_dict / primary_reading 传 NULL 或空串 = 未设置。
// 老导出 fushidicts_lookup 原样保留（Never break ABI），返回结构同一套，
// 释放同走 fushidicts_free_lookup_results。
FUSHI_EXPORT
FfiLookupResults fushidicts_lookup_with_options(void* handle, const char* text, int32_t max_results,
                                                int32_t scan_length, const char* freq_dict, int32_t freq_order,
                                                const char* primary_reading) {
  return ffi_guard("fushidicts_lookup_with_options", [&]() -> FfiLookupResults {
    auto* h = static_cast<FushidictsHandle*>(handle);
    Lookup lookup(h->query, h->deinflector);
    LookupOptions options;
    if (freq_dict && freq_dict[0] != '\0') {
      options.frequency_dictionary = std::string(freq_dict);
    }
    switch (freq_order) {
      case 1: options.frequency_order = LookupFrequencyOrder::Ascending; break;
      case 2: options.frequency_order = LookupFrequencyOrder::Descending; break;
      case 3: options.frequency_order = LookupFrequencyOrder::Disabled; break;
      default: options.frequency_order = LookupFrequencyOrder::Auto; break;
    }
    if (primary_reading && primary_reading[0] != '\0') {
      options.primary_reading = std::string(primary_reading);
    }
    auto results = lookup.lookup(text, max_results, static_cast<size_t>(scan_length), options);
    return marshal_lookup_results(results);
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
    auto& q = static_cast<FushidictsHandle*>(handle)->query;
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
    auto& q = static_cast<FushidictsHandle*>(handle)->query;
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

} // extern "C"
