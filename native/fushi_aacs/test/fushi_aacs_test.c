/*
 * Self-test for fushi_aacs: crypto vectors, then the libaacs ABI end to end on
 * a synthetic disc (AACS/Unit_Key_RO.inf + an encrypted aligned unit).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fushi_aacs_crypto.h"

#ifdef _WIN32
#include <direct.h>
#include <windows.h>
#define make_dir(path) _mkdir(path)
#else
#include <sys/stat.h>
#include <unistd.h>
#define make_dir(path) mkdir(path, 0700)
#endif

typedef struct aacs AACS;
AACS *aacs_open2(const char *path, const char *keyfile_path, int *error_code);
void aacs_close(AACS *aacs);
int aacs_decrypt_unit(AACS *aacs, uint8_t *buf);
const uint8_t *aacs_get_disc_id(AACS *aacs);
const uint8_t *aacs_get_content_cert_id(AACS *aacs);
uint32_t aacs_get_bus_encryption(AACS *aacs);
int aacs_get_mkb_version(AACS *aacs);
int fushi_aacs_abi_version(void);
int fushi_aacs_set_disc_key(const uint8_t *disc_id, const uint8_t *vuk);
void fushi_aacs_forget_disc(const uint8_t *disc_id);

static int g_failures = 0;

#define CHECK(cond)                                                   \
  do {                                                                \
    if (!(cond)) {                                                    \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      g_failures++;                                                   \
    }                                                                 \
  } while (0)

static const uint8_t kIv[16] = {0x0b, 0xa0, 0xf8, 0xdd, 0xfe, 0xa6, 0x1f, 0xb3,
                                0xd8, 0xdf, 0x9f, 0x56, 0x6a, 0x05, 0x0f, 0x78};

static void test_vectors(void) {
  /* FIPS-197 appendix C.1. */
  uint8_t key[16], plain[16], out[16], back[16];
  for (int i = 0; i < 16; i++) {
    key[i] = (uint8_t)i;
    plain[i] = (uint8_t)(i * 0x11);
  }
  static const uint8_t expected[16] = {0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b,
                                       0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80,
                                       0x70, 0xb4, 0xc5, 0x5a};
  fushi_aes128 aes;
  fushi_aes128_init(&aes, key);
  fushi_aes128_encrypt(&aes, plain, out);
  CHECK(memcmp(out, expected, 16) == 0);
  fushi_aes128_decrypt(&aes, out, back);
  CHECK(memcmp(back, plain, 16) == 0);

  /* FIPS 180-4 "abc" and the two-block padding boundary (56 bytes). */
  static const uint8_t abc[20] = {0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81,
                                  0x6a, 0xba, 0x3e, 0x25, 0x71, 0x78, 0x50,
                                  0xc2, 0x6c, 0x9c, 0xd0, 0xd8, 0x9d};
  uint8_t digest[20];
  fushi_sha1((const uint8_t *)"abc", 3, digest);
  CHECK(memcmp(digest, abc, 20) == 0);
  static const char kLong[] =
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
  static const uint8_t long_digest[20] = {
      0x84, 0x98, 0x3e, 0x44, 0x1c, 0x3b, 0xd2, 0x6e, 0xba, 0xae,
      0x4a, 0xa1, 0xf9, 0x51, 0x29, 0xe5, 0xe5, 0x46, 0x70, 0xf1};
  fushi_sha1((const uint8_t *)kLong, strlen(kLong), digest);
  CHECK(memcmp(digest, long_digest, 20) == 0);
}

static void write_file(const char *path, const uint8_t *data, size_t length) {
  FILE *file = fopen(path, "wb");
  if (!file) {
    fprintf(stderr, "cannot write %s\n", path);
    exit(2);
  }
  fwrite(data, 1, length, file);
  fclose(file);
}

