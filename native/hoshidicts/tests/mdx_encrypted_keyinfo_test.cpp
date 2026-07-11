// BUG-723: MDX dictionaries with Encrypted="2" (key-block-info obfuscation)
// failed to import with "mdx: empty key block info" because mdx_reader fed the
// scrambled section straight to libdeflate. This test builds a self-contained
// Encrypted="2" MDX v2 fixture in memory -- scrambling its key-block-info with
// the exact MDict RIPEMD-128 + rolling-XOR cipher the reader must undo -- and
// asserts mdx_reader::parse recovers the headwords and definitions.
//
// The fixture builder reimplements RIPEMD-128 and the cipher independently of
// the reader, so a transcription error in the reader's copy yields a wrong key,
// garbage after decrypt, a failed inflate, and zero entries -> the assertions
// fire. It therefore transitively pins the reader's RIPEMD-128 correctness.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <libdeflate.h>

#include "mdx_reader.hpp"

namespace {

void put_be16(std::vector<uint8_t>& v, uint16_t x) {
  v.push_back(uint8_t(x >> 8));
  v.push_back(uint8_t(x & 0xff));
}
void put_be32(std::vector<uint8_t>& v, uint32_t x) {
  for (int i = 3; i >= 0; i--) v.push_back(uint8_t((x >> (8 * i)) & 0xff));
}
void put_be64(std::vector<uint8_t>& v, uint64_t x) {
  for (int i = 7; i >= 0; i--) v.push_back(uint8_t((x >> (8 * i)) & 0xff));
}
void put_le32(std::vector<uint8_t>& v, uint32_t x) {
  for (int i = 0; i < 4; i++) v.push_back(uint8_t((x >> (8 * i)) & 0xff));
}

// --- RIPEMD-128, independent reimplementation (see reader for reference) ---
uint32_t rol32(uint32_t x, unsigned s) { return (x << s) | (x >> (32 - s)); }
std::vector<uint8_t> ripemd128(const std::vector<uint8_t>& msg) {
  static const unsigned rr[64] = {
      0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 7,  4,  13, 1,  10, 6,
      15, 3,  12, 0,  9,  5,  2,  14, 11, 8,  3,  10, 14, 4,  9,  15, 8,  1,  2,  7,  0,  6,
      13, 11, 5,  12, 1,  9,  11, 10, 0,  8,  12, 4,  13, 3,  7,  15, 14, 5,  6,  2};
  static const unsigned rrp[64] = {
      5,  14, 7,  0,  9,  2,  11, 4,  13, 6,  15, 8,  1,  10, 3,  12, 6,  11, 3,  7,  0,  13,
      5,  10, 14, 15, 8,  12, 4,  9,  1,  2,  15, 5,  1,  3,  7,  14, 6,  9,  11, 8,  12, 2,
      10, 0,  4,  13, 8,  6,  4,  1,  3,  11, 15, 0,  5,  12, 2,  13, 9,  7,  10, 14};
  static const unsigned ss[64] = {
      11, 14, 15, 12, 5,  8,  7,  9,  11, 13, 14, 15, 6,  7,  9,  8,  7,  6,  8,  13, 11, 9,
      7,  15, 7,  12, 15, 9,  11, 7,  13, 12, 11, 13, 6,  7,  14, 9,  13, 15, 14, 8,  13, 6,
      5,  12, 7,  5,  11, 12, 14, 15, 14, 15, 9,  8,  9,  14, 5,  6,  8,  6,  5,  12};
  static const unsigned ssp[64] = {
      8,  9,  9,  11, 13, 15, 15, 5,  7,  7,  8,  11, 14, 14, 12, 6,  9,  13, 15, 7,  12, 8,
      9,  11, 7,  7,  12, 7,  6,  15, 13, 11, 9,  7,  15, 11, 8,  6,  6,  14, 12, 13, 5,  14,
      13, 13, 7,  5,  15, 5,  8,  11, 14, 14, 6,  14, 6,  9,  12, 9,  12, 5,  15, 8};
  auto f = [](int j, uint32_t x, uint32_t y, uint32_t z) -> uint32_t {
    if (j < 16) return x ^ y ^ z;
    if (j < 32) return (x & y) | (~x & z);
    if (j < 48) return (x | ~y) ^ z;
    return (x & z) | (y & ~z);
  };
  auto K = [](int j) -> uint32_t {
    if (j < 16) return 0x00000000u;
    if (j < 32) return 0x5a827999u;
    if (j < 48) return 0x6ed9eba1u;
    return 0x8f1bbcdcu;
  };
  auto Kp = [](int j) -> uint32_t {
    if (j < 16) return 0x50a28be6u;
    if (j < 32) return 0x5c4dd124u;
    if (j < 48) return 0x6d703ef3u;
    return 0x00000000u;
  };
  std::vector<uint8_t> buf = msg;
  uint64_t bit_len = uint64_t(msg.size()) * 8;
  buf.push_back(0x80);
  while (buf.size() % 64 != 56) buf.push_back(0x00);
  for (int i = 0; i < 8; i++) buf.push_back(uint8_t((bit_len >> (8 * i)) & 0xff));
  uint32_t h0 = 0x67452301u, h1 = 0xefcdab89u, h2 = 0x98badcfeu, h3 = 0x10325476u;
  for (size_t chunk = 0; chunk < buf.size(); chunk += 64) {
    uint32_t X[16];
    for (int i = 0; i < 16; i++) {
      const uint8_t* p = buf.data() + chunk + i * 4;
      X[i] = p[0] | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
    }
    uint32_t A = h0, B = h1, C = h2, D = h3, Ap = h0, Bp = h1, Cp = h2, Dp = h3;
    for (int j = 0; j < 64; j++) {
      uint32_t t = rol32(A + f(j, B, C, D) + X[rr[j]] + K(j), ss[j]);
      A = D; D = C; C = B; B = t;
      t = rol32(Ap + f(63 - j, Bp, Cp, Dp) + X[rrp[j]] + Kp(j), ssp[j]);
      Ap = Dp; Dp = Cp; Cp = Bp; Bp = t;
    }
    uint32_t t = h1 + C + Dp;
    h1 = h2 + D + Ap;
    h2 = h3 + A + Bp;
    h3 = h0 + B + Cp;
    h0 = t;
  }
  std::vector<uint8_t> out(16);
  uint32_t hs[4] = {h0, h1, h2, h3};
  for (int i = 0; i < 4; i++)
    for (int b = 0; b < 4; b++) out[i * 4 + b] = uint8_t((hs[i] >> (8 * b)) & 0xff);
  return out;
}

// Encrypt = inverse of the reader's mdx_fast_decrypt (nibble-swap is its own
// inverse; chain on the *cipher* byte).
void mdx_fast_encrypt(std::vector<uint8_t>& data, const std::vector<uint8_t>& key) {
  uint8_t prev = 0x36;
  for (size_t i = 0; i < data.size(); i++) {
    uint8_t x = uint8_t(data[i] ^ prev ^ uint8_t(i & 0xff) ^ key[i % key.size()]);
    uint8_t c = uint8_t((x >> 4) | (x << 4));
    data[i] = c;
    prev = c;
  }
}

std::vector<uint8_t> zlib_compress(const std::vector<uint8_t>& in) {
  auto* c = libdeflate_alloc_compressor(6);
  size_t bound = libdeflate_zlib_compress_bound(c, in.size());
  std::vector<uint8_t> out(bound);
  size_t n = libdeflate_zlib_compress(c, in.data(), in.size(), out.data(), out.size());
  libdeflate_free_compressor(c);
  out.resize(n);
  return out;
}

// comp_type(le32=2) + 4-byte checksum placeholder + zlib(payload)
std::vector<uint8_t> make_zlib_block(const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> z = zlib_compress(payload);
  std::vector<uint8_t> block;
  put_le32(block, 2);              // zlib
  put_le32(block, 0xDEADBEEF);     // checksum (reader ignores)
  block.insert(block.end(), z.begin(), z.end());
  return block;
}

int fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  return 1;
}

}  // namespace

