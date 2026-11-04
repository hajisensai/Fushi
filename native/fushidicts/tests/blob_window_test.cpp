// BUG-4013 guard: the windowed blobs.bin path (what a 32-bit process uses)
// returns byte-identical query results to the whole-file mapping.
//
// Why: a 32-bit process (Android armeabi-v7a) has ~3 GB of address space; a
// large dictionary's blobs.bin cannot be mapped contiguously and the dictionary
// silently failed to load. memory::blob_file serves such files through 2 MB
// windows in a bounded LRU, plus heap reads for spans longer than a window.
// Pointers into windows escape into term_map keys and lazily-decompressed
// GlossaryEntry blobs, so eviction while results are alive must not unmap them.
//
// The fixture is built so the paths that matter are actually hit:
//   - several MB of poorly compressible glossaries -> records and glossaries
//     land in many different windows and straddle window boundaries;
//   - one glossary whose compressed size exceeds a window step -> heap path;
//   - the LRU budget forced down to a single window -> constant eviction while
//     earlier results are still pinned.
//
// Usage: blob_window_test   (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdint>
#include <cstdio>
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

// Deterministic, poorly compressible ASCII (JSON-safe alphabet).
std::string noise(uint64_t seed, size_t n) {
  static const char kAlphabet[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  std::string out(n, 'x');
  uint64_t x = seed * 0x9E3779B97F4A7C15ull + 1;
  for (size_t i = 0; i < n; ++i) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    out[i] = kAlphabet[x % (sizeof(kAlphabet) - 1)];
  }
  return out;
}

constexpr int kTerms = 2500;
constexpr size_t kGlossaryBytes = 3000;
const std::string kHugeTerm = "huge";

std::string term_name(int i) { return "w" + std::to_string(i); }

std::string term_bank() {
  std::string out = "[";
  for (int i = 0; i < kTerms; ++i) {
    out += "[\"" + term_name(i) + "\",\"r" + std::to_string(i) + "\",\"\",\"\",0,[\"" +
           noise(static_cast<uint64_t>(i), kGlossaryBytes) + "\"],0,\"\"],";
  }
  // Compressed well past one window step (noise compresses to ~75%).
  out += "[\"" + kHugeTerm + "\",\"\",\"\",\"\",0,[\"" + noise(999999, 3u << 20) + "\"],0,\"\"]]";
  return out;
}

// Every term's materialized glossaries, in query order.
std::vector<std::vector<std::string>> query_all(const DictionaryQuery& q) {
  std::vector<std::vector<std::string>> out;
  for (int i = 0; i <= kTerms; ++i) {
    const std::string term = i == kTerms ? kHugeTerm : term_name(i);
    std::vector<std::string> glossaries;
    for (const TermResult& r : q.query(term)) {
      for (const GlossaryEntry& g : r.glossaries) {
        glossaries.push_back(g.glossary);
      }
    }
    out.push_back(std::move(glossaries));
  }
  return out;
}

}  // namespace

int main() {
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_blob_window_out";
  std::vector<fushi_test::ZipFile> files = {
      {"index.json", "{\"title\":\"WindowDict\",\"format\":3,\"revision\":\"t\"}"},
      {"term_bank_1.json", term_bank()},
  };
  const std::string zip_path = fushi_test::write_zip("blob_window", files);
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

  memory::set_blob_mode_for_test(memory::blob_mode::whole);
  std::vector<std::vector<std::string>> expected;
  {
    DictionaryQuery q;
    q.add_term_dict(dict_dir);
    expected = query_all(q);
  }
  const auto blobs = memory::open_blob_file(dict_dir + "/blobs.bin");
  if (!blobs || blobs->windowed() || blobs->size() < 3 * memory::blob_file::kWindowBytes) {
    fail("fixture blobs.bin too small to span several windows");
  }
  for (int i = 0; i <= kTerms; ++i) {
    if (expected[static_cast<size_t>(i)].size() != 1) {
      fail("whole-file baseline missing term " + std::to_string(i));
      break;
    }
  }
  // The materialized glossary is the stored JSON form, so it is the payload plus framing.
  if (expected.back().empty() || expected.back()[0].find(noise(999999, 64)) == std::string::npos ||
      expected.back()[0].size() < (3u << 20)) {
    fail("whole-file baseline lost the huge glossary");
  }

  // Windowed, with the LRU squeezed to one window: every query evicts.
  memory::set_blob_mode_for_test(memory::blob_mode::windowed);
  memory::set_blob_window_cache_bytes_for_test(memory::blob_file::kWindowBytes);
  {
    DictionaryQuery q;
    q.add_term_dict(dict_dir);
    if (q.query(term_name(0)).empty()) {
      fail("windowed engine did not load the dictionary");
    }
    const auto windowed = memory::open_blob_file(dict_dir + "/blobs.bin");
    if (!windowed || !windowed->windowed() || memory::cached_blob_windows() == 0) {
      fail("windowed path was not exercised");
    }
    if (query_all(q) != expected) {
      fail("windowed results differ from whole-file results (1-window budget)");
    }
    if (memory::cached_blob_windows() > 1) {
      fail("LRU exceeded its budget: " + std::to_string(memory::cached_blob_windows()) + " windows");
    }
    // Media / scans also go through the same file; lookups from a second
    // engine share the windowed blob_file.
    DictionaryQuery q2;
    q2.add_term_dict(dict_dir);
    if (query_all(q2) != expected) {
      fail("second windowed engine differs");
    }
  }
  if (memory::cached_blob_windows() != 0) {
    fail("windows outlived every engine: " + std::to_string(memory::cached_blob_windows()));
  }

  // Default budget: results still identical.
  memory::set_blob_window_cache_bytes_for_test(0);
  {
    DictionaryQuery q;
    q.add_term_dict(dict_dir);
    if (query_all(q) != expected) {
      fail("windowed results differ from whole-file results (default budget)");
    }
  }
  memory::set_blob_mode_for_test(memory::blob_mode::automatic);

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
