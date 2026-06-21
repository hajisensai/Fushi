// IPA transcription meta e2e guard: importing a Yomitan dictionary that ships
// term_meta_bank records with mode "ipa" must let query() surface the IPA
// strings on the matching TermResult (PitchEntry.transcriptions), with the
// right values. This is the upstream 918744d feature ported into Hibiki's
// BlobReader-based query path (TODO-687 block3).
//
// Why this matters: IPA records reuse the PITCH dict bucket and the pitch
// storage layout (type byte 1, mode "ipa"), but the data JSON is shaped
// differently ({"reading":...,"transcriptions":[{"ipa":...}]}). query_pitch
// must branch on mode and route ipa data through parse_ipa, accumulating into
// PitchEntry.transcriptions instead of pitch_positions. Nothing exercised this
// import->query IPA path end to end before; the Dart-side tests are source
// scans / parity checks that never link the native engine.
//
// Contract facts this fixture leans on (from query.cpp / yomitan_parser.cpp):
//   * an ipa meta only attaches to a term that ALSO exists in a term_dict, so
//     the same import dir is registered as term + pitch (IPA shares the pitch
//     bucket; importer detect_type now classifies a pure-ipa dict as "pitch").
//   * meta records are indexed by xxh3(expression); reading is filtered at
//     query time — an ipa record whose data carries a `reading` that does not
//     equal the term's reading is dropped. Our fixture's reading matches.
//   * a pitch_count of 1 confirms the importer counted the ipa record under the
//     widened "pitch" || "ipa" branch.
//
// Red/green proof: removing the `mode == "ipa"` branch in query.cpp (or the
// detect_type / count widening in importer.cpp) makes transcriptions empty and
// this test FAILs; with the port in place it PASSes.
//
// Usage: ipa_import_query_test  (no args) -> exit 0 PASS, non-zero FAIL.
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

// Two IPA transcriptions for 猫: "neko" and a stressed variant. Distinct
// strings so the popup dedup (folds transcriptions into the key) keeps both.
const std::string kIpa1 = "neko";
const std::string kIpa2 = "ne\xCB\x88ko";  // neˈko (stress mark)

std::string index_json(const char* title) {
  return std::string("{\"title\":\"") + title +
         "\",\"format\":3,\"revision\":\"test\"}";
}

// term_bank: 猫 (reading ねこ) -> ["cat"].
std::string term_bank_neko() {
  return "[[\"" + kNeko + "\",\"" + kNekoReading +
         "\",\"\",\"\",0,[\"cat\"],0,\"\"]]";
}

// term_meta_bank: one ipa record (reading ねこ) with two transcriptions.
//   ["猫","ipa",{"reading":"ねこ","transcriptions":[{"ipa":"neko"},{"ipa":"neˈko"}]}]
std::string term_meta_bank_ipa() {
  return "[[\"" + kNeko + "\",\"ipa\",{\"reading\":\"" + kNekoReading +
         "\",\"transcriptions\":[{\"ipa\":\"" + kIpa1 + "\"},{\"ipa\":\"" +
         kIpa2 + "\"}]}]]";
}

}  // namespace

int main() {
  const std::string out_dir = hoshi_test::temp_dir() + "/hoshi_ipa_out";
  const char* kTitle = "IpaDict";

  std::vector<hoshi_test::ZipFile> files = {
      {"index.json", index_json(kTitle)},
      {"term_bank_1.json", term_bank_neko()},
      {"term_meta_bank_1.json", term_meta_bank_ipa()},
  };

  std::string zip_path = hoshi_test::write_zip("ipa", files);
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
      // The widened importer count branch ("pitch" || "ipa") must count the ipa
      // record under pitch_count.
      expect_eq_int("pitch_count", static_cast<int>(r.pitch_count), 1);

      // Same import dir routed to both roles, exactly how the Dart layer
      // registers a dictionary that carries terms + ipa meta (ipa shares the
      // pitch bucket).
      const std::string dict_path = out_dir + "/" + r.title;
      DictionaryQuery q;
      q.add_term_dict(dict_path);
      q.add_pitch_dict(dict_path);

      std::vector<TermResult> terms = q.query(kNeko);
      if (terms.empty()) {
        fail("query(猫) returned no terms");
      } else {
        const TermResult& t = terms.front();

        // IPA: one PitchEntry from IpaDict, no pitch positions, two
        // transcriptions [neko, neˈko].
        if (t.pitches.empty()) {
          fail("term has no pitches (ipa meta not surfaced)");
        } else {
          const PitchEntry& pe = t.pitches.front();
          if (pe.dict_name != kTitle) {
            std::fprintf(stderr, "FAIL ipa.dict_name: got '%s' want '%s'\n",
                         pe.dict_name.c_str(), kTitle);
            ++g_fail;
          }
          if (!pe.pitch_positions.empty()) {
            std::fprintf(stderr,
                         "FAIL ipa pitch_positions: got %zu want 0 (ipa carries "
                         "no positions)\n",
                         pe.pitch_positions.size());
            ++g_fail;
          }
          if (pe.transcriptions.size() != 2) {
            std::fprintf(stderr,
                         "FAIL ipa transcription count: got %zu want 2\n",
                         pe.transcriptions.size());
            ++g_fail;
          } else {
            if (pe.transcriptions[0] != kIpa1) {
              std::fprintf(stderr, "FAIL ipa.transcription0: got '%s' want '%s'\n",
                           pe.transcriptions[0].c_str(), kIpa1.c_str());
              ++g_fail;
            }
            if (pe.transcriptions[1] != kIpa2) {
              std::fprintf(stderr, "FAIL ipa.transcription1: got '%s' want '%s'\n",
                           pe.transcriptions[1].c_str(), kIpa2.c_str());
              ++g_fail;
            }
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
