// BUG-2152 guard: one dictionary must not report the SAME notation twice.
//
// User report: an English Anki card whose pitch tag box read `[/spəʊk/][/spəʊk/]`
// — the identical IPA rendered twice. Root cause is enrich_pitch() in query.cpp:
// a dict contributes exactly ONE PitchEntry, and every meta record it holds for
// the queried expression is flattened into that entry's two vectors. A headword
// the dictionary splits into several entries (English `spoke` = the noun + the
// past tense of `speak`) hands us the same notation once per entry, and every
// consumer renders one tag per element.
//
// Why the fix has to live in enrich_pitch and nowhere downstream: all three
// downstream dedups key on the WHOLE entry —
//   * Dart buildPopupJsonFromLookup, language.dart pKey
//     `dictName:positions,patterns|transcriptions`
//   * the native mirror, popup_json.cpp GroupData::seen_pitches
//   * popup.js mergeIdenticalPitchGroups
// so an entry that carries a duplicate INSIDE itself is seen once and kept
// whole. Only the flattening site can see the duplicate.
//
// Both accumulators are covered, because the two render to the same `[...]`
// shape and a screenshot cannot tell them apart:
//   * ipa mode   -> PitchEntry.transcriptions
//   * pitch mode -> PitchEntry.pitches (position + pattern + nasal + devoice)
//
// The fixture also pins the NEGATIVE half: genuinely different notations must
// all survive, in dictionary order. A dedup that collapses those would be worse
// than the bug.
//
// Red/green proof: drop either dedup in enrich_pitch and the corresponding
// count assertion below FAILs.
//
// Usage: pitch_duplicate_notation_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <string>
#include <vector>

#include "fushidicts/importer.hpp"
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

void expect_eq_str(const char* what, const std::string& got,
                   const std::string& want) {
  if (got != want) {
    std::fprintf(stderr, "FAIL %s: got '%s' want '%s'\n", what, got.c_str(),
                 want.c_str());
    ++g_fail;
  }
}

// The reported word. ASCII on purpose: the duplication is about record count,
// not encoding, and an ASCII fixture cannot be muddled by a code page.
const std::string kSpoke = "spoke";
// /spəʊk/ and /spoʊk/ — the duplicated one and a genuinely different one.
const std::string kIpaUk = "/sp\xC9\x99\xCA\x8Ak/";
const std::string kIpaUs = "/spo\xCA\x8Ak/";

std::string index_json(const char* title) {
  return std::string("{\"title\":\"") + title +
         "\",\"format\":3,\"revision\":\"test\"}";
}

// term_bank: one `spoke` entry, empty reading (English dicts carry none).
std::string term_bank_spoke() {
  return "[[\"" + kSpoke + "\",\"\",\"\",\"\",0,[\"a bar of a wheel\"],0,\"\"]]";
}

// term_meta_bank, ipa mode — three records for the one expression, mirroring a
// dictionary that splits `spoke` across entries:
//   1. the noun entry            -> /spəʊk/
//   2. the past-tense entry      -> /spəʊk/   (duplicate ACROSS records)
//   3. a US-pronunciation entry  -> /spəʊk/ twice INSIDE one record, then /spoʊk/
// Expected after dedup: exactly [/spəʊk/, /spoʊk/], in that order.
std::string term_meta_bank_ipa() {
  const std::string uk = "{\"ipa\":\"" + kIpaUk + "\"}";
  const std::string us = "{\"ipa\":\"" + kIpaUs + "\"}";
  return "[[\"" + kSpoke + "\",\"ipa\",{\"transcriptions\":[" + uk + "]}]," +
         "[\"" + kSpoke + "\",\"ipa\",{\"transcriptions\":[" + uk + "]}]," +
         "[\"" + kSpoke + "\",\"ipa\",{\"transcriptions\":[" + uk + "," + uk +
         "," + us + "]}]]";
}

