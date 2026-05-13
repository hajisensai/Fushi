#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <pthread.h>
#include "hoshidicts/deinflector.hpp"
#include "hoshidicts/importer.hpp"
#include "hoshidicts/lookup.hpp"
#include "hoshidicts/query.hpp"

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
  int32_t tag_count;
  int32_t media_count;
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
  }
  free(r.pitches);
}

// ── import ──────────────────────────────────────────────────────────

struct ImportThreadArgs {
  std::string zip_path;
  std::string output_dir;
  FfiImportResult result;
};

static void* import_thread_fn(void* arg) {
  auto* a = static_cast<ImportThreadArgs*>(arg);
  try {
    auto result = dictionary_importer::import(a->zip_path, a->output_dir);
    a->result.success = result.success ? 1 : 0;
    a->result.title = dup(result.title);
    a->result.term_count = static_cast<int32_t>(result.term_count);
    a->result.meta_count = static_cast<int32_t>(result.meta_count);
    a->result.tag_count = static_cast<int32_t>(result.tag_count);
    a->result.media_count = static_cast<int32_t>(result.media_count);
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
  return nullptr;
}

__attribute__((visibility("default")))
FfiImportResult hoshidicts_import(const char* zip_path, const char* output_dir) {
  ImportThreadArgs args;
  args.zip_path = zip_path;
  args.output_dir = output_dir;
  args.result = {};

  pthread_t thread;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, 32 * 1024 * 1024);

  int rc = pthread_create(&thread, &attr, import_thread_fn, &args);
  pthread_attr_destroy(&attr);

  if (rc != 0) {
    args.result.success = 0;
    args.result.title = dup("");
    args.result.error = dup("Failed to create import thread");
    return args.result;
  }

  pthread_join(thread, nullptr);
  return args.result;
}

__attribute__((visibility("default")))
void hoshidicts_free_import_result(FfiImportResult* r) {
  if (!r) return;
  free(r->title);
  free(r->detected_type);
  free(r->error);
}

// ── query handle ────────────────────────────────────────────────────

struct HoshidictsHandle {
  DictionaryQuery query;
  Deinflector deinflector;
};

__attribute__((visibility("default")))
void* hoshidicts_create() {
  return new HoshidictsHandle();
}

__attribute__((visibility("default")))
void hoshidicts_destroy(void* handle) {
  delete static_cast<HoshidictsHandle*>(handle);
}

__attribute__((visibility("default")))
void hoshidicts_add_term_dict(void* handle, const char* path) {
  static_cast<HoshidictsHandle*>(handle)->query.add_term_dict(path);
}

__attribute__((visibility("default")))
void hoshidicts_add_freq_dict(void* handle, const char* path) {
  static_cast<HoshidictsHandle*>(handle)->query.add_freq_dict(path);
}

__attribute__((visibility("default")))
void hoshidicts_add_pitch_dict(void* handle, const char* path) {
  static_cast<HoshidictsHandle*>(handle)->query.add_pitch_dict(path);
}

__attribute__((visibility("default")))
void hoshidicts_load_transforms(void* handle, const char* json) {
  static_cast<HoshidictsHandle*>(handle)->deinflector.load_transforms_json(json);
}

// ── query ───────────────────────────────────────────────────────────

__attribute__((visibility("default")))
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

__attribute__((visibility("default")))
void hoshidicts_free_query_result(FfiQueryResult* r) {
  if (!r) return;
  for (int i = 0; i < r->count; i++) {
    free_term(r->terms[i]);
  }
  free(r->terms);
}

// ── lookup ──────────────────────────────────────────────────────────

__attribute__((visibility("default")))
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

__attribute__((visibility("default")))
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

__attribute__((visibility("default")))
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

__attribute__((visibility("default")))
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

__attribute__((visibility("default")))
FfiMediaFile hoshidicts_get_media(void* handle, const char* dict_name, const char* media_path) {
  FfiMediaFile r{};
  auto& q = static_cast<HoshidictsHandle*>(handle)->query;
  auto data = q.get_media_file(dict_name, media_path);
  r.size = static_cast<int32_t>(data.size());
  r.data = static_cast<uint8_t*>(malloc(r.size));
  if (r.data && r.size > 0) memcpy(r.data, data.data(), r.size);
  return r;
}

__attribute__((visibility("default")))
void hoshidicts_free_media(FfiMediaFile* r) {
  if (!r) return;
  free(r->data);
}

} // extern "C"
