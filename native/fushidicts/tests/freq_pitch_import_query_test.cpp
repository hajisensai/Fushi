// freq / pitch meta e2e guard: importing a Yomitan dictionary with
// term_meta_bank frequency + pitch-accent records must let query() surface them
// on the matching TermResult (frequencies / pitches), with the right values.
//
// Why this matters: the importer stores meta records (type byte 1) opaquely and
// parses the data JSON at query time (query.cpp query_freq / query_pitch), which
// own parallel int32 arrays and char** ownership. Nothing exercised the real
// import->query freq/pitch path end to end before; the only Dart tests are
// source scans / data-model checks that never link the native engine.
//
// Contract facts this fixture leans on (from query.cpp / yomitan_parser.cpp):
//   * freq/pitch only attach to a term that ALSO exists in a term_dict, so the
//     same import dir is registered as term + freq + pitch.
//   * meta records are indexed by xxh3(expression); reading is filtered at
//     query time — a freq/pitch whose data carries a `reading` is dropped if it
//     does not equal the term's reading. We use a bare-integer freq (no reading
//     -> always kept) and a pitch whose reading matches the term reading.
//
// Usage: freq_pitch_import_query_test  (no args) -> exit 0 PASS, non-zero FAIL.
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

// 猫 / ねこ
const std::string kNeko = "\xE7\x8C\xAB";
const std::string kNekoReading = "\xE3\x81\xAD\xE3\x81\x93";

std::string index_json(const char* title) {
  return std::string("{\"title\":\"") + title +
         "\",\"format\":3,\"revision\":\"test\"}";
}

// term_bank: 猫 (reading ねこ) -> ["cat"].
std::string term_bank_neko() {
  return "[[\"" + kNeko + "\",\"" + kNekoReading +
         "\",\"\",\"\",0,[\"cat\"],0,\"\"]]";
}

// term_meta_bank: one freq (bare integer -> no reading filter) and one pitch
// (reading ねこ, pitch position 0 = heiban-ish for this fixture).
//   ["猫","freq",5000]
//   ["猫","pitch",{"reading":"ねこ","pitches":[{"position":0},{"position":2}]}]
std::string term_meta_bank_neko() {
  return "[[\"" + kNeko + "\",\"freq\",5000],"
         "[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kNekoReading +
         "\",\"pitches\":[{\"position\":0},{\"position\":2}]}]]";
}

}  // namespace

int main() {
  const std::string out_dir = hoshi_test::temp_dir() + "/hoshi_freqpitch_out";
  const char* kTitle = "FreqPitchDict";

  std::vector<hoshi_test::ZipFile> files = {
      {"index.json", index_json(kTitle)},
      {"term_bank_1.json", term_bank_neko()},
      {"term_meta_bank_1.json", term_meta_bank_neko()},
  };

  std::string zip_path = hoshi_test::write_zip("freqpitch", files);
  if (zip_path.empty()) {
    fail("could not write fixture zip");
  } else {
    ImportResult r = dictionary_importer::import(zip_path, out_dir);
    if (!r.success) {
      std::fprintf(stderr, "FAIL import: %s\n",
                   r.errors.empty() ? "(no error)" : r.errors.front().c_str());
      ++g_fail;
    } else {
      expect_eq_int("term_count", static_cast<int>(r.term_count), 1);
      expect_eq_int("freq_count", static_cast<int>(r.freq_count), 1);
      expect_eq_int("pitch_count", static_cast<int>(r.pitch_count), 1);

      // Same import dir routed to all three roles, exactly how the Dart layer
      // registers a dictionary that carries terms + freq + pitch meta.
      const std::string dict_path = out_dir + "/" + r.title;
      DictionaryQuery q;
      q.add_term_dict(dict_path);
      q.add_freq_dict(dict_path);
      q.add_pitch_dict(dict_path);

      std::vector<TermResult> terms = q.query(kNeko);
      if (terms.empty()) {
        fail("query(猫) returned no terms");
      } else {
        const TermResult& t = terms.front();

        // Frequency: one FrequencyEntry from FreqPitchDict, value 5000.
        if (t.frequencies.empty()) {
          fail("term has no frequencies (freq meta not surfaced)");
        } else {
          const FrequencyEntry& fe = t.frequencies.front();
          if (fe.dict_name != kTitle) {
            std::fprintf(stderr, "FAIL freq.dict_name: got '%s' want '%s'\n",
                         fe.dict_name.c_str(), kTitle);
            ++g_fail;
          }
          if (fe.frequencies.empty()) {
            fail("FrequencyEntry has no Frequency values");
          } else {
            expect_eq_int("freq.value", fe.frequencies.front().value, 5000);
          }
        }

        // Pitch: one PitchEntry from FreqPitchDict, positions [0, 2].
        if (t.pitches.empty()) {
          fail("term has no pitches (pitch meta not surfaced)");
        } else {
          const PitchEntry& pe = t.pitches.front();
          if (pe.dict_name != kTitle) {
            std::fprintf(stderr, "FAIL pitch.dict_name: got '%s' want '%s'\n",
                         pe.dict_name.c_str(), kTitle);
            ++g_fail;
          }
          if (pe.pitch_positions.size() != 2) {
            std::fprintf(stderr, "FAIL pitch positions count: got %zu want 2\n",
                         pe.pitch_positions.size());
            ++g_fail;
          } else {
            expect_eq_int("pitch.pos0", pe.pitch_positions[0], 0);
            expect_eq_int("pitch.pos1", pe.pitch_positions[1], 2);
          }
        }
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
