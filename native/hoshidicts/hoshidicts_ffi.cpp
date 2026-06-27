#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include "hoshidicts/platform.hpp"
#include "hoshidicts/deinflector.hpp"
#include "hoshidicts/importer.hpp"
#include "hoshidicts/lookup.hpp"
#include "hoshidicts/query.hpp"
#include "hoshidicts/popup_json.hpp"

// ── helpers ──────────────────────────────────────────────────────────
static char* dup(const std::string& s) {
  char* p = static_cast<char*>(malloc(s.size() + 1));
  if (p) memcpy(p, s.c_str(), s.size() + 1);
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
  r.glossaries = static_cast<FfiGlossary*>(malloc(sizeof(FfiGlossary) * r.glossary_count));
  for (int i = 0; i < r.glossary_count; i++) {
    r.glossaries[i].dict_name = dup(t.glossaries[i].dict_name);
    r.glossaries[i].glossary = dup(t.glossaries[i].glossary);
    r.glossaries[i].definition_tags = dup(t.glossaries[i].definition_tags);
    r.glossaries[i].term_tags = dup(t.glossaries[i].term_tags);
  }

  r.frequency_count = static_cast<int32_t>(t.frequencies.size());
  r.frequencies = static_cast<FfiFrequency*>(malloc(sizeof(FfiFrequency) * r.frequency_count));
  for (int i = 0; i < r.frequency_count; i++) {
    auto& f = t.frequencies[i];
    r.frequencies[i].dict_name = dup(f.dict_name);
    r.frequencies[i].count = static_cast<int32_t>(f.frequencies.size());
    r.frequencies[i].values = static_cast<int32_t*>(malloc(sizeof(int32_t) * f.frequencies.size()));
    r.frequencies[i].display_values = static_cast<char**>(malloc(sizeof(char*) * f.frequencies.size()));
    for (size_t j = 0; j < f.frequencies.size(); j++) {
      r.frequencies[i].values[j] = f.frequencies[j].value;
      r.frequencies[i].display_values[j] = dup(f.frequencies[j].display_value);
    }
  }

  r.pitch_count = static_cast<int32_t>(t.pitches.size());
  r.pitches = static_cast<FfiPitch*>(malloc(sizeof(FfiPitch) * r.pitch_count));
  for (int i = 0; i < r.pitch_count; i++) {
    r.pitches[i].dict_name = dup(t.pitches[i].dict_name);
    r.pitches[i].count = static_cast<int32_t>(t.pitches[i].pitch_positions.size());
    r.pitches[i].positions = static_cast<int32_t*>(malloc(sizeof(int32_t) * r.pitches[i].count));
    for (int j = 0; j < r.pitches[i].count; j++) {
      r.pitches[i].positions[j] = t.pitches[i].pitch_positions[j];
    }
    // transcriptions: char** array of IPA strings, mirroring frequency
    // display_values (malloc the pointer array, then dup each element).
    r.pitches[i].transcription_count = static_cast<int32_t>(t.pitches[i].transcriptions.size());
    r.pitches[i].transcriptions =
        static_cast<char**>(malloc(sizeof(char*) * r.pitches[i].transcription_count));
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

HOSHI_EXPORT
FfiImportResult hoshidicts_import(const char* zip_path, const char* output_dir, const char* breadcrumb_dir) {
  ImportThreadArgs args;
  args.zip_path = zip_path;
  args.output_dir = output_dir;
  // breadcrumb_dir may be null (older callers / disabled); treat as "no breadcrumb".
  args.breadcrumb_dir = breadcrumb_dir ? breadcrumb_dir : "";
  args.result = {};

  HoshiThread thread;
  bool ok = hoshi_thread_create(thread, import_thread_fn, &args, 32 * 1024 * 1024);

  if (!ok) {
    args.result.success = 0;
    args.result.title = dup("");
    args.result.error = dup("Failed to create import thread");
    return args.result;
  }

  hoshi_thread_join(thread);
  return args.result;
}

HOSHI_EXPORT
void hoshidicts_free_import_result(FfiImportResult* r) {
  if (!r) return;
  free(r->title);
  free(r->detected_type);
  free(r->error);
}

HOSHI_EXPORT
int32_t hoshidicts_probe_dict_content(const char* dir) {
  if (!dir) return 0;
  return static_cast<int32_t>(probe_dict_content(std::string(dir)));
}

// ── query handle ────────────────────────────────────────────────────

struct HoshidictsHandle {
  DictionaryQuery query;
  Deinflector deinflector;
};

HOSHI_EXPORT
void* hoshidicts_create() {
  return new HoshidictsHandle();
}

HOSHI_EXPORT
void hoshidicts_destroy(void* handle) {
  delete static_cast<HoshidictsHandle*>(handle);
}

HOSHI_EXPORT
void hoshidicts_add_term_dict(void* handle, const char* path) {
  static_cast<HoshidictsHandle*>(handle)->query.add_term_dict(path);
}

HOSHI_EXPORT
void hoshidicts_add_freq_dict(void* handle, const char* path) {
  static_cast<HoshidictsHandle*>(handle)->query.add_freq_dict(path);
}

HOSHI_EXPORT
void hoshidicts_add_pitch_dict(void* handle, const char* path) {
  static_cast<HoshidictsHandle*>(handle)->query.add_pitch_dict(path);
}

HOSHI_EXPORT
void hoshidicts_add_kanji_dict(void* handle, const char* path) {
  static_cast<HoshidictsHandle*>(handle)->query.add_kanji_dict(path);
}

HOSHI_EXPORT
void hoshidicts_load_transforms(void* handle, const char* json) {
  static_cast<HoshidictsHandle*>(handle)->deinflector.load_transforms_json(json);
}

// ── query ───────────────────────────────────────────────────────────

HOSHI_EXPORT
FfiQueryResult hoshidicts_query(void* handle, const char* expression) {
  FfiQueryResult r{};
  auto& q = static_cast<HoshidictsHandle*>(handle)->query;
  auto terms = q.query(expression);
  r.count = static_cast<int32_t>(terms.size());
  r.terms = static_cast<FfiTermResult*>(malloc(sizeof(FfiTermResult) * r.count));
  for (int i = 0; i < r.count; i++) {
    r.terms[i] = convert_term(terms[i]);
  }
  return r;
}

HOSHI_EXPORT
void hoshidicts_free_query_result(FfiQueryResult* r) {
  if (!r) return;
  for (int i = 0; i < r->count; i++) {
    free_term(r->terms[i]);
  }
  free(r->terms);
}

// ── kanji query ─────────────────────────────────────────────────────

HOSHI_EXPORT
FfiKanjiResults hoshidicts_query_kanji(void* handle, const char* character) {
  FfiKanjiResults r{};
  auto& q = static_cast<HoshidictsHandle*>(handle)->query;
  auto kanji = q.query_kanji(character);
  r.count = static_cast<int32_t>(kanji.size());
  r.results = static_cast<FfiKanjiResult*>(malloc(sizeof(FfiKanjiResult) * r.count));
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
    dst.meanings = static_cast<char**>(malloc(sizeof(char*) * dst.meaning_count));
    for (int j = 0; j < dst.meaning_count; j++) {
      dst.meanings[j] = dup(k.meanings[j]);
    }
  }
  return r;
}

HOSHI_EXPORT
void hoshidicts_free_kanji_results(FfiKanjiResults* r) {
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
  }
  free(r->results);
}