// term_meta_bank, pitch mode — same shape on the accent side: position 1 twice
// (across records) plus a distinct position 2 that must survive.
//
// `reading` is NOT optional here even though it is empty: parse_pitch reads with
// `error_on_missing_keys = true` (yomitan_parser.cpp:196) and RawPitch declares
// both `reading` and `pitches` (`:70-73`), so a record without the key fails to
// parse and the accents silently vanish. parse_ipa is the lenient one
// (`error_on_missing_keys = false`, `:226`), which is why the ipa fixture above
// can omit it. An empty reading then passes enrich_pitch's reading filter
// (`!parsed.reading.empty() && parsed.reading != term.reading`), matching the
// term_bank entry's empty reading.
std::string term_meta_bank_pitch() {
  const std::string head =
      "\"" + kSpoke + "\",\"pitch\",{\"reading\":\"\",\"pitches\":";
  return "[[" + head + "[{\"position\":1}]}]," + "[" + head +
         "[{\"position\":1}]}]," + "[" + head +
         "[{\"position\":1},{\"position\":2}]}]]";
}

// Import one fixture dict and return the queried term's single PitchEntry.
// Reports through g_fail and returns false when anything upstream broke, so the
// caller can skip its own assertions instead of reading garbage.
bool query_single_entry(const char* title, const std::string& meta_bank,
                        const std::string& out_suffix, PitchEntry& out) {
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_dup_" + out_suffix;
  std::vector<fushi_test::ZipFile> files = {
      {"index.json", index_json(title)},
      {"term_bank_1.json", term_bank_spoke()},
      {"term_meta_bank_1.json", meta_bank},
  };

  std::string zip_path = fushi_test::write_zip(out_suffix.c_str(), files);
  if (zip_path.empty()) {
    fail("could not write fixture zip");
    return false;
  }

  ImportResult r = dictionary_importer::import(zip_path, out_dir);
  if (!r.success) {
    std::fprintf(stderr, "FAIL import(%s): %s\n", title,
                 r.errors.empty() ? "(no error)" : r.errors.front().c_str());
    ++g_fail;
    return false;
  }

  // Same dir in both roles: exactly how the Dart layer registers a dictionary
  // that carries terms plus pitch/ipa meta.
  const std::string dict_path = out_dir + "/" + r.title;
  DictionaryQuery q;
  q.add_term_dict(dict_path);
  q.add_pitch_dict(dict_path);

  std::vector<TermResult> terms = q.query(kSpoke);
  if (terms.empty()) {
    std::fprintf(stderr, "FAIL query(spoke) returned no terms for %s\n", title);
    ++g_fail;
    return false;
  }
  const TermResult& t = terms.front();
  if (t.pitches.empty()) {
    std::fprintf(stderr, "FAIL %s: term has no PitchEntry\n", title);
    ++g_fail;
    return false;
  }
  out = t.pitches.front();
  return true;
}

}  // namespace

int main() {
  // --- ipa mode: transcriptions ------------------------------------------
  PitchEntry ipa;
  if (query_single_entry("DupIpaDict", term_meta_bank_ipa(), "ipa", ipa)) {
    // Four /spəʊk/ occurrences across three records collapse to one; the
    // distinct /spoʊk/ survives. This is the exact user-visible defect:
    // before the fix the count is 5 and the card renders
    // [/spəʊk/][/spəʊk/][/spəʊk/][/spəʊk/][/spoʊk/].
    expect_eq_int("ipa transcription count",
                  static_cast<int>(ipa.transcriptions.size()), 2);
    if (ipa.transcriptions.size() == 2) {
      // Dictionary order is preserved — first occurrence wins.
      expect_eq_str("ipa transcription0", ipa.transcriptions[0], kIpaUk);
      expect_eq_str("ipa transcription1", ipa.transcriptions[1], kIpaUs);
    }
    if (!ipa.pitches.empty()) {
      std::fprintf(stderr,
                   "FAIL ipa entry carries %zu pitch accents, want 0\n",
                   ipa.pitches.size());
      ++g_fail;
    }
  }

  // --- pitch mode: accents ------------------------------------------------
  PitchEntry pitch;
  if (query_single_entry("DupPitchDict", term_meta_bank_pitch(), "pitch",
                         pitch)) {
    expect_eq_int("pitch accent count", static_cast<int>(pitch.pitches.size()),
                  2);
    if (pitch.pitches.size() == 2) {
      expect_eq_int("pitch accent0 position", pitch.pitches[0].position, 1);
      expect_eq_int("pitch accent1 position", pitch.pitches[1].position, 2);
    }
    if (!pitch.transcriptions.empty()) {
      std::fprintf(stderr,
                   "FAIL pitch entry carries %zu transcriptions, want 0\n",
                   pitch.transcriptions.size());
      ++g_fail;
    }
  }

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
