/*
 * Fushi AACS module: the libaacs public ABI subset that libbluray loads.
 *
 * libbluray dlopen()s "libaacs" whenever a disc carries an AACS directory and
 * reads every menu, IG and title stream through aacs_decrypt_unit(). Without a
 * loadable module, the disc menu cannot open an encrypted disc at all.
 *
 * Keys follow Fushi's existing policy (aacs_configuration.dart): only an exact
 * disc-ID volume unique key (VUK) from KEYDB, resolved by the app, is used.
 * The app registers it through fushi_aacs_set_disc_key() before opening the
 * disc; this module never reads configuration files, processes media key
 * blocks, talks to drives, removes bus encryption, or implements AACS 2/BD+.
 * Decryption matches AacsContentDecoder (aacs_content_decoder.dart) exactly.
 *
 * Exported names and signatures are those of VideoLAN libaacs 0.11 (aacs.h).
 * aacs_init/aacs_open_device are intentionally absent, so libbluray uses the
 * aacs_open2() path-based contract that Fushi's directory discs need.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fushi_aacs_crypto.h"

#ifdef _WIN32
#include <windows.h>
#define FUSHI_AACS_API __declspec(dllexport)
#else
#include <pthread.h>
#define FUSHI_AACS_API __attribute__((visibility("default")))
#endif

#define AACS_SUCCESS 0
#define AACS_ERROR_CORRUPTED_DISC (-1)
#define AACS_ERROR_NO_CONFIG (-2)
#define AACS_ERROR_UNKNOWN (-9)

#define ALIGNED_UNIT_LEN 6144
#define SOURCE_PACKET_LEN 192
#define MAX_UNIT_KEY_FILE (1024 * 1024)
#define MAX_CONTENT_CERT (64 * 1024)
#define MAX_REGISTERED_DISCS 16

/* Bumped whenever the fushi_aacs_* contract changes; checked by the app. */
#define FUSHI_AACS_ABI_VERSION 1

static const uint8_t kAacsIv[16] = {0x0b, 0xa0, 0xf8, 0xdd, 0xfe, 0xa6,
                                    0x1f, 0xb3, 0xd8, 0xdf, 0x9f, 0x56,
                                    0x6a, 0x05, 0x0f, 0x78};

typedef struct aacs {
  uint8_t disc_id[20];
  uint32_t key_count;
  fushi_aes128 *unit_keys;
  volatile uint32_t last_key;
  int mkb_version;
  int has_content_cert;
  uint8_t content_cert_id[6];
  int has_bdj_root_cert_hash;
  uint8_t bdj_root_cert_hash[20];
  int bus_encryption_enabled;
} AACS;

typedef struct {
  int used;
  uint8_t disc_id[20];
  int has_vuk;
  uint8_t vuk[16];
} registered_disc;

static registered_disc g_discs[MAX_REGISTERED_DISCS];
static unsigned g_next_slot = 0;

#ifdef _WIN32
static SRWLOCK g_lock = SRWLOCK_INIT;
static void registry_lock(void) { AcquireSRWLockExclusive(&g_lock); }
static void registry_unlock(void) { ReleaseSRWLockExclusive(&g_lock); }
#else
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static void registry_lock(void) { pthread_mutex_lock(&g_lock); }
static void registry_unlock(void) { pthread_mutex_unlock(&g_lock); }
#endif

static void secure_zero(void *data, size_t length) {
  volatile uint8_t *p = (volatile uint8_t *)data;
  while (length--) *p++ = 0;
}

static uint32_t be32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint32_t be24(const uint8_t *p) {
  return ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[2];
}

static uint16_t be16(const uint8_t *p) {
  return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

static FILE *open_utf8(const char *path) {
#ifdef _WIN32
  wchar_t wide[4096];
  if (!MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, 4096)) return NULL;
  return _wfopen(wide, L"rb");
#else
  return fopen(path, "rb");
#endif
}

