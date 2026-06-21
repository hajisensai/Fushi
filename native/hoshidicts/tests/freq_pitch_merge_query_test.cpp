// freq / pitch *merge* e2e guard (TODO-578 stage 3).
//
// The sibling freq_pitch_import_query_test.cpp only proves the simplest path:
// one dictionary, one freq record, one pitch record. This test pins the
// *aggregation / merge* semantics that the production query path actually
// implements, which nothing exercised before:
//
//   1. Same dict, same expression, MULTIPLE freq records collapse into ONE
//      FrequencyEntry holding ALL values (append, never overwrite). Same for
//      multiple pitch records flattening into one PitchEntry.pitch_positions.
//   2. Two SEPARATE freq dicts (and two separate pitch dicts) that both carry
//      the same expression surface as TWO entries on the TermResult, each
//      carrying its own dict_name, values never crossing dictionaries. This is
//      the real meaning of "merge" — query.cpp loops every registered dict per
//      term and emplace_back one entry per dict.
//   3. freq and pitch travel independent paths (same on-disk type byte 1, but
//      a `mode` guard in query_freq / query_pitch). Registering only the freq
//      role must leave pitches empty, and vice versa — no cross contamination.
//   4. A freq/pitch record whose data carries a `reading` that differs from the
//      term reading is dropped at query time; a bare integer freq (no reading)
//      is always kept.
//
// Contract facts (from query.cpp query_freq/query_pitch + importer.cpp
// build_offset_index): freq/pitch only attach to an expression that ALSO exists
// in a term_dict, so each fixture dir is registered as term + freq + pitch.
// Records are indexed by xxh3(expression); multiple records on the same
// expression land in one bucket and are all read back. Frequencies/pitches are
// grouped one outer entry per dictionary, inner values appended in bucket order.
//
// IMPORTANT: distinct dictionaries MUST import to distinct output dirs (each
// dir owns its own blobs.bin / hash.table); reusing one dir would overwrite.
//
// Usage: freq_pitch_merge_query_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

#include "hoshidicts/importer.hpp"
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

void expect_eq_str(const char* what, const std::string& got, const std::string& want) {
  if (got != want) {
    std::fprintf(stderr, "FAIL %s: got '%s' want '%s'\n", what, got.c_str(),
                 want.c_str());
    ++g_fail;
  }
}

// 猫 / ねこ
const std::string kNeko = "\xE7\x8C\xAB";
const std::string kNekoReading = "\xE3\x81\xAD\xE3\x81\x93";
// いぬ — a deliberately mismatched reading used to test reading-filter drop.
const std::string kInuReading = "\xE3\x81\x84\xE3\x81\xAC";

std::string index_json(const char* title) {
  return std::string("{\"title\":\"") + title +
         "\",\"format\":3,\"revision\":\"test\"}";
}

// term_bank: 猫 (reading ねこ) -> ["cat"].
std::string term_bank_neko() {
  return "[[\"" + kNeko + "\",\"" + kNekoReading +
         "\",\"\",\"\",0,[\"cat\"],0,\"\"]]";
}

// Returns true iff `values` contains `want` exactly once-or-more (order free).
bool contains_int(const std::vector<Frequency>& freqs, int want) {
  return std::any_of(freqs.begin(), freqs.end(),
                     [want](const Frequency& f) { return f.value == want; });
}

bool contains_pos(const std::vector<int>& positions, int want) {
  return std::find(positions.begin(), positions.end(), want) != positions.end();
}

// Import one fixture dir; returns its on-disk dict dir (out_root/<title>) or "".
std::string import_dict(const std::string& out_root, const char* title,
                        const std::vector<hoshi_test::ZipFile>& files,
                        const char* label) {
  std::string zip_path = hoshi_test::write_zip(label, files);
  if (zip_path.empty()) {
    fail("could not write fixture zip");
    return {};
  }
  ImportResult r = dictionary_importer::import(zip_path, out_root);
  if (!r.success) {
    std::fprintf(stderr, "FAIL import(%s): %s\n", title,
                 r.errors.empty() ? "(no error)" : r.errors.front().c_str());
    ++g_fail;
    return {};
  }
  return out_root + "/" + r.title;
}

