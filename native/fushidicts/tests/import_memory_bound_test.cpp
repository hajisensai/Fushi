// BUG-3234 guard: dictionary import must not hold a whole archive member, or a
// whole MDict media companion, in RAM -- and the bounded low_ram mode Android
// and iOS now run in must produce the same dictionary as the wide default.
//
// What used to happen on Android: an MDict packed in a zip was extracted with
// Zip::read() (the whole .mdx/.mdd in a std::string, zero-filled first), and
// import_mdd_into() then read each .mdd into a vector and decoded every record
// into a second one. A few hundred MB of images/audio came to roughly three
// times that in anonymous memory, and lmkd killed the app within seconds with
// nothing any catch could see. Separately the importer's low_ram mode was
// hardwired off, so yomitan imports fanned out to hardware_concurrency()+4
// workers each holding a whole bank.
//
//   A) Zip::extract_to is byte-exact for deflate and stored entries, and a
//      corrupt entry fails without leaving a file behind.
//   B) low_ram=true and low_ram=false import the same yomitan dictionary to
//      the same terms, glossaries and media.
//   C) Importing a zip holding a small .mdx plus a 160 MB .mdd runs in a child
//      process; on Windows its peak private commit must stay under 96 MB (the
//      old path peaked near 3x the .mdd). Other platforms check the result
//      only: their RSS counts the file-backed output pages too.
//
// Usage: import_memory_bound_test  (no args) -> exit 0 on PASS.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <psapi.h>
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

#include <libdeflate.h>

#include "fushidicts/importer.hpp"
#include "fushidicts/query.hpp"
#include "mdx_fixture.hpp"
#include "zip/zip.hpp"
#include "zip_fixture.hpp"

namespace {

namespace fs = std::filesystem;

constexpr size_t kMediaRecords = 2560;
constexpr size_t kMediaRecordBytes = 64 * 1024;  // 2560 x 64 KiB = 160 MiB
constexpr size_t kRecordBlockBytes = 1024 * 1024;
constexpr size_t kPeakBudgetBytes = 96ull * 1024 * 1024;

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

std::string read_all(const std::string& path) {
  std::ifstream in(fs::u8path(path), std::ios::binary);
  return {std::istreambuf_iterator<char>(in), {}};
}

void write_all(const std::string& path, const void* data, size_t size) {
  std::ofstream out(fs::u8path(path), std::ios::binary);
  out.write(static_cast<const char*>(data), static_cast<std::streamsize>(size));
}

std::string deflate_raw(const std::string& input) {
  libdeflate_compressor* c = libdeflate_alloc_compressor(6);
  std::string out(libdeflate_deflate_compress_bound(c, input.size()), '\0');
  const size_t n = libdeflate_deflate_compress(c, input.data(), input.size(), out.data(), out.size());
  libdeflate_free_compressor(c);
  out.resize(n);
  return out;
}

// Incompressible bytes, so the .mdd stays as large on disk as in memory.
std::string noise(size_t size, uint64_t seed) {
  std::string out(size, '\0');
  uint64_t x = seed * 0x9E3779B97F4A7C15ull + 1;
  for (size_t i = 0; i < size; i++) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    out[i] = static_cast<char>(x);
  }
  return out;
}

// ---------------------------------------------------------------- A ----------
void test_extract_to() {
  std::string text;
  for (int i = 0; i < 20000; i++) text += "line " + std::to_string(i) + " of a compressible member\n";
  const std::string stored = noise(300000, 7);

  const std::string deflated_zip = fushi_test::write_zip_deflate(
      "extract_deflate", {{"big.txt", deflate_raw(text), static_cast<uint32_t>(text.size())},
                          {"bad.txt", deflate_raw(text).substr(0, 64), static_cast<uint32_t>(text.size())}});
  const std::string stored_zip = fushi_test::write_zip("extract_stored", {{"blob.bin", stored}, {"empty.txt", ""}});

  const std::string out = fushi_test::temp_dir() + "/fushi_extract_to_out";
  std::error_code ec;
  fs::remove_all(fs::u8path(out), ec);
  fs::create_directories(fs::u8path(out));

  Zip dz;
  if (!dz.open(deflated_zip)) return fail("A: could not open deflate fixture");
  if (!dz.extract_to(dz.find("big.txt"), out + "/big.txt")) fail("A: deflate extract returned false");
  if (read_all(out + "/big.txt") != text) fail("A: deflate extract is not byte-exact");
  if (dz.extract_to(dz.find("bad.txt"), out + "/bad.txt")) fail("A: corrupt deflate extract returned true");
  if (fs::exists(fs::u8path(out + "/bad.txt"))) fail("A: corrupt deflate extract left a file behind");
  if (dz.extract_to(99, out + "/none")) fail("A: out-of-range index returned true");

  Zip sz;
  if (!sz.open(stored_zip)) return fail("A: could not open stored fixture");
  if (!sz.extract_to(sz.find("blob.bin"), out + "/blob.bin")) fail("A: stored extract returned false");
  if (read_all(out + "/blob.bin") != stored) fail("A: stored extract is not byte-exact");
  if (!sz.extract_to(sz.find("empty.txt"), out + "/empty.txt")) fail("A: empty extract returned false");
  if (!fs::exists(fs::u8path(out + "/empty.txt")) || fs::file_size(fs::u8path(out + "/empty.txt")) != 0) {
    fail("A: empty entry must extract to an empty file");
  }
}

