// A real .mdd declares `<Library_Data … Encoding="">` and keys its files with
// UTF-16LE paths. Defaulting that empty Encoding to UTF-8 made the key-block
// scan walk single-byte NULs through UTF-16 data: every key offset drifted and
// the parse aborted with "record block info overflow". The companion was then
// silently skipped ("continuing without this part"), so the dictionary lost its
// entire media store — fonts, images, audio and scripts alike — while the
// import still reported success.
//
// Guard: such an .mdd auto-mounts and its files come back byte-exact under
// their normalized paths.
//
// Red/green: default the empty Encoding back to "utf-8" and every lookup below
// misses (the mdd fails to parse at all).
//
// Usage: mdd_empty_encoding_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "fushidicts/importer.hpp"
#include "fushidicts/query.hpp"
#include "mdx_fixture.hpp"
#include "zip_fixture.hpp"

namespace {
int g_fail = 0;
void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

void write_bytes(const std::string& path, const std::vector<uint8_t>& bytes) {
  std::ofstream f(std::filesystem::u8path(path), std::ios::binary);
  f.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
}
}  // namespace

int main() {
  const std::string base = fushi_test::temp_dir() + "/fushi_mdd_empty_encoding";
  std::filesystem::remove_all(std::filesystem::u8path(base));
  std::filesystem::create_directories(std::filesystem::u8path(base));

  const std::string mdx_path = base + "/EncDict.mdx";
  const std::string mdd_path = base + "/EncDict.mdd";
  const std::string out_dir = base + "/out";

  // Paths shaped like the real thing: backslash-separated, with a leading one.
  const std::string script = "window.__probe = 1;\n";
  const std::string font = std::string("\x00\x01\x00\x00OTTO", 8) + std::string("FONTBYTES", 9);
  const std::string svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>";

  auto mdd = mdx_fixture::build_mdd_utf16_library_data("Untitled Dictionary",
                                                       {
                                                           {"\\scripts\\dict-jquery.js", script},
                                                           {"\\fonts\\Bookerly-Regular.ttf", font},
                                                           {"\\images\\level_a1.svg", svg},
                                                       });
  auto mdx = mdx_fixture::build_mdx_plain(
      "EncDict", {{"apple", "<script src=\"scripts/dict-jquery.js\"></script>def-apple"}});
  write_bytes(mdx_path, mdx);
  write_bytes(mdd_path, mdd);

  ImportResult r = dictionary_importer::import(mdx_path, out_dir);
  if (!r.success) {
    fail(r.errors.empty() ? "import failed" : r.errors.front().c_str());
  } else {
    const std::string dict_dir = out_dir + "/" + r.title;
    if (!std::filesystem::exists(std::filesystem::u8path(dict_dir + "/media.bin"))) {
      fail("media.bin absent — the .mdd was skipped entirely");
    }

    DictionaryQuery q;
    q.add_term_dict(dict_dir);

    struct Expect {
      const char* path;
      const std::string* want;
    };
    const Expect expects[] = {
        {"scripts/dict-jquery.js", &script},
        {"fonts/Bookerly-Regular.ttf", &font},
        {"images/level_a1.svg", &svg},
    };
    for (const auto& e : expects) {
      std::vector<char> got = q.get_media_file(r.title, e.path);
      if (got.empty()) {
        std::fprintf(stderr, "FAIL: '%s' missing from the media store\n", e.path);
        ++g_fail;
      } else if (std::string(got.begin(), got.end()) != *e.want) {
        std::fprintf(stderr, "FAIL: '%s' bytes differ (got %zu want %zu)\n", e.path, got.size(),
                     e.want->size());
        ++g_fail;
      }
    }
  }

  // An .mdd that DOES declare an encoding must keep being taken at its word —
  // the legacy `<Dictionary … Encoding="UTF-8">` fixture shape still works.
  {
    const std::string base2 = fushi_test::temp_dir() + "/fushi_mdd_declared_encoding";
    std::filesystem::remove_all(std::filesystem::u8path(base2));
    std::filesystem::create_directories(std::filesystem::u8path(base2));
    const std::string mdx2 = base2 + "/LegacyDict.mdx";
    const std::string mdd2 = base2 + "/LegacyDict.mdd";
    const std::string out2 = base2 + "/out";
    const std::string blob = "LEGACY-BYTES";

    write_bytes(mdd2, mdx_fixture::build_mdd_plain("Legacy", {{"img/a.png", blob}}));
    write_bytes(mdx2, mdx_fixture::build_mdx_plain("LegacyDict", {{"apple", "def"}}));

    ImportResult r2 = dictionary_importer::import(mdx2, out2);
    if (!r2.success) {
      fail(r2.errors.empty() ? "legacy mdd import failed" : r2.errors.front().c_str());
    } else {
      DictionaryQuery q2;
      q2.add_term_dict(out2 + "/" + r2.title);
      std::vector<char> got = q2.get_media_file(r2.title, "img/a.png");
      if (std::string(got.begin(), got.end()) != blob) {
        fail("a UTF-8-declaring .mdd regressed");
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
