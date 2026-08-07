// TODO-094 S0-S2 guard: importing a Yomitan kanji_bank dictionary must produce
// type=2 records and let query_kanji() read back onyomi / kunyomi / radical /
// strokes / meanings for a single character. Before this work the importer had
// no write_kanji path: a kanji-only dictionary threw "empty dictionary" and a
// mixed (term + kanji) dictionary silently dropped its kanji_bank.
//
// Two fixtures, both built as hand-rolled STORED zips (no external zip tool):
//   A) kanji-only dictionary  -> import OK, detected_type "kanji",
//                                 query_kanji("日") returns the full record.
//   B) mixed term + kanji     -> query("日本") (term) AND query_kanji("水")
//                                 both hit; the kanji bank is not dropped.
//
// Usage: kanji_import_query_test   (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "hoshidicts/importer.hpp"
#include "hoshidicts/query.hpp"

namespace {

int g_fail = 0;

void put16(std::vector<uint8_t>& b, uint16_t v) {
  b.push_back(static_cast<uint8_t>(v & 0xff));
  b.push_back(static_cast<uint8_t>((v >> 8) & 0xff));
}
void put32(std::vector<uint8_t>& b, uint32_t v) {
  for (int i = 0; i < 4; i++) b.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
}

struct ZipFile {
  std::string name;
  std::string data;
};

// Build a minimal multi-entry STORED zip (method 0, no compression, no zip64).
std::vector<uint8_t> build_zip(const std::vector<ZipFile>& files) {
  std::vector<uint8_t> z;
  std::vector<uint32_t> lfh_offsets;

  for (const auto& f : files) {
    lfh_offsets.push_back(static_cast<uint32_t>(z.size()));
    put32(z, 0x04034b50);                                  // local file header sig
    put16(z, 20);                                          // version needed
    put16(z, 0);                                           // flags
    put16(z, 0);                                           // method = stored
    put16(z, 0);                                           // mod time
    put16(z, 0);                                           // mod date
    put32(z, 0);                                           // crc32 (parser ignores)
    put32(z, static_cast<uint32_t>(f.data.size()));        // comp size
    put32(z, static_cast<uint32_t>(f.data.size()));        // uncomp size
    put16(z, static_cast<uint16_t>(f.name.size()));        // name len
    put16(z, 0);                                           // extra len
    for (char c : f.name) z.push_back(static_cast<uint8_t>(c));
    for (char c : f.data) z.push_back(static_cast<uint8_t>(c));
  }

  const size_t cd_off = z.size();
  for (size_t i = 0; i < files.size(); i++) {
    const auto& f = files[i];
    put32(z, 0x02014b50);                                  // central dir header sig
    put16(z, 20);                                          // version made by
    put16(z, 20);                                          // version needed
    put16(z, 0);                                           // flags
    put16(z, 0);                                           // method = stored
    put16(z, 0);                                           // mod time
    put16(z, 0);                                           // mod date
    put32(z, 0);                                           // crc32
    put32(z, static_cast<uint32_t>(f.data.size()));        // comp size
    put32(z, static_cast<uint32_t>(f.data.size()));        // uncomp size
    put16(z, static_cast<uint16_t>(f.name.size()));        // name len
    put16(z, 0);                                           // extra len
    put16(z, 0);                                           // comment len
    put16(z, 0);                                           // disk start
    put16(z, 0);                                           // internal attrs
    put32(z, 0);                                           // external attrs
    put32(z, lfh_offsets[i]);                              // lfh offset
    for (char c : f.name) z.push_back(static_cast<uint8_t>(c));
  }
  const size_t cd_size = z.size() - cd_off;

  put32(z, 0x06054b50);                                    // EOCD sig
  put16(z, 0);                                             // disk number
  put16(z, 0);                                             // cd start disk
  put16(z, static_cast<uint16_t>(files.size()));           // entries this disk
  put16(z, static_cast<uint16_t>(files.size()));           // total entries
  put32(z, static_cast<uint32_t>(cd_size));
  put32(z, static_cast<uint32_t>(cd_off));
  put16(z, 0);                                             // comment len
  return z;
}

std::string write_zip(const char* label, const std::vector<ZipFile>& files) {
  const char* tmp = std::getenv("TEMP");
  if (!tmp) tmp = std::getenv("TMPDIR");
  std::string path = std::string(tmp ? tmp : ".") + "/hoshi_kanji_" + label + ".zip";
  std::vector<uint8_t> bytes = build_zip(files);
  FILE* fp = std::fopen(path.c_str(), "wb");
  if (!fp) return {};
  std::fwrite(bytes.data(), 1, bytes.size(), fp);
  std::fclose(fp);
  return path;
}

void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

void expect_eq_str(const char* what, const std::string& got, const std::string& want) {
  if (got != want) {
    std::fprintf(stderr, "FAIL %s: got '%s' want '%s'\n", what, got.c_str(), want.c_str());
    ++g_fail;
  }
}

void expect_eq_int(const char* what, int got, int want) {
  if (got != want) {
    std::fprintf(stderr, "FAIL %s: got %d want %d\n", what, got, want);
    ++g_fail;
  }
}

// UTF-8 literals for the kanji we exercise.
const std::string kHi = "\xE6\x97\xA5";    // 日
const std::string kMizu = "\xE6\xB0\xB4";  // 水
const std::string kNihon = "\xE6\x97\xA5\xE6\x9C\xAC";  // 日本

// index.json for a kanji dictionary.
std::string index_json(const char* title) {
  return std::string("{\"title\":\"") + title + "\",\"format\":3,\"revision\":\"test\"}";
}

// One kanji_bank entry: [char, onyomi, kunyomi, tags, [meanings], {stats}].
// stats carries radical + stroke count under common KANJIDIC key names.
std::string kanji_bank_hi() {
  // 日 : onyomi "nichi jitsu", kunyomi "hi -bi -ka", meanings day/sun,
  // radical 日, strokes 4.
  return "[[\"\xE6\x97\xA5\",\"nichi jitsu\",\"hi -bi -ka\",\"jouyou\","
         "[\"day\",\"sun\"],"
         "{\"radical\":\"\xE6\x97\xA5\",\"strokes\":\"4\"}]]";
}

std::string kanji_bank_mizu() {
  // 水 : onyomi "sui", kunyomi "mizu", meanings water, radical 水, strokes 4.
  return "[[\"\xE6\xB0\xB4\",\"sui\",\"mizu\",\"\","
         "[\"water\"],"
         "{\"radical\":\"\xE6\xB0\xB4\",\"strokes\":\"4\"}]]";
}

std::string term_bank_nihon() {
  // 日本 : reading 日本, glossary ["Japan"].
  return "[[\"\xE6\x97\xA5\xE6\x9C\xAC\",\"\xE6\x97\xA5\xE6\x9C\xAC\",\"\",\"\",0,"
         "[\"Japan\"],0,\"\"]]";
}

}  // namespace