// ---------------------------------------------------------------- B ----------
std::string term_bank(int bank, int n) {
  std::string out = "[";
  for (int i = 0; i < n; i++) {
    if (i) out.push_back(',');
    const std::string word = "w" + std::to_string(bank) + "_" + std::to_string(i);
    out += "[\"" + word + "\",\"" + word + "\",\"\",\"\",0,[\"shared training phrase for bank " +
           std::to_string(bank) + " entry " + std::to_string(i) + " with overlapping vocabulary\"],0,\"\"]";
  }
  out.push_back(']');
  return out;
}

void test_low_ram_equivalence() {
  constexpr int kBanks = 6;
  constexpr int kTerms = 40;
  std::vector<fushi_test::ZipFile> files = {{"index.json", "{\"title\":\"LowRamEq\",\"format\":3,\"revision\":\"t\"}"}};
  for (int b = 1; b <= kBanks; b++) files.push_back({"term_bank_" + std::to_string(b) + ".json", term_bank(b, kTerms)});
  files.push_back({"img/a.png", noise(5000, 1)});
  files.push_back({"img/b.png", noise(7000, 2)});
  const std::string zip_path = fushi_test::write_zip("low_ram_eq", files);

  const std::string base = fushi_test::temp_dir() + "/fushi_low_ram_eq";
  std::error_code ec;
  fs::remove_all(fs::u8path(base), ec);
  const ImportResult wide = dictionary_importer::import(zip_path, base + "/wide", false);
  const ImportResult narrow = dictionary_importer::import(zip_path, base + "/narrow", true);
  if (!wide.success || !narrow.success) return fail("B: import failed");
  if (wide.term_count != narrow.term_count || narrow.term_count != kBanks * kTerms) {
    fail("B: term_count differs: wide=" + std::to_string(wide.term_count) +
         " low_ram=" + std::to_string(narrow.term_count));
  }
  if (wide.media_count != narrow.media_count || narrow.media_count != 2) fail("B: media_count differs");

  DictionaryQuery qw;
  qw.add_term_dict(base + "/wide/" + wide.title);
  DictionaryQuery qn;
  qn.add_term_dict(base + "/narrow/" + narrow.title);
  for (int b = 1; b <= kBanks; b++) {
    for (int i = 0; i < kTerms; i++) {
      const std::string word = "w" + std::to_string(b) + "_" + std::to_string(i);
      const auto rw = qw.query(word);
      const auto rn = qn.query(word);
      if (rn.empty() || rn.front().glossaries.empty()) return fail("B: low_ram dictionary lost " + word);
      if (rw.empty() || rw.front().glossaries.front().glossary != rn.front().glossaries.front().glossary) {
        return fail("B: glossary differs for " + word);
      }
    }
  }
  const std::vector<char> png = qn.get_media_file(narrow.title, "img/b.png");
  if (std::string(png.begin(), png.end()) != noise(7000, 2)) fail("B: low_ram media is not byte-exact");
}

// ---------------------------------------------------------------- C ----------
// Child mode: import, then report through the exit code only. (The MDX path
// does not fill ImportResult::media_count; the parent checks the store itself.)
int child_import(const std::string& zip_path, const std::string& out_dir) {
  const ImportResult r = dictionary_importer::import(zip_path, out_dir);
  if (!r.success) {
    std::fprintf(stderr, "child: import failed: %s\n", r.errors.empty() ? "?" : r.errors.front().c_str());
    return 3;
  }
  return 0;
}