/* Reads <device>/<relative> fully when it is at most max_bytes long. */
static uint8_t *read_disc_file(const char *device, const char *relative,
                               size_t max_bytes, size_t *length) {
  const size_t device_len = strlen(device);
  char *path = (char *)malloc(device_len + strlen(relative) + 2);
  if (!path) return NULL;
  memcpy(path, device, device_len);
  size_t at = device_len;
  if (at > 0 && path[at - 1] != '/' && path[at - 1] != '\\') path[at++] = '/';
  strcpy(path + at, relative);
  FILE *file = open_utf8(path);
  free(path);
  if (!file) return NULL;
  uint8_t *data = NULL;
  long size = -1;
  if (fseek(file, 0, SEEK_END) == 0) size = ftell(file);
  if (size > 0 && (size_t)size <= max_bytes && fseek(file, 0, SEEK_SET) == 0) {
    data = (uint8_t *)malloc((size_t)size);
    if (data && fread(data, 1, (size_t)size, file) != (size_t)size) {
      free(data);
      data = NULL;
    }
  }
  fclose(file);
  if (data) *length = (size_t)size;
  return data;
}

/* Returns 1 and copies the VUK (or reports a key-less plain disc). */
static int lookup_disc(const uint8_t disc_id[20], int *has_vuk, uint8_t vuk[16]) {
  int found = 0;
  registry_lock();
  for (int i = 0; i < MAX_REGISTERED_DISCS; i++) {
    if (g_discs[i].used && memcmp(g_discs[i].disc_id, disc_id, 20) == 0) {
      *has_vuk = g_discs[i].has_vuk;
      memcpy(vuk, g_discs[i].vuk, 16);
      found = 1;
      break;
    }
  }
  registry_unlock();
  return found;
}

/* Unit_Key_RO.inf layout as read by AacsContentDecoder.fromVolumeUniqueKey. */
static int load_unit_keys(AACS *aacs, const uint8_t *file, size_t length,
                          const uint8_t vuk[16]) {
  if (length < 20 || file[17] == 0) return AACS_ERROR_CORRUPTED_DISC;
  const uint32_t offset = be32(file);
  if (offset > length - 2) return AACS_ERROR_CORRUPTED_DISC;
  const uint32_t count = be16(file + offset);
  if (count == 0 || (uint64_t)offset + 16 + (uint64_t)count * 48 > length) {
    return AACS_ERROR_CORRUPTED_DISC;
  }
  aacs->unit_keys = (fushi_aes128 *)calloc(count, sizeof(fushi_aes128));
  if (!aacs->unit_keys) return AACS_ERROR_UNKNOWN;
  fushi_aes128 volume;
  fushi_aes128_init(&volume, vuk);
  for (uint32_t i = 0; i < count; i++) {
    uint8_t key[16];
    fushi_aes128_decrypt(&volume, file + offset + 48 * (i + 1), key);
    fushi_aes128_init(&aacs->unit_keys[i], key);
    secure_zero(key, sizeof(key));
  }
  secure_zero(&volume, sizeof(volume));
  aacs->key_count = count;
  return AACS_SUCCESS;
}

static void load_mkb_version(AACS *aacs, const char *device) {
  size_t length = 0;
  uint8_t *mkb = read_disc_file(device, "AACS/MKB_RO.inf", 64 * 1024 * 1024, &length);
  if (!mkb) return;
  /* Records are type(1) + length(3); "Type and Version" (0x10) holds it at +8. */
  for (size_t at = 0; at + 12 <= length;) {
    const uint32_t record_len = be24(mkb + at + 1);
    if (mkb[at] == 0x10) {
      aacs->mkb_version = (int)be32(mkb + at + 8);
      break;
    }
    if (record_len < 4) break;
    at += record_len;
  }
  free(mkb);
}

static void load_content_cert(AACS *aacs, const char *device) {
  static const char *const kNames[] = {"AACS/Content000.cer", "AACS/Content001.cer"};
  for (size_t n = 0; n < sizeof(kNames) / sizeof(kNames[0]); n++) {
    size_t length = 0;
    uint8_t *cert = read_disc_file(device, kNames[n], MAX_CONTENT_CERT, &length);
    if (!cert) continue;
    /* AACS 1 content certificate; AACS 2 is rejected by the app beforehand. */
    if (length >= 26 && cert[0] == 0x00) {
      aacs->has_content_cert = 1;
      aacs->bus_encryption_enabled = cert[1] >> 7;
      memcpy(aacs->content_cert_id, cert + 14, 6);
      if (be16(cert + 24) >= 40 && length >= 66) {
        aacs->has_bdj_root_cert_hash = 1;
        memcpy(aacs->bdj_root_cert_hash, cert + 46, 20);
      }
    }
    free(cert);
    if (aacs->has_content_cert) return;
  }
}

