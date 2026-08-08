// MDX glossaries are HTML that <link> a sibling stylesheet (Foo.mdx -> Foo.css).
// import_mdx must inline that sibling .css as the dictionary's styles.css so the
// popup can scope+inject it; otherwise definitions render unstyled. This test
// writes a real .mdx + sibling .css to disk, imports, and asserts the dict's
// styles.css exists with matching bytes.
//
// Red/green: revert import_mdx's read_sibling_css wiring and styles.css is
// absent -> FAIL.
//
// Usage: simple_dict_css_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "fushidicts/importer.hpp"
#include "mdx_fixture.hpp"
#include "zip_fixture.hpp"

namespace {
int g_fail = 0;
void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}
}  // namespace

int main() {
  const std::string base = fushi_test::temp_dir() + "/hoshi_mdx_css";
  std::filesystem::create_directories(std::filesystem::u8path(base));
  const std::string mdx_path = base + "/CssDict.mdx";
  const std::string css_path = base + "/CssDict.css";
  const std::string out_dir = base + "/out";
  const std::string css = "body{color:red}\n.hoshi{font-weight:bold}";

  auto bytes = mdx_fixture::build_mdx_plain(
      "CssDict", {{"apple", "<link rel=\"stylesheet\" href=\"CssDict.css\">def-apple"}});
  {
    std::ofstream f(std::filesystem::u8path(mdx_path), std::ios::binary);
    f.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
  }
  {
    std::ofstream f(std::filesystem::u8path(css_path), std::ios::binary);
    f.write(css.data(), static_cast<std::streamsize>(css.size()));
  }

  ImportResult r = dictionary_importer::import(mdx_path, out_dir);
  if (!r.success) {
    fail(r.errors.empty() ? "import failed" : r.errors.front().c_str());
  } else {
    const std::string styles_path = out_dir + "/" + r.title + "/styles.css";
    std::ifstream sf(std::filesystem::u8path(styles_path), std::ios::binary);
    if (!sf) {
      fail("styles.css was not written from sibling .css");
    } else {
      std::string got((std::istreambuf_iterator<char>(sf)), std::istreambuf_iterator<char>());
      if (got != css) {
        std::fprintf(stderr, "FAIL styles.css: got '%s' want '%s'\n", got.c_str(), css.c_str());
        ++g_fail;
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