static void make_plain_unit(uint8_t unit[6144], uint8_t seed) {
  for (int i = 0; i < 6144; i++) unit[i] = (uint8_t)(seed + i * 7);
  for (int packet = 0; packet < 32; packet++) {
    unit[packet * 192] = (uint8_t)(0xc0 | (unit[packet * 192] & 0x3f));
    unit[packet * 192 + 4] = 0x47;
  }
}

/* Inverse of the AACS aligned-unit decryption, for the fixture only. */
static void encrypt_unit(const uint8_t unit_key[16], const uint8_t plain[6144],
                         uint8_t out[6144]) {
  fushi_aes128 uk, content;
  uint8_t derived[16];
  fushi_aes128_init(&uk, unit_key);
  fushi_aes128_encrypt(&uk, plain, derived);
  for (int i = 0; i < 16; i++) derived[i] ^= plain[i];
  fushi_aes128_init(&content, derived);
  memcpy(out, plain, 16);
  uint8_t chain[16];
  memcpy(chain, kIv, 16);
  for (int offset = 16; offset < 6144; offset += 16) {
    uint8_t block[16];
    for (int i = 0; i < 16; i++) block[i] = (uint8_t)(plain[offset + i] ^ chain[i]);
    fushi_aes128_encrypt(&content, block, out + offset);
    memcpy(chain, out + offset, 16);
  }
}