int main() {
  const char* tmp = std::getenv("TEMP");
  if (!tmp) tmp = std::getenv("TMPDIR");
  const std::string out_dir = std::string(tmp ? tmp : ".") + "/hoshi_kanji_out";

  // ----- Case A: kanji-only dictionary -----
  {
    std::vector<ZipFile> files = {
        {"index.json", index_json("KanjiOnly")},
        {"kanji_bank_1.json", kanji_bank_hi()},
    };
    std::string zip_path = write_zip("only", files);
    if (zip_path.empty()) {
      fail("A: could not write fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (!r.success) {
        std::fprintf(stderr, "FAIL A: import failed: %s\n",
                     r.errors.empty() ? "(no error)" : r.errors.front().c_str());
        ++g_fail;
      } else {
        expect_eq_str("A.detected_type", r.detected_type, "kanji");
        expect_eq_int("A.kanji_count", static_cast<int>(r.kanji_count), 1);

        DictionaryQuery q;
        q.add_kanji_dict(out_dir + "/" + r.title);
        std::vector<KanjiResult> res = q.query_kanji(kHi);
        if (res.empty()) {
          fail("A: query_kanji(日) returned nothing");
        } else {
          const KanjiResult& k = res.front();
          expect_eq_str("A.character", k.character, kHi);
          expect_eq_str("A.onyomi", k.onyomi, "nichi jitsu");
          expect_eq_str("A.kunyomi", k.kunyomi, "hi -bi -ka");
          expect_eq_str("A.radical", k.radical, kHi);
          expect_eq_int("A.strokes", k.strokes, 4);
          if (k.meanings.size() != 2) {
            std::fprintf(stderr, "FAIL A.meanings count: got %zu want 2\n", k.meanings.size());
            ++g_fail;
          } else {
            expect_eq_str("A.meaning0", k.meanings[0], "day");
            expect_eq_str("A.meaning1", k.meanings[1], "sun");
          }
        }

        // TODO-622: probe a pure-kanji dictionary -> bit1 (hasKanji) only.
        int mask = probe_dict_content(out_dir + "/" + r.title);
        expect_eq_int("A.probe_mask", mask, 0x2);
      }
    }
  }

  // ----- Case B: mixed term + kanji dictionary -----
  {
    std::vector<ZipFile> files = {
        {"index.json", index_json("Mixed")},
        {"term_bank_1.json", term_bank_nihon()},
        {"kanji_bank_1.json", kanji_bank_mizu()},
    };
    std::string zip_path = write_zip("mixed", files);
    if (zip_path.empty()) {
      fail("B: could not write fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (!r.success) {
        std::fprintf(stderr, "FAIL B: import failed: %s\n",
                     r.errors.empty() ? "(no error)" : r.errors.front().c_str());
        ++g_fail;
      } else {
        // A mixed term+kanji dictionary must classify as "term" (word lookup is
        // primary); its kanji bank is still written and reachable via the
        // kanji bucket. Before TODO-622 detect_type returned "kanji" here and
        // the whole dictionary vanished from word lookup.
        expect_eq_str("B.detected_type", r.detected_type, "term");
        // Both banks must be written; kanji must not be dropped.
        expect_eq_int("B.term_count", static_cast<int>(r.term_count), 1);
        expect_eq_int("B.kanji_count", static_cast<int>(r.kanji_count), 1);

        // The same dictionary path is registered in both buckets, exactly how
        // the Dart layer will route a mixed dictionary (term + kanji).
        const std::string dict_path = out_dir + "/" + r.title;
        DictionaryQuery q;
        q.add_term_dict(dict_path);
        q.add_kanji_dict(dict_path);

        std::vector<TermResult> terms = q.query(kNihon);
        if (terms.empty()) {
          fail("B: query(日本) term lookup returned nothing");
        } else {
          expect_eq_str("B.term.expression", terms.front().expression, kNihon);
        }

        std::vector<KanjiResult> kanji = q.query_kanji(kMizu);
        if (kanji.empty()) {
          fail("B: query_kanji(水) returned nothing");
        } else {
          expect_eq_str("B.kanji.character", kanji.front().character, kMizu);
          expect_eq_str("B.kanji.onyomi", kanji.front().onyomi, "sui");
          expect_eq_int("B.kanji.strokes", kanji.front().strokes, 4);
          if (kanji.front().meanings.size() != 1) {
            std::fprintf(stderr, "FAIL B.kanji.meanings count: got %zu want 1\n",
                         kanji.front().meanings.size());
            ++g_fail;
          } else {
            expect_eq_str("B.kanji.meaning0", kanji.front().meanings[0], "water");
          }
        }

        // TODO-622: a mixed dictionary's blobs.bin contains BOTH term (type 0)
        // and kanji (type 2) records, so the probe must report bit0|bit1 = 0x3.
        // This is the native single source of truth used to re-bucket and
        // self-heal mixed dictionaries the Dart layer cannot classify from the
        // opaque blob alone.
        int mask = probe_dict_content(dict_path);
        expect_eq_int("B.probe_mask", mask, 0x3);
      }
    }
  }

  // ----- Case C: pure term dictionary (probe -> hasTerm only) -----
  {
    std::vector<ZipFile> files = {
        {"index.json", index_json("TermOnly")},
        {"term_bank_1.json", term_bank_nihon()},
    };
    std::string zip_path = write_zip("term", files);
    if (zip_path.empty()) {
      fail("C: could not write fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (!r.success) {
        fail("C: import failed");
      } else {
        expect_eq_str("C.detected_type", r.detected_type, "term");
        int mask = probe_dict_content(out_dir + "/" + r.title);
        expect_eq_int("C.probe_mask", mask, 0x1);
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
