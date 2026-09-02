#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

// Some focused tests include windows.h before this header. Keep the helper
// usable from ordinary C++ headers even in that order.
#ifdef min
#undef min
#endif
#ifdef max
#undef max
#endif

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace fushi_voice_hook::exact_lookup {

// A signature is only a candidate locator. Every production caller must also
// bind its sole match back to an exact-hash profile RVA and validate the PE
// section/call graph/ABI that gives that RVA meaning. A null mask means every
// byte is significant; a zero mask byte wildcards the corresponding byte.
struct MaskedPattern {
  const uint8_t* bytes = nullptr;
  const uint8_t* mask = nullptr;
  size_t size = 0u;
};

struct UniquePatternMatch {
  const uint8_t* address = nullptr;
  // Saturates at two: callers distinguish no match, exactly one, and
  // ambiguous. An ambiguous result never exposes an address.
  uint32_t count = 0u;
};

template <size_t Size>
constexpr std::array<uint8_t, Size> MaskExceptRanges(
    size_t first_begin = Size, size_t first_end = Size,
    size_t second_begin = Size, size_t second_end = Size,
    size_t third_begin = Size, size_t third_end = Size,
    size_t fourth_begin = Size, size_t fourth_end = Size) {
  std::array<uint8_t, Size> mask = {};
  for (size_t index = 0u; index < Size; ++index) mask[index] = 0xffu;
  const size_t begins[4] = {first_begin, second_begin, third_begin,
                            fourth_begin};
  const size_t ends[4] = {first_end, second_end, third_end, fourth_end};
  for (size_t range = 0u; range < 4u; ++range) {
    const size_t begin = begins[range] < Size ? begins[range] : Size;
    const size_t end = ends[range] < Size ? ends[range] : Size;
    for (size_t index = begin; index < end; ++index) mask[index] = 0u;
  }
  return mask;
}

inline bool MatchesMaskedPattern(const uint8_t* candidate,
                                 const MaskedPattern& pattern) {
  if (candidate == nullptr || pattern.bytes == nullptr || pattern.size == 0u) {
    return false;
  }
  for (size_t index = 0u; index < pattern.size; ++index) {
    if (pattern.mask != nullptr && pattern.mask[index] == 0u) continue;
    if (candidate[index] != pattern.bytes[index]) return false;
  }
  return true;
}

inline UniquePatternMatch FindUniqueMaskedPattern(const uint8_t* bytes,
                                                   size_t byte_count,
                                                   const MaskedPattern& pattern) {
  UniquePatternMatch result;
  if (bytes == nullptr || pattern.size == 0u || pattern.size > byte_count) {
    return result;
  }
  for (size_t offset = 0u; offset <= byte_count - pattern.size; ++offset) {
    if (!MatchesMaskedPattern(bytes + offset, pattern)) continue;
    if (result.count == 0u) result.address = bytes + offset;
    if (++result.count > 1u) {
      result.count = 2u;
      result.address = nullptr;
      return result;
    }
  }
  return result;
}

inline bool IsReadableProtection(DWORD protection) {
  const DWORD base = protection & 0xffu;
  return base == PAGE_READONLY || base == PAGE_READWRITE ||
         base == PAGE_WRITECOPY || base == PAGE_EXECUTE_READ ||
         base == PAGE_EXECUTE_READWRITE || base == PAGE_EXECUTE_WRITECOPY;
}

inline bool IsExecutableProtection(DWORD protection) {
  const DWORD base = protection & 0xffu;
  return base == PAGE_EXECUTE || base == PAGE_EXECUTE_READ ||
         base == PAGE_EXECUTE_READWRITE ||
         base == PAGE_EXECUTE_WRITECOPY;
}

inline bool IsReadableSpan(const void* address, size_t bytes) {
  if (address == nullptr || bytes == 0u) return false;
  const uintptr_t begin = reinterpret_cast<uintptr_t>(address);
  if (begin > (std::numeric_limits<uintptr_t>::max)() - bytes) return false;
  const uintptr_t end = begin + bytes;
  uintptr_t cursor = begin;
  while (cursor < end) {
    MEMORY_BASIC_INFORMATION memory = {};
    if (VirtualQuery(reinterpret_cast<const void*>(cursor), &memory,
                     sizeof(memory)) != sizeof(memory) ||
        memory.State != MEM_COMMIT ||
        (memory.Protect & (PAGE_GUARD | PAGE_NOACCESS)) != 0u ||
        !IsReadableProtection(memory.Protect)) {
      return false;
    }
    const uintptr_t region = reinterpret_cast<uintptr_t>(memory.BaseAddress);
    if (region > (std::numeric_limits<uintptr_t>::max)() - memory.RegionSize) {
      return false;
    }
    const uintptr_t next = region + memory.RegionSize;
    if (next <= cursor) return false;
    cursor = (std::min)(next, end);
  }
  return true;
}

inline bool IsExecutableAddress(const void* address) {
  if (address == nullptr) return false;
  MEMORY_BASIC_INFORMATION memory = {};
  return VirtualQuery(address, &memory, sizeof(memory)) == sizeof(memory) &&
         memory.State == MEM_COMMIT &&
         (memory.Protect & (PAGE_GUARD | PAGE_NOACCESS)) == 0u &&
         IsExecutableProtection(memory.Protect);
}

struct LoadedPeSection {
  const uint8_t* bytes = nullptr;
  size_t size = 0u;
  uint32_t rva = 0u;
  uint32_t characteristics = 0u;
};

struct LoadedPeImage {
  const uint8_t* base = nullptr;
  // 绝对 VA 操作数所对齐的基址。0 表示与 base 相同——进程内已加载的模块就是这种情况
  // （代码里的绝对操作数已被重定位成实际加载基址）。而把**磁盘上的原始映像**映射进来
  // 校验时（LOAD_LIBRARY_AS_IMAGE_RESOURCE 明确不施加重定位）两者必然不同：读字节要用
  // 映射地址 base，解绝对操作数却要用 PE 头里的首选基址。合成一个字段会让其中一路恒错。
  uintptr_t absolute_base = 0u;
  size_t size = 0u;
  uint16_t machine = 0u;
  uint8_t pointer_bits = 0u;
  std::array<LoadedPeSection, 96u> sections = {};
  size_t section_count = 0u;
};

inline bool OpenLoadedPeImage(HMODULE module, LoadedPeImage* image) {
  if (module == nullptr || image == nullptr) return false;
  *image = {};
  const auto* base = reinterpret_cast<const uint8_t*>(module);
  if (!IsReadableSpan(base, sizeof(IMAGE_DOS_HEADER))) return false;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
      dos->e_lfanew > 1024 * 1024) {
    return false;
  }
  const size_t nt_offset = static_cast<size_t>(dos->e_lfanew);
  const size_t fixed_nt_bytes =
      sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER) + sizeof(WORD);
  if (!IsReadableSpan(base + nt_offset, fixed_nt_bytes)) return false;
  DWORD signature = 0u;
  std::memcpy(&signature, base + nt_offset, sizeof(signature));
  if (signature != IMAGE_NT_SIGNATURE) return false;
  IMAGE_FILE_HEADER file = {};
  std::memcpy(&file, base + nt_offset + sizeof(DWORD), sizeof(file));
  if (file.NumberOfSections == 0u ||
      file.NumberOfSections > image->sections.size()) {
    return false;
  }
  const uint8_t* optional =
      base + nt_offset + sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER);
  if (file.SizeOfOptionalHeader < sizeof(WORD) ||
      !IsReadableSpan(optional, file.SizeOfOptionalHeader)) {
    return false;
  }
  WORD magic = 0u;
  std::memcpy(&magic, optional, sizeof(magic));
  uint32_t image_bytes = 0u;
  uint8_t pointer_bits = 0u;
  if (magic == IMAGE_NT_OPTIONAL_HDR32_MAGIC &&
      file.SizeOfOptionalHeader >= sizeof(IMAGE_OPTIONAL_HEADER32)) {
    IMAGE_OPTIONAL_HEADER32 header = {};
    std::memcpy(&header, optional, sizeof(header));
    image_bytes = header.SizeOfImage;
    pointer_bits = 32u;
  } else if (magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC &&
             file.SizeOfOptionalHeader >= sizeof(IMAGE_OPTIONAL_HEADER64)) {
    IMAGE_OPTIONAL_HEADER64 header = {};
    std::memcpy(&header, optional, sizeof(header));
    image_bytes = header.SizeOfImage;
    pointer_bits = 64u;
  } else {
    return false;
  }
  if (image_bytes < 4096u || image_bytes > 2u * 1024u * 1024u * 1024u) {
    return false;
  }
  const uint8_t* section_headers = optional + file.SizeOfOptionalHeader;
  const size_t section_header_bytes =
      static_cast<size_t>(file.NumberOfSections) *
      sizeof(IMAGE_SECTION_HEADER);
  if (!IsReadableSpan(section_headers, section_header_bytes)) return false;

  image->base = base;
  image->size = image_bytes;
  image->machine = file.Machine;
  image->pointer_bits = pointer_bits;
  image->section_count = file.NumberOfSections;
  for (size_t index = 0u; index < image->section_count; ++index) {
    IMAGE_SECTION_HEADER section = {};
    std::memcpy(&section,
                section_headers + index * sizeof(IMAGE_SECTION_HEADER),
                sizeof(section));
    const uint32_t span =
        (std::max)(section.Misc.VirtualSize, section.SizeOfRawData);
    if (span == 0u || section.VirtualAddress >= image_bytes ||
        span > image_bytes - section.VirtualAddress) {
      *image = {};
      return false;
    }
    image->sections[index] = {
        base + section.VirtualAddress, span, section.VirtualAddress,
        section.Characteristics};
  }
  return true;
}

