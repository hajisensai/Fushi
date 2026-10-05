// BUG-2952 guard: a dictionary import must end with an ImportResult, never with
// a dead process.
//
// The user-visible report was "DictImport.crashRecovered ... native 词典导入未返回"
// for two ordinary dictionaries (a Yomitan kanji dictionary and an MDX zip) on
// an Android phone. Both import fine with free space; on a (nearly) full volume
// they killed the app:
//   * hash.table / bloom.filter are written through a MAP_SHARED mapping of a
//     file that was only ftruncate()d, i.e. sparse. The first store into each
//     page has to allocate a block; with no space left the kernel answers the
//     page fault with SIGBUS -- uncatchable.
//   * several write failures (MDX extraction, the post-success MDD media write,
//     failure-path cleanup) threw out of dictionary_importer::import instead of
//     becoming ImportResult::errors.
//
// The cases below pin each layer: map_rw reserves real blocks, map_rw failures
// carry an errno, every format path's exceptions stop at the importer, a bad
// kanji record no longer takes its whole bank down, and (POSIX) a write limit
// hit mid-import yields a failed result instead of a signal.
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <system_error>
#include <vector>

#ifndef _WIN32
#include <csignal>
#include <sys/resource.h>
#include <sys/stat.h>
#endif

#include "fushidicts/importer.hpp"
#include "fushidicts/query.hpp"
#include "hash/hash.hpp"
#include "memory/memory.hpp"

#include <utf8.h>

