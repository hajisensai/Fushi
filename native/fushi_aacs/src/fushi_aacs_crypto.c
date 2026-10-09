/*
 * Self-contained AES-128 (FIPS-197) and SHA-1 (FIPS 180-4).
 *
 * Byte-oriented reference implementations: AACS decrypts one 6144-byte unit
 * per call, so clarity is worth more here than table-driven speed.
 */
#include "fushi_aacs_crypto.h"

#include <string.h>

static const uint8_t kSbox[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
    0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
    0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26,
    0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
    0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0,
    0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed,
    0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f,
    0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
    0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec,
    0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
    0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c,
    0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d,
    0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f,
    0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e,
    0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e, 0xe1, 0xf8, 0x98, 0x11,
    0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f,
    0xb0, 0x54, 0xbb, 0x16};

static uint8_t g_inv_sbox[256];
static int g_inv_sbox_ready = 0;

static void build_inv_sbox(void) {
  /* Idempotent: concurrent first calls write identical bytes. */
  if (g_inv_sbox_ready) return;
  for (int i = 0; i < 256; i++) g_inv_sbox[kSbox[i]] = (uint8_t)i;
  g_inv_sbox_ready = 1;
}

static uint8_t xtime(uint8_t x) {
  return (uint8_t)((x << 1) ^ ((x & 0x80) ? 0x1b : 0x00));
}

static uint8_t gmul(uint8_t a, uint8_t b) {
  uint8_t product = 0;
  while (b) {
    if (b & 1) product ^= a;
    a = xtime(a);
    b >>= 1;
  }
  return product;
}

void fushi_aes128_init(fushi_aes128 *aes, const uint8_t key[16]) {
  static const uint8_t kRcon[10] = {0x01, 0x02, 0x04, 0x08, 0x10,
                                    0x20, 0x40, 0x80, 0x1b, 0x36};
  uint8_t *w = aes->round_keys;
  memcpy(w, key, 16);
  for (int i = 4; i < 44; i++) {
    uint8_t t[4];
    memcpy(t, w + (i - 1) * 4, 4);
    if (i % 4 == 0) {
      const uint8_t first = t[0];
      t[0] = (uint8_t)(kSbox[t[1]] ^ kRcon[i / 4 - 1]);
      t[1] = kSbox[t[2]];
      t[2] = kSbox[t[3]];
      t[3] = kSbox[first];
    }
    for (int j = 0; j < 4; j++) w[i * 4 + j] = (uint8_t)(w[(i - 4) * 4 + j] ^ t[j]);
  }
  build_inv_sbox();
}

static void add_round_key(uint8_t s[16], const uint8_t *k) {
  for (int i = 0; i < 16; i++) s[i] ^= k[i];
}

/* State is column-major: s[c * 4 + r]. */
static void shift_rows(uint8_t s[16]) {
  uint8_t t[16];
  for (int c = 0; c < 4; c++)
    for (int r = 0; r < 4; r++) t[c * 4 + r] = s[((c + r) % 4) * 4 + r];
  memcpy(s, t, 16);
}

static void inv_shift_rows(uint8_t s[16]) {
  uint8_t t[16];
  for (int c = 0; c < 4; c++)
    for (int r = 0; r < 4; r++) t[((c + r) % 4) * 4 + r] = s[c * 4 + r];
  memcpy(s, t, 16);
}

static void mix_columns(uint8_t s[16]) {
  for (int c = 0; c < 4; c++) {
    uint8_t *col = s + c * 4;
    const uint8_t a0 = col[0], a1 = col[1], a2 = col[2], a3 = col[3];
    col[0] = (uint8_t)(gmul(a0, 2) ^ gmul(a1, 3) ^ a2 ^ a3);
    col[1] = (uint8_t)(a0 ^ gmul(a1, 2) ^ gmul(a2, 3) ^ a3);
    col[2] = (uint8_t)(a0 ^ a1 ^ gmul(a2, 2) ^ gmul(a3, 3));
    col[3] = (uint8_t)(gmul(a0, 3) ^ a1 ^ a2 ^ gmul(a3, 2));
  }
}

static void inv_mix_columns(uint8_t s[16]) {
  for (int c = 0; c < 4; c++) {
    uint8_t *col = s + c * 4;
    const uint8_t a0 = col[0], a1 = col[1], a2 = col[2], a3 = col[3];
    col[0] = (uint8_t)(gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9));
    col[1] = (uint8_t)(gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13));
    col[2] = (uint8_t)(gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11));
    col[3] = (uint8_t)(gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14));
  }
}

