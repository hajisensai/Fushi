// MDD is the MDX media companion (same container, binary records keyed by file
// path). This test covers two levels:
//   1) mdx_reader::parse_mdd returns each record byte-exact (incl. embedded NUL)
//      with its raw path key -- no transcoding, no NUL stripping, no @@@LINK.
//   2) end-to-end: importing Foo.mdx auto-mounts sibling Foo.mdd PLUS numbered
//      overflow parts Foo.1.mdd / Foo.2.mdd (BUG-1261) into one merged media
//      store, and DictionaryQuery::get_media_file returns the bytes via the
//      normalized path -- exactly the image:// scheme the popup consumes.
//
// Red/green: revert parse_mdd (binary records) or import_mdx's sibling mount and
// the retrieved blob is empty / wrong -> FAIL.
//
// Usage: mdd_media_import_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "hoshidicts/importer.hpp"
#include "hoshidicts/query.hpp"
#include "mdx_fixture.hpp"
#include "mdx_reader.hpp"
#include "zip_fixture.hpp"

namespace {
int g_fail = 0;
void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

void write_file(const std::string& path, const std::vector<uint8_t>& bytes) {
  std::ofstream f(std::filesystem::u8path(path), std::ios::binary);
  f.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
}
}  // namespace

int main() {
  // A fake PNG blob with an embedded NUL and a high byte, to prove byte-exact
  // handling (a real image legitimately contains 0x00).
  const std::string png("\x89PNG\x0D\x0A\x1A\x0A\x00\x01\xFF\x00T", 14);
  const std::string mdd_key = "\\img\\a.png";  // real MDD keys use backslashes

  // --- Part 1: parse_mdd byte-exactness -----------------------------------
  {
    auto mdd_bytes = mdx_fixture::build_mdd_plain("MediaDict", {{mdd_key, png}});
    auto media = mdx_reader::parse_mdd(mdd_bytes.data(), mdd_bytes.size());
    if (media.size() != 1) {
      fail("parse_mdd expected 1 record");
    } else {
      if (media[0].path != mdd_key) {
        std::fprintf(stderr, "FAIL parse_mdd path: got '%s' want '%s'\n", media[0].path.c_str(),
                     mdd_key.c_str());
        ++g_fail;
      }
      if (media[0].blob != png) {
        std::fprintf(stderr, "FAIL parse_mdd blob byte-exactness (got %zu bytes want %zu)\n",
                     media[0].blob.size(), png.size());
        ++g_fail;
      }
    }
  }

  // --- Part 2: import Foo.mdx + sibling Foo.mdd + numbered overflow parts ---
  // BUG-1261: MDict splits large media across Foo.mdd / Foo.1.mdd / Foo.2.mdd
  // (OALD ships all pronunciation mp3 in the numbered parts). All parts must
  // merge into ONE media.bin/media.idx: every key from every part retrievable.
  // Red/green: revert collect_sibling_mdd_paths -> uk/us mp3 missing; revert
  // the merged single-index write (per-part truncation) -> img/a.png missing.
  const std::string base = hoshi_test::temp_dir() + "/hoshi_mdd";
  std::filesystem::create_directories(std::filesystem::u8path(base));
  const std::string mdx_path = base + "/M.mdx";
  const std::string out_dir = base + "/out";

  const std::string mp3_uk("\xFF\xFB\x90\x00UK-FRAME\x00\x01", 12);
  const std::string mp3_us("\xFF\xFB\x90\x00US-FRAME\xFE", 11);

  write_file(mdx_path,
             mdx_fixture::build_mdx_plain("MediaDict", {{"apple", "<img src=\"img/a.png\">def"}}));
  write_file(base + "/M.mdd", mdx_fixture::build_mdd_plain("MediaDict", {{mdd_key, png}}));
  write_file(base + "/M.1.mdd",
             mdx_fixture::build_mdd_plain("MediaDict", {{"\\uk\\apple.mp3", mp3_uk}}));
  write_file(base + "/M.2.mdd",
             mdx_fixture::build_mdd_plain("MediaDict", {{"\\us\\apple.mp3", mp3_us}}));

  ImportResult r = dictionary_importer::import(mdx_path, out_dir);
  if (!r.success) {
    fail(r.errors.empty() ? "import failed" : r.errors.front().c_str());
  } else {
    DictionaryQuery q;
    q.add_term_dict(out_dir + "/" + r.title);
    auto expect_media = [&](const char* path, const std::string& want, const char* what) {
      std::vector<char> blob = q.get_media_file(r.title, path);
      if (blob.empty()) {
        std::fprintf(stderr, "FAIL %s: get_media_file empty (part not mounted / index clobbered)\n",
                     what);
        ++g_fail;
      } else if (std::string(blob.begin(), blob.end()) != want) {
        std::fprintf(stderr, "FAIL %s: wrong bytes\n", what);
        ++g_fail;
      }
    };
    expect_media("img/a.png", png, "main .mdd blob");
    expect_media("uk/apple.mp3", mp3_uk, "numbered part .1.mdd blob");
    expect_media("us/apple.mp3", mp3_us, "numbered part .2.mdd blob");
  }

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