inline const LoadedPeSection* FindSectionForRva(const LoadedPeImage& image,
                                                uintptr_t rva, size_t bytes) {
  if (bytes == 0u || rva > image.size || bytes > image.size - rva) {
    return nullptr;
  }
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto& section = image.sections[index];
    if (rva >= section.rva && rva - section.rva <= section.size &&
        bytes <= section.size - (rva - section.rva)) {
      return &section;
    }
  }
  return nullptr;
}

inline bool SectionHasRole(const LoadedPeSection* section,
                           uint32_t required_characteristics,
                           uint32_t forbidden_characteristics = 0u) {
  return section != nullptr &&
         (section->characteristics & required_characteristics) ==
             required_characteristics &&
         (section->characteristics & forbidden_characteristics) == 0u;
}

inline bool AddressToRva(const LoadedPeImage& image, uintptr_t address,
                         uintptr_t* rva) {
  if (rva == nullptr || image.base == nullptr) return false;
  const uintptr_t base = reinterpret_cast<uintptr_t>(image.base);
  if (address < base || address - base >= image.size) return false;
  *rva = address - base;
  return true;
}

inline UniquePatternMatch FindUniquePatternInSection(
    const LoadedPeSection* section, const MaskedPattern& pattern) {
  if (section == nullptr || section->bytes == nullptr || section->size == 0u ||
      !IsReadableSpan(section->bytes, section->size)) {
    return {};
  }
  return FindUniqueMaskedPattern(section->bytes, section->size, pattern);
}

