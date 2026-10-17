/*
 * Self-contained AES-128 and SHA-1 for the Fushi AACS module.
 *
 * Kept dependency-free so the same source builds unchanged for Windows,
 * Android and macOS without linking a platform crypto library.
 */
#ifndef FUSHI_AACS_CRYPTO_H
#define FUSHI_AACS_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint8_t round_keys[176];
} fushi_aes128;

void fushi_aes128_init(fushi_aes128 *aes, const uint8_t key[16]);
void fushi_aes128_encrypt(const fushi_aes128 *aes, const uint8_t in[16],
                          uint8_t out[16]);
void fushi_aes128_decrypt(const fushi_aes128 *aes, const uint8_t in[16],
                          uint8_t out[16]);

/* In-place AES-128-CBC decryption; length must be a multiple of 16. */
void fushi_aes128_cbc_decrypt(const fushi_aes128 *aes, const uint8_t iv[16],
                              uint8_t *data, size_t length);

void fushi_sha1(const uint8_t *data, size_t length, uint8_t digest[20]);

#endif
