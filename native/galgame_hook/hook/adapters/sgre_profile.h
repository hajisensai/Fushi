#pragma once

#include <windows.h>
#include <bcrypt.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "sgre_anchors.h"
#include "sgre_lookup.h"
#include "sgre_voice_archive.h"

#pragma comment(lib, "bcrypt.lib")

namespace fushi_voice_hook {

// ── Identity ────────────────────────────────────────────────────────────────
//
// Two layers, deliberately separate:
//
//   * Family: the process runs the M2 wind3d11 runtime. The runtime keeps all
//     character voice in `wind3d11data\voice_body.bin` next to the executable;
//     that archive is the data contract the audio adapter proves membership
//     against, so it is also the family identity. No executable name, no hash.
//
//   * Build: the executable SHA-256 selects a row of measured anchors
//     (kSgreKnownBuilds). A miss is not a rejection any more -- it sends anchor
//     resolution down the signature path (sgre_anchors.h). Every hook site
//     still requires its own resolved anchor; nothing is ever hooked at an
//     address that was neither measured nor uniquely matched.

// True when the digest matches a measured build row.
inline bool MatchesSgreExecutableHash(const uint8_t* digest,
                                      size_t digest_bytes) {
  return FindSgreKnownBuild(digest, digest_bytes) != nullptr;
}

inline bool Sha256FileForSgreProfile(const wchar_t* path,
                                     std::array<uint8_t, 32>* digest) {
  if (path == nullptr || digest == nullptr) return false;
  HANDLE file = CreateFileW(path, GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_bytes = 0;
  DWORD hash_bytes = 0;
  DWORD result_bytes = 0;
  bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                        nullptr, 0) == 0;
  if (ok) {
    ok = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                           reinterpret_cast<PUCHAR>(&object_bytes),
                           sizeof(object_bytes), &result_bytes, 0) == 0;
  }
  if (ok) {
    ok = BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH,
                           reinterpret_cast<PUCHAR>(&hash_bytes),
                           sizeof(hash_bytes), &result_bytes, 0) == 0 &&
         hash_bytes == digest->size();
  }
  std::vector<uint8_t> hash_object(object_bytes);
  if (ok) {
    ok = BCryptCreateHash(algorithm, &hash, hash_object.data(), object_bytes,
                          nullptr, 0, 0) == 0;
  }
  std::array<uint8_t, 64 * 1024> buffer = {};
  while (ok) {
    DWORD read = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &read, nullptr)) {
      ok = false;
      break;
    }
    if (read == 0) break;
    ok = BCryptHashData(hash, buffer.data(), read, 0) == 0;
  }
  if (ok) {
    ok = BCryptFinishHash(hash, digest->data(),
                          static_cast<ULONG>(digest->size()), 0) == 0;
  }
  if (hash != nullptr) BCryptDestroyHash(hash);
  if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  CloseHandle(file);
  return ok;
}

inline bool SgreExecutablePath(std::wstring* path_out) {
  if (path_out == nullptr) return false;
  wchar_t executable[32768] = {};
  const DWORD chars = GetModuleFileNameW(
      nullptr, executable,
      static_cast<DWORD>(sizeof(executable) / sizeof(executable[0])));
  if (chars == 0 || chars >= sizeof(executable) / sizeof(executable[0])) {
    return false;
  }
  path_out->assign(executable, chars);
  return true;
}

inline bool SgreVoiceArchivePath(std::wstring* archive_path) {
  if (archive_path == nullptr) return false;
  std::wstring path;
  if (!SgreExecutablePath(&path)) return false;
  const size_t slash = path.find_last_of(L"/\\");
  if (slash == std::wstring::npos) return false;
  path.resize(slash + 1);
  path += L"wind3d11data\\voice_body.bin";
  *archive_path = std::move(path);
  return true;
}

