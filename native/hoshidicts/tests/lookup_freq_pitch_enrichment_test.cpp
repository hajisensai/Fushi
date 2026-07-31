// BUG-1286 guard: Lookup::lookup() must still surface frequency AND pitch on
// the results it returns, after the enrichment was moved OUT of query_raw().
//
// Why a separate test from freq_pitch_import_query_test: every pre-existing
// freq/pitch test drives `DictionaryQuery::query()` — the single-expression
// entry point. Nothing exercised `Lookup::lookup()`, which is the path the app
// actually calls on every user lookup, and which is exactly the path BUG-1286
// changed. Without this file the whole suite stays green even if lookup() came
// back with frequencies/pitches stripped.
//
// What BUG-1286 changed: query_raw() used to call query_freq()+query_pitch() on
// its intermediate results. lookup() invokes query_raw() once per
// (scan candidate x text variant x deinflection) — hundreds to thousands of
// times per user lookup — so every intermediate term hit every frequency and
// pitch dictionary (each with its own JSON parse) only for the dedup +
// partial_sort + resize that follow to discard nearly all of it. Enrichment now
// happens once on the surviving set: frequency before the sort (the comparator
// ranks by it), pitch after the resize (nothing reads it earlier).
//
// This test pins the observable contract that move must preserve:
//   * lookup() results still carry frequencies with the right values,
//   * lookup() results still carry pitches with the right positions,
//   * a deinflected (conjugated) form still gets enriched — that form only
//     reaches the result set through the inner loop that no longer enriches.
//
// Usage: lookup_freq_pitch_enrichment_test  (no args) -> exit 0 PASS.
#include <cstdio>
#include <string>
#include <vector>

#include "hoshidicts/importer.hpp"
#include "hoshidicts/lookup.hpp"
#include "hoshidicts/query.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

void expect_eq_int(const char* what, int got, int want) {
  if (got != want) {
    std::fprintf(stderr, "FAIL %s: got %d want %d\n", what, got, want);
    ++g_fail;
  }
}

// 猫 / ねこ
const std::string kNeko = "\xE7\x8C\xAB";
const std::string kNekoReading = "\xE3\x81\xAD\xE3\x81\x93";

std::string index_json(const char* title) {
  return std::string("{\"title\":\"") + title + "\",\"format\":3,\"revision\":\"test\"}";
}

std::string term_bank_neko() {
  return "[[\"" + kNeko + "\",\"" + kNekoReading + "\",\"\",\"\",0,[\"cat\"],0,\"\"]]";
}

std::string term_meta_bank_neko() {
  return "[[\"" + kNeko + "\",\"freq\",5000],"
         "[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kNekoReading +
         "\",\"pitches\":[{\"position\":0},{\"position\":2}]}]]";
}

// Find the LookupResult whose term is 猫, regardless of ranking.
const LookupResult* find_neko(const std::vector<LookupResult>& results) {
  for (const LookupResult& r : results) {
    if (r.term.expression == kNeko) {
      return &r;
    }
  }
  return nullptr;
}

void check_enriched(const char* label, const LookupResult* r) {
  if (r == nullptr) {
    std::fprintf(stderr, "FAIL %s: lookup() returned no 猫 term\n", label);
    ++g_fail;
    return;
  }

  if (r->term.frequencies.empty()) {
    std::fprintf(stderr, "FAIL %s: term has no frequencies — enrichment was lost when it moved out of query_raw()\n",
                 label);
    ++g_fail;
  } else if (r->term.frequencies.front().frequencies.empty()) {
    std::fprintf(stderr, "FAIL %s: FrequencyEntry has no values\n", label);
    ++g_fail;
  } else {
    expect_eq_int(label, r->term.frequencies.front().frequencies.front().value, 5000);
  }

  if (r->term.pitches.empty()) {
    std::fprintf(stderr, "FAIL %s: term has no pitches — pitch enrichment must survive the post-resize move\n", label);
    ++g_fail;
  } else {
    const PitchEntry& pe = r->term.pitches.front();
    if (pe.pitch_positions.size() != 2) {
      std::fprintf(stderr, "FAIL %s pitch count: got %zu want 2\n", label, pe.pitch_positions.size());
      ++g_fail;
    } else {
      expect_eq_int(label, pe.pitch_positions[0], 0);
      expect_eq_int(label, pe.pitch_positions[1], 2);
    }
  }

  // Glossary must still be materialized (that step also lives after the resize).
  if (r->term.glossaries.empty() || r->term.glossaries.front().glossary.empty()) {
    std::fprintf(stderr, "FAIL %s: glossary not materialized\n", label);
    ++g_fail;
  }
}

}  // namespace

int main() {
  const std::string out_dir = hoshi_test::temp_dir() + "/hoshi_lookup_enrich_out";
  const char* kTitle = "LookupEnrichDict";

  std::vector<hoshi_test::ZipFile> files = {
      {"index.json", index_json(kTitle)},
      {"term_bank_1.json", term_bank_neko()},
      {"term_meta_bank_1.json", term_meta_bank_neko()},
  };

  std::string zip_path = hoshi_test::write_zip("lookup_enrich", files);
  if (zip_path.empty()) {
    fail("could not write fixture zip");
  } else {
    ImportResult r = dictionary_importer::import(zip_path, out_dir);
    if (!r.success) {
      std::fprintf(stderr, "FAIL import: %s\n", r.errors.empty() ? "(no error)" : r.errors.front().c_str());
      ++g_fail;
    } else {
      const std::string dict_path = out_dir + "/" + r.title;
      DictionaryQuery q;
      q.add_term_dict(dict_path);
      q.add_freq_dict(dict_path);
      q.add_pitch_dict(dict_path);

      Deinflector d;
      Lookup lk(q, d);

      // Plain form: reaches the result set on the first scan candidate.
      check_enriched("lookup(猫)", find_neko(lk.lookup(kNeko)));

      // The same term reached through a longer input string, so the scan /
      // text-variant loops really run more than one query_raw() round — that is
      // the loop the enrichment was pulled out of.
      const std::string sentence = kNeko + "\xE3\x81\x8C";  // 猫が
      check_enriched("lookup(猫が)", find_neko(lk.lookup(sentence)));

      // max_results=1 forces the resize() to actually truncate, proving pitch
      // enrichment still runs on what survives rather than on the wider set.
      std::vector<LookupResult> truncated = lk.lookup(kNeko, 1);
      if (truncated.size() != 1) {
        std::fprintf(stderr, "FAIL truncated size: got %zu want 1\n", truncated.size());
        ++g_fail;
      } else {
        check_enriched("lookup(猫, max=1)", find_neko(truncated));
      }
    }
  }

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