// ---------------------------------------------------------------------------
// Case 1: same dict, same expression, multiple freq + multiple pitch records.
//   freq:  5000 and 8000 -> one FrequencyEntry, two Frequency values.
//   pitch: two separate pitch records (positions 0 and 2) -> one PitchEntry,
//          flattened pitch_positions [0, 2].
// ---------------------------------------------------------------------------
void case_multi_records_same_dict() {
  const std::string out_dir =
      hoshi_test::temp_dir() + "/hoshi_merge_multi_out";
  const char* kTitle = "MultiRecDict";

  // Two bare-integer freq records + two single-position pitch records, all on 猫.
  std::string meta =
      "[[\"" + kNeko + "\",\"freq\",5000],"
      "[\"" + kNeko + "\",\"freq\",8000],"
      "[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kNekoReading +
      "\",\"pitches\":[{\"position\":0}]}],"
      "[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kNekoReading +
      "\",\"pitches\":[{\"position\":2}]}]]";

  std::vector<hoshi_test::ZipFile> files = {
      {"index.json", index_json(kTitle)},
      {"term_bank_1.json", term_bank_neko()},
      {"term_meta_bank_1.json", meta},
  };

  std::string dir = import_dict(out_dir, kTitle, files, "merge_multi");
  if (dir.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(dir);
  q.add_freq_dict(dir);
  q.add_pitch_dict(dir);

  std::vector<TermResult> terms = q.query(kNeko);
  if (terms.empty()) {
    fail("case1 query(猫) returned no terms");
    return;
  }
  const TermResult& t = terms.front();

  // One entry (one dict) carrying BOTH freq values — not two entries, not one
  // value overwriting the other.
  expect_eq_int("case1 freq entry count", static_cast<int>(t.frequencies.size()),
                1);
  if (!t.frequencies.empty()) {
    const FrequencyEntry& fe = t.frequencies.front();
    expect_eq_str("case1 freq dict_name", fe.dict_name, kTitle);
    expect_eq_int("case1 freq value count",
                  static_cast<int>(fe.frequencies.size()), 2);
    if (!contains_int(fe.frequencies, 5000))
      fail("case1 freq missing 5000 (record dropped/overwritten)");
    if (!contains_int(fe.frequencies, 8000))
      fail("case1 freq missing 8000 (record dropped/overwritten)");
  }

  // Two pitch records flatten into one PitchEntry's positions [0, 2].
  expect_eq_int("case1 pitch entry count", static_cast<int>(t.pitches.size()),
                1);
  if (!t.pitches.empty()) {
    const PitchEntry& pe = t.pitches.front();
    expect_eq_str("case1 pitch dict_name", pe.dict_name, kTitle);
    expect_eq_int("case1 pitch position count",
                  static_cast<int>(pe.pitch_positions.size()), 2);
    if (!contains_pos(pe.pitch_positions, 0))
      fail("case1 pitch missing position 0");
    if (!contains_pos(pe.pitch_positions, 2))
      fail("case1 pitch missing position 2");
  }
}

// ---------------------------------------------------------------------------
// Case 2: two separate freq dicts + two separate pitch dicts, all on 猫.
//   -> term.frequencies has two entries (one per freq dict, own dict_name),
//      term.pitches has two entries (one per pitch dict). Values never cross.
// This is the core "merge across dictionaries" semantic.
// ---------------------------------------------------------------------------
void case_merge_across_dicts() {
  const std::string out_a = hoshi_test::temp_dir() + "/hoshi_merge_dictA_out";
  const std::string out_b = hoshi_test::temp_dir() + "/hoshi_merge_dictB_out";
  const char* kTitleA = "FreqPitchA";
  const char* kTitleB = "FreqPitchB";

  std::string metaA =
      "[[\"" + kNeko + "\",\"freq\",1111],"
      "[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kNekoReading +
      "\",\"pitches\":[{\"position\":1}]}]]";
  std::string metaB =
      "[[\"" + kNeko + "\",\"freq\",2222],"
      "[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kNekoReading +
      "\",\"pitches\":[{\"position\":3}]}]]";

  std::vector<hoshi_test::ZipFile> filesA = {
      {"index.json", index_json(kTitleA)},
      {"term_bank_1.json", term_bank_neko()},
      {"term_meta_bank_1.json", metaA},
  };
  std::vector<hoshi_test::ZipFile> filesB = {
      {"index.json", index_json(kTitleB)},
      {"term_bank_1.json", term_bank_neko()},
      {"term_meta_bank_1.json", metaB},
  };

  std::string dirA = import_dict(out_a, kTitleA, filesA, "merge_dictA");
  std::string dirB = import_dict(out_b, kTitleB, filesB, "merge_dictB");
  if (dirA.empty() || dirB.empty()) return;

  DictionaryQuery q;
  // dirA owns the term records; register both dicts in the freq + pitch roles.
  q.add_term_dict(dirA);
  q.add_freq_dict(dirA);
  q.add_freq_dict(dirB);
  q.add_pitch_dict(dirA);
  q.add_pitch_dict(dirB);

  std::vector<TermResult> terms = q.query(kNeko);
  if (terms.empty()) {
    fail("case2 query(猫) returned no terms");
    return;
  }
  const TermResult& t = terms.front();

  // Two freq entries, one per dict, each with its own value — not merged into
  // one entry, not overwritten.
  expect_eq_int("case2 freq entry count", static_cast<int>(t.frequencies.size()),
                2);
  bool sawA_freq = false, sawB_freq = false;
  for (const FrequencyEntry& fe : t.frequencies) {
    if (fe.dict_name == kTitleA) {
      sawA_freq = true;
      if (!contains_int(fe.frequencies, 1111))
        fail("case2 FreqPitchA freq value not 1111");
      if (contains_int(fe.frequencies, 2222))
        fail("case2 FreqPitchA leaked B's value 2222 (cross-dict bleed)");
    } else if (fe.dict_name == kTitleB) {
      sawB_freq = true;
      if (!contains_int(fe.frequencies, 2222))
        fail("case2 FreqPitchB freq value not 2222");
      if (contains_int(fe.frequencies, 1111))
        fail("case2 FreqPitchB leaked A's value 1111 (cross-dict bleed)");
    }
  }
  if (!sawA_freq) fail("case2 missing freq entry for FreqPitchA");
  if (!sawB_freq) fail("case2 missing freq entry for FreqPitchB");

  // Two pitch entries, one per dict, positions never crossing.
  expect_eq_int("case2 pitch entry count", static_cast<int>(t.pitches.size()),
                2);
  bool sawA_pitch = false, sawB_pitch = false;
  for (const PitchEntry& pe : t.pitches) {
    if (pe.dict_name == kTitleA) {
      sawA_pitch = true;
      if (!contains_pos(pe.pitch_positions, 1))
        fail("case2 FreqPitchA pitch position not 1");
      if (contains_pos(pe.pitch_positions, 3))
        fail("case2 FreqPitchA leaked B's pitch position 3");
    } else if (pe.dict_name == kTitleB) {
      sawB_pitch = true;
      if (!contains_pos(pe.pitch_positions, 3))
        fail("case2 FreqPitchB pitch position not 3");
      if (contains_pos(pe.pitch_positions, 1))
        fail("case2 FreqPitchB leaked A's pitch position 1");
    }
  }
  if (!sawA_pitch) fail("case2 missing pitch entry for FreqPitchA");
  if (!sawB_pitch) fail("case2 missing pitch entry for FreqPitchB");
}

// ---------------------------------------------------------------------------
// Case 3: freq and pitch travel independent roles. Register the dict ONLY in
// the freq role -> pitches must be empty (and vice versa). Also: a freq record
// whose reading mismatches the term is dropped; a pitch record whose reading
// mismatches is dropped.
// ---------------------------------------------------------------------------
void case_path_isolation_and_reading_filter() {
  const std::string out_dir =
      hoshi_test::temp_dir() + "/hoshi_merge_iso_out";
  const char* kTitle = "IsoDict";

  // 猫: one kept bare freq (5000), one freq with MISMATCHED reading いぬ (must
  // be dropped), one pitch with MATCHED reading (kept), one pitch with
  // MISMATCHED reading (dropped).
  std::string meta =
      "[[\"" + kNeko + "\",\"freq\",5000],"
      "[\"" + kNeko + "\",\"freq\",{\"reading\":\"" + kInuReading +
      "\",\"frequency\":9999}],"
      "[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kNekoReading +
      "\",\"pitches\":[{\"position\":0}]}],"
      "[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kInuReading +
      "\",\"pitches\":[{\"position\":5}]}]]";

  std::vector<hoshi_test::ZipFile> files = {
      {"index.json", index_json(kTitle)},
      {"term_bank_1.json", term_bank_neko()},
      {"term_meta_bank_1.json", meta},
  };

  std::string dir = import_dict(out_dir, kTitle, files, "merge_iso");
  if (dir.empty()) return;

  // 3a: freq role ONLY -> pitches empty, freq dropped the mismatched-reading one.
  {
    DictionaryQuery q;
    q.add_term_dict(dir);
    q.add_freq_dict(dir);
    // deliberately NOT add_pitch_dict
    std::vector<TermResult> terms = q.query(kNeko);
    if (terms.empty()) {
      fail("case3a query(猫) returned no terms");
    } else {
      const TermResult& t = terms.front();
      if (!t.pitches.empty())
        fail("case3a pitches non-empty though no pitch dict registered "
             "(freq/pitch path bleed)");
      if (t.frequencies.empty()) {
        fail("case3a no frequencies though freq dict registered");
      } else {
        const FrequencyEntry& fe = t.frequencies.front();
        // Only the bare 5000 survives; the いぬ-reading 9999 is reading-filtered.
        if (!contains_int(fe.frequencies, 5000))
          fail("case3a kept freq 5000 missing");
        if (contains_int(fe.frequencies, 9999))
          fail("case3a mismatched-reading freq 9999 not dropped");
      }
    }
  }

  // 3b: pitch role ONLY -> frequencies empty, pitch dropped mismatched reading.
  {
    DictionaryQuery q;
    q.add_term_dict(dir);
    q.add_pitch_dict(dir);
    // deliberately NOT add_freq_dict
    std::vector<TermResult> terms = q.query(kNeko);
    if (terms.empty()) {
      fail("case3b query(猫) returned no terms");
    } else {
      const TermResult& t = terms.front();
      if (!t.frequencies.empty())
        fail("case3b frequencies non-empty though no freq dict registered "
             "(freq/pitch path bleed)");
      if (t.pitches.empty()) {
        fail("case3b no pitches though pitch dict registered");
      } else {
        const PitchEntry& pe = t.pitches.front();
        if (!contains_pos(pe.pitch_positions, 0))
          fail("case3b kept pitch position 0 missing");
        if (contains_pos(pe.pitch_positions, 5))
          fail("case3b mismatched-reading pitch position 5 not dropped");
      }
    }
  }
}

}  // namespace

int main() {
  case_multi_records_same_dict();
  case_merge_across_dicts();
  case_path_isolation_and_reading_filter();

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