inline UniquePatternMatch FindUniquePatternInExecutableSections(
    const LoadedPeImage& image, const MaskedPattern& pattern) {
  UniquePatternMatch result;
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto* section = &image.sections[index];
    if (!SectionHasRole(section, IMAGE_SCN_MEM_EXECUTE)) continue;
    // Uniqueness is an image-wide property. If any executable section cannot
    // be inspected, treating it as "no match" could hide a second candidate
    // and turn a partial scan into a production hook. Fail closed instead.
    if (section->bytes == nullptr || section->size == 0u ||
        !IsReadableSpan(section->bytes, section->size)) {
      return {nullptr, 2u};
    }
    const auto local = FindUniquePatternInSection(section, pattern);
    if (local.count == 0u) continue;
    if (local.count != 1u || result.count != 0u) {
      result.address = nullptr;
      result.count = 2u;
      return result;
    }
    result = local;
  }
  return result;
}

inline bool DecodeRipRelativeAddress(const uint8_t* instruction,
                                     size_t displacement_offset,
                                     size_t instruction_bytes,
                                     uintptr_t* target) {
  if (instruction == nullptr || target == nullptr ||
      displacement_offset > instruction_bytes ||
      sizeof(int32_t) > instruction_bytes - displacement_offset ||
      !IsReadableSpan(instruction, instruction_bytes)) {
    return false;
  }
  int32_t displacement = 0;
  std::memcpy(&displacement, instruction + displacement_offset,
              sizeof(displacement));
  const uintptr_t after =
      reinterpret_cast<uintptr_t>(instruction) + instruction_bytes;
  *target = static_cast<uintptr_t>(
      static_cast<intptr_t>(after) + static_cast<intptr_t>(displacement));
  return true;
}