int main(void) {
  test_vectors();
  CHECK(fushi_aacs_abi_version() == 1);

  char root[512];
#ifdef _WIN32
  char temp[MAX_PATH];
  GetTempPathA(MAX_PATH, temp);
  snprintf(root, sizeof(root), "%sfushi_aacs_test_%lu", temp,
           (unsigned long)GetCurrentProcessId());
#else
  snprintf(root, sizeof(root), "/tmp/fushi_aacs_test_%ld", (long)getpid());
#endif
  char dir[600], path[700];
  make_dir(root);
  snprintf(dir, sizeof(dir), "%s/AACS", root);
  make_dir(dir);

  const uint8_t vuk[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
  const uint8_t unit_keys[2][16] = {
      {0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe, 0, 1, 2, 3, 4, 5, 6, 7},
      {0xa5, 0x5a, 0xa5, 0x5a, 0x11, 0x22, 0x33, 0x44, 9, 8, 7, 6, 5, 4, 3, 2}};
  uint8_t unit_file[176];
  memset(unit_file, 0, sizeof(unit_file));
  unit_file[3] = 64; /* table offset */
  unit_file[17] = 1; /* header title count */
  unit_file[65] = 2; /* two CPS unit keys */
  fushi_aes128 volume;
  fushi_aes128_init(&volume, vuk);
  fushi_aes128_encrypt(&volume, unit_keys[0], unit_file + 64 + 48);
  fushi_aes128_encrypt(&volume, unit_keys[1], unit_file + 64 + 96);
  snprintf(path, sizeof(path), "%s/Unit_Key_RO.inf", dir);
  write_file(path, unit_file, sizeof(unit_file));

  uint8_t cert[100];
  memset(cert, 0, sizeof(cert));
  cert[1] = 0x80; /* bus encryption enabled */
  memcpy(cert + 14, "\x01\x02\x03\x04\x05\x06", 6);
  snprintf(path, sizeof(path), "%s/Content000.cer", dir);
  write_file(path, cert, sizeof(cert));

  uint8_t mkb[16] = {0x10, 0x00, 0x00, 0x0c, 0, 0, 0, 0, 0x00, 0x00, 0x00, 0x44};
  snprintf(path, sizeof(path), "%s/MKB_RO.inf", dir);
  write_file(path, mkb, 12);

  uint8_t disc_id[20];
  fushi_sha1(unit_file, sizeof(unit_file), disc_id);

  int error = 0;
  CHECK(aacs_open2(root, NULL, &error) == NULL);
  CHECK(error == -2); /* not registered: no configuration */

  fushi_aacs_set_disc_key(disc_id, vuk);
  AACS *aacs = aacs_open2(root, NULL, &error);
  CHECK(aacs != NULL);
  CHECK(error == 0);
  if (aacs) {
    CHECK(memcmp(aacs_get_disc_id(aacs), disc_id, 20) == 0);
    CHECK(aacs_get_content_cert_id(aacs) != NULL &&
          memcmp(aacs_get_content_cert_id(aacs), "\x01\x02\x03\x04\x05\x06", 6) == 0);
    CHECK(aacs_get_bus_encryption(aacs) == 1);
    CHECK(aacs_get_mkb_version(aacs) == 0x44);

    uint8_t plain[6144], unit[6144];
    for (int k = 1; k >= 0; k--) { /* second key first: exercises key search */
      make_plain_unit(plain, (uint8_t)(k * 31 + 5));
      encrypt_unit(unit_keys[k], plain, unit);
      CHECK(memcmp(unit, plain, 6144) != 0);
      CHECK(aacs_decrypt_unit(aacs, unit) == 1);
      for (int packet = 0; packet < 32; packet++) plain[packet * 192] &= 0x3f;
      CHECK(memcmp(unit, plain, 6144) == 0);
    }
    /* A clear unit passes through untouched. */
    CHECK(aacs_decrypt_unit(aacs, plain) == 1);
    /* Garbage marked encrypted fails without changing the buffer. */
    uint8_t garbage[6144], copy[6144];
    for (int i = 0; i < 6144; i++) garbage[i] = (uint8_t)(i * 13 + 1);
    garbage[0] |= 0xc0;
    memcpy(copy, garbage, 6144);
    CHECK(aacs_decrypt_unit(aacs, garbage) == 0);
    CHECK(memcmp(garbage, copy, 6144) == 0);
    aacs_close(aacs);
  }

  /* Wrong VUK: opens (keys cannot be checked offline) but never decrypts. */
  uint8_t wrong[16];
  memcpy(wrong, vuk, 16);
  wrong[0] ^= 0xff;
  fushi_aacs_set_disc_key(disc_id, wrong);
  aacs = aacs_open2(root, NULL, &error);
  CHECK(aacs != NULL);
  if (aacs) {
    uint8_t plain[6144], unit[6144];
    make_plain_unit(plain, 9);
    encrypt_unit(unit_keys[0], plain, unit);
    CHECK(aacs_decrypt_unit(aacs, unit) == 0);
    aacs_close(aacs);
  }

  /* Clear-disc registration: opens without keys; encrypted units fail. */
  fushi_aacs_set_disc_key(disc_id, NULL);
  aacs = aacs_open2(root, NULL, &error);
  CHECK(aacs != NULL && error == 0);
  if (aacs) {
    uint8_t plain[6144], unit[6144];
    make_plain_unit(plain, 3);
    encrypt_unit(unit_keys[0], plain, unit);
    CHECK(aacs_decrypt_unit(aacs, unit) == 0);
    plain[0] &= 0x3f;
    CHECK(aacs_decrypt_unit(aacs, plain) == 1);
    aacs_close(aacs);
  }

  fushi_aacs_forget_disc(disc_id);
  CHECK(aacs_open2(root, NULL, &error) == NULL && error == -2);

  /* Missing Unit_Key_RO.inf is a corrupted disc. */
  snprintf(path, sizeof(path), "%s/missing", root);
  CHECK(aacs_open2(path, NULL, &error) == NULL && error == -1);

  snprintf(path, sizeof(path), "%s/Unit_Key_RO.inf", dir);
  remove(path);
  snprintf(path, sizeof(path), "%s/Content000.cer", dir);
  remove(path);
  snprintf(path, sizeof(path), "%s/MKB_RO.inf", dir);
  remove(path);
#ifdef _WIN32
  _rmdir(dir);
  _rmdir(root);
#else
  rmdir(dir);
  rmdir(root);
#endif

  if (g_failures) {
    fprintf(stderr, "%d check(s) failed\n", g_failures);
    return 1;
  }
  printf("fushi_aacs_test: all checks passed\n");
  return 0;
}
