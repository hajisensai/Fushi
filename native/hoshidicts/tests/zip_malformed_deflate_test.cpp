// TODO-892 guard: malformed DEFLATE zip entries must produce a structured error
// (empty read / failed import), NEVER a hard crash.
//
// Root cause this defends: Zip::read()/read_media() fed the raw deflate stream
// to libdeflate. Two attacker-/corruption-controlled failure shapes existed:
//   1) the thread_local decompressor alloc returning null and being deref'd ->
//      0xC0000005 (covered by the source-scan guard; can't be forced in a unit
//      test without faking the allocator), and
//   2) an oversized declared uncompressed_size driving std::string::resize() to
//      a multi-GB allocation -> std::bad_alloc on a worker thread.
// This test exercises the observable behaviour: a truncated stream, a corrupt
// stream, and a forged-huge uncompressed_size all return "" from Zip::read and
// the process stays alive. A full malformed-bank yomitan import returns
// success==false with a non-empty error and does not crash.
//
// Usage: zip_malformed_deflate_test  (no args) -> exit 0 on PASS.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <libdeflate.h>

#include "hoshidicts/importer.hpp"
#include "zip/zip.hpp"
#include "zip_fixture.hpp"

namespace {

// Raw-deflate compress `input` with libdeflate; aborts the test on failure.
std::string deflate_compress(const std::string& input) {
  libdeflate_compressor* c = libdeflate_alloc_compressor(6);
  if (!c) {
    std::fprintf(stderr, "FAIL: could not alloc compressor\n");
    std::exit(2);
  }
  const size_t bound = libdeflate_deflate_compress_bound(c, input.size());
  std::string out;
  out.resize(bound);
  const size_t n = libdeflate_deflate_compress(c, input.data(), input.size(),
                                               out.data(), out.size());
  libdeflate_free_compressor(c);
  if (n == 0) {
    std::fprintf(stderr, "FAIL: deflate_compress produced 0 bytes\n");
    std::exit(2);
  }
  out.resize(n);
  return out;
}

bool expect_empty_read(const char* label, const std::vector<uint8_t>& bytes,
                       const std::string& entry_name) {
  const std::string path =
      hoshi_test::temp_dir() + "/hoshi_mal_" + label + ".zip";
  FILE* fp = std::fopen(path.c_str(), "wb");
  if (!fp) {
    std::fprintf(stderr, "FAIL[%s]: cannot write fixture\n", label);
    return false;
  }
  std::fwrite(bytes.data(), 1, bytes.size(), fp);
  std::fclose(fp);

  Zip zip;
  if (!zip.open(path)) {
    // A central directory that the parser rejects outright is also "no crash".
    std::printf("ok[%s] (zip.open rejected, no crash)\n", label);
    return true;
  }
  const int idx = zip.find(entry_name);
  if (idx < 0) {
    std::fprintf(stderr, "FAIL[%s]: entry not found\n", label);
    return false;
  }
  const std::string got = zip.read(idx);  // must NOT crash
  if (!got.empty()) {
    std::fprintf(stderr, "FAIL[%s]: expected empty read, got %zu bytes\n", label,
                 got.size());
    return false;
  }
  std::printf("ok[%s] (structured empty read, no crash)\n", label);
  return true;
}

}  // namespace

int main() {
  bool ok = true;
  const std::string name = "term_bank_1.json";
  const std::string payload = "[[\"\xe8\xaa\x9e\",\"\",\"\",\"\",0,[],0,\"\"]]";
  const std::string deflated = deflate_compress(payload);

  // 1) Truncated deflate stream: keep only the first half of the bytes. The
  //    declared comp size in build_zip_deflate equals the (truncated) payload
  //    size, so has_entry_payload() passes; libdeflate must report BAD_DATA.
  {
    std::string truncated = deflated.substr(0, deflated.size() / 2);
    auto bytes = hoshi_test::build_zip_deflate(
        {{name, truncated, static_cast<uint32_t>(payload.size())}});
    ok &= expect_empty_read("truncated", bytes, name);
  }

  // 2) Corrupt deflate stream: full length, random-ish bytes (not valid DEFLATE).
  {
    std::string corrupt = deflated;
    for (size_t i = 0; i < corrupt.size(); ++i) {
      corrupt[i] = static_cast<char>((corrupt[i] ^ 0xA5) + 0x13);
    }
    auto bytes = hoshi_test::build_zip_deflate(
        {{name, corrupt, static_cast<uint32_t>(payload.size())}});
    ok &= expect_empty_read("corrupt", bytes, name);
  }

  // 3) Oversized declared uncompressed_size: valid small deflate payload but a
  //    forged ~3.5 GB uncompressed size. The resize upper-bound guard must
  //    reject it BEFORE result.resize() attempts the allocation.
  {
    auto bytes = hoshi_test::build_zip_deflate(
        {{name, deflated, 0xE0000000u}});
    ok &= expect_empty_read("oversized", bytes, name);
  }

  // 4) Full malformed-bank yomitan import: valid index.json + a corrupt
  //    term_bank. import() must return success==false with an error, no crash.
  {
    const std::string index =
        "{\"title\":\"mal\",\"format\":3,\"revision\":\"r\"}";
    std::string corrupt = deflated;
    for (auto& ch : corrupt) ch = static_cast<char>(~ch);
    // index.json is STORED (read by import_yomitan); the term bank is a corrupt
    // deflate entry. Build a single zip carrying both by concatenating layout is
    // non-trivial; instead reuse the STORED builder for index and a separate
    // deflate builder is not directly mergeable, so use a STORED index + STORED
    // (but corrupt-when-inflated is N/A for STORED). To keep one archive, store
    // index normally and store the term bank as a method-8 corrupt entry via a
    // hand-merged build below.
    // Simplest robust check: a yomitan zip whose ONLY term bank is corrupt
    // deflate yields no parseable entries -> "empty dictionary".
    std::vector<hoshi_test::DeflateZipFile> dfiles = {
        {"term_bank_1.json", corrupt, static_cast<uint32_t>(payload.size())}};
    // Compose: STORED index.json + DEFLATE corrupt term bank in one archive.
    // build_zip_deflate only emits method-8 entries, so deflate-compress the
    // index too (valid) and append the corrupt bank.
    std::string index_deflated = deflate_compress(index);
    dfiles.insert(dfiles.begin(),
                  {"index.json", index_deflated,
                   static_cast<uint32_t>(index.size())});
    const std::string zip_path =
        hoshi_test::temp_dir() + "/hoshi_mal_import.zip";
    {
      auto bytes = hoshi_test::build_zip_deflate(dfiles);
      FILE* fp = std::fopen(zip_path.c_str(), "wb");
      if (!fp) {
        std::fprintf(stderr, "FAIL[import]: cannot write fixture\n");
        return 1;
      }
      std::fwrite(bytes.data(), 1, bytes.size(), fp);
      std::fclose(fp);
    }
    const std::string out_dir = hoshi_test::temp_dir() + "/hoshi_mal_out";
    ImportResult r = dictionary_importer::import(zip_path, out_dir);  // no crash
    if (r.success) {
      std::fprintf(stderr,
                   "FAIL[import]: expected failure on corrupt-only banks\n");
      ok = false;
    } else if (r.errors.empty()) {
      std::fprintf(stderr, "FAIL[import]: failure had no error message\n");
      ok = false;
    } else {
      std::printf("ok[import] (success=false, errors[0]='%s', no crash)\n",
                  r.errors.front().c_str());
    }
  }

  if (!ok) return 1;
  std::printf("PASS\n");
  return 0;
}