namespace {

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

void put16(std::vector<uint8_t>& b, uint16_t v) {
  b.push_back(static_cast<uint8_t>(v & 0xff));
  b.push_back(static_cast<uint8_t>((v >> 8) & 0xff));
}
void put32(std::vector<uint8_t>& b, uint32_t v) {
  for (int i = 0; i < 4; i++) b.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
}

struct ZipFile {
  std::string name;
  std::string data;
};

// Minimal STORED zip (same layout as the other e2e tests' builders).
std::vector<uint8_t> build_zip(const std::vector<ZipFile>& files) {
  std::vector<uint8_t> z;
  std::vector<uint32_t> lfh_offsets;
  for (const auto& f : files) {
    lfh_offsets.push_back(static_cast<uint32_t>(z.size()));
    put32(z, 0x04034b50);
    put16(z, 20);
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put32(z, 0);
    put32(z, static_cast<uint32_t>(f.data.size()));
    put32(z, static_cast<uint32_t>(f.data.size()));
    put16(z, static_cast<uint16_t>(f.name.size()));
    put16(z, 0);
    for (char c : f.name) z.push_back(static_cast<uint8_t>(c));
    for (char c : f.data) z.push_back(static_cast<uint8_t>(c));
  }
  const size_t cd_off = z.size();
  for (size_t i = 0; i < files.size(); i++) {
    const auto& f = files[i];
    put32(z, 0x02014b50);
    put16(z, 20);
    put16(z, 20);
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put32(z, 0);
    put32(z, static_cast<uint32_t>(f.data.size()));
    put32(z, static_cast<uint32_t>(f.data.size()));
    put16(z, static_cast<uint16_t>(f.name.size()));
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put32(z, 0);
    put32(z, lfh_offsets[i]);
    for (char c : f.name) z.push_back(static_cast<uint8_t>(c));
  }
  const size_t cd_size = z.size() - cd_off;
  put32(z, 0x06054b50);
  put16(z, 0);
  put16(z, 0);
  put16(z, static_cast<uint16_t>(files.size()));
  put16(z, static_cast<uint16_t>(files.size()));
  put32(z, static_cast<uint32_t>(cd_size));
  put32(z, static_cast<uint32_t>(cd_off));
  put16(z, 0);
  return z;
}

std::string tmp_root() {
  const char* tmp = std::getenv("TEMP");
  if (!tmp) tmp = std::getenv("TMPDIR");
  return std::string(tmp ? tmp : ".") + "/fushi_import_boundary";
}

std::string write_zip(const std::string& label, const std::vector<ZipFile>& files) {
  std::filesystem::create_directories(tmp_root());
  std::string path = tmp_root() + "/" + label + ".zip";
  std::vector<uint8_t> bytes = build_zip(files);
  FILE* fp = std::fopen(path.c_str(), "wb");
  if (!fp) return {};
  std::fwrite(bytes.data(), 1, bytes.size(), fp);
  std::fclose(fp);
  return path;
}

std::string fresh_dir(const std::string& label) {
  std::string dir = tmp_root() + "/" + label;
  std::error_code ec;
  std::filesystem::remove_all(dir, ec);
  std::filesystem::create_directories(dir);
  return dir;
}

// Runs the importer; any exception escaping it is the bug this file guards.
bool import_no_throw(const std::string& label, const std::string& zip, const std::string& out, ImportResult& r) {
  try {
    r = dictionary_importer::import(zip, out);
    return true;
  } catch (const std::exception& e) {
    fail(label + ": exception escaped dictionary_importer::import: " + e.what());
  } catch (...) {
    fail(label + ": non-std exception escaped dictionary_importer::import");
  }
  return false;
}

const std::string kHi = "\xE6\x97\xA5";           // 日
const std::string kShitsu = "\xF0\xA0\xAE\x9F";   // 𠮟 (4-byte UTF-8, as in mozc Kanji Variants)
const std::string kIndex = "{\"title\":\"Boundary\",\"format\":3,\"revision\":\"t\"}";

// --- 1. map_rw reserves blocks: the SIGBUS root cause ------------------------
void case_map_rw_reserves_blocks() {
#ifndef _WIN32
  const std::string dir = fresh_dir("map_rw");
  const std::string path = dir + "/reserved.bin";
  constexpr size_t kSize = 4 * 1024 * 1024;
  auto m = memory::map_rw(path, kSize);
  if (!m) {
    fail("map_rw: could not map " + path);
    return;
  }
  struct stat st {};
  if (stat(path.c_str(), &st) != 0) {
    fail("map_rw: stat failed");
  } else if (static_cast<uint64_t>(st.st_blocks) * 512 < kSize) {
    // A sparse file here means block allocation is still deferred to the page
    // faults -> SIGBUS when the disk is full.
    fail("map_rw: file is sparse (" + std::to_string(st.st_blocks * 512) + " of " + std::to_string(kSize) +
         " bytes allocated); a full disk would SIGBUS on first write");
  }
  memory::unmap(m);
#else
  std::fprintf(stderr, "SKIP map_rw block reservation (NTFS SetEndOfFile allocates)\n");
#endif
}

// --- 2. map_rw failures carry an errno -------------------------------------
void case_map_rw_failure_reports_errno() {
  const std::string missing = tmp_root() + "/no/such/dir/hash.table";
  auto m = memory::map_rw(missing, 4096);
  if (m) {
    fail("map_rw into a missing directory unexpectedly succeeded");
    memory::unmap(m);
    return;
  }
  if (memory::last_error() == 0) {
    fail("map_rw failure left last_error() == 0");
  }
  try {
    hash::linear table;
    table.build_to_file({{1, 2}}, missing);
    fail("hash build into a missing directory did not throw");
  } catch (const std::system_error& e) {
    if (e.code().value() == 0) fail("map_error carries no error code");
  } catch (const std::exception& e) {
    fail(std::string("hash build threw a non-system_error: ") + e.what());
  }
}

// --- 3. exceptions from a format path stop at the importer -----------------
void case_mdx_extract_failure_is_a_result() {
  const std::string out = fresh_dir("mdx_out");
  // import_mdx_from_zip creates "<out>/_mdx_temp"; a *file* in its place makes
  // create_directories / the extraction throw, which used to escape import().
  FILE* fp = std::fopen((out + "/_mdx_temp").c_str(), "wb");
  if (fp) std::fclose(fp);
  const std::string zip = write_zip("mdx_extract", {{"a.mdx", std::string(64, 'x')}});
  ImportResult r;
  if (!import_no_throw("mdx_extract", zip, out, r)) return;
  if (r.success) fail("mdx_extract: import into a blocked temp dir reported success");
  if (r.errors.empty()) fail("mdx_extract: failed import carries no error message");
}

// --- 4. a malformed index.json title cannot break the import ----------------
void case_invalid_utf8_title() {
  const std::string out = fresh_dir("utf8_out");
  const std::string index = std::string("{\"title\":\"bad\xFF\xFE title\",\"format\":3,\"revision\":\"t\"}");
  const std::string bank = "[[\"" + kHi + "\",\"\",\"\",\"\",[\"day\"],{}]]";
  const std::string zip = write_zip("utf8_title", {{"index.json", index}, {"kanji_bank_1.json", bank}});
  ImportResult r;
  if (!import_no_throw("utf8_title", zip, out, r)) return;
  if (!r.success) {
    fail("utf8_title: import failed: " + (r.errors.empty() ? std::string("(none)") : r.errors.front()));
    return;
  }
  if (!utf8::is_valid(r.title.begin(), r.title.end())) fail("utf8_title: title is still not valid UTF-8");
}

// --- 5. one malformed kanji record no longer drops its whole bank ----------
void case_kanji_bank_malformed_entries() {
  const std::string out = fresh_dir("kanji_out");
  // mozc Kanji Variants shape: empty readings, "" inside meanings, {} stats,
  // 4-byte character -- plus records with wrong types around it.
  const std::string bank = std::string("[") +
                           "[\"" + kHi + "\",\"nichi\",\"hi\",\"jouyou\",[\"day\",\"\",\"sun\"],{\"strokes\":\"4\"}]," +
                           "[123,\"\",\"\",\"\",[\"number as character\"],{}]," +
                           "[\"x\",\"\",\"\",\"\",\"meanings-not-an-array\",{}]," +
                           "[\"" + kShitsu + "\",\"\",\"\",\"\",[\"\xE7\x95\xB0\xE4\xBD\x93\xE5\xAD\x97\",\"\"],{}]," +
                           "[\"y\",\"\",\"\",\"\",[],\"stats-as-string\"]" + "]";
  const std::string zip = write_zip("kanji_malformed", {{"index.json", kIndex}, {"kanji_bank_1.json", bank}});
  ImportResult r;
  if (!import_no_throw("kanji_malformed", zip, out, r)) return;
  if (!r.success) {
    fail("kanji_malformed: import failed: " + (r.errors.empty() ? std::string("(none)") : r.errors.front()));
    return;
  }
  // 日, 𠮟 and y are well-formed; 123 and x are not.
  if (r.kanji_count != 3) fail("kanji_malformed: kanji_count " + std::to_string(r.kanji_count) + " != 3");
  DictionaryQuery q;
  q.add_kanji_dict(out + "/" + r.title);
  if (q.query_kanji(kHi).empty()) fail("kanji_malformed: 日 not queryable");
  if (q.query_kanji(kShitsu).empty()) fail("kanji_malformed: 4-byte 𠮟 not queryable");
}

// --- 6. (POSIX) a write limit hit mid-import ends as a failed result --------
void case_write_limit_mid_import() {
#ifndef _WIN32
  const std::string out = fresh_dir("limit_out");
  std::string bank = "[";
  for (int i = 0; i < 4000; i++) {
    if (i) bank += ",";
    bank += "[\"w" + std::to_string(i) + "\",\"r\",\"\",\"\",0,[\"gloss number " + std::to_string(i * 7919) +
            " with some padding text\"]," + std::to_string(i) + ",\"\"]";
  }
  bank += "]";
  const std::string zip = write_zip("limit", {{"index.json", kIndex}, {"term_bank_1.json", bank}});

  // RLIMIT_FSIZE stands in for a full disk: every write past it fails (EFBIG).
  // SIGXFSZ would kill the process first, so ignore it the way a full-disk
  // ENOSPC never raises a signal on write().
  struct rlimit old {};
  getrlimit(RLIMIT_FSIZE, &old);
  auto old_handler = std::signal(SIGXFSZ, SIG_IGN);
  struct rlimit lim = old;
  lim.rlim_cur = 16 * 1024;
  setrlimit(RLIMIT_FSIZE, &lim);
  ImportResult r;
  const bool ok = import_no_throw("write_limit", zip, out, r);
  setrlimit(RLIMIT_FSIZE, &old);
  std::signal(SIGXFSZ, old_handler);
  if (!ok) return;
  if (r.success) fail("write_limit: import reported success although writes were capped at 16 KiB");
  if (std::filesystem::exists(out + "/Boundary")) fail("write_limit: half-written dictionary directory left behind");
#else
  std::fprintf(stderr, "SKIP write-limit case (POSIX RLIMIT_FSIZE only)\n");
#endif
}

}  // namespace

int main() {
  case_map_rw_reserves_blocks();
  case_map_rw_failure_reports_errno();
  case_mdx_extract_failure_is_a_result();
  case_invalid_utf8_title();
  case_kanji_bank_malformed_entries();
  case_write_limit_mid_import();
  if (g_fail) {
    std::fprintf(stderr, "%d failure(s)\n", g_fail);
    return 1;
  }
  std::fprintf(stderr, "import_failure_boundary_test: all cases passed\n");
  return 0;
}
