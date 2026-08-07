// BUG-051 guard: a dictionary's reported name must exactly equal its
// index.json title — no garbage prefix.
//
// Root cause: Index::title (yomitan_parser.hpp) is a std::string_view that
// glaze parses zero-copy into the JSON source buffer. DictionaryQuery::add_dict
// used to read index.title AFTER its index_buf block had closed (buffer freed),
// a use-after-free that left dict.name's leading bytes overwritten by recycled
// heap data — rendered as U+FFFD garble in the popup, heap-layout dependent so
// intermittent. Fixed by copying index.title into dict.name inside the buffer's
// scope (query.cpp).
//
// Usage: dict_name_lifetime_test <dict_dir> <query_term_utf8> <expected_title_utf8>
//   <dict_dir>  an already-imported hoshidicts dictionary directory
//               (contains index.json + .hoshidicts_1 + hash.table + blobs.bin)
//   <query_term_utf8>      a term that exists in that dictionary
//   <expected_title_utf8>  the dictionary's index.json "title"
// Exit 0 + "PASS" on success; non-zero with a diagnostic otherwise.
//
// Catching the use-after-free reliably is heap-layout dependent, so run it with
// several dictionaries loaded (it only checks the queried one) to exercise the
// allocator. The companion deterministic guard is the source scan at
// hibiki/test/dictionary/dict_name_lifetime_guard_test.dart.
#include <cstdio>
#include <string>
#include <vector>

#include "hoshidicts/query.hpp"

#ifdef _WIN32
#include <windows.h>
// Windows narrow argv is encoded in the active code page (ANSI), which mangles
// the UTF-8 dictionary terms/titles this test needs. Re-read the command line
// as UTF-16 and re-encode to UTF-8 so the arguments survive intact.
static std::vector<std::string> utf8_args() {
  std::vector<std::string> out;
  int argc = 0;
  LPWSTR* wargv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!wargv) return out;
  for (int i = 0; i < argc; i++) {
    int len = WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, nullptr, 0, nullptr,
                                  nullptr);
    std::string s(len > 0 ? len - 1 : 0, '\0');
    if (len > 0) {
      WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, s.data(), len, nullptr,
                          nullptr);
    }
    out.push_back(std::move(s));
  }
  LocalFree(wargv);
  return out;
}
#endif

int main(int argc, char** argv) {
#ifdef _WIN32
  std::vector<std::string> args = utf8_args();
#else
  std::vector<std::string> args(argv, argv + argc);
#endif
  if (args.size() < 4) {
    std::fprintf(stderr,
                 "usage: %s <dict_dir> <query_term> <expected_title>\n",
                 args.empty() ? "dict_name_lifetime_test" : args[0].c_str());
    return 2;
  }
  const std::string dict_dir = args[1];
  const std::string term = args[2];
  const std::string expected_title = args[3];

  DictionaryQuery q;
  q.add_term_dict(dict_dir);

  std::vector<TermResult> results = q.query(term);
  if (results.empty()) {
    std::fprintf(stderr, "QUERY FAILED: no results for '%s'\n", term.c_str());
    return 1;
  }

  size_t checked = 0;
  for (const TermResult& t : results) {
    for (const GlossaryEntry& g : t.glossaries) {
      checked++;
      if (g.dict_name != expected_title) {
        std::fprintf(stderr,
                     "FAIL: dict_name mismatch — expected '%s', got '%s' "
                     "(use-after-free corrupted the title's leading bytes)\n",
                     expected_title.c_str(), g.dict_name.c_str());
        return 1;
      }
    }
  }
  if (checked == 0) {
    std::fprintf(stderr, "FAIL: no glossaries to check\n");
    return 1;
  }

  std::printf("PASS: %zu glossaries, dict_name == '%s'\n", checked,
              expected_title.c_str());
  return 0;
}
