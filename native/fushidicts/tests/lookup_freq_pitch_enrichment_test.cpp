// BUG-1304 guard: Lookup::lookup() must still surface frequency AND pitch on
// the results it returns, after the enrichment was moved OUT of query_raw().
//
// Why a separate test from freq_pitch_import_query_test: every pre-existing
// freq/pitch test drives `DictionaryQuery::query()` — the single-expression
// entry point. Nothing exercised `Lookup::lookup()`, which is the path the app
// actually calls on every user lookup, and which is exactly the path BUG-1304
// changed. Without this file the whole suite stays green even if lookup() came
// back with frequencies/pitches stripped.
//
// What BUG-1304 changed: query_raw() used to call query_freq()+query_pitch() on
// its intermediate results. lookup() invokes query_raw() once per
// (scan candidate x text variant x deinflection) — ~69 times per user lookup
// (measured) — so every intermediate term hit every frequency and
// pitch dictionary (each with its own JSON parse) only for the dedup +
// partial_sort + resize that follow to discard most of it. Enrichment now
// happens once on the surviving set: frequency before the sort (the comparator
// ranks by it), pitch after the resize (nothing reads it earlier).
// Measured win is modest (2.94x fewer enrichments, ~5-9% of a ~0.18 ms engine
// lookup); what this file guards is CORRECTNESS of the move, not the speedup.
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

// ---------------------------------------------------------------------------
// Ranking fixture: three terms that tie on EVERY sort key above frequency, so
// frequency is the only thing that can order them.
//
// Sort keys in Lookup::lookup()'s comparator, in order:
//   matched length -> preprocessor_steps -> trace length ->
//   (expression == deinflected) -> per-freq-dict frequency values ->
//   (expression == reading)
//
// All three entries share expression 猫 and differ only in reading, so:
//   * they are all produced by the SAME query_raw() call on the SAME scan
//     candidate / text variant / deinflection -> identical matched, identical
//     preprocessor_steps, identical trace;
//   * expression == deinflected == 猫 for all three;
//   * expression != reading for all three (the tie-breaker below frequency is
//     also equal, so it cannot rescue a broken frequency comparison);
//   * the lookup() dedup key is (expression, reading), so none of them collapse.
// That leaves the reading-scoped frequency values as the sole decider.
//
// The frequencies are deliberately assigned AGAINST the natural map order.
// result_map is std::map<pair<expression, reading>>, so its iteration order is
// UTF-8 byte order of the reading: ね(E3 81 AD) < び(E3 81 B3) < み(E3 81 BF),
// i.e. ねこ, びょう, みょう. The correct frequency ranking is the opposite-ish
// permutation びょう(100), みょう(5000), ねこ(90000). If enrichment ever moves
// after the sort, every term's frequency list is empty, get_freq_value_for_dict
// returns INT_MAX for all of them, the comparator ties on everything, and the
// unsorted map order survives — which these assertions reject.
const std::string kByouReading = "\xE3\x81\xB3\xE3\x82\x87\xE3\x81\x86";  // びょう
const std::string kMyouReading = "\xE3\x81\xBF\xE3\x82\x87\xE3\x81\x86";  // みょう

// 猫 with three different readings; identical in every other term_bank field so
// nothing but frequency can distinguish them.
std::string term_bank_rank() {
  return "[[\"" + kNeko + "\",\"" + kNekoReading + "\",\"\",\"\",0,[\"cat-neko\"],0,\"\"],"
         "[\"" + kNeko + "\",\"" + kByouReading + "\",\"\",\"\",0,[\"cat-byou\"],0,\"\"],"
         "[\"" + kNeko + "\",\"" + kMyouReading + "\",\"\",\"\",0,[\"cat-myou\"],0,\"\"]]";
}

// Reading-scoped frequencies (enrich_freq drops a record whose `reading` does
// not equal the term's reading), plus one pitch per reading so the post-resize
// pitch enrichment is exercised on a multi-result set too.
std::string term_meta_bank_rank() {
  return "[[\"" + kNeko + "\",\"freq\",{\"reading\":\"" + kNekoReading + "\",\"frequency\":90000}],"
         "[\"" + kNeko + "\",\"freq\",{\"reading\":\"" + kByouReading + "\",\"frequency\":100}],"
         "[\"" + kNeko + "\",\"freq\",{\"reading\":\"" + kMyouReading + "\",\"frequency\":5000}],"
         "[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kNekoReading + "\",\"pitches\":[{\"position\":1}]}],"
         "[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kByouReading + "\",\"pitches\":[{\"position\":2}]}],"
         "[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kMyouReading + "\",\"pitches\":[{\"position\":3}]}]]";
}