void fushi_aes128_encrypt(const fushi_aes128 *aes, const uint8_t in[16],
                          uint8_t out[16]) {
  uint8_t s[16];
  memcpy(s, in, 16);
  add_round_key(s, aes->round_keys);
  for (int round = 1; round <= 10; round++) {
    for (int i = 0; i < 16; i++) s[i] = kSbox[s[i]];
    shift_rows(s);
    if (round != 10) mix_columns(s);
    add_round_key(s, aes->round_keys + round * 16);
  }
  memcpy(out, s, 16);
}

void fushi_aes128_decrypt(const fushi_aes128 *aes, const uint8_t in[16],
                          uint8_t out[16]) {
  uint8_t s[16];
  memcpy(s, in, 16);
  add_round_key(s, aes->round_keys + 160);
  for (int round = 9; round >= 0; round--) {
    inv_shift_rows(s);
    for (int i = 0; i < 16; i++) s[i] = g_inv_sbox[s[i]];
    add_round_key(s, aes->round_keys + round * 16);
    if (round != 0) inv_mix_columns(s);
  }
  memcpy(out, s, 16);
}

void fushi_aes128_cbc_decrypt(const fushi_aes128 *aes, const uint8_t iv[16],
                              uint8_t *data, size_t length) {
  uint8_t previous[16];
  uint8_t cipher[16];
  memcpy(previous, iv, 16);
  for (size_t offset = 0; offset + 16 <= length; offset += 16) {
    memcpy(cipher, data + offset, 16);
    fushi_aes128_decrypt(aes, cipher, data + offset);
    for (int i = 0; i < 16; i++) data[offset + i] ^= previous[i];
    memcpy(previous, cipher, 16);
  }
}

static uint32_t rol32(uint32_t value, int bits) {
  return (value << bits) | (value >> (32 - bits));
}

static void sha1_block(uint32_t h[5], const uint8_t block[64]) {
  uint32_t w[80];
  for (int i = 0; i < 16; i++) {
    w[i] = ((uint32_t)block[i * 4] << 24) | ((uint32_t)block[i * 4 + 1] << 16) |
           ((uint32_t)block[i * 4 + 2] << 8) | (uint32_t)block[i * 4 + 3];
  }
  for (int i = 16; i < 80; i++) w[i] = rol32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
  uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
  for (int i = 0; i < 80; i++) {
    uint32_t f, k;
    if (i < 20) {
      f = (b & c) | (~b & d);
      k = 0x5a827999u;
    } else if (i < 40) {
      f = b ^ c ^ d;
      k = 0x6ed9eba1u;
    } else if (i < 60) {
      f = (b & c) | (b & d) | (c & d);
      k = 0x8f1bbcdcu;
    } else {
      f = b ^ c ^ d;
      k = 0xca62c1d6u;
    }
    const uint32_t t = rol32(a, 5) + f + e + k + w[i];
    e = d;
    d = c;
    c = rol32(b, 30);
    b = a;
    a = t;
  }
  h[0] += a;
  h[1] += b;
  h[2] += c;
  h[3] += d;
  h[4] += e;
}

void fushi_sha1(const uint8_t *data, size_t length, uint8_t digest[20]) {
  uint32_t h[5] = {0x67452301u, 0xefcdab89u, 0x98badcfeu, 0x10325476u,
                   0xc3d2e1f0u};
  size_t offset = 0;
  for (; offset + 64 <= length; offset += 64) sha1_block(h, data + offset);
  uint8_t tail[128];
  const size_t rest = length - offset;
  memset(tail, 0, sizeof(tail));
  memcpy(tail, data + offset, rest);
  tail[rest] = 0x80;
  const size_t tail_len = rest + 9 <= 64 ? 64 : 128;
  const uint64_t bits = (uint64_t)length * 8u;
  for (int i = 0; i < 8; i++) tail[tail_len - 1 - i] = (uint8_t)(bits >> (8 * i));
  sha1_block(h, tail);
  if (tail_len == 128) sha1_block(h, tail + 64);
  for (int i = 0; i < 5; i++) {
    digest[i * 4] = (uint8_t)(h[i] >> 24);
    digest[i * 4 + 1] = (uint8_t)(h[i] >> 16);
    digest[i * 4 + 2] = (uint8_t)(h[i] >> 8);
    digest[i * 4 + 3] = (uint8_t)h[i];
  }
}