inline UniquePatternMatch FindUniqueRipRelativePatternInSection(
    const LoadedPeSection* section, const MaskedPattern& pattern,
    size_t instruction_offset, size_t displacement_offset,
    size_t instruction_bytes, uintptr_t expected_target) {
  if (section == nullptr || section->bytes == nullptr ||
      pattern.size == 0u || pattern.size > section->size ||
      instruction_offset > pattern.size ||
      instruction_bytes > pattern.size - instruction_offset ||
      !IsReadableSpan(section->bytes, section->size)) {
    return {};
  }
  const auto raw = FindUniquePatternInSection(section, pattern);
  if (raw.count != 1u) return raw;
  uintptr_t target = 0u;
  return DecodeRipRelativeAddress(raw.address + instruction_offset,
                                  displacement_offset, instruction_bytes,
                                  &target) &&
                 target == expected_target
             ? raw
             : UniquePatternMatch{};
}

inline UniquePatternMatch FindUniqueRipRelativePatternInExecutableSections(
    const LoadedPeImage& image, const MaskedPattern& pattern,
    size_t instruction_offset, size_t displacement_offset,
    size_t instruction_bytes, uintptr_t expected_target) {
  if (instruction_offset > pattern.size ||
      instruction_bytes > pattern.size - instruction_offset) {
    return {};
  }
  const auto raw = FindUniquePatternInExecutableSections(image, pattern);
  if (raw.count != 1u) return raw;
  uintptr_t target = 0u;
  return DecodeRipRelativeAddress(raw.address + instruction_offset,
                                  displacement_offset, instruction_bytes,
                                  &target) &&
                 target == expected_target
             ? raw
             : UniquePatternMatch{};
}

inline bool DecodeRel32CallTarget(const uint8_t* call, uintptr_t* target) {
  return call != nullptr && IsReadableSpan(call, 5u) && call[0] == 0xe8u &&
         DecodeRipRelativeAddress(call, 1u, 5u, target);
}