std::string build_big_mdict_zip() {
  std::string zip_path;
  std::vector<uint8_t> mdd;
  {
    std::vector<std::pair<std::string, std::string>> media;
    media.reserve(kMediaRecords);
    for (size_t i = 0; i < kMediaRecords; i++) {
      media.emplace_back("\\img\\" + std::to_string(i) + ".bin", noise(kMediaRecordBytes, i + 11));
    }
    std::vector<size_t> splits;
    for (size_t off = kRecordBlockBytes; off < kMediaRecords * kMediaRecordBytes; off += kRecordBlockBytes) {
      splits.push_back(off);
    }
    mdd = mdx_fixture::build_mdd_record_splits("BigMedia", media, splits);
  }
  const auto mdx = mdx_fixture::build_mdx_plain("BigMedia", {{"alpha", "<img src=\"img/0.bin\">"}});
  zip_path = fushi_test::write_zip(
      "big_mdict", {{"BigMedia.mdx", std::string(mdx.begin(), mdx.end())},
                    {"BigMedia.mdd", std::string(mdd.begin(), mdd.end())}});
  return zip_path;
}

void test_mdict_zip_peak_memory(const char* self) {
  const std::string zip_path = build_big_mdict_zip();
  if (zip_path.empty()) return fail("C: could not write the MDict zip fixture");
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_big_mdict_out";
  std::error_code ec;
  fs::remove_all(fs::u8path(out_dir), ec);

#ifdef _WIN32
  std::string cmd = "\"" + std::string(self) + "\" --child-import \"" + zip_path + "\" \"" + out_dir + "\"";
  STARTUPINFOA si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (!CreateProcessA(nullptr, cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
    return fail("C: could not start the child import");
  }
  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD code = 1;
  GetExitCodeProcess(pi.hProcess, &code);
  PROCESS_MEMORY_COUNTERS pmc{};
  pmc.cb = sizeof(pmc);
  const bool measured = GetProcessMemoryInfo(pi.hProcess, &pmc, sizeof(pmc)) != 0;
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  if (code != 0) return fail("C: child import failed with exit code " + std::to_string(code));
  if (!measured) return fail("C: could not read the child's memory counters");
  const size_t peak = pmc.PeakPagefileUsage;
  std::fprintf(stderr, "INFO C: child peak private commit %.1f MiB (budget %.0f MiB, .mdd %.0f MiB)\n",
               peak / 1048576.0, kPeakBudgetBytes / 1048576.0, kMediaRecords * kMediaRecordBytes / 1048576.0);
  if (peak > kPeakBudgetBytes) fail("C: import held the media companion in memory");
#else
  const pid_t pid = fork();
  if (pid == 0) {
    execl(self, self, "--child-import", zip_path.c_str(), out_dir.c_str(), static_cast<char*>(nullptr));
    _exit(127);
  }
  int status = 0;
  waitpid(pid, &status, 0);
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return fail("C: child import failed");
  std::fprintf(stderr, "INFO C: peak-memory assertion runs on Windows only\n");
#endif

  // The media store holds every record, byte-exact.
  DictionaryQuery q;
  q.add_term_dict(out_dir + "/BigMedia");
  for (size_t i : {size_t{0}, size_t{1234}, kMediaRecords - 1}) {
    const std::vector<char> blob = q.get_media_file("BigMedia", "img/" + std::to_string(i) + ".bin");
    if (std::string(blob.begin(), blob.end()) != noise(kMediaRecordBytes, i + 11)) {
      fail("C: media record " + std::to_string(i) + " is missing or not byte-exact");
    }
  }
  fs::remove_all(fs::u8path(out_dir), ec);
  fs::remove(fs::u8path(zip_path), ec);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 4 && std::strcmp(argv[1], "--child-import") == 0) {
    return child_import(argv[2], argv[3]);
  }
  test_extract_to();
  test_low_ram_equivalence();
  test_mdict_zip_peak_memory(argv[0]);
  if (g_fail) {
    std::fprintf(stderr, "import_memory_bound_test: %d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("import_memory_bound_test: PASS\n");
  return 0;
}
