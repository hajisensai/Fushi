// BUG-4013 guard: dictionary file mappings are shared process-wide by file
// identity, and media.bin is never mapped.
//
// Why: Dart reloads dictionaries by building a whole new engine (the
// `loadPendingAsync` shadow) while the old engine -- and any handle a
// background isolate still borrows -- stays alive. With one private mapping per
// engine every overlap added another full copy of the dictionary set to the
// virtual address space (~3.8 GB per copy on the reporting iPhone), which
// exhausted iOS's address-space limit; media.bin alone was ~1.6 GB of that and
// is only read when a popup shows an image or plays audio.
//
// Pins:
//   1. Two engines loading the same dictionary hold ONE set of mappings.
//   2. Mappings live exactly as long as the last engine holding them.
//   3. media.bin is not held open/mapped between requests: it can be removed
//      while an engine is loaded (Windows refuses to delete a mapped file), and
//      a missing / replaced media.bin degrades to a miss instead of a crash.
//
// Usage: shared_mapping_test   (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include "fushidicts/importer.hpp"
#include "fushidicts/query.hpp"
#include "memory/memory.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

std::string term_bank() {
  return "[[\"\xE6\x97\xA5\",\"\xE3\x81\xB2\",\"\",\"\",0,"
         "[{\"type\":\"structured-content\","
         "\"content\":{\"tag\":\"img\",\"path\":\"img/sun.png\"}}],"
         "0,\"\"]]";
}

}  // namespace

int main() {
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_shared_mapping_out";
  const std::string png = std::string("\x89PNG\r\n\x1a\n", 8) + std::string("SHARED", 6);

  std::vector<fushi_test::ZipFile> files = {
      {"index.json", "{\"title\":\"SharedDict\",\"format\":3,\"revision\":\"t\"}"},
      {"term_bank_1.json", term_bank()},
      {"img/sun.png", png},
  };
  const std::string zip_path = fushi_test::write_zip("shared_mapping", files);
  if (zip_path.empty()) {
    fail("could not write fixture zip");
    return 1;
  }
  const ImportResult r = dictionary_importer::import(zip_path, out_dir);
  if (!r.success) {
    fail("import: " + (r.errors.empty() ? std::string("(no error)") : r.errors.front()));
    return 1;
  }
  const std::string dict_dir = out_dir + "/" + r.title;
  const size_t base = memory::live_shared_mappings();

  auto q1 = std::make_unique<DictionaryQuery>();
  q1->add_term_dict(dict_dir);
  const size_t one_engine = memory::live_shared_mappings();
  // hash.table + blobs.bin at minimum (bloom.filter / media.idx when present).
  if (one_engine < base + 2) {
    fail("first engine registered " + std::to_string(one_engine - base) + " shared mappings, want >= 2");
  }

  // 1. A second engine over the same files must reuse every mapping.
  auto q2 = std::make_unique<DictionaryQuery>();
  q2->add_term_dict(dict_dir);
  if (memory::live_shared_mappings() != one_engine) {
    fail("second engine added mappings: " + std::to_string(memory::live_shared_mappings()) + " vs " +
         std::to_string(one_engine));
  }

  // 2. Dropping one engine keeps the other's mappings valid and queryable.
  q1.reset();
  if (memory::live_shared_mappings() != one_engine) {
    fail("mappings released while another engine still holds them");
  }
  if (q2->query("\xE6\x97\xA5").empty()) {
    fail("surviving engine lost its dictionary after the other was destroyed");
  }
  std::vector<char> hit = q2->get_media_file(r.title, "img/sun.png");
  if (std::string(hit.begin(), hit.end()) != png) {
    fail("media read via positional reader returned wrong bytes");
  }

  // 3. media.bin is not held between requests: replacing it with a different
  //    size must miss (index no longer matches), removing it must miss, and on
  //    Windows the removal itself proves no mapping/handle pins the file.
  const std::filesystem::path media = std::filesystem::path(dict_dir) / "media.bin";
  {
    std::ofstream(media, std::ios::binary | std::ios::trunc) << "different-size-payload";
  }
  if (!q2->get_media_file(r.title, "img/sun.png").empty()) {
    fail("replaced media.bin (size mismatch) should read as a miss");
  }
  std::error_code ec;
  std::filesystem::remove(media, ec);
  if (ec) {
    fail("media.bin could not be removed while an engine is loaded (still mapped/open?): " + ec.message());
  }
  if (!q2->get_media_file(r.title, "img/sun.png").empty()) {
    fail("missing media.bin should read as a miss");
  }

  q2.reset();
  if (memory::live_shared_mappings() != base) {
    fail("mappings outlived the last engine: " + std::to_string(memory::live_shared_mappings()) + " vs base " +
         std::to_string(base));
  }

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
