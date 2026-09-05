// MDX entries reference their scripts with a bare <script src="foo.js">, and
// that file sits NEXT TO the .mdx rather than inside the .mdd. Without folding
// it into the media store there is no way to fetch it by name, so the popup
// would have to grow a second, path-based channel just for loose scripts.
//
// Guard: a sibling .js named by the entries lands in the media store under its
// bare name, alongside whatever the .mdd already provided, and a script the
// entries never mention is not swept in.
//
// Red/green: drop the extra_files wiring in import_mdx and "dict-main.js" is
// missing from the store.
//
// Usage: mdx_sibling_script_media_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "fushidicts/importer.hpp"
#include "fushidicts/query.hpp"
#include "media_fixture.hpp"
#include "mdx_fixture.hpp"
#include "zip_fixture.hpp"

namespace {
using fushi_test::fail;
using fushi_test::media_str;
using fushi_test::write_bytes;
using fushi_test::write_text;
}  // namespace

int main() {
  const std::string base = fushi_test::temp_dir() + "/fushi_mdx_sibling_script";
  std::filesystem::remove_all(std::filesystem::u8path(base));
  std::filesystem::create_directories(std::filesystem::u8path(base));

  const std::string mdx_path = base + "/ScriptDict.mdx";
  const std::string mdd_path = base + "/ScriptDict.mdd";
  const std::string out_dir = base + "/out";

  const std::string main_js = "window.__dictMain = 1;\n";
  const std::string unused_js = "window.__neverReferenced = 1;\n";
  const std::string jquery_js = "window.__dictJquery = 1;\n";

  // Entry HTML shaped like a real dictionary: a bare sibling script, a script
  // that lives in a .mdd subdirectory, and an inline one.
  const std::string definition =
      "<link rel=\"stylesheet\" href=\"ScriptDict.css\">"
      "<div class=\"entry\">def</div>"
      "<script src=\"dict-main.js\"></script>"
      "<script src=\"scripts/dict-jquery.js\"></script>"
      "<script>window.__inline = 1;</script>";

  write_bytes(mdx_path, mdx_fixture::build_mdx_plain("ScriptDict", {{"apple", definition}}));
  write_bytes(mdd_path, mdx_fixture::build_mdd_utf16_library_data(
                            "Untitled", {{"\\scripts\\dict-jquery.js", jquery_js}}));
  write_text(base + "/dict-main.js", main_js);
  write_text(base + "/unreferenced.js", unused_js);

  ImportResult r = dictionary_importer::import(mdx_path, out_dir);
  if (!r.success) {
    fail(r.errors.empty() ? "import failed" : r.errors.front().c_str());
  } else {
    DictionaryQuery q;
    q.add_term_dict(out_dir + "/" + r.title);

    if (media_str(q, r.title, "dict-main.js") != main_js) {
      fail("the sibling script named by <script src> is not in the media store");
    }
    if (media_str(q, r.title, "scripts/dict-jquery.js") != jquery_js) {
      fail("the .mdd script regressed when loose siblings joined the store");
    }
    if (!q.get_media_file(r.title, "unreferenced.js").empty()) {
      fail("a sibling script the entries never reference was swept in");
    }
  }

  // A dictionary with NO .mdd at all must still get a media store created for
  // its loose script — that is the NLT shape.
  {
    const std::string base2 = fushi_test::temp_dir() + "/fushi_mdx_script_no_mdd";
    std::filesystem::remove_all(std::filesystem::u8path(base2));
    std::filesystem::create_directories(std::filesystem::u8path(base2));
    const std::string mdx2 = base2 + "/FreqDict.mdx";
    const std::string out2 = base2 + "/out";
    const std::string js2 = "document.addEventListener('DOMContentLoaded', function(){});\n";

    write_bytes(mdx2, mdx_fixture::build_mdx_plain(
                          "FreqDict", {{"apple", "<script src=\"NLT.js\"></script><table></table>"}}));
    write_text(base2 + "/NLT.js", js2);

    ImportResult r2 = dictionary_importer::import(mdx2, out2);
    if (!r2.success) {
      fail(r2.errors.empty() ? "no-mdd import failed" : r2.errors.front().c_str());
    } else {
      DictionaryQuery q2;
      q2.add_term_dict(out2 + "/" + r2.title);
      if (media_str(q2, r2.title, "NLT.js") != js2) {
        fail("a dictionary without any .mdd got no media store for its loose script");
      }
    }
  }

  if (fushi_test::g_fail) {
    std::fprintf(stderr, "%d FAIL\n", fushi_test::g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