inline bool MatchesRel32CallEndingAt(const LoadedPeImage& image,
                                     uintptr_t return_rva,
                                     uintptr_t expected_target_rva) {
  if (return_rva < 5u || return_rva > image.size) return false;
  const auto* call = image.base + return_rva - 5u;
  uintptr_t target = 0u;
  uintptr_t target_rva = 0u;
  return SectionHasRole(FindSectionForRva(image, return_rva - 5u, 5u),
                        IMAGE_SCN_MEM_EXECUTE) &&
         DecodeRel32CallTarget(call, &target) &&
         AddressToRva(image, target, &target_rva) &&
         SectionHasRole(FindSectionForRva(image, target_rva, 1u),
                        IMAGE_SCN_MEM_EXECUTE) &&
         target_rva == expected_target_rva;
}

inline bool MatchesRegisterIndirectCallEndingAt(const LoadedPeImage& image,
                                                 uintptr_t return_rva,
                                                 uint8_t expected_modrm) {
  if (return_rva < 2u || return_rva > image.size ||
      !SectionHasRole(FindSectionForRva(image, return_rva - 2u, 2u),
                      IMAGE_SCN_MEM_EXECUTE)) {
    return false;
  }
  const auto* call = image.base + return_rva - 2u;
  return IsReadableSpan(call, 2u) && call[0] == 0xffu &&
         call[1] == expected_modrm;
}

inline bool DecodeAbsolute32ImageAddress(const LoadedPeImage& image,
                                         const uint8_t* operand,
                                         uintptr_t* target,
                                         uintptr_t* target_rva = nullptr) {
  if (operand == nullptr || target == nullptr ||
      !IsReadableSpan(operand, sizeof(uint32_t))) {
    return false;
  }
  uint32_t absolute = 0u;
  std::memcpy(&absolute, operand, sizeof(absolute));
  const uintptr_t address = absolute;
  // 只有**绝对** VA 操作数按 absolute_base 换算。rel32 / 寄存器间接那几路算出来的是
  // 映射内地址，必须继续走 AddressToRva 的 image.base——把这条也改成 absolute_base，
  // 未重定位的磁盘映像上那几路会整片假失败（实测过）。
  const uintptr_t absolute_base =
      image.absolute_base != 0u ? image.absolute_base
                                : reinterpret_cast<uintptr_t>(image.base);
  if (address < absolute_base || address - absolute_base >= image.size)
    return false;
  const uintptr_t rva = address - absolute_base;
  *target = address;
  if (target_rva != nullptr) *target_rva = rva;
  return true;
}

inline UniquePatternMatch FindUniqueAbsolute32PatternInExecutableSections(
    const LoadedPeImage& image, const MaskedPattern& pattern,
    size_t operand_offset, uintptr_t expected_target) {
  if (operand_offset > pattern.size ||
      sizeof(uint32_t) > pattern.size - operand_offset) {
    return {};
  }
  const auto raw = FindUniquePatternInExecutableSections(image, pattern);
  if (raw.count != 1u) return raw;
  uintptr_t target = 0u;
  return DecodeAbsolute32ImageAddress(
             image, raw.address + operand_offset, &target, nullptr) &&
                 target == expected_target
             ? raw
             : UniquePatternMatch{};
}

inline bool MatchesAbsoluteIndirectCallEndingAt(
    const LoadedPeImage& image, uintptr_t return_rva,
    uintptr_t expected_slot_rva) {
  if (return_rva < 6u || return_rva > image.size ||
      !SectionHasRole(FindSectionForRva(image, return_rva - 6u, 6u),
                      IMAGE_SCN_MEM_EXECUTE)) {
    return false;
  }
  const auto* call = image.base + return_rva - 6u;
  uintptr_t slot = 0u;
  uintptr_t slot_rva = 0u;
  return IsReadableSpan(call, 6u) && call[0] == 0xffu && call[1] == 0x15u &&
         DecodeAbsolute32ImageAddress(image, call + 2u, &slot, &slot_rva) &&
         slot_rva == expected_slot_rva &&
         SectionHasRole(
             FindSectionForRva(image, slot_rva, sizeof(uint32_t)),
             IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_EXECUTE);
}

