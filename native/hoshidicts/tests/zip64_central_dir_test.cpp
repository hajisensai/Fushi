// Guard: a ZIP whose central-directory entry uses the ZIP64 0xFFFFFFFF
// sentinels (forced-zip64, even when the archive is <4GB) must open. Before the
// fix, Zip::parse_central_directory bailed at the first sentinel and
// zip.open() returned false -> "unsupported format or failed to open file".
// Real-world trigger: （大修館）明鏡国語辞典［第二版］.zip (an MDict packed as a
// forced-zip64 archive). Python's zipfile opens it fine; our hand-rolled parser
// did not.
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
}  // namespace

int main() {
  const std::string name = "a.txt";
  const std::string data = "hi";

  std::vector<uint8_t> z;
  // ---- Local File Header @0 ----
  put32(z, 0x04034b50);                            // sig
  put16(z, 45);                                    // version needed (zip64)
  put16(z, 0);                                     // flags
  put16(z, 0);                                     // method = stored
  put16(z, 0);                                     // modtime
  put16(z, 0);                                     // moddate
  put32(z, 0);                                     // crc32 (parser ignores)
  put32(z, static_cast<uint32_t>(data.size()));    // comp size (LFH; parser ignores)
  put32(z, static_cast<uint32_t>(data.size()));    // uncomp size
  put16(z, static_cast<uint16_t>(name.size()));    // name len
  put16(z, 0);                                     // extra len
  for (char c : name) z.push_back(static_cast<uint8_t>(c));
  for (char c : data) z.push_back(static_cast<uint8_t>(c));

  // ---- Central Directory Header @cd_off ----
  const size_t cd_off = z.size();
  put32(z, 0x02014b50);                            // sig
  put16(z, 45);                                    // version made by
  put16(z, 45);                                    // version needed
  put16(z, 0);                                     // flags
  put16(z, 0);                                     // method = stored
  put16(z, 0);                                     // modtime
  put16(z, 0);                                     // moddate
  put32(z, 0);                                     // crc32
  put32(z, 0xFFFFFFFF);                            // comp size  -> ZIP64 sentinel
  put32(z, 0xFFFFFFFF);                            // uncomp size -> ZIP64 sentinel
  put16(z, static_cast<uint16_t>(name.size()));    // name len
  put16(z, 28);                                    // extra len (4 hdr + 8+8+8 = 28)
  put16(z, 0);                                     // comment len
  put16(z, 0);                                     // disk start
  put16(z, 0);                                     // internal attrs
  put32(z, 0);                                     // external attrs
  put32(z, 0xFFFFFFFF);                            // lfh offset -> ZIP64 sentinel
  for (char c : name) z.push_back(static_cast<uint8_t>(c));
  // ZIP64 extra: id=0x0001, size=24, body = uncompressed, compressed, lfh-offset
  put16(z, 0x0001);
  put16(z, 24);
  put64(z, data.size());                           // uncompressed
  put64(z, data.size());                           // compressed
  put64(z, 0);                                     // local-header offset
  const size_t cd_size = z.size() - cd_off;

  // ---- End Of Central Directory @eocd ----
  put32(z, 0x06054b50);                            // sig
  put16(z, 0);                                     // disk
  put16(z, 0);                                     // cd start disk
  put16(z, 1);                                     // entries this disk
  put16(z, 1);                                     // total entries
  put32(z, static_cast<uint32_t>(cd_size));
  put32(z, static_cast<uint32_t>(cd_off));
  put16(z, 0);                                     // comment len

  const char* tmp = std::getenv("TEMP");
  const std::string path =
      std::string(tmp ? tmp : ".") + "/hoshi_zip64_fixture.zip";
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) {
    std::fprintf(stderr, "FAIL: cannot write fixture to %s\n", path.c_str());
    return 2;
  }
  std::fwrite(z.data(), 1, z.size(), f);
  std::fclose(f);

  Zip zip;
  if (!zip.open(path)) {
    std::fprintf(stderr, "FAIL: zip.open returned false on zip64 fixture\n");
    return 1;
  }
  const int idx = zip.find(name);
  if (idx < 0) {
    std::fprintf(stderr, "FAIL: entry '%s' not found\n", name.c_str());
    return 1;
  }
  const std::string got = zip.read(idx);
  if (got != data) {
    std::fprintf(stderr, "FAIL: content mismatch: got '%s' want '%s'\n",
                 got.c_str(), data.c_str());
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
