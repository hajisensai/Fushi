// Guard: a ZIP whose central-directory entry uses the ZIP64 0xFFFFFFFF
// sentinels (forced-zip64, even when the archive is <4GB) must open. Before the
// fix, Zip::parse_central_directory bailed at the first sentinel and
// zip.open() returned false -> "unsupported format or failed to open file".
// Real-world trigger: （大修館）明鏡国語辞典［第二版］.zip (an MDict packed as a
// forced-zip64 archive). Python's zipfile opens it fine; our hand-rolled parser
// did not.
//
// Two fixtures are exercised:
//   A) all three fields (uncomp/comp/lfh) sentinel-ed (24-byte 0x0001 body).
//   B) ONLY lfh-offset sentinel-ed (8-byte 0x0001 body); comp/uncomp are real
//      32-bit values. Case B is the one that would break if take64() consumed
//      the extra block unconditionally instead of per-overflowed-field.
//
// Usage: zip64_central_dir_test   (no args) -> exit 0 on PASS, non-zero on FAIL.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "zip/zip.hpp"

namespace {
void put16(std::vector<uint8_t>& b, uint16_t v) {
  b.push_back(static_cast<uint8_t>(v & 0xff));
  b.push_back(static_cast<uint8_t>((v >> 8) & 0xff));
}
void put32(std::vector<uint8_t>& b, uint32_t v) {
  for (int i = 0; i < 4; i++) b.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
}
void put64(std::vector<uint8_t>& b, uint64_t v) {
  for (int i = 0; i < 8; i++) b.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
}

// Build a minimal single-entry STORED zip. Each of uncomp/comp/lfh is written as
// the 0xFFFFFFFF sentinel when its flag is set, and the real 64-bit value is
// appended (in fixed order) to the 0x0001 extra block; otherwise the real
// 32-bit value is written inline and it is absent from the extra block.
std::vector<uint8_t> build_zip(const std::string& name, const std::string& data,
                               bool s_unc, bool s_comp, bool s_lfh) {
  const uint32_t kSent = 0xFFFFFFFF;
  std::vector<uint8_t> z;
  // ---- Local File Header @0 (lfh_offset = 0) ----
  put32(z, 0x04034b50);
  put16(z, 45);
  put16(z, 0);
  put16(z, 0);                                   // method = stored
  put16(z, 0);
  put16(z, 0);
  put32(z, 0);                                   // crc32 (parser ignores)
  put32(z, static_cast<uint32_t>(data.size()));  // comp size (LFH; parser ignores)
  put32(z, static_cast<uint32_t>(data.size()));  // uncomp size
  put16(z, static_cast<uint16_t>(name.size()));
  put16(z, 0);                                   // extra len
  for (char c : name) z.push_back(static_cast<uint8_t>(c));
  for (char c : data) z.push_back(static_cast<uint8_t>(c));

  // ---- ZIP64 extra body: only the sentinel-ed fields, in fixed order ----
  std::vector<uint8_t> body;
  if (s_unc) put64(body, data.size());
  if (s_comp) put64(body, data.size());
  if (s_lfh) put64(body, 0);
  const uint16_t extra_len =
      body.empty() ? 0 : static_cast<uint16_t>(4 + body.size());

  // ---- Central Directory Header @cd_off ----
  const size_t cd_off = z.size();
  put32(z, 0x02014b50);
  put16(z, 45);
  put16(z, 45);
  put16(z, 0);
  put16(z, 0);                                   // method = stored
  put16(z, 0);
  put16(z, 0);
  put32(z, 0);                                   // crc32
  put32(z, s_comp ? kSent : static_cast<uint32_t>(data.size()));   // comp size
  put32(z, s_unc ? kSent : static_cast<uint32_t>(data.size()));    // uncomp size
  put16(z, static_cast<uint16_t>(name.size()));
  put16(z, extra_len);
  put16(z, 0);                                   // comment len
  put16(z, 0);                                   // disk start
  put16(z, 0);                                   // internal attrs
  put32(z, 0);                                   // external attrs
  put32(z, s_lfh ? kSent : 0);                   // lfh offset (real = 0)
  for (char c : name) z.push_back(static_cast<uint8_t>(c));
  if (extra_len) {
    put16(z, 0x0001);
    put16(z, static_cast<uint16_t>(body.size()));
    for (uint8_t v : body) z.push_back(v);
  }
  const size_t cd_size = z.size() - cd_off;

  // ---- End Of Central Directory ----
  put32(z, 0x06054b50);
  put16(z, 0);
  put16(z, 0);
  put16(z, 1);                                   // entries this disk
  put16(z, 1);                                   // total entries
  put32(z, static_cast<uint32_t>(cd_size));
  put32(z, static_cast<uint32_t>(cd_off));
  put16(z, 0);                                   // comment len
  return z;
}

// Write `bytes` to a temp file, open it through the real parser and assert the
// single entry reads back as `data`. Returns true on success.
bool run_case(const char* label, const std::vector<uint8_t>& bytes,
              const std::string& name, const std::string& data) {
  const char* tmp = std::getenv("TEMP");
  const std::string path =
      std::string(tmp ? tmp : ".") + "/hoshi_zip64_" + label + ".zip";
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) {
    std::fprintf(stderr, "FAIL[%s]: cannot write fixture\n", label);
    return false;
  }
  std::fwrite(bytes.data(), 1, bytes.size(), f);
  std::fclose(f);

  Zip zip;
  if (!zip.open(path)) {
    std::fprintf(stderr, "FAIL[%s]: zip.open returned false\n", label);
    return false;
  }
  const int idx = zip.find(name);
  if (idx < 0) {
    std::fprintf(stderr, "FAIL[%s]: entry not found\n", label);
    return false;
  }
  const std::string got = zip.read(idx);
  if (got != data) {
    std::fprintf(stderr, "FAIL[%s]: content '%s' != '%s'\n", label, got.c_str(),
                 data.c_str());
    return false;
  }
  std::printf("ok[%s]\n", label);
  return true;
}
}  // namespace

int main() {
  const std::string name = "a.txt";
  const std::string data = "hi";

  bool ok = true;
  // A: all three fields sentinel-ed.
  ok &= run_case("all", build_zip(name, data, true, true, true), name, data);
  // B: ONLY lfh-offset sentinel-ed (conditional consumption must skip comp/unc).
  ok &= run_case("lfh_only", build_zip(name, data, false, false, true), name,
                 data);

  if (!ok) return 1;
  std::printf("PASS\n");
  return 0;
}
