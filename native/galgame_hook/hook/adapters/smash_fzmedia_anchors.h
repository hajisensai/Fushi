#pragma once

// smash/fzmedia 锚点自推导（纯函数、无 Win32 调用、无 IPC）。
//
// 这一层只看 PE 映像字节：TYPE-MOON smash 框架的 KAG 重实现把文本层的逐字布局收在
// `TextLayerBase::layoutChar(layer, run, index, &next)` 里，我们要 hook 的正是它。它没有
// 导出名、也不钉 exe 哈希（禁止 SHA 白名单），所以整条链全部从二进制**结构**推出来：
//
//   RTTI TypeDescriptor 名 `.?AVGlyphComponentMesh@krkrz@app@`
//     → x64 MSVC CompleteObjectLocator（sig=1, offset=0, pTD=该 TD 的 RVA, pSelf=自身 RVA）
//     → vtable（紧随「指向 COL 的指针」之后：vtable[-1] == &COL）
//     → ctor = 唯一含 `lea rax,[rip+vtable]` 且紧随 `mov [rsi],rax` 的函数
//     → 网格构建函数 = 唯一 `E8 rel32` 直调 ctor ≥ 5 次的函数
//     → layoutChar = 唯一同时含 `mov rax,[rdx+d]; movzx r10d,word [rax+r8*2]` 且直调网格构建
//       恰好 1 次的函数
//     → 各字段位移从 layoutChar 自己的指令里解出（多义 / 缺失 → 整条链拒绝）。
//
// 每一步都要求**唯一**命中；任何多义都 fail-closed，宁可不装文本能力也不猜。函数边界用
// PE 异常目录（RUNTIME_FUNCTION 数组）并追 chained unwind 的父片段，因为 MSVC 会把一个
// 逻辑函数拆成多个相邻片段（见 hunex GetHunexGgeFunctionSpan 的教训）。
//
// 所有读取都对映像大小做边界校验：这段代码跑在玩家的游戏进程里，也跑在合成夹具上。

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook {
namespace smash_fzmedia {

// x64 unwind-info CHAININFO flag.  <windows.h> only defines UNW_FLAG_CHAININFO
// when the *host* toolchain targets x64, but this parser reads x64 game images
// from either the x64 or the x86 build (x86 injector attaches to WOW64-hosted
// targets), so the numeric value from the AMD64 exception-handling spec is used
// directly instead of the SDK macro.
inline constexpr uint8_t kUnwFlagChainInfo = 0x4u;

constexpr size_t kImageMaxSections = 64u;

struct ImageSection {
  uint32_t rva = 0u;
  uint32_t size = 0u;
  uint32_t characteristics = 0u;
};

// 一份已展开（按节 VA 排布）的 PE64 映像视图。base 指向可读字节；absolute_base 是映像内
// 绝对指针所相对的基址（进程内模块 = 实际加载基址；合成夹具 = 头里的 ImageBase）。
struct ImageView {
  const uint8_t* base = nullptr;
  uint64_t absolute_base = 0u;
  uint32_t size = 0u;
  uint16_t machine = 0u;
  ImageSection sections[kImageMaxSections] = {};
  size_t section_count = 0u;
  uint32_t export_dir_rva = 0u;
  uint32_t export_dir_size = 0u;
  uint32_t import_dir_rva = 0u;
  uint32_t import_dir_size = 0u;
  uint32_t exception_dir_rva = 0u;
  uint32_t exception_dir_size = 0u;

  bool Contains(uint64_t rva, uint64_t bytes) const {
    return base != nullptr && bytes != 0u && rva < size &&
           bytes <= static_cast<uint64_t>(size) - rva;
  }
  const uint8_t* At(uint64_t rva, uint64_t bytes) const {
    return Contains(rva, bytes) ? base + rva : nullptr;
  }
  const ImageSection* SectionOf(uint64_t rva) const {
    for (size_t i = 0u; i < section_count; ++i) {
      const ImageSection& s = sections[i];
      if (rva >= s.rva && rva - s.rva < s.size) return &s;
    }
    return nullptr;
  }
  static bool IsExecutableSection(const ImageSection* s) {
    return s != nullptr && (s->characteristics & IMAGE_SCN_MEM_EXECUTE) != 0u;
  }
  static bool IsDataSection(const ImageSection* s) {
    return s != nullptr && (s->characteristics & IMAGE_SCN_MEM_READ) != 0u &&
           (s->characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u;
  }
  // [rva, rva+bytes) 全落在同一个可执行节内。
  bool IsExecutable(uint64_t rva, uint64_t bytes) const {
    const ImageSection* s = SectionOf(rva);
    return Contains(rva, bytes) && IsExecutableSection(s) &&
           bytes <= static_cast<uint64_t>(s->size) - (rva - s->rva);
  }
  bool IsData(uint64_t rva, uint64_t bytes) const {
    const ImageSection* s = SectionOf(rva);
    return Contains(rva, bytes) && IsDataSection(s) &&
           bytes <= static_cast<uint64_t>(s->size) - (rva - s->rva);
  }
};

inline bool ReadU32(const ImageView& image, uint64_t rva, uint32_t* out) {
  const uint8_t* p = image.At(rva, sizeof(uint32_t));
  if (p == nullptr || out == nullptr) return false;
  std::memcpy(out, p, sizeof(*out));
  return true;
}

inline bool ReadU64(const ImageView& image, uint64_t rva, uint64_t* out) {
  const uint8_t* p = image.At(rva, sizeof(uint64_t));
  if (p == nullptr || out == nullptr) return false;
  std::memcpy(out, p, sizeof(*out));
  return true;
}

// 解析 PE64 头。absolute_base == 0 时取头里的 ImageBase（合成夹具）；进程内模块必须
// 传实际基址——代码里的绝对操作数已被重定位。失败时 *out 清零。
inline bool OpenImageView(const uint8_t* base, uint64_t absolute_base,
                          ImageView* out) {
  if (base == nullptr || out == nullptr) return false;
  *out = {};
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
      dos->e_lfanew > 0x1000) {
    return false;
  }
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
      nt->FileHeader.SizeOfOptionalHeader < sizeof(IMAGE_OPTIONAL_HEADER64)) {
    return false;
  }
  const uint32_t image_size = nt->OptionalHeader.SizeOfImage;
  const size_t count = nt->FileHeader.NumberOfSections;
  // 唯一性是全映像性质：节表放不下就拒绝，绝不静默截断后半张表。
  if (count == 0u || count > kImageMaxSections || image_size < 0x1000u) {
    return false;
  }
  const IMAGE_SECTION_HEADER* section = IMAGE_FIRST_SECTION(nt);
  out->base = base;
  out->absolute_base =
      absolute_base != 0u ? absolute_base : nt->OptionalHeader.ImageBase;
  out->size = image_size;
  out->machine = nt->FileHeader.Machine;
  out->section_count = count;
  for (size_t i = 0u; i < count; ++i) {
    const uint32_t span = section[i].Misc.VirtualSize > section[i].SizeOfRawData
                              ? section[i].Misc.VirtualSize
                              : section[i].SizeOfRawData;
    if (span == 0u || section[i].VirtualAddress >= image_size ||
        span > image_size - section[i].VirtualAddress) {
      *out = {};
      return false;
    }
    out->sections[i] = {section[i].VirtualAddress, span,
                        section[i].Characteristics};
  }
  const uint32_t dirs = nt->OptionalHeader.NumberOfRvaAndSizes;
  auto directory = [&](uint32_t index, uint32_t* rva, uint32_t* size) {
    if (index >= dirs) return;
    const IMAGE_DATA_DIRECTORY& d = nt->OptionalHeader.DataDirectory[index];
    if (d.VirtualAddress != 0u && d.Size != 0u &&
        d.VirtualAddress < image_size && d.Size <= image_size - d.VirtualAddress) {
      *rva = d.VirtualAddress;
      *size = d.Size;
    }
  };
  directory(IMAGE_DIRECTORY_ENTRY_EXPORT, &out->export_dir_rva,
            &out->export_dir_size);
  directory(IMAGE_DIRECTORY_ENTRY_IMPORT, &out->import_dir_rva,
            &out->import_dir_size);
  directory(IMAGE_DIRECTORY_ENTRY_EXCEPTION, &out->exception_dir_rva,
            &out->exception_dir_size);
  return true;
}

// ── 字符串小工具（不依赖 CRT locale）────────────────────────────────────────

inline char AsciiLower(char c) {
  return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

// 映像内 NUL 结尾串是否以 prefix 开头（大小写不敏感），越界即 false。
inline bool ImageStringStartsWithNoCase(const ImageView& image, uint64_t rva,
                                        const char* prefix) {
  if (prefix == nullptr) return false;
  for (size_t i = 0u;; ++i) {
    if (prefix[i] == '\0') return true;
    const uint8_t* ch = image.At(rva + i, 1u);
    if (ch == nullptr || *ch == 0u) return false;
    if (AsciiLower(static_cast<char>(*ch)) != AsciiLower(prefix[i])) return false;
  }
}

inline bool ImageStringStartsWith(const ImageView& image, uint64_t rva,
                                  const char* prefix) {
  if (prefix == nullptr) return false;
  for (size_t i = 0u;; ++i) {
    if (prefix[i] == '\0') return true;
    const uint8_t* ch = image.At(rva + i, 1u);
    if (ch == nullptr || static_cast<char>(*ch) != prefix[i]) return false;
  }
}

inline bool ImageStringEquals(const ImageView& image, uint64_t rva,
                              const char* text) {
  if (text == nullptr) return false;
  for (size_t i = 0u;; ++i) {
    const uint8_t* ch = image.At(rva + i, 1u);
    if (ch == nullptr) return false;
    if (static_cast<char>(*ch) != text[i]) return false;
    if (text[i] == '\0') return true;
  }
}

// 映像内 NUL 结尾串（上限 max_len）是否含子串 needle。
inline bool ImageStringContains(const ImageView& image, uint64_t rva,
                                const char* needle, size_t max_len = 1024u) {
  if (needle == nullptr || needle[0] == '\0') return false;
  const size_t needle_len = std::strlen(needle);
  for (size_t start = 0u; start < max_len; ++start) {
    const uint8_t* ch = image.At(rva + start, 1u);
    if (ch == nullptr || *ch == 0u) return false;
    bool match = true;
    for (size_t k = 0u; k < needle_len; ++k) {
      const uint8_t* c = image.At(rva + start + k, 1u);
      if (c == nullptr || *c == 0u || static_cast<char>(*c) != needle[k]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

// ── 导出表 ──────────────────────────────────────────────────────────────────

struct ExportMatch {
  uint32_t rva = 0u;    // 唯一命中时的函数 RVA（转发导出记 0）
  uint32_t count = 0u;  // 饱和到 2：0 无 / 1 唯一 / 2 多义
};

// 按名字前缀（区分大小写，MSVC 修饰名）在导出表里找函数。
inline ExportMatch FindExportByPrefix(const ImageView& image,
                                      const char* prefix) {
  ExportMatch result;
  if (prefix == nullptr || prefix[0] == '\0' || image.export_dir_rva == 0u ||
      image.export_dir_size < sizeof(IMAGE_EXPORT_DIRECTORY)) {
    return result;
  }
  const uint8_t* dir_bytes =
      image.At(image.export_dir_rva, sizeof(IMAGE_EXPORT_DIRECTORY));
  if (dir_bytes == nullptr) return result;
  IMAGE_EXPORT_DIRECTORY dir = {};
  std::memcpy(&dir, dir_bytes, sizeof(dir));
  if (dir.NumberOfNames > 65536u || dir.NumberOfFunctions > 65536u) return result;
  for (uint32_t i = 0u; i < dir.NumberOfNames; ++i) {
    uint32_t name_rva = 0u;
    if (!ReadU32(image, static_cast<uint64_t>(dir.AddressOfNames) + i * 4u,
                 &name_rva)) {
      return {0u, 2u};  // 表读不全 = 无法证明唯一，按多义拒绝
    }
    if (!ImageStringStartsWith(image, name_rva, prefix)) continue;
    uint32_t ordinal16 = 0u;
    const uint8_t* ord_bytes =
        image.At(static_cast<uint64_t>(dir.AddressOfNameOrdinals) + i * 2u, 2u);
    if (ord_bytes == nullptr) return {0u, 2u};
    uint16_t ordinal = 0u;
    std::memcpy(&ordinal, ord_bytes, sizeof(ordinal));
    ordinal16 = ordinal;
    if (ordinal16 >= dir.NumberOfFunctions) return {0u, 2u};
    uint32_t function_rva = 0u;
    if (!ReadU32(image,
                 static_cast<uint64_t>(dir.AddressOfFunctions) + ordinal16 * 4u,
                 &function_rva)) {
      return {0u, 2u};
    }
    if (result.count == 0u) {
      // 转发导出（RVA 落在导出目录内）没有本地代码可 hook。
      const bool forwarded =
          function_rva >= image.export_dir_rva &&
          function_rva < image.export_dir_rva + image.export_dir_size;
      result.rva = forwarded ? 0u : function_rva;
    }
    if (++result.count > 1u) {
      result.count = 2u;
      result.rva = 0u;
      return result;
    }
  }
  return result;
}

inline bool HasExportWithPrefix(const ImageView& image, const char* prefix) {
  return FindExportByPrefix(image, prefix).count >= 1u;
}

// ── 导入表（PE64 thunk）────────────────────────────────────────────────────

// 某个 DLL 名以 dll_prefix 开头（大小写不敏感）、且它的按名导入里有一个名字含
// symbol_substring。这是 smash 框架的结构签名：主 exe 导入 null-ge-*.dll 的
// `...IGameEngine@fw@smash@@...`。
inline bool ImportsSymbolFromDll(const ImageView& image, const char* dll_prefix,
                                 const char* symbol_substring) {
  if (dll_prefix == nullptr || symbol_substring == nullptr ||
      image.import_dir_rva == 0u) {
    return false;
  }
  for (uint32_t offset = 0u;; offset += sizeof(IMAGE_IMPORT_DESCRIPTOR)) {
    const uint8_t* bytes =
        image.At(static_cast<uint64_t>(image.import_dir_rva) + offset,
                 sizeof(IMAGE_IMPORT_DESCRIPTOR));
    if (bytes == nullptr) return false;
    IMAGE_IMPORT_DESCRIPTOR desc = {};
    std::memcpy(&desc, bytes, sizeof(desc));
    if (desc.Name == 0u && desc.FirstThunk == 0u) return false;
    if (!ImageStringStartsWithNoCase(image, desc.Name, dll_prefix)) continue;
    const uint32_t lookup = desc.OriginalFirstThunk != 0u
                                ? desc.OriginalFirstThunk
                                : desc.FirstThunk;
    if (lookup == 0u) continue;
    for (uint32_t i = 0u; i < 65536u; ++i) {
      uint64_t entry = 0u;
      if (!ReadU64(image, static_cast<uint64_t>(lookup) + i * 8u, &entry) ||
          entry == 0u) {
        break;
      }
      if ((entry & IMAGE_ORDINAL_FLAG64) != 0u) continue;
      // IMAGE_IMPORT_BY_NAME：2 字节 Hint + NUL 结尾名字。
      if (ImageStringContains(image, entry + 2u, symbol_substring)) return true;
    }
  }
}

// 按名导入 symbol（精确匹配；dll_prefix 可为 nullptr = 任意 DLL）的 IAT 槽 RVA。
// 要求唯一：命中两处或表读不全都返回 0。
inline uint32_t FindImportThunkRva(const ImageView& image,
                                   const char* dll_prefix,
                                   const char* symbol) {
  if (symbol == nullptr || image.import_dir_rva == 0u) return 0u;
  uint32_t found = 0u;
  for (uint32_t offset = 0u;; offset += sizeof(IMAGE_IMPORT_DESCRIPTOR)) {
    const uint8_t* bytes =
        image.At(static_cast<uint64_t>(image.import_dir_rva) + offset,
                 sizeof(IMAGE_IMPORT_DESCRIPTOR));
    if (bytes == nullptr) return 0u;
    IMAGE_IMPORT_DESCRIPTOR desc = {};
    std::memcpy(&desc, bytes, sizeof(desc));
    if (desc.Name == 0u && desc.FirstThunk == 0u) break;
    if (dll_prefix != nullptr &&
        !ImageStringStartsWithNoCase(image, desc.Name, dll_prefix)) {
      continue;
    }
    const uint32_t lookup = desc.OriginalFirstThunk != 0u
                                ? desc.OriginalFirstThunk
                                : desc.FirstThunk;
    if (lookup == 0u || desc.FirstThunk == 0u) continue;
    for (uint32_t i = 0u; i < 65536u; ++i) {
      uint64_t entry = 0u;
      if (!ReadU64(image, static_cast<uint64_t>(lookup) + i * 8u, &entry) ||
          entry == 0u) {
        break;
      }
      if ((entry & IMAGE_ORDINAL_FLAG64) != 0u) continue;
      if (!ImageStringEquals(image, entry + 2u, symbol)) continue;
      const uint64_t slot = static_cast<uint64_t>(desc.FirstThunk) + i * 8u;
      if (slot > 0xffffffffu || !image.Contains(slot, 8u)) return 0u;
      if (found != 0u) return 0u;  // 多义
      found = static_cast<uint32_t>(slot);
    }
  }
  return found;
}

// ── 掩码模式 ────────────────────────────────────────────────────────────────

struct Pattern {
  const uint8_t* bytes = nullptr;
  const uint8_t* mask = nullptr;  // 0 = 通配
  size_t size = 0u;
};

inline bool MatchesAt(const uint8_t* candidate, const Pattern& p) {
  for (size_t i = 0u; i < p.size; ++i) {
    if (p.mask != nullptr && p.mask[i] == 0u) continue;
    if (candidate[i] != p.bytes[i]) return false;
  }
  return true;
}

// ── 函数边界（异常目录 + chained unwind）──────────────────────────────────────

struct RuntimeEntry {
  uint32_t begin = 0u;
  uint32_t end = 0u;
  uint32_t unwind = 0u;
};

inline uint32_t RuntimeEntryCount(const ImageView& image) {
  constexpr uint32_t kBytes = 12u;
  if (image.exception_dir_rva == 0u || image.exception_dir_size < kBytes ||
      image.exception_dir_size % kBytes != 0u ||
      !image.Contains(image.exception_dir_rva, image.exception_dir_size)) {
    return 0u;
  }
  return image.exception_dir_size / kBytes;
}

inline bool ReadRuntimeEntry(const ImageView& image, uint32_t index,
                             RuntimeEntry* out) {
  const uint8_t* p =
      image.At(static_cast<uint64_t>(image.exception_dir_rva) + index * 12u, 12u);
  if (p == nullptr || out == nullptr) return false;
  std::memcpy(&out->begin, p, 4u);
  std::memcpy(&out->end, p + 4u, 4u);
  std::memcpy(&out->unwind, p + 8u, 4u);
  return out->begin != 0u && out->end > out->begin && out->unwind != 0u;
}

// 追 UNW_FLAG_CHAININFO 得到根片段的 begin。非链式片段返回自身 begin；坏数据返回 0。
inline uint32_t ResolveRootFunctionBegin(const ImageView& image,
                                         const RuntimeEntry& entry) {
  RuntimeEntry current = entry;
  for (uint32_t depth = 0u; depth < 32u; ++depth) {
    const uint8_t* unwind = image.At(current.unwind, 4u);
    if (unwind == nullptr) return 0u;
    const uint8_t version = static_cast<uint8_t>(unwind[0] & 0x07u);
    const uint8_t flags = static_cast<uint8_t>(unwind[0] >> 3u);
    if (version != 1u && version != 2u) return 0u;
    if ((flags & kUnwFlagChainInfo) == 0u) return current.begin;
    const uint32_t code_count = unwind[2];
    const uint32_t aligned = (code_count + 1u) & ~1u;
    const uint8_t* chained =
        image.At(static_cast<uint64_t>(current.unwind) + 4u + aligned * 2u, 12u);
    if (chained == nullptr) return 0u;
    RuntimeEntry parent;
    std::memcpy(&parent.begin, chained, 4u);
    std::memcpy(&parent.end, chained + 4u, 4u);
    std::memcpy(&parent.unwind, chained + 8u, 4u);
    if (parent.begin == 0u || parent.end <= parent.begin || parent.unwind == 0u)
      return 0u;
    current = parent;
  }
  return 0u;
}

// 含 code_rva 的根函数 begin。要求恰好一个片段含该地址；否则 0。
inline uint32_t FindContainingFunctionBegin(const ImageView& image,
                                            uint32_t code_rva) {
  const uint32_t count = RuntimeEntryCount(image);
  uint32_t found = 0u;
  bool any = false;
  for (uint32_t i = 0u; i < count; ++i) {
    RuntimeEntry entry;
    if (!ReadRuntimeEntry(image, i, &entry)) return 0u;
    if (code_rva < entry.begin || code_rva >= entry.end) continue;
    if (!image.IsExecutable(entry.begin, entry.end - entry.begin)) return 0u;
    const uint32_t root = ResolveRootFunctionBegin(image, entry);
    if (root == 0u) return 0u;
    if (any && root != found) return 0u;
    found = root;
    any = true;
  }
  return any ? found : 0u;
}

// 逐片段遍历属于根函数 root_begin 的所有 [begin,end)。fn(begin,end) 返回 false 即中止。
template <typename Fn>
inline bool ForEachFunctionFragment(const ImageView& image, uint32_t root_begin,
                                    Fn fn) {
  const uint32_t count = RuntimeEntryCount(image);
  if (root_begin == 0u || count == 0u) return false;
  bool seen_root = false;
  for (uint32_t i = 0u; i < count; ++i) {
    RuntimeEntry entry;
    if (!ReadRuntimeEntry(image, i, &entry)) return false;
    if (ResolveRootFunctionBegin(image, entry) != root_begin) continue;
    if (!image.IsExecutable(entry.begin, entry.end - entry.begin)) return false;
    if (entry.begin == root_begin) seen_root = true;
    if (!fn(entry.begin, entry.end)) return false;
  }
  return seen_root;
}

// 函数体内 `E8 rel32` 直调 target_rva 的次数（跨全部片段）。
inline uint32_t CountRel32CallsInFunction(const ImageView& image,
                                          uint32_t root_begin,
                                          uint32_t target_rva) {
  uint32_t calls = 0u;
  ForEachFunctionFragment(image, root_begin, [&](uint32_t begin, uint32_t end) {
    if (end - begin < 5u) return true;
    for (uint32_t rva = begin; rva + 5u <= end; ++rva) {
      const uint8_t* p = image.base + rva;
      if (p[0] != 0xe8u) continue;
      int32_t rel = 0;
      std::memcpy(&rel, p + 1, sizeof(rel));
      const int64_t target = static_cast<int64_t>(rva) + 5 + rel;
      if (target == static_cast<int64_t>(target_rva)) ++calls;
    }
    return true;
  });
  return calls;
}

// 函数体内所有模式命中；fn(hit_rva, bytes) 返回 false 即中止。
template <typename Fn>
inline void ForEachPatternHitInFunction(const ImageView& image,
                                        uint32_t root_begin, const Pattern& p,
                                        Fn fn) {
  ForEachFunctionFragment(image, root_begin, [&](uint32_t begin, uint32_t end) {
    if (end - begin < p.size) return true;
    for (uint32_t rva = begin; rva + p.size <= end; ++rva) {
      if (MatchesAt(image.base + rva, p) && !fn(rva, image.base + rva)) {
        return false;
      }
    }
    return true;
  });
}

// ── 唯一函数集合（有界）─────────────────────────────────────────────────────

constexpr size_t kMaxDistinctFunctions = 64u;

struct FunctionTally {
  uint32_t begin[kMaxDistinctFunctions] = {};
  uint32_t count[kMaxDistinctFunctions] = {};
  size_t size = 0u;
  bool overflow = false;

  void Add(uint32_t function_begin) {
    for (size_t i = 0u; i < size; ++i) {
      if (begin[i] == function_begin) {
        ++count[i];
        return;
      }
    }
    if (size >= kMaxDistinctFunctions) {
      overflow = true;
      return;
    }
    begin[size] = function_begin;
    count[size] = 1u;
    ++size;
  }
  // 满足 count >= threshold 的函数恰好一个时返回它，否则 0。
  uint32_t Unique(uint32_t threshold) const {
    if (overflow) return 0u;
    uint32_t found = 0u;
    for (size_t i = 0u; i < size; ++i) {
      if (count[i] < threshold) continue;
      if (found != 0u) return 0u;
      found = begin[i];
    }
    return found;
  }
};

// ── 文本锚点 ────────────────────────────────────────────────────────────────

inline constexpr char kGlyphComponentMeshTypeNamePrefix[] =
    ".?AVGlyphComponentMesh@krkrz@app@";
inline constexpr uint32_t kMinimumConstructorCallsInMeshBuild = 5u;
inline constexpr uint32_t kMaxLayerFieldOffset = 0x1000u;

// lea rax,[rip+rel32]  (vtable 载入；构造函数里 lea 与 mov [this],rax 存储之间常隔着
// 别的 mov——真实 GlyphComponentMesh ctor 两者相距 18 字节——所以只按 lea 命中函数，
// 存储由 FunctionStoresRaxToThis 另行校验，不再要求两条指令相邻。)
inline constexpr uint8_t kCtorVtableLeaBytes[] = {0x48, 0x8D, 0x05,
                                                  0x00, 0x00, 0x00, 0x00};
inline constexpr uint8_t kCtorVtableLeaMask[] = {0xff, 0xff, 0xff,
                                                 0x00, 0x00, 0x00, 0x00};
// mov rax,[rdx+d8] ; movzx r10d,word [rax+r8*2]
inline constexpr uint8_t kLayoutTextIndexBytes[] = {0x48, 0x8B, 0x42, 0x00, 0x46,
                                                    0x0F, 0xB7, 0x14, 0x40};
inline constexpr uint8_t kLayoutTextIndexMask[] = {0xff, 0xff, 0xff, 0x00, 0xff,
                                                   0xff, 0xff, 0xff, 0xff};
// mov rax,[r15+e] ; sub rax,[r15+b] ; sar rax,1
inline constexpr uint8_t kLayoutTextLengthBytes[] = {
    0x49, 0x8B, 0x47, 0x00, 0x49, 0x2B, 0x47, 0x00, 0x48, 0xD1, 0xF8};
inline constexpr uint8_t kLayoutTextLengthMask[] = {
    0xff, 0xff, 0xff, 0x00, 0xff, 0xff, 0xff, 0x00, 0xff, 0xff, 0xff};
// addss xmm7,[rdi+d] ; movss [rdi+d],xmm7
inline constexpr uint8_t kLayoutCursorXBytes[] = {0xF3, 0x0F, 0x58, 0x7F, 0x00,
                                                  0xF3, 0x0F, 0x11, 0x7F, 0x00};
inline constexpr uint8_t kLayoutCursorXMask[] = {0xff, 0xff, 0xff, 0xff, 0x00,
                                                 0xff, 0xff, 0xff, 0xff, 0x00};
// movss xmm6,[rdi+d]
inline constexpr uint8_t kLayoutCursorYBytes[] = {0xF3, 0x0F, 0x10, 0x77, 0x00};
inline constexpr uint8_t kLayoutCursorYMask[] = {0xff, 0xff, 0xff, 0xff, 0x00};
// movd xmm0,[rdi+d]
inline constexpr uint8_t kLayoutLinePitchBytes[] = {0x66, 0x0F, 0x6E, 0x47, 0x00};
inline constexpr uint8_t kLayoutLinePitchMask[] = {0xff, 0xff, 0xff, 0xff, 0x00};
// mulss xmm8,[rdi+d]
inline constexpr uint8_t kLayoutFontPxBytes[] = {0xF3, 0x44, 0x0F, 0x59, 0x47,
                                                 0x00};
inline constexpr uint8_t kLayoutFontPxMask[] = {0xff, 0xff, 0xff, 0xff, 0xff,
                                                0x00};
// movss xmm0,[rdi+d] / mulss xmm0,[rdi+d]
inline constexpr uint8_t kLayoutScaleLoadBytes[] = {0xF3, 0x0F, 0x10, 0x47, 0x00};
inline constexpr uint8_t kLayoutScaleMulBytes[] = {0xF3, 0x0F, 0x59, 0x47, 0x00};
inline constexpr uint8_t kLayoutScaleMask[] = {0xff, 0xff, 0xff, 0xff, 0x00};

inline constexpr Pattern kCtorVtableLeaPattern = {
    kCtorVtableLeaBytes, kCtorVtableLeaMask, sizeof(kCtorVtableLeaBytes)};
inline constexpr Pattern kLayoutTextIndexPattern = {
    kLayoutTextIndexBytes, kLayoutTextIndexMask, sizeof(kLayoutTextIndexBytes)};
inline constexpr Pattern kLayoutTextLengthPattern = {
    kLayoutTextLengthBytes, kLayoutTextLengthMask,
    sizeof(kLayoutTextLengthBytes)};
inline constexpr Pattern kLayoutCursorXPattern = {
    kLayoutCursorXBytes, kLayoutCursorXMask, sizeof(kLayoutCursorXBytes)};
inline constexpr Pattern kLayoutCursorYPattern = {
    kLayoutCursorYBytes, kLayoutCursorYMask, sizeof(kLayoutCursorYBytes)};
inline constexpr Pattern kLayoutLinePitchPattern = {
    kLayoutLinePitchBytes, kLayoutLinePitchMask, sizeof(kLayoutLinePitchBytes)};
inline constexpr Pattern kLayoutFontPxPattern = {
    kLayoutFontPxBytes, kLayoutFontPxMask, sizeof(kLayoutFontPxBytes)};
inline constexpr Pattern kLayoutScaleLoadPattern = {
    kLayoutScaleLoadBytes, kLayoutScaleMask, sizeof(kLayoutScaleLoadBytes)};
inline constexpr Pattern kLayoutScaleMulPattern = {
    kLayoutScaleMulBytes, kLayoutScaleMask, sizeof(kLayoutScaleMulBytes)};

struct TextAnchors {
  uint32_t type_descriptor_rva = 0u;
  uint32_t complete_object_locator_rva = 0u;
  uint32_t vtable_rva = 0u;
  uint32_t ctor_rva = 0u;
  uint32_t mesh_build_rva = 0u;
  uint32_t mesh_build_ctor_calls = 0u;
  uint32_t layout_char_rva = 0u;
  // run 对象字段（wchar_t* 指针）
  uint32_t text_begin = 0u;
  uint32_t text_end = 0u;
  // layer 对象字段
  uint32_t cursor_x = 0u;    // float
  uint32_t cursor_y = 0u;    // float
  uint32_t line_pitch = 0u;  // int32
  uint32_t font_px = 0u;     // float
  uint32_t scale = 0u;       // float
};

enum class TextAnchorStage : uint32_t {
  kNone = 0,
  kImage,
  kTypeDescriptor,
  kCompleteObjectLocator,
  kVtable,
  kConstructor,
  kMeshBuild,
  kLayoutChar,
  kTextOffsets,
  kCursorOffsets,
  kFontOffsets,
  kResolved,
};

struct TextAnchorResult {
  bool ok = false;
  TextAnchorStage failed_stage = TextAnchorStage::kNone;
  TextAnchors anchors;
};

inline const char* TextAnchorStageName(TextAnchorStage stage) {
  switch (stage) {
    case TextAnchorStage::kNone: return "none";
    case TextAnchorStage::kImage: return "image";
    case TextAnchorStage::kTypeDescriptor: return "type_descriptor";
    case TextAnchorStage::kCompleteObjectLocator: return "complete_object_locator";
    case TextAnchorStage::kVtable: return "vtable";
    case TextAnchorStage::kConstructor: return "constructor";
    case TextAnchorStage::kMeshBuild: return "mesh_build";
    case TextAnchorStage::kLayoutChar: return "layout_char";
    case TextAnchorStage::kTextOffsets: return "text_offsets";
    case TextAnchorStage::kCursorOffsets: return "cursor_offsets";
    case TextAnchorStage::kFontOffsets: return "font_offsets";
    case TextAnchorStage::kResolved: return "resolved";
  }
  return "unknown";
}

// 数据节内唯一的 TypeDescriptor：MSVC x64 TypeDescriptor = {vtable ptr, spare, name[]}，
// 名字在 +16。
inline uint32_t FindUniqueTypeDescriptor(const ImageView& image,
                                         const char* name_prefix) {
  const size_t prefix_len = std::strlen(name_prefix);
  uint32_t found = 0u;
  uint32_t hits = 0u;
  for (size_t s = 0u; s < image.section_count; ++s) {
    const ImageSection& section = image.sections[s];
    if (!ImageView::IsDataSection(&section) || section.size < prefix_len + 16u)
      continue;
    const uint8_t* bytes = image.base + section.rva;
    for (uint32_t off = 16u; off + prefix_len <= section.size; ++off) {
      if (bytes[off] != static_cast<uint8_t>(name_prefix[0])) continue;
      if (std::memcmp(bytes + off, name_prefix, prefix_len) != 0) continue;
      if (++hits > 1u) return 0u;
      found = section.rva + off - 16u;
    }
  }
  return hits == 1u ? found : 0u;
}

// x64 RTTI CompleteObjectLocator：{sig=1, offset=0, cdOffset, pTD, pCHD, pSelf}（全 RVA）。
inline uint32_t FindUniqueCompleteObjectLocator(const ImageView& image,
                                                uint32_t type_descriptor_rva) {
  uint32_t found = 0u;
  uint32_t hits = 0u;
  for (size_t s = 0u; s < image.section_count; ++s) {
    const ImageSection& section = image.sections[s];
    if (!ImageView::IsDataSection(&section) || section.size < 24u) continue;
    const uint8_t* bytes = image.base + section.rva;
    for (uint32_t off = 0u; off + 24u <= section.size; off += 4u) {
      uint32_t fields[6] = {};
      std::memcpy(fields, bytes + off, sizeof(fields));
      if (fields[0] != 1u || fields[1] != 0u || fields[3] != type_descriptor_rva)
        continue;
      const uint32_t self_rva = section.rva + off;
      if (fields[5] != self_rva || !image.Contains(fields[4], 4u)) continue;
      if (++hits > 1u) return 0u;
      found = self_rva;
    }
  }
  return hits == 1u ? found : 0u;
}

// vtable 紧随「指向 COL 的指针」：找到数据节内唯一一个值 == absolute_base + col_rva 的
// 8 字节槽，vtable = 槽 + 8；并要求 vtable[0] 指向可执行节。
inline uint32_t FindUniqueVtable(const ImageView& image, uint32_t col_rva) {
  const uint64_t col_va = image.absolute_base + col_rva;
  uint32_t found = 0u;
  uint32_t hits = 0u;
  for (size_t s = 0u; s < image.section_count; ++s) {
    const ImageSection& section = image.sections[s];
    if (!ImageView::IsDataSection(&section) || section.size < 16u) continue;
    const uint8_t* bytes = image.base + section.rva;
    for (uint32_t off = 0u; off + 16u <= section.size; off += 8u) {
      uint64_t value = 0u;
      std::memcpy(&value, bytes + off, sizeof(value));
      if (value != col_va) continue;
      if (++hits > 1u) return 0u;
      found = section.rva + off + 8u;
    }
  }
  if (hits != 1u) return 0u;
  uint64_t first_slot = 0u;
  if (!ReadU64(image, found, &first_slot) || first_slot < image.absolute_base ||
      !image.IsExecutable(first_slot - image.absolute_base, 1u)) {
    return 0u;
  }
  return found;
}

// 函数体（含 chained 片段）内是否有 `mov [reg], rax` 把 rax 存到 this(+0)：
// REX.W(0x48) 0x89 modrm，modrm = 00 000 bbb（mod=0 无 disp、reg 字段=rax、
// bbb=基址寄存器，排除 4=SIB / 5=RIP-disp32）。这是 MSVC ctor 装 vtable 的形状，
// 真实 ctor 用 [rsi]（bbb=6），但不同类可能用 [rcx]/[rdi] 等，故按寄存器集合判。
inline bool FunctionStoresRaxToThis(const ImageView& image,
                                    uint32_t root_begin) {
  bool found = false;
  ForEachFunctionFragment(
      image, root_begin, [&](uint32_t begin, uint32_t end) {
        for (uint32_t rva = begin; rva + 3u <= end; ++rva) {
          const uint8_t* b = image.base + rva;
          if (b[0] != 0x48u || b[1] != 0x89u) continue;
          const uint8_t modrm = b[2];
          const uint8_t mod = static_cast<uint8_t>(modrm >> 6u);
          const uint8_t reg = static_cast<uint8_t>((modrm >> 3u) & 0x7u);
          const uint8_t rm = static_cast<uint8_t>(modrm & 0x7u);
          if (mod == 0u && reg == 0u && rm != 4u && rm != 5u) {
            found = true;
            return false;
          }
        }
        return true;
      });
  return found;
}

// 唯一「含 `lea rax,[rip+vtable]`（任意距离）且把 rax 存回 this(+0)」的函数。
// 不要求 lea 与存储相邻：真实构造函数里两者之间还夹着别的成员初始化。
inline uint32_t FindUniqueConstructor(const ImageView& image,
                                      uint32_t vtable_rva) {
  FunctionTally tally;
  for (size_t s = 0u; s < image.section_count; ++s) {
    const ImageSection& section = image.sections[s];
    if (!ImageView::IsExecutableSection(&section) ||
        section.size < kCtorVtableLeaPattern.size) {
      continue;
    }
    const uint8_t* bytes = image.base + section.rva;
    for (uint32_t off = 0u; off + kCtorVtableLeaPattern.size <= section.size;
         ++off) {
      if (!MatchesAt(bytes + off, kCtorVtableLeaPattern)) continue;
      int32_t rel = 0;
      std::memcpy(&rel, bytes + off + 3u, sizeof(rel));
      const int64_t target = static_cast<int64_t>(section.rva + off) + 7 + rel;
      if (target != static_cast<int64_t>(vtable_rva)) continue;
      const uint32_t function =
          FindContainingFunctionBegin(image, section.rva + off);
      if (function == 0u) return 0u;
      if (!FunctionStoresRaxToThis(image, function)) continue;
      tally.Add(function);
    }
  }
  return tally.Unique(1u);
}

// 唯一 `E8 rel32` 直调 ctor ≥ threshold 次的函数。
inline uint32_t FindUniqueMeshBuild(const ImageView& image, uint32_t ctor_rva,
                                    uint32_t threshold, uint32_t* calls) {
  FunctionTally tally;
  for (size_t s = 0u; s < image.section_count; ++s) {
    const ImageSection& section = image.sections[s];
    if (!ImageView::IsExecutableSection(&section) || section.size < 5u) continue;
    const uint8_t* bytes = image.base + section.rva;
    for (uint32_t off = 0u; off + 5u <= section.size; ++off) {
      if (bytes[off] != 0xe8u) continue;
      int32_t rel = 0;
      std::memcpy(&rel, bytes + off + 1u, sizeof(rel));
      const int64_t target = static_cast<int64_t>(section.rva + off) + 5 + rel;
      if (target != static_cast<int64_t>(ctor_rva)) continue;
      const uint32_t function =
          FindContainingFunctionBegin(image, section.rva + off);
      if (function == 0u) return 0u;
      tally.Add(function);
    }
  }
  const uint32_t unique = tally.Unique(threshold);
  if (unique != 0u && calls != nullptr) {
    for (size_t i = 0u; i < tally.size; ++i) {
      if (tally.begin[i] == unique) *calls = tally.count[i];
    }
  }
  return unique;
}

// 唯一同时满足「含 text-index 模式」且「直调 mesh_build 恰好 1 次」的函数；
// *text_begin 为该函数内所有 text-index 命中一致的 disp8。
inline uint32_t FindUniqueLayoutChar(const ImageView& image,
                                     uint32_t mesh_build_rva,
                                     uint32_t* text_begin) {
  FunctionTally tally;
  for (size_t s = 0u; s < image.section_count; ++s) {
    const ImageSection& section = image.sections[s];
    if (!ImageView::IsExecutableSection(&section) ||
        section.size < kLayoutTextIndexPattern.size) {
      continue;
    }
    const uint8_t* bytes = image.base + section.rva;
    for (uint32_t off = 0u; off + kLayoutTextIndexPattern.size <= section.size;
         ++off) {
      if (!MatchesAt(bytes + off, kLayoutTextIndexPattern)) continue;
      const uint32_t function =
          FindContainingFunctionBegin(image, section.rva + off);
      if (function == 0u) return 0u;
      if (CountRel32CallsInFunction(image, function, mesh_build_rva) != 1u)
        continue;
      tally.Add(function);
    }
  }
  const uint32_t unique = tally.Unique(1u);
  if (unique == 0u) return 0u;
  // 该函数内全部命中的 disp8 必须一致。
  bool consistent = true;
  bool any = false;
  uint32_t offset = 0u;
  ForEachPatternHitInFunction(
      image, unique, kLayoutTextIndexPattern,
      [&](uint32_t, const uint8_t* hit) {
        const uint32_t d = hit[3];
        if (any && d != offset) consistent = false;
        offset = d;
        any = true;
        return consistent;
      });
  if (!any || !consistent || offset >= 0x80u) return 0u;
  if (text_begin != nullptr) *text_begin = offset;
  return unique;
}

// 函数内某模式所有命中的 disp8（位于 operand_index）必须一致；返回是否至少一处且一致。
inline bool UniqueDisp8InFunction(const ImageView& image, uint32_t function,
                                  const Pattern& pattern, size_t operand_index,
                                  uint32_t* value, uint32_t* first_hit_rva,
                                  uint32_t* last_hit_rva) {
  bool consistent = true;
  bool any = false;
  uint32_t d = 0u;
  uint32_t first = 0u;
  uint32_t last = 0u;
  ForEachPatternHitInFunction(
      image, function, pattern, [&](uint32_t rva, const uint8_t* hit) {
        const uint32_t candidate = hit[operand_index];
        if (any && candidate != d) consistent = false;
        if (!any) first = rva;
        last = rva;
        d = candidate;
        any = true;
        return consistent;
      });
  if (!any || !consistent || d >= 0x80u) return false;
  if (value != nullptr) *value = d;
  if (first_hit_rva != nullptr) *first_hit_rva = first;
  if (last_hit_rva != nullptr) *last_hit_rva = last;
  return true;
}

inline TextAnchorResult DeriveTextAnchors(const ImageView& image) {
  TextAnchorResult result;
  TextAnchors& a = result.anchors;
  auto fail = [&](TextAnchorStage stage) {
    result.ok = false;
    result.failed_stage = stage;
    return result;
  };
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_AMD64 ||
      RuntimeEntryCount(image) == 0u) {
    return fail(TextAnchorStage::kImage);
  }
  a.type_descriptor_rva =
      FindUniqueTypeDescriptor(image, kGlyphComponentMeshTypeNamePrefix);
  if (a.type_descriptor_rva == 0u) return fail(TextAnchorStage::kTypeDescriptor);
  a.complete_object_locator_rva =
      FindUniqueCompleteObjectLocator(image, a.type_descriptor_rva);
  if (a.complete_object_locator_rva == 0u)
    return fail(TextAnchorStage::kCompleteObjectLocator);
  a.vtable_rva = FindUniqueVtable(image, a.complete_object_locator_rva);
  if (a.vtable_rva == 0u) return fail(TextAnchorStage::kVtable);
  a.ctor_rva = FindUniqueConstructor(image, a.vtable_rva);
  if (a.ctor_rva == 0u) return fail(TextAnchorStage::kConstructor);
  a.mesh_build_rva = FindUniqueMeshBuild(
      image, a.ctor_rva, kMinimumConstructorCallsInMeshBuild,
      &a.mesh_build_ctor_calls);
  if (a.mesh_build_rva == 0u) return fail(TextAnchorStage::kMeshBuild);
  a.layout_char_rva =
      FindUniqueLayoutChar(image, a.mesh_build_rva, &a.text_begin);
  if (a.layout_char_rva == 0u) return fail(TextAnchorStage::kLayoutChar);

  // text_end：mov rax,[r15+e]; sub rax,[r15+b]; sar rax,1，要求 b == text_begin 且 e == b+8。
  {
    bool consistent = true;
    bool any = false;
    uint32_t e = 0u;
    uint32_t b = 0u;
    ForEachPatternHitInFunction(
        image, a.layout_char_rva, kLayoutTextLengthPattern,
        [&](uint32_t, const uint8_t* hit) {
          if (any && (hit[3] != e || hit[7] != b)) consistent = false;
          e = hit[3];
          b = hit[7];
          any = true;
          return consistent;
        });
    if (!any || !consistent || b != a.text_begin || e != b + 8u || e >= 0x80u)
      return fail(TextAnchorStage::kTextOffsets);
    a.text_end = e;
  }

  // cursor_x：addss xmm7,[rdi+d]; movss [rdi+d],xmm7，两处 d 相等。
  {
    bool consistent = true;
    bool any = false;
    uint32_t d = 0u;
    ForEachPatternHitInFunction(
        image, a.layout_char_rva, kLayoutCursorXPattern,
        [&](uint32_t, const uint8_t* hit) {
          if (hit[4] != hit[9]) consistent = false;
          if (any && hit[4] != d) consistent = false;
          d = hit[4];
          any = true;
          return consistent;
        });
    if (!any || !consistent || d >= 0x80u)
      return fail(TextAnchorStage::kCursorOffsets);
    a.cursor_x = d;
  }
  // cursor_y：movss xmm6,[rdi+d] 中 d == cursor_x + 4 的那一处，随后要有
  // movd xmm0,[rdi+line_pitch]。
  {
    const uint32_t expected_y = a.cursor_x + 4u;
    uint32_t first_y_hit = 0u;
    bool any_y = false;
    ForEachPatternHitInFunction(
        image, a.layout_char_rva, kLayoutCursorYPattern,
        [&](uint32_t rva, const uint8_t* hit) {
          if (hit[4] == expected_y && !any_y) {
            first_y_hit = rva;
            any_y = true;
          }
          return true;
        });
    if (!any_y) return fail(TextAnchorStage::kCursorOffsets);
    a.cursor_y = expected_y;
    uint32_t pitch = 0u;
    uint32_t pitch_last = 0u;
    if (!UniqueDisp8InFunction(image, a.layout_char_rva, kLayoutLinePitchPattern,
                               4u, &pitch, nullptr, &pitch_last) ||
        pitch_last <= first_y_hit) {
      return fail(TextAnchorStage::kCursorOffsets);
    }
    a.line_pitch = pitch;
  }
  // font_px：mulss xmm8,[rdi+d]。scale：mulss xmm0,[rdi+d] 与某处 movss xmm0,[rdi+d] 同 d。
  {
    uint32_t font = 0u;
    if (!UniqueDisp8InFunction(image, a.layout_char_rva, kLayoutFontPxPattern,
                               5u, &font, nullptr, nullptr)) {
      return fail(TextAnchorStage::kFontOffsets);
    }
    uint32_t scale = 0u;
    if (!UniqueDisp8InFunction(image, a.layout_char_rva, kLayoutScaleMulPattern,
                               4u, &scale, nullptr, nullptr)) {
      return fail(TextAnchorStage::kFontOffsets);
    }
    bool load_matches = false;
    ForEachPatternHitInFunction(
        image, a.layout_char_rva, kLayoutScaleLoadPattern,
        [&](uint32_t, const uint8_t* hit) {
          if (hit[4] == scale) load_matches = true;
          return !load_matches;
        });
    if (!load_matches) return fail(TextAnchorStage::kFontOffsets);
    a.font_px = font;
    a.scale = scale;
  }
  // layer 字段互不重叠（各 4 字节）；位移都在合理范围内。
  {
    const uint32_t layer_fields[] = {a.cursor_x, a.cursor_y, a.line_pitch,
                                     a.font_px, a.scale};
    for (size_t i = 0u; i < 5u; ++i) {
      if (layer_fields[i] >= kMaxLayerFieldOffset)
        return fail(TextAnchorStage::kFontOffsets);
      for (size_t k = i + 1u; k < 5u; ++k) {
        if (layer_fields[i] == layer_fields[k])
          return fail(TextAnchorStage::kFontOffsets);
      }
    }
    if (a.text_begin >= a.text_end || a.text_end >= kMaxLayerFieldOffset)
      return fail(TextAnchorStage::kTextOffsets);
  }
  result.ok = true;
  result.failed_stage = TextAnchorStage::kResolved;
  return result;
}

}  // namespace smash_fzmedia
}  // namespace fushi_voice_hook
