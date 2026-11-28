#ifndef RUNNER_DART_AOT_IMAGE_H_
#define RUNNER_DART_AOT_IMAGE_H_

// Where the Dart AOT snapshot (data\app.so) sits in memory, for symbolizing
// hang / crash dumps.
//
// On Windows the engine loads app.so with Dart's own ELF loader (VirtualAlloc +
// copy), not LoadLibrary. The minidump's module list therefore has no entry for
// it, and every Dart frame in cdb is a bare `0x0000021e\`f3f2966f`. To map such
// a frame to `file:line` we need two things: the image's load base (the frame
// minus the base is the ELF virtual address) and the GNU build-id (which picks
// the right saved debugging-info file, the `windows-dart-symbols-<sequence>`
// CI artifact). [FindDartAotImage] finds both by walking the address space;
// crash_dump.cpp writes them into every minidump as a user stream, and
// hang_watchdog.cpp also appends them to hang_watchdog.log.
//
// The parsing half is pure (header-only, no Win32) so
// tests/dart_aot_image_test.cpp runs it against hand-built ELF buffers.

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace fushi
{
  // Minidump user stream that carries the [FormatDartAotImageLine] text
  // (> LastReservedStream, so it never collides with a dbghelp stream).
  // tool/windows_dump_symbolize.dart reads it back by this number.
  constexpr uint32_t kDartAotImageStreamType = 0x46555348;  // 'FUSH'

  struct DartAotImageInfo
  {
    uint64_t base = 0;
    // Bytes from [base] to the end of the last PT_LOAD segment.
    uint64_t span = 0;
    // Lower-case hex, NUL-terminated (build-ids are 16–32 bytes; 64 hex max).
    char build_id[65] = {};
  };

  namespace dart_aot_image_detail
  {
    inline bool ReadU16(const uint8_t* p, size_t size, size_t off, uint16_t* out)
    {
      if (off > size || size - off < 2) return false;
      std::memcpy(out, p + off, 2);
      return true;
    }

    inline bool ReadU32(const uint8_t* p, size_t size, size_t off, uint32_t* out)
    {
      if (off > size || size - off < 4) return false;
      std::memcpy(out, p + off, 4);
      return true;
    }

    inline bool ReadU64(const uint8_t* p, size_t size, size_t off, uint64_t* out)
    {
      if (off > size || size - off < 8) return false;
      std::memcpy(out, p + off, 8);
      return true;
    }
  }  // namespace dart_aot_image_detail

  // Parses an ELF64 little-endian x86-64 image mapped at [image] (the loaded
  // layout: segment p_vaddr is the offset from [image]). [readable] is how many
  // bytes from [image] may be read. On success fills [out]->span and
  // [out]->build_id (empty when the image has no GNU build-id note) and returns
  // true. [out]->base is left to the caller.
  inline bool DescribeLoadedElf(const uint8_t* image, size_t readable,
                                DartAotImageInfo* out)
  {
    using namespace dart_aot_image_detail;
    if (image == nullptr || out == nullptr || readable < 64) return false;
    if (std::memcmp(image, "\x7f" "ELF", 4) != 0) return false;
    // ELFCLASS64, ELFDATA2LSB.
    if (image[4] != 2 || image[5] != 1) return false;
    uint16_t machine = 0;
    if (!ReadU16(image, readable, 0x12, &machine) || machine != 62) {
      return false;  // EM_X86_64
    }
    uint64_t phoff = 0;
    uint16_t phentsize = 0;
    uint16_t phnum = 0;
    if (!ReadU64(image, readable, 0x20, &phoff) ||
        !ReadU16(image, readable, 0x36, &phentsize) ||
        !ReadU16(image, readable, 0x38, &phnum) || phentsize < 56 ||
        phnum == 0) {
      return false;
    }
    uint64_t span = 0;
    out->build_id[0] = '\0';
    for (uint16_t i = 0; i < phnum; ++i) {
      const uint64_t ph = phoff + static_cast<uint64_t>(i) * phentsize;
      if (ph > readable) return false;
      const size_t at = static_cast<size_t>(ph);
      uint32_t p_type = 0;
      uint64_t p_vaddr = 0;
      uint64_t p_filesz = 0;
      uint64_t p_memsz = 0;
      if (!ReadU32(image, readable, at, &p_type) ||
          !ReadU64(image, readable, at + 0x10, &p_vaddr) ||
          !ReadU64(image, readable, at + 0x20, &p_filesz) ||
          !ReadU64(image, readable, at + 0x28, &p_memsz)) {
        return false;
      }
      if (p_type == 1 && p_vaddr + p_memsz > span) span = p_vaddr + p_memsz;
      if (p_type != 4 || out->build_id[0] != '\0') continue;  // PT_NOTE
      // Walk the notes for NT_GNU_BUILD_ID (type 3, name "GNU").
      uint64_t note = p_vaddr;
      const uint64_t note_end = p_vaddr + p_filesz;
      while (note + 12 <= note_end && note + 12 <= readable) {
        uint32_t namesz = 0;
        uint32_t descsz = 0;
        uint32_t ntype = 0;
        const size_t n = static_cast<size_t>(note);
        ReadU32(image, readable, n, &namesz);
        ReadU32(image, readable, n + 4, &descsz);
        ReadU32(image, readable, n + 8, &ntype);
        const uint64_t desc = note + 12 + ((namesz + 3ull) & ~3ull);
        const uint64_t next = desc + ((descsz + 3ull) & ~3ull);
        if (next > note_end || next > readable) break;
        if (ntype == 3 && namesz == 4 &&
            std::memcmp(image + n + 12, "GNU", 4) == 0 && descsz > 0 &&
            descsz <= 32) {
          static const char kHex[] = "0123456789abcdef";
          for (uint32_t b = 0; b < descsz; ++b) {
            const uint8_t v = image[static_cast<size_t>(desc) + b];
            out->build_id[b * 2] = kHex[v >> 4];
            out->build_id[b * 2 + 1] = kHex[v & 0xF];
          }
          out->build_id[descsz * 2] = '\0';
          break;
        }
        note = next;
      }
    }
    if (span == 0) return false;
    out->span = span;
    return true;
  }

  // Only the real image counts: Dart's loader also leaves a one-page copy of
  // the ELF header elsewhere, whose allocation is far smaller than the span its
  // program headers describe.
  inline bool IsLoadedImageAllocation(uint64_t allocation_size, uint64_t span)
  {
    return span > 0 && allocation_size >= span;
  }

  // `dart_aot base=0x<hex> span=0x<hex> build_id=<hex>` — the line both the
  // minidump user stream and hang_watchdog.log carry. Returns the length, or 0
  // when [buf] is too small.
  inline size_t FormatDartAotImageLine(const DartAotImageInfo& info, char* buf,
                                       size_t buf_size)
  {
    const int n = std::snprintf(buf, buf_size,
      "dart_aot base=0x%llx span=0x%llx build_id=%s",
      static_cast<unsigned long long>(info.base),
      static_cast<unsigned long long>(info.span),
      info.build_id[0] ? info.build_id : "none");
    if (n <= 0 || static_cast<size_t>(n) >= buf_size) return 0;
    return static_cast<size_t>(n);
  }

  // Finds the loaded Dart AOT image in this process (zero heap; safe from the
  // crash filter and the watchdog thread). The result is cached after the
  // first success — the image never moves. Returns false before the engine has
  // loaded app.so (or in a JIT debug build, which has no app.so).
  bool FindDartAotImage(DartAotImageInfo* out);
}

#endif  // RUNNER_DART_AOT_IMAGE_H_
