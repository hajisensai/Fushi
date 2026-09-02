// An MDX's stylesheet is named by its own <link> tag, not by the .mdx stem.
//
// Real dictionaries ship e.g. "NLT（話し言葉）.mdx" whose every entry carries
// <link href="NLT.css">. import_mdx used to look only for the stem-named
// sibling ("NLT（話し言葉）.css"), found nothing, wrote no styles.css, and the
// definitions rendered unstyled — tables lost their borders and the columns the
// sheet hides with display:none showed up.
//
// Guard: the stylesheet the entries actually <link> wins, and it is inlined as
// the dictionary's styles.css (the popup scopes that per dictionary; letting the
// rewritten <link> fetch it instead would apply bare table/th/td rules to every
// dictionary in the shared popup document).
//
// Red/green: make read_sibling_css consult only the stem again and the decoy
// below is picked up instead of the linked sheet -> FAIL.
//
// Usage: mdx_linked_css_name_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
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

void write_text(const std::string& path, const std::string& text) {
  std::ofstream f(std::filesystem::u8path(path), std::ios::binary);
  f.write(text.data(), static_cast<std::streamsize>(text.size()));
}

std::string read_text(const std::string& path) {
  std::ifstream f(std::filesystem::u8path(path), std::ios::binary);
  if (!f) return {};
  return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}
}  // namespace

int main() {
  const std::string base = fushi_test::temp_dir() + "/fushi_mdx_linked_css";
  std::filesystem::remove_all(std::filesystem::u8path(base));
  std::filesystem::create_directories(std::filesystem::u8path(base));

  // Stem is "FreqDict"; the stylesheet the entries link is named differently.
  const std::string mdx_path = base + "/FreqDict.mdx";
  const std::string linked_css_path = base + "/NltStyle.css";
  const std::string decoy_css_path = base + "/FreqDict.css";
  const std::string out_dir = base + "/out";

  const std::string linked_css = "th{background:#2B8E58}\ntd:nth-child(5){display:none}";
  const std::string decoy_css = "/* stem-named decoy: must lose to the linked sheet */";

  // Entry HTML shaped like a real MDX frequency dictionary: a <link> to the
  // stylesheet, a <script> beside it, then the table.
  const std::string definition =
      "<link rel=\"stylesheet\" type=\"text/css\" href=\"NltStyle.css\" />\n"
      "<script src=\"NltStyle.js\" type=\"text/javascript\"></script>\n"
      "<table><tr><th>\xE9\xA0\xBB\xE5\xBA\xA6</th></tr></table>";

  auto bytes = mdx_fixture::build_mdx_plain("FreqDict", {{"apple", definition}});
  {
    std::ofstream f(std::filesystem::u8path(mdx_path), std::ios::binary);
    f.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
  }
  write_text(linked_css_path, linked_css);
  write_text(decoy_css_path, decoy_css);

  ImportResult r = dictionary_importer::import(mdx_path, out_dir);
  if (!r.success) {
    fail(r.errors.empty() ? "import failed" : r.errors.front().c_str());
  } else {
    const std::string got = read_text(out_dir + "/" + r.title + "/styles.css");
    if (got.empty()) {
      fail("styles.css was not written from the <link>-named stylesheet");
    } else if (got == decoy_css) {
      fail("styles.css came from the stem-named decoy, not the <link>-named sheet");
    } else if (got != linked_css) {
      std::fprintf(stderr, "FAIL styles.css: got '%s' want '%s'\n", got.c_str(), linked_css.c_str());
      ++g_fail;
    }
  }

  // The stem-named sibling stays the fallback when no entry links a stylesheet.
  {
    const std::string base2 = fushi_test::temp_dir() + "/fushi_mdx_stem_css";
    std::filesystem::remove_all(std::filesystem::u8path(base2));
    std::filesystem::create_directories(std::filesystem::u8path(base2));
    const std::string mdx2 = base2 + "/PlainDict.mdx";
    const std::string css2 = base2 + "/PlainDict.css";
    const std::string out2 = base2 + "/out";
    const std::string stem_css = "body{color:red}";

    auto b2 = mdx_fixture::build_mdx_plain("PlainDict", {{"apple", "no link here"}});
    {
      std::ofstream f(std::filesystem::u8path(mdx2), std::ios::binary);
      f.write(reinterpret_cast<const char*>(b2.data()), static_cast<std::streamsize>(b2.size()));
    }
    write_text(css2, stem_css);

    ImportResult r2 = dictionary_importer::import(mdx2, out2);
    if (!r2.success) {
      fail(r2.errors.empty() ? "stem-fallback import failed" : r2.errors.front().c_str());
    } else if (read_text(out2 + "/" + r2.title + "/styles.css") != stem_css) {
      fail("stem-named sibling fallback stopped working");
    }
  }

  // A traversing href must never be resolved: no styles.css may appear, and the
  // file it points at must not be read.
  {
    const std::string base3 = fushi_test::temp_dir() + "/fushi_mdx_escape_css";
    std::filesystem::remove_all(std::filesystem::u8path(base3));
    std::filesystem::create_directories(std::filesystem::u8path(base3 + "/dict"));
    const std::string secret = base3 + "/secret.css";
    write_text(secret, "SECRET-SHOULD-NOT-BE-READ");

    const std::string mdx3 = base3 + "/dict/EscapeDict.mdx";
    const std::string out3 = base3 + "/out";
    auto b3 = mdx_fixture::build_mdx_plain(
        "EscapeDict", {{"apple", "<link rel=\"stylesheet\" href=\"../secret.css\">x"}});
    {
      std::ofstream f(std::filesystem::u8path(mdx3), std::ios::binary);
      f.write(reinterpret_cast<const char*>(b3.data()), static_cast<std::streamsize>(b3.size()));
    }

    ImportResult r3 = dictionary_importer::import(mdx3, out3);
    if (!r3.success) {
      fail(r3.errors.empty() ? "escape-case import failed" : r3.errors.front().c_str());
    } else if (read_text(out3 + "/" + r3.title + "/styles.css").find("SECRET") != std::string::npos) {
      fail("a ../ href escaped the dictionary directory");
    }
  }

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