std::string hex(const std::vector<uint8_t>& v) {
  static const char* h = "0123456789abcdef";
  std::string s;
  for (uint8_t b : v) {
    s.push_back(h[b >> 4]);
    s.push_back(h[b & 0xf]);
  }
  return s;
}

std::vector<uint8_t> bytes(const std::string& s) {
  return std::vector<uint8_t>(s.begin(), s.end());
}

int main() {
  // --- RIPEMD-128 known-answer vectors -----------------------------------
  // Published test vectors (homes.esat.kuleuven.be/~bosselae/ripemd). This
  // pins the fixture's RIPEMD-128 to the spec; because the fixture below only
  // decrypts if the reader's RIPEMD-128 agrees with the fixture's, a passing
  // suite proves the reader's RIPEMD-128 is spec-correct too.
  if (hex(ripemd128(bytes(""))) != "cdf26213a150dc3ecb610f18f6b38b46")
    return fail("RIPEMD-128(\"\") KAT mismatch");
  if (hex(ripemd128(bytes("abc"))) != "c14a12199c66e4ba84636b0f69144c77")
    return fail("RIPEMD-128(\"abc\") KAT mismatch");
  if (hex(ripemd128(bytes("message digest"))) != "9e327b3d6e523062afc1132d7df9d1b8")
    return fail("RIPEMD-128(\"message digest\") KAT mismatch");

  // --- Two entries -> record stream + null-terminated definitions ---
  const std::string k0 = "apple", k1 = "banana";
  const std::string d0 = "def-apple", d1 = "def-banana";
  std::vector<uint8_t> records;
  uint64_t off0 = records.size();
  records.insert(records.end(), d0.begin(), d0.end());
  records.push_back(0);
  uint64_t off1 = records.size();
  records.insert(records.end(), d1.begin(), d1.end());
  records.push_back(0);

  // --- Key block (entries: be64 offset + headword + NUL) ---
  std::vector<uint8_t> key_entries;
  put_be64(key_entries, off0);
  key_entries.insert(key_entries.end(), k0.begin(), k0.end());
  key_entries.push_back(0);
  put_be64(key_entries, off1);
  key_entries.insert(key_entries.end(), k1.begin(), k1.end());
  key_entries.push_back(0);
  std::vector<uint8_t> key_block = make_zlib_block(key_entries);

  // --- Key block info (one block meta), then compress + scramble ---
  std::vector<uint8_t> kbi_plain;
  put_be64(kbi_plain, 2);  // num entries in this key block
  put_be16(kbi_plain, uint16_t(k0.size()));
  kbi_plain.insert(kbi_plain.end(), k0.begin(), k0.end());
  kbi_plain.push_back(0);
  put_be16(kbi_plain, uint16_t(k1.size()));
  kbi_plain.insert(kbi_plain.end(), k1.begin(), k1.end());
  kbi_plain.push_back(0);
  put_be64(kbi_plain, key_block.size());   // compressed size of the key block
  put_be64(kbi_plain, key_entries.size()); // decompressed size of the key block

  std::vector<uint8_t> kbi_z = zlib_compress(kbi_plain);
  std::vector<uint8_t> kbi;
  put_le32(kbi, 2);          // comp_type zlib
  kbi.push_back(0x11);       // [4..8) adler bytes -- also the RIPEMD seed
  kbi.push_back(0x22);
  kbi.push_back(0x33);
  kbi.push_back(0x44);
  kbi.insert(kbi.end(), kbi_z.begin(), kbi_z.end());
  // Scramble bytes [8..) exactly as the reader will unscramble them.
  std::vector<uint8_t> seed = {kbi[4], kbi[5], kbi[6], kbi[7], 0x95, 0x36, 0x00, 0x00};
  std::vector<uint8_t> key = ripemd128(seed);
  std::vector<uint8_t> enc(kbi.begin() + 8, kbi.end());
  mdx_fast_encrypt(enc, key);
  std::copy(enc.begin(), enc.end(), kbi.begin() + 8);

  // --- Record block info + record blocks ---
  std::vector<uint8_t> record_block = make_zlib_block(records);
  std::vector<uint8_t> record_block_info;
  put_be64(record_block_info, record_block.size());
  put_be64(record_block_info, records.size());

  // --- Assemble the whole file ---
  std::vector<uint8_t> file;
  std::string header =
      "<Dictionary GeneratedByEngineVersion=\"2.0\" Encrypted=\"2\" "
      "Encoding=\"UTF-8\" Title=\"Fixture\"/>";
  put_be32(file, uint32_t(header.size()));
  file.insert(file.end(), header.begin(), header.end());
  put_be32(file, 0);  // header adler (ignored)

  put_be64(file, 1);                    // num key blocks
  put_be64(file, 2);                    // num entries
  put_be64(file, kbi_plain.size());     // key_block_info_decomp_size
  put_be64(file, kbi.size());           // key_block_info_size
  put_be64(file, key_block.size());     // key_blocks_size
  put_be32(file, 0);                    // key block info adler (ignored)
  file.insert(file.end(), kbi.begin(), kbi.end());
  file.insert(file.end(), key_block.begin(), key_block.end());

  put_be64(file, 1);                       // num record blocks
  put_be64(file, 2);                       // num entries (ignored)
  put_be64(file, record_block_info.size());
  put_be64(file, record_block.size());     // record_blocks_total_size
  file.insert(file.end(), record_block_info.begin(), record_block_info.end());
  file.insert(file.end(), record_block.begin(), record_block.end());

  // --- Parse and verify ---
  MdxResult r = mdx_reader::parse(file.data(), file.size());
  if (r.entries.size() != 2)
    return fail(("expected 2 entries, got " + std::to_string(r.entries.size())).c_str());
  if (r.entries[0].key != k0 || r.entries[0].definition != d0)
    return fail("entry 0 mismatch");
  if (r.entries[1].key != k1 || r.entries[1].definition != d1)
    return fail("entry 1 mismatch");
  if (r.title != "Fixture") return fail("title mismatch");

  std::printf("OK: decrypted Encrypted=2 key-block-info, recovered %zu entries\n",
              r.entries.size());
  return 0;
}