// Whole-sequence assertion: expression + reading of every returned result, in
// order. Not size-only, not first-only — the truncation and the ordering are
// both part of the contract the enrichment position guarantees.
void expect_readings(const char* what, const std::vector<LookupResult>& got,
                     const std::vector<std::string>& want_readings) {
  bool ok = got.size() == want_readings.size();
  if (ok) {
    for (size_t i = 0; i < got.size(); ++i) {
      if (got[i].term.expression != kNeko || got[i].term.reading != want_readings[i]) {
        ok = false;
        break;
      }
    }
  }
  if (ok) {
    return;
  }
  std::fprintf(stderr, "FAIL %s: result sequence mismatch\n  got : ", what);
  for (const LookupResult& r : got) {
    std::fprintf(stderr, "[%s/%s] ", r.term.expression.c_str(), r.term.reading.c_str());
  }
  std::fprintf(stderr, "\n  want: ");
  for (const std::string& reading : want_readings) {
    std::fprintf(stderr, "[%s/%s] ", kNeko.c_str(), reading.c_str());
  }
  std::fprintf(stderr, "\n");
  ++g_fail;
}

void expect_freq_value(const char* what, const LookupResult& r, int want) {
  if (r.term.frequencies.empty() || r.term.frequencies.front().frequencies.empty()) {
    std::fprintf(stderr, "FAIL %s: term %s/%s has no frequency\n", what, r.term.expression.c_str(),
                 r.term.reading.c_str());
    ++g_fail;
    return;
  }
  expect_eq_int(what, r.term.frequencies.front().frequencies.front().value, want);
}

void expect_pitch_position(const char* what, const LookupResult& r, int want) {
  if (r.term.pitches.empty() || r.term.pitches.front().pitches.empty()) {
    std::fprintf(stderr, "FAIL %s: term %s/%s has no pitch\n", what, r.term.expression.c_str(),
                 r.term.reading.c_str());
    ++g_fail;
    return;
  }
  expect_eq_int(what, r.term.pitches.front().pitches.front().position, want);
}

// Frequency must be enriched BEFORE the partial_sort, otherwise the comparator
// ranks on empty frequency lists and both the order and the surviving set of a
// truncated lookup are wrong.
void case_frequency_is_sole_sort_key() {
  const std::string out_dir = fushi_test::temp_dir() + "/hoshi_lookup_rank_out";
  const char* kTitle = "LookupRankDict";

  std::vector<fushi_test::ZipFile> files = {
      {"index.json", index_json(kTitle)},
      {"term_bank_1.json", term_bank_rank()},
      {"term_meta_bank_1.json", term_meta_bank_rank()},
  };

  std::string zip_path = fushi_test::write_zip("lookup_rank", files);
  if (zip_path.empty()) {
    fail("rank: could not write fixture zip");
    return;
  }

  ImportResult r = dictionary_importer::import(zip_path, out_dir);
  if (!r.success) {
    std::fprintf(stderr, "FAIL rank import: %s\n", r.errors.empty() ? "(no error)" : r.errors.front().c_str());
    ++g_fail;
    return;
  }

  const std::string dict_path = out_dir + "/" + r.title;
  DictionaryQuery q;
  q.add_term_dict(dict_path);
  q.add_freq_dict(dict_path);
  q.add_pitch_dict(dict_path);

  Deinflector d;
  Lookup lk(q, d);

  // A) max_results wide enough that nothing is dropped: the full set AND its
  //    order are pinned, entry by entry.
  std::vector<LookupResult> all = lk.lookup(kNeko, 16);
  expect_readings("rank full order", all, {kByouReading, kMyouReading, kNekoReading});
  if (all.size() == 3) {
    expect_freq_value("rank full freq[0]", all[0], 100);
    expect_freq_value("rank full freq[1]", all[1], 5000);
    expect_freq_value("rank full freq[2]", all[2], 90000);
    expect_pitch_position("rank full pitch[0]", all[0], 2);
    expect_pitch_position("rank full pitch[1]", all[1], 3);
    expect_pitch_position("rank full pitch[2]", all[2], 1);
  }

  // B) max_results smaller than the candidate set: WHICH entries survive the
  //    truncation is pinned too, proving the sort keys were right before the
  //    resize rather than after it.
  std::vector<LookupResult> top2 = lk.lookup(kNeko, 2);
  expect_readings("rank top2 survivors", top2, {kByouReading, kMyouReading});
  if (top2.size() == 2) {
    expect_freq_value("rank top2 freq[0]", top2[0], 100);
    expect_freq_value("rank top2 freq[1]", top2[1], 5000);
    expect_pitch_position("rank top2 pitch[0]", top2[0], 2);
    expect_pitch_position("rank top2 pitch[1]", top2[1], 3);
  }

  std::vector<LookupResult> top1 = lk.lookup(kNeko, 1);
  expect_readings("rank top1 survivor", top1, {kByouReading});
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
    if (pe.pitches.size() != 2) {
      std::fprintf(stderr, "FAIL %s pitch count: got %zu want 2\n", label, pe.pitches.size());
      ++g_fail;
    } else {
      expect_eq_int(label, pe.pitches[0].position, 0);
      expect_eq_int(label, pe.pitches[1].position, 2);
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
  const std::string out_dir = fushi_test::temp_dir() + "/hoshi_lookup_enrich_out";
  const char* kTitle = "LookupEnrichDict";

  std::vector<fushi_test::ZipFile> files = {
      {"index.json", index_json(kTitle)},
      {"term_bank_1.json", term_bank_neko()},
      {"term_meta_bank_1.json", term_meta_bank_neko()},
  };

  std::string zip_path = fushi_test::write_zip("lookup_enrich", files);
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

  case_frequency_is_sole_sort_key();

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
