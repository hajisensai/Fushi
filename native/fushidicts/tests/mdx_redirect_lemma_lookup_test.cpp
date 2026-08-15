// BUG-1665 guard: an MDX @@@LINK= redirect entry must not out-rank its lemma.
//
// mdx_reader resolves @@@LINK=target by COPYING the target's definition bytes
// under the redirect key, so an imported OALD-style dictionary carries
// "belongs" as a full entry whose definition is byte-identical to "belong"'s.
// Lookup("belongs") then surfaced BOTH the alias exact hit (0 transforms) and
// the deinflected lemma hit (1 transform); the comparator ranks fewer
// transforms first, so the popup header — and the mined Anki term — became the
// inflected surface form instead of the lemma (Yomitan mines the lemma).
//
// The fix lives in Lookup::lookup(): the importer dedupes identical
// definitions by hash into ONE compressed blob, so within a dict the alias
// glossary and its lemma glossary share the same blob pointer. For each
// surface form, every glossary on the untransformed exact hit whose blob also
// backs a lemma hit of the same surface is dropped (per-glossary, so a second
// dictionary's REAL inflected entry on the same result survives), and a result
// stripped of every glossary is removed entirely. Already-imported
// dictionaries are healed with no re-import.
//
// Cases pinned here:
//   1) redirect alias collapses into the lemma (only "belong" survives);
//   2) a genuinely distinct inflected entry (different definition bytes) is
//      kept and still ranks first;
//   3) a spelling-variant redirect with no deinflection rule (colour->color)
//      is untouched;
//   4) per-glossary granularity: dictA redirects "belongs" while dictB defines
//      "belongs" for real -> the "belongs" result keeps ONLY dictB's glossary.
//
// Usage: mdx_redirect_lemma_lookup_test  (no args) -> exit 0 PASS.
#include <cstdio>
#include <string>
#include <vector>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/query.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

// Minimal English-like descriptor: verb condition + third-person "s" ->
// "" suffix transform (the same shape as assets/transforms/en.json).
const std::string kEnTransforms =
    "{\"language\":\"en\",\"conditions\":{"
    "\"v\":{\"name\":\"Verb\",\"isDictionaryForm\":true,\"subConditions\":[]}"
    "},\"transforms\":{\"3ps\":{\"name\":\"3ps\",\"description\":\"\",\"rules\":["
    "{\"type\":\"suffix\",\"fromSuffix\":\"s\",\"toSuffix\":\"\","
    "\"conditionsIn\":[\"v\"],\"conditionsOut\":[\"v\"]}]}}}";

std::string dump_results(const std::vector<LookupResult>& results) {
  std::string s;
  for (const LookupResult& r : results) {
    s += "[" + r.term.expression + " glossaries=" + std::to_string(r.term.glossaries.size()) + "] ";
  }
  return s;
}

// Writes a simple dict (the storage MDX/StarDict/DSL imports share) and
// returns its on-disk path, or "" on failure.
std::string write_dict(const char* title, const std::vector<SimpleEntry>& entries) {
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_redirect_lemma_out";
  ImportResult r = dictionary_importer::write_simple_dict(title, entries, out_dir);
  if (!r.success) {
    std::fprintf(stderr, "FAIL write_simple_dict(%s): %s\n", title,
                 r.errors.empty() ? "(no error)" : r.errors.front().c_str());
    ++g_fail;
    return "";
  }
  return out_dir + "/" + r.title;
}

