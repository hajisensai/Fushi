// MdxBuilder writes the literal placeholder "Title (No HTML code allowed)" into
// the header when the author leaves the title empty. The importer only fell back
// to the file name for an EMPTY title, so every untitled .mdx imported under the
// same placeholder name and later ones were skipped as duplicates (feedback
// cto-U3CIS_).
//
// Guard: two untitled .mdx files import under their own file stems; a real
// title still wins over the stem.
//
// Red/green: drop the is_placeholder_mdx_title() normalization in mdx_reader.cpp
// and both imports come back titled "Title (No HTML code allowed)" -> FAIL.
//
// Usage: mdx_placeholder_title_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <filesystem>
#include <string>

#include "fushidicts/importer.hpp"
#include "media_fixture.hpp"
#include "mdx_fixture.hpp"
#include "zip_fixture.hpp"

namespace {
using fushi_test::fail;
using fushi_test::write_bytes;

std::string import_title(const std::string& base, const std::string& stem,
                         const std::string& header_title) {
  const std::string mdx_path = base + "/" + stem + ".mdx";
  write_bytes(mdx_path, mdx_fixture::build_mdx_plain(header_title, {{"apple", "<b>apple</b>"}}));
  ImportResult r = dictionary_importer::import(mdx_path, base + "/out");
  if (!r.success) {
    fail(r.errors.empty() ? "import failed" : r.errors.front().c_str());
    return {};
  }
  return r.title;
}
}  // namespace

int main() {
  const std::string base = fushi_test::temp_dir() + "/fushi_mdx_placeholder_title";
  std::filesystem::remove_all(std::filesystem::u8path(base));
  std::filesystem::create_directories(std::filesystem::u8path(base));

  if (import_title(base, "Oxford", "Title (No HTML code allowed)") != "Oxford") {
    fail("placeholder title must fall back to the file stem (Oxford)");
  }
  if (import_title(base, "Collins", " Title (No HTML code allowed) ") != "Collins") {
    fail("padded placeholder title must fall back to the file stem (Collins)");
  }
  if (import_title(base, "Blank", "   ") != "Blank") {
    fail("blank title must fall back to the file stem (Blank)");
  }
  if (import_title(base, "stem", "Real Name") != "Real Name") {
    fail("a real header title must still win over the stem");
  }

  std::filesystem::remove_all(std::filesystem::u8path(base));
  if (fushi_test::g_fail == 0) std::printf("PASS mdx_placeholder_title_test\n");
  return fushi_test::g_fail == 0 ? 0 : 1;
}
