// BUG-927 guard: TODO-892 added a compression-RATIO cap (uncompressed <=
// compressed * 1100) to zip.cpp. That is the wrong discriminator: a legitimate
// yomitan term/meta/kanji bank is highly-redundant JSON whose single-bank ratio
// can legitimately exceed 1100:1, so the cap rejected valid banks -> Zip::read()
// returned "" -> 0 entries -> that dictionary imported empty (BUG-927: "only the
// first dictionary downloaded successfully, proxy makes no difference").
//
// The fix replaces the ratio cap with an ABSOLUTE upper bound
// (kMaxUncompressedEntryBytes = 1 GiB) on the declared uncompressed_size -- which
// is exactly the allocation size result.resize() will request, the only thing the
// guard actually needs to bound. This test pins the boundary directly via the now
// public zip_uncompressed_size_in_range(), independent of whatever ratio a given
// DEFLATE encoder emits, plus an end-to-end Zip::read() inflate sanity check.
//
// Build/run: see ../build927.bat (cl + /DNOMINMAX) -> exit 0 on PASS.
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#include <libdeflate.h>
#include "zip/zip.hpp"
#include "zip_fixture.hpp"

namespace {
ZipEntry make_entry(uint64_t compressed, uint64_t uncompressed) {
  ZipEntry e;
  e.name = "term_bank_1.json";
  e.compression_method = 8;  // deflate
  e.compressed_size = compressed;
  e.uncompressed_size = uncompressed;
  e.data_offset = 0;
  return e;
}

// What the OLD TODO-892 guard computed (kept here only to assert the regression
// existed and the new guard no longer reproduces it).
bool old_ratio_guard(uint64_t compressed, uint64_t uncompressed) {
  constexpr uint64_t kRatio = 1100;
  constexpr uint64_t kFloor = 64 * 1024;
  const uint64_t cap = compressed * kRatio;
  const uint64_t limit = cap < kFloor ? kFloor : cap;
  return uncompressed <= limit;
}

std::string deflate_compress(const std::string& input) {
  libdeflate_compressor* c = libdeflate_alloc_compressor(12);
  const size_t bound = libdeflate_deflate_compress_bound(c, input.size());
  std::string out;
  out.resize(bound);
  const size_t n = libdeflate_deflate_compress(c, input.data(), input.size(),
                                               out.data(), out.size());
  libdeflate_free_compressor(c);
  out.resize(n);
  return out;
}
}  // namespace

int main() {
  bool ok = true;

  // 1) Regression boundary: a bank with a legitimate >1100:1 ratio.
  //    compressed = 10 KB, uncompressed = 20 MB  -> ratio 2000:1, well under 1 GiB.
  {
    const uint64_t compressed = 10u * 1024u;
    const uint64_t uncompressed = 20u * 1024u * 1024u;
    ZipEntry e = make_entry(compressed, uncompressed);
    const bool oldGuard = old_ratio_guard(compressed, uncompressed);
    const bool newGuard = zip_uncompressed_size_in_range(e);
    if (oldGuard) {
      std::fprintf(stderr,
                   "FAIL[regression]: fixture (ratio %.0f:1) was NOT rejected by "
                   "the old guard; it does not exercise the regression\n",
                   (double)uncompressed / (double)compressed);
      ok = false;
    } else if (!newGuard) {
      std::fprintf(stderr,
                   "FAIL[regression]: new guard STILL rejects a legitimate "
                   "high-ratio (%.0f:1) bank -- BUG-927 not fixed\n",
                   (double)uncompressed / (double)compressed);
      ok = false;
    } else {
      std::printf(
          "ok[regression] legit 2000:1 bank: old guard rejected, new guard "
          "accepts\n");
    }
  }

  // 2) Zip-bomb / forged size still rejected: a multi-GB uncompressed size must
  //    be refused before result.resize() attempts the allocation.
  {
    ZipEntry e = make_entry(4096, 0xE0000000u);  // ~3.5 GiB declared
    if (zip_uncompressed_size_in_range(e)) {
      std::fprintf(stderr,
                   "FAIL[bomb]: forged ~3.5GB uncompressed_size was accepted\n");
      ok = false;
    } else {
      std::printf("ok[bomb] forged 3.5GB size rejected (no huge resize)\n");
    }
  }

  // 3) Exactly-at-the-cap accepted, one byte over rejected (off-by-one pin).
  {
    ZipEntry at = make_entry(1, kMaxUncompressedEntryBytes);
    ZipEntry over = make_entry(1, kMaxUncompressedEntryBytes + 1);
    if (!zip_uncompressed_size_in_range(at)) {
      std::fprintf(stderr, "FAIL[cap]: entry exactly at 1 GiB cap rejected\n");
      ok = false;
    } else if (zip_uncompressed_size_in_range(over)) {
      std::fprintf(stderr, "FAIL[cap]: entry one byte over 1 GiB accepted\n");
      ok = false;
    } else {
      std::printf("ok[cap] boundary at kMaxUncompressedEntryBytes is exact\n");
    }
  }

  // 4) End-to-end: a real (small) DEFLATE bank still inflates byte-for-byte
  //    through Zip::read() (the guard does not break the happy path).
  {
    const std::string name = "term_bank_1.json";
    const std::string payload =
        "[[\"a\",\"\",\"\",\"\",0,[],0,\"\"],[\"b\",\"\",\"\",\"\",0,[],0,\"\"]]";
    const std::string deflated = deflate_compress(payload);
    auto bytes = hoshi_test::build_zip_deflate(
        {{name, deflated, (uint32_t)payload.size()}});
    const std::string path = hoshi_test::temp_dir() + "/hoshi_927_roundtrip.zip";
    FILE* fp = std::fopen(path.c_str(), "wb");
    std::fwrite(bytes.data(), 1, bytes.size(), fp);
    std::fclose(fp);
    Zip zip;
    if (!zip.open(path)) {
      std::fprintf(stderr, "FAIL[roundtrip]: open\n");
      ok = false;
    } else {
      std::string got = zip.read(zip.find(name));
      if (got != payload) {
        std::fprintf(stderr, "FAIL[roundtrip]: got %zu bytes, expected %zu\n",
                     got.size(), payload.size());
        ok = false;
      } else {
        std::printf("ok[roundtrip] valid bank inflated byte-for-byte\n");
      }
    }
  }

  if (!ok) return 1;
  std::printf("PASS\n");
  return 0;
}
