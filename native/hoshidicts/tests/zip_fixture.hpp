// Shared in-memory STORED-zip fixture builder for the hoshidicts native e2e
// tests (TODO-578). Hand-rolls a minimal multi-entry ZIP (method 0, no
// compression, no zip64) so a fixture dictionary can be built and imported with
// zero external素材 / zip tools. The byte layout matches the one already proven
// in kanji_import_query_test.cpp and zip64_central_dir_test.cpp.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace hoshi_test {

struct ZipFile {
  std::string name;
  std::string data;
};

inline void put16(std::vector<uint8_t>& b, uint16_t v) {
  b.push_back(static_cast<uint8_t>(v & 0xff));
  b.push_back(static_cast<uint8_t>((v >> 8) & 0xff));
}

inline void put32(std::vector<uint8_t>& b, uint32_t v) {
  for (int i = 0; i < 4; i++) {
    b.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
  }
}

// Build a minimal multi-entry STORED zip (method 0, no compression, no zip64).
inline std::vector<uint8_t> build_zip(const std::vector<ZipFile>& files) {
  std::vector<uint8_t> z;
  std::vector<uint32_t> lfh_offsets;

  for (const auto& f : files) {
    lfh_offsets.push_back(static_cast<uint32_t>(z.size()));
    put32(z, 0x04034b50);                            // local file header sig
    put16(z, 20);                                    // version needed
    put16(z, 0);                                     // flags
    put16(z, 0);                                     // method = stored
    put16(z, 0);                                     // mod time
    put16(z, 0);                                     // mod date
    put32(z, 0);                                     // crc32 (parser ignores)
    put32(z, static_cast<uint32_t>(f.data.size()));  // comp size
    put32(z, static_cast<uint32_t>(f.data.size()));  // uncomp size
    put16(z, static_cast<uint16_t>(f.name.size()));  // name len
    put16(z, 0);                                     // extra len
    for (char c : f.name) z.push_back(static_cast<uint8_t>(c));
    for (char c : f.data) z.push_back(static_cast<uint8_t>(c));
  }

  const size_t cd_off = z.size();
  for (size_t i = 0; i < files.size(); i++) {
    const auto& f = files[i];
    put32(z, 0x02014b50);                            // central dir header sig
    put16(z, 20);                                    // version made by
    put16(z, 20);                                    // version needed
    put16(z, 0);                                     // flags
    put16(z, 0);                                     // method = stored
    put16(z, 0);                                     // mod time
    put16(z, 0);                                     // mod date
    put32(z, 0);                                     // crc32
    put32(z, static_cast<uint32_t>(f.data.size()));  // comp size
    put32(z, static_cast<uint32_t>(f.data.size()));  // uncomp size
    put16(z, static_cast<uint16_t>(f.name.size()));  // name len
    put16(z, 0);                                     // extra len
    put16(z, 0);                                     // comment len
    put16(z, 0);                                     // disk start
    put16(z, 0);                                     // internal attrs
    put32(z, 0);                                     // external attrs
    put32(z, lfh_offsets[i]);                        // lfh offset
    for (char c : f.name) z.push_back(static_cast<uint8_t>(c));
  }
  const size_t cd_size = z.size() - cd_off;

  put32(z, 0x06054b50);                              // EOCD sig
  put16(z, 0);                                       // disk number
  put16(z, 0);                                       // cd start disk
  put16(z, static_cast<uint16_t>(files.size()));     // entries this disk
  put16(z, static_cast<uint16_t>(files.size()));     // total entries
  put32(z, static_cast<uint32_t>(cd_size));
  put32(z, static_cast<uint32_t>(cd_off));
  put16(z, 0);                                       // comment len
  return z;
}

// Returns the platform temp dir (TEMP / TMPDIR), or "." as a last resort.
inline std::string temp_dir() {
  const char* tmp = std::getenv("TEMP");
  if (!tmp) tmp = std::getenv("TMPDIR");
  return std::string(tmp ? tmp : ".");
}

// Write the given files as a STORED zip to <temp>/hoshi_<label>.zip; returns the
// path (empty string on write failure).
inline std::string write_zip(const char* label, const std::vector<ZipFile>& files) {
  std::string path = temp_dir() + "/hoshi_" + label + ".zip";
  std::vector<uint8_t> bytes = build_zip(files);
  FILE* fp = std::fopen(path.c_str(), "wb");
  if (!fp) return {};
  std::fwrite(bytes.data(), 1, bytes.size(), fp);
  std::fclose(fp);
  return path;
}

}  // namespace hoshi_test
