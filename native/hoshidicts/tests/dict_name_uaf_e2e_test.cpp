// BUG-052 self-contained e2e guard: a dictionary's reported name (the
// dict_name carried on every GlossaryEntry) must exactly equal its index.json
// "title", byte-for-byte, even when the title is non-ASCII and long.
//
// Root cause (query.cpp DictionaryQuery::add_dict): Index::title
// (yomitan_parser.hpp) is a std::string_view that glaze parses zero-copy into
// the in-memory JSON source buffer. add_dict used to read index.title AFTER its
// index_buf block had closed (the buffer freed) -> a use-after-free that
// overwrote the title's leading bytes with recycled heap data, rendered as
// U+FFFD garble in the popup. The corruption is heap-layout dependent, so a
// single clean ASCII title rarely triggers it; this test deliberately:
//   * uses NON-ASCII, multi-byte titles whose first byte is the one corrupted,
//   * loads SEVERAL dictionaries to churn the allocator before querying,
//   * asserts dict_name == title byte-for-byte (not just "non-empty").
//
// Unlike dict_name_lifetime_test.cpp (which takes a pre-imported dict dir on
// argv), this test builds + imports its own fixtures from hand-rolled in-memory
// STORED zips, so it runs with no external素材 and is wired into ctest.
//
// Usage: dict_name_uaf_e2e_test   (no args) -> exit 0 PASS, non-zero FAIL.
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

// A term_bank_1.json with a single entry: expression/reading both `expr`,
// glossary ["<gloss>"].
std::string term_bank(const std::string& expr, const std::string& gloss) {
  // [[expr, reading, defTags, rules, score, [glossary], seq, termTags]]
  return "[[\"" + expr + "\",\"" + expr + "\",\"\",\"\",0,[\"" + gloss +
         "\"],0,\"\"]]";
}

std::string index_json(const std::string& title) {
  return "{\"title\":\"" + title + "\",\"format\":3,\"revision\":\"test\"}";
}

// Build, import and register one term dictionary; returns its index title (the
// importer sanitizes the on-disk dir name, but the dict_name carried on results
// must remain the original index.json title).
struct Imported {
  bool ok = false;
  std::string title;       // sanitized on-disk title (dir name + r.title)
  std::string index_title; // original index.json title (expected dict_name)
};

Imported import_dict(const std::string& label, const std::string& index_title,
                     const std::string& expr, const std::string& gloss,
                     const std::string& out_dir) {
  std::vector<hoshi_test::ZipFile> files = {
      {"index.json", index_json(index_title)},
      {"term_bank_1.json", term_bank(expr, gloss)},
  };
  std::string zip_path = hoshi_test::write_zip(label.c_str(), files);
  Imported out;
  out.index_title = index_title;
  if (zip_path.empty()) {
    fail((label + ": could not write fixture zip").c_str());
    return out;
  }
  ImportResult r = dictionary_importer::import(zip_path, out_dir);
  if (!r.success) {
    std::fprintf(stderr, "FAIL %s: import failed: %s\n", label.c_str(),
                 r.errors.empty() ? "(no error)" : r.errors.front().c_str());
    ++g_fail;
    return out;
  }
  // The importer keeps the index.json title intact (only the on-disk dir name is
  // sanitized). Confirm the round-tripped title matches what we put in.
  if (r.title != index_title) {
    std::fprintf(stderr,
                 "FAIL %s: ImportResult.title '%s' != index title '%s'\n",
                 label.c_str(), r.title.c_str(), index_title.c_str());
    ++g_fail;
  }
  out.ok = true;
  out.title = r.title;
  return out;
}

}  // namespace

int main() {
  const std::string out_dir = hoshi_test::temp_dir() + "/hoshi_uaf_out";

  // Long, non-ASCII titles. The leading bytes are exactly what a UAF would
  // corrupt, so any garble shows up in the byte-for-byte comparison below.
  // 「大修館 明鏡国語辞典（第二版）— 携帯版」
  const std::string title_a =
      "\xE5\xA4\xA7\xE4\xBF\xAE\xE9\xA4\xA8 "             // 大修館␣
      "\xE6\x98\x8E\xE9\x8F\xA1"                           // 明鏡
      "\xE5\x9B\xBD\xE8\xAA\x9E\xE8\xBE\x9E\xE5\x85\xB8"   // 国語辞典
      "\xEF\xBC\x88\xE7\xAC\xAC\xE4\xBA\x8C\xE7\x89\x88\xEF\xBC\x89"; // （第二版）
  // 「ロシア語＝日本語辞典 Большой словарь」(mixes JP + Cyrillic)
  const std::string title_b =
      "\xE3\x83\xAD\xE3\x82\xB7\xE3\x82\xA2\xE8\xAA\x9E"   // ロシア語
      "\xEF\xBC\x9D"                                       // ＝
      "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E\xE8\xBE\x9E\xE5\x85\xB8 " // 日本語辞典␣
      "\xD0\x91\xD0\xBE\xD0\xBB\xD1\x8C\xD1\x88\xD0\xBE\xD0\xB9";     // Большой
  // 「café — Diccionario español」(precomposed accents, leading 'c' is ASCII but
  // tail is multi-byte)
  const std::string title_c =
      "caf\xC3\xA9 \xE2\x80\x94 Diccionario espa\xC3\xB1ol";

  const std::string expr = "\xE6\x97\xA5\xE6\x9C\xAC";  // 日本

  // Import three dictionaries with the SAME expression but distinct non-ASCII
  // titles. Loading all three churns the allocator before any query, which is
  // what makes a UAF on the title's backing buffer observable.
  Imported a = import_dict("uaf_a", title_a, expr, "Japan-A", out_dir);
  Imported b = import_dict("uaf_b", title_b, expr, "Japan-B", out_dir);
  Imported c = import_dict("uaf_c", title_c, expr, "Japan-C", out_dir);

  if (a.ok && b.ok && c.ok) {
    DictionaryQuery q;
    q.add_term_dict(out_dir + "/" + a.title);
    q.add_term_dict(out_dir + "/" + b.title);
    q.add_term_dict(out_dir + "/" + c.title);

    std::vector<TermResult> results = q.query(expr);
    if (results.empty()) {
      fail("query(日本) returned no results");
    } else {
      // Every glossary's dict_name must be one of the three exact titles, and
      // each title must appear (no dict silently dropped, none garbled).
      bool seen_a = false, seen_b = false, seen_c = false;
      size_t checked = 0;
      for (const TermResult& t : results) {
        for (const GlossaryEntry& g : t.glossaries) {
          ++checked;
          if (g.dict_name == a.index_title) {
            seen_a = true;
          } else if (g.dict_name == b.index_title) {
            seen_b = true;
          } else if (g.dict_name == c.index_title) {
            seen_c = true;
          } else {
            std::fprintf(stderr,
                         "FAIL: dict_name '%s' matches no expected title "
                         "(use-after-free likely corrupted the title bytes)\n",
                         g.dict_name.c_str());
            ++g_fail;
          }
        }
      }
      if (checked == 0) fail("no glossaries to check");
      if (!seen_a) fail("title A never appeared as a dict_name");
      if (!seen_b) fail("title B never appeared as a dict_name");
      if (!seen_c) fail("title C never appeared as a dict_name");
    }
  }

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