static void release(AACS *aacs) {
  if (!aacs) return;
  if (aacs->unit_keys) {
    secure_zero(aacs->unit_keys, aacs->key_count * sizeof(fushi_aes128));
    free(aacs->unit_keys);
  }
  free(aacs);
}

FUSHI_AACS_API AACS *aacs_open2(const char *path, const char *keyfile_path,
                                int *error_code) {
  (void)keyfile_path; /* Keys come only from fushi_aacs_set_disc_key(). */
  int error = AACS_ERROR_UNKNOWN;
  AACS *aacs = NULL;
  size_t length = 0;
  uint8_t *unit_file = path
      ? read_disc_file(path, "AACS/Unit_Key_RO.inf", MAX_UNIT_KEY_FILE, &length)
      : NULL;
  if (!unit_file || length < 16) {
    error = AACS_ERROR_CORRUPTED_DISC;
    goto done;
  }
  aacs = (AACS *)calloc(1, sizeof(AACS));
  if (!aacs) goto done;
  fushi_sha1(unit_file, length, aacs->disc_id);
  int has_vuk = 0;
  uint8_t vuk[16];
  if (!lookup_disc(aacs->disc_id, &has_vuk, vuk)) {
    error = AACS_ERROR_NO_CONFIG;
    goto done;
  }
  /* A registration without a VUK is the app's verdict that streams are clear. */
  error = has_vuk ? load_unit_keys(aacs, unit_file, length, vuk) : AACS_SUCCESS;
  secure_zero(vuk, sizeof(vuk));
  if (error != AACS_SUCCESS) goto done;
  load_mkb_version(aacs, path);
  load_content_cert(aacs, path);

done:
  free(unit_file);
  if (error != AACS_SUCCESS) {
    release(aacs);
    aacs = NULL;
  }
  if (error_code) *error_code = error;
  return aacs;
}

FUSHI_AACS_API AACS *aacs_open(const char *path, const char *keyfile_path) {
  return aacs_open2(path, keyfile_path, NULL);
}

FUSHI_AACS_API void aacs_close(AACS *aacs) { release(aacs); }

static int valid_transport(const uint8_t *unit) {
  for (int offset = 4; offset < ALIGNED_UNIT_LEN; offset += SOURCE_PACKET_LEN) {
    if (unit[offset] != 0x47) return 0;
  }
  return 1;
}

static int try_unit_key(const fushi_aes128 *unit_key, const uint8_t *input,
                        uint8_t *output) {
  uint8_t content_key[16];
  fushi_aes128_encrypt(unit_key, input, content_key);
  for (int i = 0; i < 16; i++) content_key[i] ^= input[i];
  fushi_aes128 content;
  fushi_aes128_init(&content, content_key);
  memcpy(output, input, ALIGNED_UNIT_LEN);
  fushi_aes128_cbc_decrypt(&content, kAacsIv, output + 16, ALIGNED_UNIT_LEN - 16);
  secure_zero(content_key, sizeof(content_key));
  secure_zero(&content, sizeof(content));
  return valid_transport(output);
}

/* Returns 1 on success (including clear units) and 0 when no key fits. */
FUSHI_AACS_API int aacs_decrypt_unit(AACS *aacs, uint8_t *buf) {
  if (!(buf[0] & 0xc0)) return 1;
  if (!aacs || aacs->key_count == 0) return 0;
  uint8_t candidate[ALIGNED_UNIT_LEN];
  const uint32_t first = aacs->last_key;
  for (uint32_t attempt = 0; attempt < aacs->key_count; attempt++) {
    const uint32_t index = (first + attempt) % aacs->key_count;
    if (!try_unit_key(&aacs->unit_keys[index], buf, candidate)) continue;
    /* libbluray rejects units whose copy_permission_indicator stays set. */
    for (int offset = 0; offset < ALIGNED_UNIT_LEN; offset += SOURCE_PACKET_LEN) {
      candidate[offset] &= 0x3f;
    }
    memcpy(buf, candidate, ALIGNED_UNIT_LEN);
    aacs->last_key = index;
    return 1;
  }
  return 0;
}