// ── lookup ──────────────────────────────────────────────────────────

HOSHI_EXPORT
FfiLookupResults hoshidicts_lookup(void* handle, const char* text, int32_t max_results, int32_t scan_length) {
  FfiLookupResults r{};
  auto* h = static_cast<HoshidictsHandle*>(handle);
  Lookup lookup(h->query, h->deinflector);
  auto results = lookup.lookup(text, max_results, static_cast<size_t>(scan_length));
  r.count = static_cast<int32_t>(results.size());
  r.results = static_cast<FfiLookupResult*>(malloc(sizeof(FfiLookupResult) * r.count));
  for (int i = 0; i < r.count; i++) {
    auto& src = results[i];
    auto& dst = r.results[i];
    dst.matched = dup(src.matched);
    dst.deinflected = dup(src.deinflected);
    dst.preprocessor_steps = src.preprocessor_steps;
    dst.trace_count = static_cast<int32_t>(src.trace.size());
    dst.trace = static_cast<FfiTransformGroup*>(malloc(sizeof(FfiTransformGroup) * dst.trace_count));
    for (int j = 0; j < dst.trace_count; j++) {
      dst.trace[j].name = dup(src.trace[j].name);
      dst.trace[j].description = dup(src.trace[j].description);
    }
    dst.term = convert_term(src.term);
  }
  return r;
}

HOSHI_EXPORT
void hoshidicts_free_lookup_results(FfiLookupResults* r) {
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
}

// ── styles ──────────────────────────────────────────────────────────

HOSHI_EXPORT
FfiDictStyles hoshidicts_get_styles(void* handle) {
  FfiDictStyles r{};
  auto& q = static_cast<HoshidictsHandle*>(handle)->query;
  auto styles = q.get_styles();
  r.count = static_cast<int32_t>(styles.size());
  r.items = static_cast<FfiDictStyle*>(malloc(sizeof(FfiDictStyle) * r.count));
  for (int i = 0; i < r.count; i++) {
    r.items[i].dict_name = dup(styles[i].dict_name);
    r.items[i].styles = dup(styles[i].styles);
  }
  return r;
}

HOSHI_EXPORT
void hoshidicts_free_styles(FfiDictStyles* r) {
  if (!r) return;
  for (int i = 0; i < r->count; i++) {
    free(r->items[i].dict_name);
    free(r->items[i].styles);
  }
  free(r->items);
}

// ── media ───────────────────────────────────────────────────────────

struct FfiMediaFile {
  uint8_t* data;
  int32_t size;
};

HOSHI_EXPORT
FfiMediaFile hoshidicts_get_media(void* handle, const char* dict_name, const char* media_path) {
  FfiMediaFile r{};
  auto& q = static_cast<HoshidictsHandle*>(handle)->query;
  auto data = q.get_media_file(dict_name, media_path);
  r.size = static_cast<int32_t>(data.size());
  r.data = static_cast<uint8_t*>(malloc(r.size));
  if (r.data && r.size > 0) memcpy(r.data, data.data(), r.size);
  return r;
}

HOSHI_EXPORT
void hoshidicts_free_media(FfiMediaFile* r) {
  if (!r) return;
  free(r->data);
}

// ── popup JSON (single source of truth for both FFI and JNI) ───────

HOSHI_EXPORT
char* hoshidicts_lookup_popup_json(void* handle, const char* text,
                                   int32_t max_results, int32_t scan_length,
                                   int32_t max_terms) {
  auto* h = static_cast<HoshidictsHandle*>(handle);
  Lookup lookup(h->query, h->deinflector);
  auto results = lookup.lookup(text, max_results,
                               static_cast<size_t>(scan_length));
  std::string json = build_popup_json(results, max_terms);
  return dup(json);
}

HOSHI_EXPORT
void hoshidicts_free_string(char* s) {
  free(s);
}

} // extern "C"