// Validate a call boundary whose callee is an imported/system function rather
// than another profile RVA. The admitted exact callers use ordinary x86 rel32,
// absolute-IAT, or register-indirect call forms. For forms with a materialized
// target, require that target to be executable; for an IAT call also require
// the slot to live in readable non-executable image data.
inline bool MatchesExecutableCallEndingAt(const LoadedPeImage& image,
                                          uintptr_t return_rva) {
  if (return_rva > image.size) return false;
  if (return_rva >= 5u &&
      SectionHasRole(FindSectionForRva(image, return_rva - 5u, 5u),
                     IMAGE_SCN_MEM_EXECUTE)) {
    uintptr_t target = 0u;
    if (DecodeRel32CallTarget(image.base + return_rva - 5u, &target) &&
        IsExecutableAddress(reinterpret_cast<const void*>(target))) {
      return true;
    }
  }
  if (return_rva >= 6u &&
      SectionHasRole(FindSectionForRva(image, return_rva - 6u, 6u),
                     IMAGE_SCN_MEM_EXECUTE)) {
    const auto* call = image.base + return_rva - 6u;
    uintptr_t slot = 0u;
    uintptr_t slot_rva = 0u;
    if (IsReadableSpan(call, 6u) && call[0] == 0xffu && call[1] == 0x15u &&
        DecodeAbsolute32ImageAddress(image, call + 2u, &slot, &slot_rva) &&
        SectionHasRole(
            FindSectionForRva(image, slot_rva, sizeof(uint32_t)),
            IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_EXECUTE) &&
        IsReadableSpan(reinterpret_cast<const void*>(slot), sizeof(uint32_t))) {
      uint32_t target = 0u;
      std::memcpy(&target, reinterpret_cast<const void*>(slot),
                  sizeof(target));
      if (IsExecutableAddress(reinterpret_cast<const void*>(
              static_cast<uintptr_t>(target)))) {
        return true;
      }
    }
  }
  if (return_rva >= 2u &&
      SectionHasRole(FindSectionForRva(image, return_rva - 2u, 2u),
                     IMAGE_SCN_MEM_EXECUTE)) {
    const auto* call = image.base + return_rva - 2u;
    // FF /2 with mod=11 selects an x86 general register (D0..D7).
    if (IsReadableSpan(call, 2u) && call[0] == 0xffu &&
        call[1] >= 0xd0u && call[1] <= 0xd7u) {
      return true;
    }
  }
  return false;
}

inline bool PointerTableTargetsExecutableSections(const LoadedPeImage& image,
                                                  uintptr_t table_rva,
                                                  size_t entries) {
  const size_t pointer_bytes = image.pointer_bits == 64u ? 8u : 4u;
  if ((image.pointer_bits != 32u && image.pointer_bits != 64u) ||
      entries == 0u || entries > 64u ||
      entries > (std::numeric_limits<size_t>::max)() / pointer_bytes ||
      FindSectionForRva(image, table_rva, entries * pointer_bytes) == nullptr ||
      !IsReadableSpan(image.base + table_rva, entries * pointer_bytes)) {
    return false;
  }
  for (size_t index = 0u; index < entries; ++index) {
    uintptr_t address = 0u;
    if (pointer_bytes == 8u) {
      uint64_t value = 0u;
      std::memcpy(&value, image.base + table_rva + index * pointer_bytes,
                  sizeof(value));
      address = static_cast<uintptr_t>(value);
    } else {
      uint32_t value = 0u;
      std::memcpy(&value, image.base + table_rva + index * pointer_bytes,
                  sizeof(value));
      address = value;
    }
    uintptr_t target_rva = 0u;
    if (!AddressToRva(image, address, &target_rva) ||
        !SectionHasRole(FindSectionForRva(image, target_rva, 1u),
                        IMAGE_SCN_MEM_EXECUTE)) {
      return false;
    }
  }
  return true;
}

}  // namespace fushi_voice_hook::exact_lookup