// 1) The redirect alias collapses into the lemma: only "belong" survives, and
//    it records the inflected surface as `matched`.
void case_alias_collapses_into_lemma() {
  const std::string dict = write_dict(
      "RedirectDict", {{"belong", "to be in the right place"},
                       {"belongs", "to be in the right place"}});  // resolved @@@LINK copy
  if (dict.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(dict);
  Deinflector d;
  d.load_transforms_json(kEnTransforms);
  Lookup lk(q, d);

  std::vector<LookupResult> results = lk.lookup("belongs", 16);
  bool has_lemma = false;
  bool has_alias = false;
  for (const LookupResult& r : results) {
    if (r.term.expression == "belong") {
      has_lemma = true;
      if (r.matched != "belongs") fail("alias-collapse: lemma result must keep matched=belongs");
      if (r.deinflected != "belong") fail("alias-collapse: lemma result must record deinflected=belong");
    }
    if (r.term.expression == "belongs") has_alias = true;
  }
  if (!has_lemma) fail("alias-collapse: lemma entry 'belong' missing from results");
  if (has_alias) fail("alias-collapse: redirect alias 'belongs' must be dropped");
  if (!results.empty() && results.front().term.expression != "belong") {
    std::fprintf(stderr, "FAIL alias-collapse: first result must be the lemma; got %s\n",
                 dump_results(results).c_str());
    ++g_fail;
  }
}

// 2) A genuinely distinct inflected entry (different definition bytes -> its
//    own blob) is NOT a redirect and must survive, still ranked first.
void case_distinct_inflected_entry_kept() {
  const std::string dict = write_dict(
      "DistinctDict", {{"lead", "to guide"}, {"leads", "plural of lead (metal strips)"}});
  if (dict.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(dict);
  Deinflector d;
  d.load_transforms_json(kEnTransforms);
  Lookup lk(q, d);

  std::vector<LookupResult> results = lk.lookup("leads", 16);
  bool has_exact = false;
  bool has_lemma = false;
  for (const LookupResult& r : results) {
    if (r.term.expression == "leads") has_exact = true;
    if (r.term.expression == "lead") has_lemma = true;
  }
  if (!has_exact) fail("distinct: real inflected entry 'leads' must be kept");
  if (!has_lemma) fail("distinct: lemma 'lead' must still be found via deinflection");
  if (!results.empty() && results.front().term.expression != "leads") {
    std::fprintf(stderr, "FAIL distinct: exact entry must still rank first; got %s\n",
                 dump_results(results).c_str());
    ++g_fail;
  }
}

// 3) Spelling-variant redirect (colour -> color): no deinflection rule reaches
//    "color", so there is no lemma hit and the alias MUST keep working.
void case_spelling_variant_untouched() {
  const std::string dict =
      write_dict("VariantDict", {{"color", "a hue"}, {"colour", "a hue"}});  // resolved @@@LINK copy
  if (dict.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(dict);
  Deinflector d;
  d.load_transforms_json(kEnTransforms);
  Lookup lk(q, d);

  std::vector<LookupResult> results = lk.lookup("colour", 16);
  bool has_variant = false;
  for (const LookupResult& r : results) {
    if (r.term.expression == "colour") has_variant = true;
  }
  if (!has_variant) fail("variant: 'colour' redirect entry must still be found");
}

// 4) Per-glossary granularity across dictionaries: dictA redirects "belongs"
//    to belong's bytes, dictB defines "belongs" in its own right. The merged
//    "belongs" result must lose ONLY dictA's copied glossary.
void case_cross_dict_keeps_real_glossary() {
  const std::string dict_a = write_dict(
      "CrossRedirectDict", {{"belong", "to be in the right place"},
                            {"belongs", "to be in the right place"}});
  const std::string dict_b =
      write_dict("CrossRealDict", {{"belongs", "third-person entry of its own"}});
  if (dict_a.empty() || dict_b.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(dict_a);
  q.add_term_dict(dict_b);
  Deinflector d;
  d.load_transforms_json(kEnTransforms);
  Lookup lk(q, d);

  std::vector<LookupResult> results = lk.lookup("belongs", 16);
  const LookupResult* exact = nullptr;
  const LookupResult* lemma = nullptr;
  for (const LookupResult& r : results) {
    if (r.term.expression == "belongs") exact = &r;
    if (r.term.expression == "belong") lemma = &r;
  }
  if (lemma == nullptr) fail("cross-dict: lemma 'belong' missing");
  if (exact == nullptr) {
    fail("cross-dict: 'belongs' with a real dictB glossary must survive");
  } else {
    if (exact->term.glossaries.size() != 1) {
      std::fprintf(stderr, "FAIL cross-dict: 'belongs' must keep exactly dictB's glossary, got %zu\n",
                   exact->term.glossaries.size());
      ++g_fail;
    } else if (exact->term.glossaries.front().dict_name != "CrossRealDict") {
      std::fprintf(stderr, "FAIL cross-dict: surviving glossary must be CrossRealDict's, got %s\n",
                   exact->term.glossaries.front().dict_name.c_str());
      ++g_fail;
    }
  }
}

}  // namespace

int main() {
  case_alias_collapses_into_lemma();
  case_distinct_inflected_entry_kept();
  case_spelling_variant_untouched();
  case_cross_dict_keeps_real_glossary();

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