// Family probe: the wind3d11 voice archive sits next to the executable.
inline bool MatchesSgreFamily() {
  std::wstring archive_path;
  return SgreVoiceArchivePath(&archive_path) &&
         GetFileAttributesW(archive_path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// ── In-process image view ───────────────────────────────────────────────────

// POD only: this runs under SEH, which MSVC refuses to combine with objects
// that need unwinding.
inline bool ReadSgreImageSectionsUnsafe(const uint8_t* base,
                                        SgreImageView* view) {
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE) return false;
  const WORD expected_magic = sizeof(void*) == 8 ? IMAGE_NT_OPTIONAL_HDR64_MAGIC
                                                 : IMAGE_NT_OPTIONAL_HDR32_MAGIC;
  if (nt->OptionalHeader.Magic != expected_magic) return false;
  const DWORD image_size = nt->OptionalHeader.SizeOfImage;
  const IMAGE_SECTION_HEADER* section = IMAGE_FIRST_SECTION(nt);
  const size_t count = nt->FileHeader.NumberOfSections;
  view->image_base = reinterpret_cast<uintptr_t>(base);
  view->section_count = 0;
  for (size_t i = 0; i < count && view->section_count < kSgreImageMaxSections;
       ++i) {
    const IMAGE_SECTION_HEADER& s = section[i];
    if (s.VirtualAddress == 0 || s.Misc.VirtualSize == 0) continue;
    if (s.VirtualAddress > image_size ||
        s.Misc.VirtualSize > image_size - s.VirtualAddress) {
      continue;
    }
    SgreImageSection& out = view->sections[view->section_count++];
    std::memcpy(out.name, s.Name, IMAGE_SIZEOF_SHORT_NAME);
    out.name[IMAGE_SIZEOF_SHORT_NAME] = '\0';
    out.rva = s.VirtualAddress;
    out.size = s.Misc.VirtualSize;
    out.bytes = base + s.VirtualAddress;
    out.executable = (s.Characteristics & IMAGE_SCN_MEM_EXECUTE) != 0;
    out.writable = (s.Characteristics & IMAGE_SCN_MEM_WRITE) != 0;
  }
  return view->section_count != 0;
}

inline bool ReadSgreImageSections(HMODULE module, SgreImageView* view) {
  if (module == nullptr || view == nullptr) return false;
  bool ok = false;
  __try {
    ok = ReadSgreImageSectionsUnsafe(reinterpret_cast<const uint8_t*>(module),
                                     view);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    ok = false;
  }
  return ok;
}

// Signature scanning touches every byte of the named sections. Pages can be
// guard/no-access in a live process; SEH turns that into "unresolved" rather
// than a crash.
inline bool ResolveSgreAnchorsGuarded(const uint8_t* digest,
                                      size_t digest_bytes,
                                      const SgreImageView* image,
                                      SgreAnchorSet* out) {
  if (out == nullptr || image == nullptr) return false;
  bool ok = false;
  __try {
    *out = ResolveSgreAnchors(digest, digest_bytes, *image);
    ok = true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    ok = false;
  }
  return ok;
}

// Resolves the anchors of the running executable: measured row on a hash hit,
// signature scan otherwise. `digest_out` receives the executable SHA-256 when
// it could be computed (all zero otherwise) so the caller can report it.
inline SgreAnchorSet ResolveSgreRuntimeAnchors(
    std::array<uint8_t, 32>* digest_out) {
  SgreAnchorSet anchors;
  std::array<uint8_t, 32> digest = {};
  std::wstring executable;
  const bool hashed = SgreExecutablePath(&executable) &&
                      Sha256FileForSgreProfile(executable.c_str(), &digest);
  if (digest_out != nullptr) {
    *digest_out = hashed ? digest : std::array<uint8_t, 32>{};
  }
  // Static storage: the view is ~1 KB of section descriptors and only ever
  // describes the main module, which never unloads.
  static SgreImageView image;
  if (!ReadSgreImageSections(GetModuleHandleW(nullptr), &image)) {
    image.section_count = 0;
  }
  if (!ResolveSgreAnchorsGuarded(hashed ? digest.data() : nullptr,
                                 hashed ? digest.size() : 0, &image,
                                 &anchors)) {
    anchors = SgreAnchorSet();
  }
  return anchors;
}

}  // namespace fushi_voice_hook