/* Bus encryption needs a drive's read data key, which file discs never have. */
FUSHI_AACS_API int aacs_decrypt_bus(AACS *aacs, uint8_t *buf) {
  (void)aacs;
  (void)buf;
  return -1;
}

/* Every unit tries all unit keys starting at the last match, as the decoder. */
FUSHI_AACS_API void aacs_select_title(AACS *aacs, uint32_t title_number) {
  (void)aacs;
  (void)title_number;
}

FUSHI_AACS_API int aacs_get_mkb_version(AACS *aacs) {
  return aacs ? aacs->mkb_version : 0;
}

FUSHI_AACS_API const uint8_t *aacs_get_disc_id(AACS *aacs) {
  return aacs ? aacs->disc_id : NULL;
}

FUSHI_AACS_API const uint8_t *aacs_get_content_cert_id(AACS *aacs) {
  return aacs && aacs->has_content_cert ? aacs->content_cert_id : NULL;
}

FUSHI_AACS_API const uint8_t *aacs_get_bdj_root_cert_hash(AACS *aacs) {
  return aacs && aacs->has_bdj_root_cert_hash ? aacs->bdj_root_cert_hash : NULL;
}

/* Values that need a drive or the media key block are not available. */
FUSHI_AACS_API const uint8_t *aacs_get_vid(AACS *aacs) {
  (void)aacs;
  return NULL;
}

FUSHI_AACS_API const uint8_t *aacs_get_pmsn(AACS *aacs) {
  (void)aacs;
  return NULL;
}

FUSHI_AACS_API const uint8_t *aacs_get_mk(AACS *aacs) {
  (void)aacs;
  return NULL;
}

FUSHI_AACS_API const uint8_t *aacs_get_device_binding_id(AACS *aacs) {
  (void)aacs;
  return NULL;
}

FUSHI_AACS_API const uint8_t *aacs_get_device_nonce(AACS *aacs) {
  (void)aacs;
  return NULL;
}

/* Enabled flag only: never "capable", so libbluray never asks for bus decrypt. */
FUSHI_AACS_API uint32_t aacs_get_bus_encryption(AACS *aacs) {
  return aacs && aacs->bus_encryption_enabled ? 1u : 0u;
}

FUSHI_AACS_API void aacs_get_version(int *major, int *minor, int *micro) {
  if (major) *major = 0;
  if (minor) *minor = 11;
  if (micro) *micro = 1;
}

FUSHI_AACS_API int fushi_aacs_abi_version(void) { return FUSHI_AACS_ABI_VERSION; }

/*
 * Registers the key for one disc (disc ID = SHA-1 of AACS/Unit_Key_RO.inf).
 * vuk == NULL records that the disc's streams are already clear. Returns 0.
 */
FUSHI_AACS_API int fushi_aacs_set_disc_key(const uint8_t *disc_id,
                                           const uint8_t *vuk) {
  if (!disc_id) return -1;
  registry_lock();
  registered_disc *slot = NULL;
  for (int i = 0; i < MAX_REGISTERED_DISCS && !slot; i++) {
    if (g_discs[i].used && memcmp(g_discs[i].disc_id, disc_id, 20) == 0) {
      slot = &g_discs[i];
    }
  }
  if (!slot) {
    slot = &g_discs[g_next_slot];
    g_next_slot = (g_next_slot + 1) % MAX_REGISTERED_DISCS;
  }
  secure_zero(slot, sizeof(*slot));
  slot->used = 1;
  memcpy(slot->disc_id, disc_id, 20);
  if (vuk) {
    slot->has_vuk = 1;
    memcpy(slot->vuk, vuk, 16);
  }
  registry_unlock();
  return 0;
}

FUSHI_AACS_API void fushi_aacs_forget_disc(const uint8_t *disc_id) {
  if (!disc_id) return;
  registry_lock();
  for (int i = 0; i < MAX_REGISTERED_DISCS; i++) {
    if (g_discs[i].used && memcmp(g_discs[i].disc_id, disc_id, 20) == 0) {
      secure_zero(&g_discs[i], sizeof(g_discs[i]));
    }
  }
  registry_unlock();
}
