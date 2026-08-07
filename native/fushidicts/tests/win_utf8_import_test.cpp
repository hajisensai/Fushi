// BUG-045 end-to-end guard: importing + reading back a dictionary whose path /
// title contains non-ASCII (UTF-8) characters must succeed on Windows. Before
// the fs_utf8 fix this failed at zip.open() with
// "unsupported format or failed to open file" (CreateFileA / ANSI path decode).
//
// Usage: win_utf8_import_test <utf8_zip_path> <utf8_output_dir>
// Exit 0 on success, non-zero (with a message) on any failure.
#include <cstdio>
#include <string>

#include "hoshidicts/importer.hpp"
#include "hoshidicts/query.hpp"

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <zip_path> <output_dir>\n", argv[0]);
    return 2;
  }
  const std::string zip_path = argv[1];
  const std::string output_dir = argv[2];

  ImportResult r = dictionary_importer::import(zip_path, output_dir);
  if (!r.success) {
    std::fprintf(stderr, "IMPORT FAILED: %s\n",
                 r.errors.empty() ? "(no error)" : r.errors.front().c_str());
    return 1;
  }
  std::printf("import OK: title='%s' detected_type='%s'\n", r.title.c_str(),
              r.detected_type.c_str());

  const std::string dict_path = output_dir + "/" + r.title;
  DictionaryQuery q;
  q.add_term_dict(dict_path);
  std::vector<TermResult> results = q.query("\xe6\x97\xa5\xe6\x9c\xac");  // "日本" in UTF-8
  if (results.empty()) {
    std::fprintf(stderr, "QUERY FAILED: no results for expression\n");
    return 1;
  }
  std::printf("query OK: expression='%s' reading='%s' glossaries=%zu\n",
              results.front().expression.c_str(),
              results.front().reading.c_str(),
              results.front().glossaries.size());
  std::printf("PASS\n");
  return 0;
}
