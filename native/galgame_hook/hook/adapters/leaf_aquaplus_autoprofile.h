#pragma once

// Leaf/AQUAPLUS 锚点的**自推导**。
//
// 原实现把整份 profile（25 个 RVA）钉死在单个 exe SHA-256 上：白2 换个发行版/补丁版就
// 完全不被认领。但那五处掩码签名本来就把操作数 wildcard 掉了——**签名本身是跨构建的**，
// 真正把它钉死的只是三个"期望操作数"来自硬编码 RVA。其中两个有完全通用的来源（PE 导入表、
// load config 目录），第三个（D3D9 设备指针）根本不需要期望值：从唯一命中里读出来即可。
//
// 这里只做**静态可推导**的那一层。return site / 栈帧偏移 / 顶点格式仍来自已测量 profile，
// 因此本模块单独不足以认领一个未知构建——它是那条路的第一段，且对已测量构建可当运行期自检。
//
// 所有读取都对 image.size 做边界校验：这段代码跑在玩家的游戏进程里。

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "exact_lookup_signature.h"
#include "leaf_aquaplus_profile.h"

namespace fushi_voice_hook {
namespace leaf_autoprofile {

struct DerivedAnchors {
  uintptr_t stack_cookie_rva = 0;
  uintptr_t get_async_key_state_iat_rva = 0;
  uintptr_t read_file_iat_rva = 0;
  uintptr_t text_traversal_rva = 0;
  uintptr_t raster_draw_rva = 0;
  uintptr_t input_poller_first_return_rva = 0;
  uintptr_t embed_leaf_hook_rva = 0;
  uintptr_t d3d9_device_pointer_rva = 0;
};

// 推导断在哪一步的**事实**（只记录，不参与判定）。离线探针与运行期诊断共用：
// 认领失败时唯一能推进事情的信息就是「五处签名各命中几次、交叉校验断在哪」。
struct LeafAnchorTrace {
  uint32_t traversal_hits = 0;
  uint32_t raster_hits = 0;
  uint32_t poller_hits = 0;
  uint32_t embed_hits = 0;
  uint32_t device_hits = 0;
  bool cookie_agree = false;
  bool iat_found = false;
  bool embed_site_detoured_rejected = false;
};

inline uintptr_t AbsoluteBaseOf(const exact_lookup::LoadedPeImage& image) {
  return image.absolute_base != 0u
             ? image.absolute_base
             : reinterpret_cast<uintptr_t>(image.base);
}

// RVA 落在映像内且从该处起至少还有 bytes 个字节可读。
inline bool RvaInImage(const exact_lookup::LoadedPeImage& image, uint64_t rva,
                       uint64_t bytes) {
  return image.base != nullptr && bytes != 0u && rva < image.size &&
         bytes <= static_cast<uint64_t>(image.size) - rva;
}

inline const uint8_t* AtRva(const exact_lookup::LoadedPeImage& image,
                            uint64_t rva, uint64_t bytes) {
  return RvaInImage(image, rva, bytes) ? image.base + rva : nullptr;
}

inline const IMAGE_NT_HEADERS32* NtHeaders32(
    const exact_lookup::LoadedPeImage& image) {
  const uint8_t* dos_bytes = AtRva(image, 0u, sizeof(IMAGE_DOS_HEADER));
  if (dos_bytes == nullptr) return nullptr;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(dos_bytes);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) return nullptr;
  const uint8_t* nt_bytes = AtRva(image, static_cast<uint64_t>(dos->e_lfanew),
                                  sizeof(IMAGE_NT_HEADERS32));
  if (nt_bytes == nullptr) return nullptr;
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS32*>(nt_bytes);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
    return nullptr;
  }
  return nt;
}

inline bool DataDirectoryOf(const exact_lookup::LoadedPeImage& image,
                            uint32_t index, uint32_t* rva, uint32_t* size) {
  const auto* nt = NtHeaders32(image);
  if (nt == nullptr || rva == nullptr || size == nullptr) return false;
  if (index >= nt->OptionalHeader.NumberOfRvaAndSizes) return false;
  *rva = nt->OptionalHeader.DataDirectory[index].VirtualAddress;
  *size = nt->OptionalHeader.DataDirectory[index].Size;
  return *rva != 0u;
}

// 导入表里某个符号的 IAT 槽 RVA。dll 名大小写不敏感，符号名精确匹配。
inline uintptr_t DeriveImportThunkRva(const exact_lookup::LoadedPeImage& image,
                                      const char* dll, const char* symbol) {
  uint32_t dir_rva = 0u;
  uint32_t dir_size = 0u;
  if (dll == nullptr || symbol == nullptr ||
      !DataDirectoryOf(image, IMAGE_DIRECTORY_ENTRY_IMPORT, &dir_rva,
                       &dir_size)) {
    return 0u;
  }
  for (uint32_t offset = 0u;; offset += sizeof(IMAGE_IMPORT_DESCRIPTOR)) {
    const uint8_t* bytes =
        AtRva(image, static_cast<uint64_t>(dir_rva) + offset,
              sizeof(IMAGE_IMPORT_DESCRIPTOR));
    if (bytes == nullptr) return 0u;
    const auto* desc = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(bytes);
    if (desc->Name == 0u && desc->FirstThunk == 0u) return 0u;
    // 名字是 NUL 结尾串，长度未知：逐字节比较，越界即放弃。
    bool name_matches = true;
    for (uint32_t i = 0u;; ++i) {
      const uint8_t* ch = AtRva(image, static_cast<uint64_t>(desc->Name) + i, 1u);
      if (ch == nullptr) return 0u;
      const char lhs = static_cast<char>(*ch);
      const char rhs = dll[i];
      const char lower_lhs =
          (lhs >= 'A' && lhs <= 'Z') ? static_cast<char>(lhs - 'A' + 'a') : lhs;
      const char lower_rhs =
          (rhs >= 'A' && rhs <= 'Z') ? static_cast<char>(rhs - 'A' + 'a') : rhs;
      if (lower_lhs != lower_rhs) {
        name_matches = false;
        break;
      }
      if (lhs == '\0') break;
    }
    if (!name_matches) continue;

    const uint32_t lookup = desc->OriginalFirstThunk != 0u
                                ? desc->OriginalFirstThunk
                                : desc->FirstThunk;
    if (lookup == 0u || desc->FirstThunk == 0u) return 0u;
    for (uint32_t i = 0u;; ++i) {
      const uint8_t* slot_bytes =
          AtRva(image, static_cast<uint64_t>(lookup) + i * sizeof(uint32_t),
                sizeof(uint32_t));
      if (slot_bytes == nullptr) return 0u;
      uint32_t entry = 0u;
      std::memcpy(&entry, slot_bytes, sizeof(entry));
      if (entry == 0u) return 0u;
      if ((entry & IMAGE_ORDINAL_FLAG32) != 0u) continue;  // 按序号导入，无名字
      // IMAGE_IMPORT_BY_NAME：2 字节 Hint + NUL 结尾名字。
      bool symbol_matches = true;
      for (uint32_t j = 0u;; ++j) {
        const uint8_t* ch =
            AtRva(image, static_cast<uint64_t>(entry) + 2u + j, 1u);
        if (ch == nullptr) return 0u;
        if (static_cast<char>(*ch) != symbol[j]) {
          symbol_matches = false;
          break;
        }
        if (symbol[j] == '\0') break;
      }
      if (symbol_matches)
        return static_cast<uintptr_t>(desc->FirstThunk) +
               i * sizeof(uint32_t);
    }
  }
}

// /GS 栈 cookie。首选 load config 目录；老工具链可能没有该字段，此时返回 0，
// 由调用方改用"两个独立签名读出的操作数必须一致"这条更强的路（见 DeriveLeafAnchors）。
inline uintptr_t DeriveSecurityCookieRva(
    const exact_lookup::LoadedPeImage& image) {
  uint32_t dir_rva = 0u;
  uint32_t dir_size = 0u;
  if (!DataDirectoryOf(image, IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG, &dir_rva,
                       &dir_size)) {
    return 0u;
  }
  // SecurityCookie 在 IMAGE_LOAD_CONFIG_DIRECTORY32 的 0x3c 处。目录 Size 由链接器
  // 写入，老版本会短于完整结构，不能直接按结构体大小读。
  constexpr uint32_t kSecurityCookieOffset = 0x3cu;
  if (dir_size < kSecurityCookieOffset + sizeof(uint32_t)) return 0u;
  const uint8_t* bytes =
      AtRva(image, static_cast<uint64_t>(dir_rva) + kSecurityCookieOffset,
            sizeof(uint32_t));
  if (bytes == nullptr) return 0u;
  uint32_t va = 0u;
  std::memcpy(&va, bytes, sizeof(va));
  const uintptr_t absolute_base = AbsoluteBaseOf(image);
  if (va < absolute_base || va - absolute_base >= image.size) return 0u;
  return static_cast<uintptr_t>(va) - absolute_base;
}

// 定位一处唯一掩码签名，并（可选）读出其中的操作数。
inline bool LocateUniqueSignature(const exact_lookup::LoadedPeImage& image,
                                  const exact_lookup::MaskedPattern& pattern,
                                  uintptr_t* site_rva, size_t operand_offset,
                                  uint32_t* operand,
                                  uint32_t* hit_count = nullptr) {
  const auto hit =
      exact_lookup::FindUniquePatternInExecutableSections(image, pattern);
  if (hit_count != nullptr) *hit_count = hit.count;
  if (hit.count != 1u || hit.address == nullptr || site_rva == nullptr)
    return false;
  const uintptr_t rva = static_cast<uintptr_t>(hit.address - image.base);
  if (operand != nullptr) {
    if (operand_offset + sizeof(uint32_t) > pattern.size ||
        !RvaInImage(image, rva + operand_offset, sizeof(uint32_t))) {
      return false;
    }
    std::memcpy(operand, hit.address + operand_offset, sizeof(*operand));
  }
  *site_rva = rva;
  return true;
}

// 结构证明读的是哪一份字节。
//   kPristineFile：磁盘 exe 手工按节展开的私有副本（不经加载器、无任何 detour）。
//   kRuntimeImage：本进程已加载的主模块。带壳 / 运行期解密的构建只有这一份是真代码，
//                  但它可能已被注入的 hook 改写过（见 EmbedHookSiteIsIntact）。
enum class LeafImageSource : uint8_t { kPristineFile, kRuntimeImage };

// hook 点的两字节：原样 `2b c3`（sub eax, ebx），或（仅运行时映像）一条目标落在主映像
// 之外的 rel32 jmp——注入模块的 detour。跳回映像内部的 jmp 不是 detour 形状，拒绝。
inline bool EmbedHookSiteIsIntact(const exact_lookup::LoadedPeImage& image,
                                  uintptr_t hook_rva, LeafImageSource source) {
  const uint8_t* site = AtRva(image, hook_rva, 5u);
  if (site == nullptr) return false;
  if (site[0] == 0x2bu && site[1] == 0xc3u) return true;
  if (source != LeafImageSource::kRuntimeImage || site[0] != 0xe9u) return false;
  int32_t displacement = 0;
  std::memcpy(&displacement, site + 1, sizeof(displacement));
  const int64_t target = static_cast<int64_t>(hook_rva) + 5 +
                         static_cast<int64_t>(displacement);
  return target < 0 || static_cast<uint64_t>(target) >= image.size;
}

inline bool DeriveLeafAnchors(const exact_lookup::LoadedPeImage& image,
                              DerivedAnchors* out,
                              LeafAnchorTrace* trace = nullptr,
                              LeafImageSource source =
                                  LeafImageSource::kPristineFile) {
  if (out == nullptr) return false;
  *out = {};
  LeafAnchorTrace local_trace;
  LeafAnchorTrace& t = trace != nullptr ? *trace : local_trace;
  t = {};
  const uintptr_t absolute_base = AbsoluteBaseOf(image);

  uintptr_t traversal_rva = 0u;
  uint32_t traversal_cookie = 0u;
  uintptr_t raster_rva = 0u;
  uint32_t raster_cookie = 0u;
  // 两处都要扫完再判：命中计数是诊断事实，短路会让第二处永远记成 0。
  const bool traversal_ok = LocateUniqueSignature(
      image, leaf_exact::kTextTraversalEntryPattern, &traversal_rva,
      leaf_exact::kTextTraversalCookieOperandOffset, &traversal_cookie,
      &t.traversal_hits);
  const bool raster_ok = LocateUniqueSignature(
      image, leaf_exact::kRasterDrawEntryPattern, &raster_rva,
      leaf_exact::kRasterDrawCookieOperandOffset, &raster_cookie,
      &t.raster_hits);
  if (!traversal_ok || !raster_ok) return false;
  // 两处**互相独立**的签名必须读出同一个 cookie。这既是 cookie 的来源，也是"这份二进制
  // 确实是这套引擎"的交叉校验——不一致就说明识别不可信，宁可不认领。
  if (traversal_cookie != raster_cookie) return false;
  if (traversal_cookie < absolute_base ||
      traversal_cookie - absolute_base >= image.size) {
    return false;
  }
  const uintptr_t cookie_rva =
      static_cast<uintptr_t>(traversal_cookie) - absolute_base;
  const uintptr_t load_config_cookie = DeriveSecurityCookieRva(image);
  if (load_config_cookie != 0u && load_config_cookie != cookie_rva) return false;
  t.cookie_agree = true;

  const uintptr_t key_state_iat =
      DeriveImportThunkRva(image, "user32.dll", "GetAsyncKeyState");
  const uintptr_t read_file_iat =
      DeriveImportThunkRva(image, "kernel32.dll", "ReadFile");
  if (key_state_iat == 0u || read_file_iat == 0u) return false;
  t.iat_found = true;

  uintptr_t poller_anchor = 0u;
  uint32_t poller_operand = 0u;
  if (!LocateUniqueSignature(image, leaf_exact::kInputPollerEntryPattern,
                             &poller_anchor,
                             leaf_exact::kInputPollerIatOperandOffset,
                             &poller_operand, &t.poller_hits)) {
    return false;
  }
  // 输入轮询签名里的操作数必须正好是导入表推出的那个 IAT 槽。
  if (poller_operand != absolute_base + key_state_iat) return false;

  // 文本 hook 点前 23 字节（对象字段 + NUL 扫描循环）唯一定位锚点；hook 点本身的两字节
  // 单独判。磁盘原始映像上它必须原样是 `sub eax, ebx`；运行时映像上它可能已被注入的文本
  // hook（Fushi 自己选给 LunaHook 的 HSX0:0 就落在这里）换成一条跳出主映像的 rel32 jmp
  // ——那是「这里正是那个 hook 点」的又一条证据，不是结构不符。
  uintptr_t embed_anchor = 0u;
  if (!LocateUniqueSignature(image, leaf_exact::kEmbedLoopPrefixPattern,
                             &embed_anchor, 0u, nullptr, &t.embed_hits)) {
    return false;
  }
  if (!EmbedHookSiteIsIntact(image,
                             embed_anchor + leaf_exact::kEmbedHookOffsetFromAnchor,
                             source)) {
    t.embed_site_detoured_rejected = true;
    return false;
  }

  uintptr_t device_site = 0u;
  uint32_t device_operand = 0u;
  if (!LocateUniqueSignature(image, leaf_exact::kD3dDeviceAccessPattern,
                             &device_site,
                             leaf_exact::kD3dDevicePointerOperandOffset,
                             &device_operand, &t.device_hits)) {
    return false;
  }
  if (device_operand < absolute_base ||
      device_operand - absolute_base >= image.size) {
    return false;
  }

  out->stack_cookie_rva = cookie_rva;
  out->get_async_key_state_iat_rva = key_state_iat;
  out->read_file_iat_rva = read_file_iat;
  out->text_traversal_rva = traversal_rva;
  out->raster_draw_rva = raster_rva;
  out->input_poller_first_return_rva = poller_anchor + 10u;
  out->embed_leaf_hook_rva =
      embed_anchor + leaf_exact::kEmbedHookOffsetFromAnchor;
  out->d3d9_device_pointer_rva =
      static_cast<uintptr_t>(device_operand) - absolute_base;
  return true;
}

// 推导结果与已测量 profile 是否一致。已测量构建上这必须恒真——它是自推导路径的
// 运行期自检，也是把 profile 从"钉死在一个哈希"迁走之前唯一能拿到的正确性证据。
inline bool DerivedAnchorsMatchProfile(const DerivedAnchors& derived,
                                       const LeafAquaplusProfile& profile) {
  return derived.stack_cookie_rva == profile.stack_cookie_rva &&
         derived.get_async_key_state_iat_rva ==
             profile.get_async_key_state_iat_rva &&
         derived.read_file_iat_rva == profile.read_file_iat_rva &&
         derived.text_traversal_rva == profile.text_traversal_rva &&
         derived.raster_draw_rva == profile.raster_draw_rva &&
         derived.input_poller_first_return_rva ==
             profile.input_poller_first_return_rva &&
         derived.embed_leaf_hook_rva == profile.embed_leaf_hook_rva &&
         derived.d3d9_device_pointer_rva == profile.d3d9_device_pointer_rva;
}


// ── 第二段：return site 的解析 ────────────────────────────────────────────
//
// 这些字段（glyph 派发、各处 call 的返回点、VOICE.PAK 的同步 ReadFile 返回点）没有各自
// 的唯一签名可扫。给每个都编一套 ad-hoc 推导规则很容易猜错，而且是**静默**猜错——几何
// 会歪、语音会配不上，却没有任何一处报错。
//
// 采用的办法是：把它们表达成**相对已推导锚点的位移**，再用结构门里已有的调用形状校验逐个
// 验真。位移取自已测量构建，只当搜索起点；真正决定采信与否的永远是那几个调用形状判定。
// VN 的补丁版最常见的变化是整体地址位移而非重新 codegen，位移 + 形状校验正好覆盖这一类；
// codegen 真变了则形状校验失败，于是拒绝认领——不猜。
//
// 起点不成立时在有界窗口内搜索，且要求窗口内**唯一**满足形状判定的位置：多于一个就说明
// 判据不足以定位，同样拒绝。
constexpr uintptr_t kLeafResolveWindow = 0x40u;

struct LeafAnchorDeltas {
  intptr_t glyph_dispatch_from_traversal = -0x220;
  intptr_t raster_glyph_return_from_traversal = -0x9;
  intptr_t glyph_single_return_from_traversal = 0xCB2;
  intptr_t glyph_double_first_return_from_traversal = 0xE02;
  intptr_t glyph_double_second_return_from_traversal = 0xEC5;
  intptr_t quad_draw_return_from_raster = 0x2789;
  intptr_t alternate_quad_draw_return_from_raster = 0x13D8;
  intptr_t input_poller_last_return_from_anchor = 0x180;
  intptr_t voice_archive_read_return_from_embed_anchor = 0x7E9A;
};

inline constexpr LeafAnchorDeltas kMeasuredLeafAnchorDeltas = {};

// rel32 call 的目标 RVA。return_rva 是**调用之后**那条指令的 RVA。
inline bool DecodeRel32CallTarget(const exact_lookup::LoadedPeImage& image,
                                  uintptr_t return_rva, uintptr_t* target_rva) {
  if (target_rva == nullptr || return_rva < 5u) return false;
  const uint8_t* call = AtRva(image, return_rva - 5u, 5u);
  if (call == nullptr || call[0] != 0xe8u) return false;
  int32_t displacement = 0;
  std::memcpy(&displacement, call + 1, sizeof(displacement));
  const int64_t target =
      static_cast<int64_t>(return_rva) + static_cast<int64_t>(displacement);
  if (target < 0 || static_cast<uint64_t>(target) >= image.size) return false;
  *target_rva = static_cast<uintptr_t>(target);
  return true;
}

// 在 [candidate-window, candidate+window] 内找**唯一**满足 predicate 的 RVA。
// candidate 自身成立时直接采用（补丁版位移为零的常见情形），不再扫窗口。
template <typename Predicate>
inline bool ResolveNearCandidate(uintptr_t candidate, uintptr_t window,
                                 size_t image_size, Predicate predicate,
                                 uintptr_t* resolved) {
  if (resolved == nullptr || candidate == 0u || candidate >= image_size)
    return false;
  if (predicate(candidate)) {
    *resolved = candidate;
    return true;
  }
  uintptr_t hit = 0u;
  uint32_t hits = 0u;
  const uintptr_t low = candidate > window ? candidate - window : 1u;
  const uintptr_t high =
      candidate + window < image_size ? candidate + window : image_size - 1u;
  for (uintptr_t rva = low; rva <= high; ++rva) {
    if (!predicate(rva)) continue;
    if (++hits > 1u) return false;  // 判据不足以定位，宁可不认
    hit = rva;
  }
  if (hits != 1u) return false;
  *resolved = hit;
  return true;
}

inline uintptr_t OffsetRva(uintptr_t anchor, intptr_t delta) {
  const intptr_t value = static_cast<intptr_t>(anchor) + delta;
  return value > 0 ? static_cast<uintptr_t>(value) : 0u;
}

// traversal 函数体的扫描上界。WA2 的 26-dword 文本遍历函数体约 0x1600 字节；上界只用于
// 「派发函数被它调用了几次」这一计数，略大于函数体不影响判定（外面的调用者也必须调同一
// 目标才会被计入，且只做下限判断）。
constexpr uintptr_t kLeafTraversalBodyBytes = 0x2000u;

// [begin, begin+bytes) 内以 rel32 call 调向 target_rva 的位置数。
inline uint32_t CountRel32CallersInRange(
    const exact_lookup::LoadedPeImage& image, uintptr_t target_rva,
    uintptr_t begin, uintptr_t bytes) {
  uint32_t count = 0u;
  const uintptr_t end =
      begin + bytes < image.size ? begin + bytes : static_cast<uintptr_t>(image.size);
  for (uintptr_t rva = begin + 5u; rva <= end; ++rva) {
    if (exact_lookup::MatchesRel32CallEndingAt(image, rva, target_rva)) ++count;
  }
  return count;
}

// `sub esp, 0x100; mov ecx, 0x40; mov edi, esp; rep movsd` 紧贴在结束于 return_rva 的
// rel32 call 之前：把 0x100 字节（0x40 dword）文字状态按值拷进参数区。
inline bool HasGlyphStateCopyBeforeCall(const exact_lookup::LoadedPeImage& image,
                                        uintptr_t return_rva) {
  static constexpr uint8_t kCopy[] = {0x81, 0xec, 0x00, 0x01, 0x00, 0x00,
                                      0xb9, 0x40, 0x00, 0x00, 0x00, 0x8b,
                                      0xfc, 0xf3, 0xa5};
  if (return_rva < 5u + sizeof(kCopy)) return false;
  const uint8_t* bytes = AtRva(image, return_rva - 5u - sizeof(kCopy),
                               sizeof(kCopy));
  return bytes != nullptr && std::memcmp(bytes, kCopy, sizeof(kCopy)) == 0;
}

// 结束于 return_rva 的调用之后紧跟 `add esp, 8; ret`：两个 cdecl 参数、调用者无局部帧。
inline bool HasTwoArgumentFramelessReturnAfter(
    const exact_lookup::LoadedPeImage& image, uintptr_t return_rva) {
  const uint8_t* bytes = AtRva(image, return_rva, 4u);
  return bytes != nullptr && bytes[0] == 0x83u && bytes[1] == 0xc4u &&
         bytes[2] == 0x08u && bytes[3] == 0xc3u;
}

// 用推导出的锚点 + 形状校验解析出一份完整 profile。
// 成功返回 true，且 out 里除栈帧偏移/顶点格式外的每个 RVA 都经过形状判定。
enum class LeafResolveStage : uint8_t {
  kNone = 0,
  kInvalidInput,
  kGlyphSingleReturn,
  kGlyphDispatch,
  kGlyphDoubleReturns,
  kRasterGlyphReturn,
  kIndirectCallReturns,
  kVoiceArchiveReadReturn,
};

struct LeafResolveTrace {
  LeafResolveStage failed_at = LeafResolveStage::kNone;
};

inline const char* LeafResolveStageName(LeafResolveStage stage) {
  switch (stage) {
    case LeafResolveStage::kNone: return "none";
    case LeafResolveStage::kInvalidInput: return "invalid_input";
    case LeafResolveStage::kGlyphSingleReturn: return "glyph_single_return";
    case LeafResolveStage::kGlyphDispatch: return "glyph_dispatch";
    case LeafResolveStage::kGlyphDoubleReturns: return "glyph_double_returns";
    case LeafResolveStage::kRasterGlyphReturn: return "raster_glyph_return";
    case LeafResolveStage::kIndirectCallReturns: return "indirect_call_returns";
    case LeafResolveStage::kVoiceArchiveReadReturn:
      return "voice_archive_read_return";
  }
  return "unknown";
}

inline bool FailResolve(LeafResolveTrace* trace, LeafResolveStage stage) {
  if (trace != nullptr) trace->failed_at = stage;
  return false;
}

inline bool ResolveLeafProfile(const exact_lookup::LoadedPeImage& image,
                               const DerivedAnchors& anchors,
                               const LeafAnchorDeltas& deltas,
                               LeafAquaplusProfile* out,
                               LeafResolveTrace* trace = nullptr) {
  if (trace != nullptr) *trace = {};
  if (out == nullptr || image.base == nullptr) return FailResolve(trace, LeafResolveStage::kInvalidInput);
  const uintptr_t traversal = anchors.text_traversal_rva;
  const uintptr_t raster = anchors.raster_draw_rva;
  if (traversal == 0u || raster == 0u) return FailResolve(trace, LeafResolveStage::kInvalidInput);
  const uintptr_t poller_anchor =
      anchors.input_poller_first_return_rva >= 10u
          ? anchors.input_poller_first_return_rva - 10u
          : 0u;
  const uintptr_t embed_anchor =
      anchors.embed_leaf_hook_rva >= leaf_exact::kEmbedHookOffsetFromAnchor
          ? anchors.embed_leaf_hook_rva - leaf_exact::kEmbedHookOffsetFromAnchor
          : 0u;
  if (poller_anchor == 0u || embed_anchor == 0u) return FailResolve(trace, LeafResolveStage::kInvalidInput);

  // glyph 派发函数先定下来：位移起点 + 「被 traversal 函数体内至少三处 rel32 调用」这一
  // 调用图判据。旧实现先用「任意一条 rel32 call」去定单字节返回点、再解码其目标——那条判据
  // 在 traversal 这种每几字节就一条 call 的函数里毫无选择性：函数体内只要有一段代码插入，
  // 窗口里就会出现多条 call，于是整体拒绝（另一个 WA2 构建就是在这里断的）。
  uintptr_t glyph_dispatch = 0u;
  if (!ResolveNearCandidate(
          OffsetRva(traversal, deltas.glyph_dispatch_from_traversal),
          kLeafResolveWindow, image.size,
          [&image, traversal](uintptr_t rva) {
            return CountRel32CallersInRange(image, rva, traversal,
                                            kLeafTraversalBodyBytes) >= 3u;
          },
          &glyph_dispatch)) {
    return FailResolve(trace, LeafResolveStage::kGlyphDispatch);
  }
  if (!exact_lookup::SectionHasRole(
          exact_lookup::FindSectionForRva(image, glyph_dispatch, 1u),
          IMAGE_SCN_MEM_EXECUTE)) {
    return FailResolve(trace, LeafResolveStage::kGlyphDispatch);
  }

  // 三个准入的 glyph 返回点：判据是「调向派发函数」（每个窗口里这种调用至多一条），
  // 且调用点前是把 0x100 字节文字状态按值拷进参数区的 rep movsd 帧形状——
  // raster_packed_cp932_stack_offset 的 0x110 正是由这 0x100 字节 + 两个压栈参数撑出来的，
  // 形状对上了这条栈偏移才有结构依据，而不只是「已测量构建上是这个数」。
  const auto calls_dispatch = [&image, glyph_dispatch](uintptr_t rva) {
    return exact_lookup::MatchesRel32CallEndingAt(image, rva, glyph_dispatch) &&
           HasGlyphStateCopyBeforeCall(image, rva);
  };
  uintptr_t glyph_single = 0u;
  if (!ResolveNearCandidate(
          OffsetRva(traversal, deltas.glyph_single_return_from_traversal),
          kLeafResolveWindow, image.size, calls_dispatch, &glyph_single)) {
    return FailResolve(trace, LeafResolveStage::kGlyphSingleReturn);
  }
  uintptr_t glyph_double_first = 0u;
  uintptr_t glyph_double_second = 0u;
  if (!ResolveNearCandidate(
          OffsetRva(traversal, deltas.glyph_double_first_return_from_traversal),
          kLeafResolveWindow, image.size, calls_dispatch,
          &glyph_double_first) ||
      !ResolveNearCandidate(
          OffsetRva(traversal,
                    deltas.glyph_double_second_return_from_traversal),
          kLeafResolveWindow, image.size, calls_dispatch,
          &glyph_double_second)) {
    return FailResolve(trace, LeafResolveStage::kGlyphDoubleReturns);
  }
  // 三点是同一段单字节 / 双字节分支：彼此间距是那段代码自身的长度，与函数体前面插入了多少
  // 代码无关。间距对不上 = 窗口各自挑中了不相干的调用，拒绝。
  const intptr_t single_to_first =
      deltas.glyph_double_first_return_from_traversal -
      deltas.glyph_single_return_from_traversal;
  const intptr_t first_to_second =
      deltas.glyph_double_second_return_from_traversal -
      deltas.glyph_double_first_return_from_traversal;
  if (static_cast<intptr_t>(glyph_double_first - glyph_single) !=
          single_to_first ||
      static_cast<intptr_t>(glyph_double_second - glyph_double_first) !=
          first_to_second) {
    return FailResolve(trace, LeafResolveStage::kGlyphDoubleReturns);
  }

  // 派发函数里那一处 raster 调用：`call raster; add esp, 8; ret`。两个参数、无局部帧，
  // raster_parent_return_stack_offset 的 0x0c（返回槽 + 两个参数）由此得到结构依据。
  uintptr_t raster_glyph_return = 0u;
  if (!ResolveNearCandidate(
          OffsetRva(traversal, deltas.raster_glyph_return_from_traversal),
          kLeafResolveWindow, image.size,
          [&image, raster](uintptr_t rva) {
            return exact_lookup::MatchesRel32CallEndingAt(image, rva, raster) &&
                   HasTwoArgumentFramelessReturnAfter(image, rva);
          },
          &raster_glyph_return)) {
    return FailResolve(trace, LeafResolveStage::kRasterGlyphReturn);
  }
  if (raster_glyph_return <= glyph_dispatch ||
      raster_glyph_return - glyph_dispatch > kLeafTraversalBodyBytes) {
    return FailResolve(trace, LeafResolveStage::kRasterGlyphReturn);
  }

  const auto indirect_d0 = [&image](uintptr_t rva) {
    return exact_lookup::MatchesRegisterIndirectCallEndingAt(image, rva, 0xd0u);
  };
  const auto indirect_d6 = [&image](uintptr_t rva) {
    return exact_lookup::MatchesRegisterIndirectCallEndingAt(image, rva, 0xd6u);
  };
  uintptr_t quad_draw_return = 0u;
  uintptr_t alternate_quad_draw_return = 0u;
  uintptr_t poller_last_return = 0u;
  if (!ResolveNearCandidate(
          OffsetRva(raster, deltas.quad_draw_return_from_raster),
          kLeafResolveWindow, image.size, indirect_d0, &quad_draw_return) ||
      !ResolveNearCandidate(
          OffsetRva(raster, deltas.alternate_quad_draw_return_from_raster),
          kLeafResolveWindow, image.size, indirect_d0,
          &alternate_quad_draw_return) ||
      !ResolveNearCandidate(
          OffsetRva(poller_anchor,
                    deltas.input_poller_last_return_from_anchor),
          kLeafResolveWindow, image.size, indirect_d6, &poller_last_return)) {
    return FailResolve(trace, LeafResolveStage::kIndirectCallReturns);
  }
  if (quad_draw_return == alternate_quad_draw_return) return FailResolve(trace, LeafResolveStage::kIndirectCallReturns);

  const uintptr_t read_file_iat = anchors.read_file_iat_rva;
  uintptr_t voice_read_return = 0u;
  if (!ResolveNearCandidate(
          OffsetRva(embed_anchor,
                    deltas.voice_archive_read_return_from_embed_anchor),
          kLeafResolveWindow, image.size,
          [&image, read_file_iat](uintptr_t rva) {
            return exact_lookup::MatchesAbsoluteIndirectCallEndingAt(
                image, rva, read_file_iat);
          },
          &voice_read_return)) {
    return FailResolve(trace, LeafResolveStage::kVoiceArchiveReadReturn);
  }

  *out = kWhiteAlbum2LeafAquaplusProfile;  // 栈帧偏移/顶点格式沿用已测量值
  out->executable_sha256 = {};  // 解析出来的 profile 不冒充已测量身份
  out->d3d9_device_pointer_rva = anchors.d3d9_device_pointer_rva;
  out->stack_cookie_rva = anchors.stack_cookie_rva;
  out->get_async_key_state_iat_rva = anchors.get_async_key_state_iat_rva;
  out->read_file_iat_rva = anchors.read_file_iat_rva;
  out->embed_leaf_hook_rva = anchors.embed_leaf_hook_rva;
  out->input_poller_first_return_rva = anchors.input_poller_first_return_rva;
  out->input_poller_last_return_rva = poller_last_return;
  out->text_traversal_rva = traversal;
  out->raster_draw_rva = raster;
  out->glyph_dispatch_rva = glyph_dispatch;
  out->raster_glyph_return_rva = raster_glyph_return;
  out->glyph_single_return_rva = glyph_single;
  out->glyph_double_first_return_rva = glyph_double_first;
  out->glyph_double_second_return_rva = glyph_double_second;
  out->quad_draw_return_rva = quad_draw_return;
  out->alternate_quad_draw_return_rva = alternate_quad_draw_return;
  out->voice_archive_read_return_rva = voice_read_return;
  return true;
}

// 解析出的每个 RVA 落在角色正确的节里：代码点在可执行节，D3D 设备槽 / cookie 在可写数据节，
// IAT 槽在可读非执行节。结构门的最后一道，防止「形状碰巧对上、却落在资源节」这类误认。
inline bool LeafProfileSectionRolesValid(
    const exact_lookup::LoadedPeImage& image,
    const LeafAquaplusProfile& profile) {
  const auto executable_rva = [&image](uintptr_t rva, size_t bytes = 1u) {
    return exact_lookup::SectionHasRole(
        exact_lookup::FindSectionForRva(image, rva, bytes),
        IMAGE_SCN_MEM_EXECUTE);
  };
  const auto data_rva = [&image](uintptr_t rva, size_t bytes,
                                 uint32_t required) {
    return exact_lookup::SectionHasRole(
        exact_lookup::FindSectionForRva(image, rva, bytes), required,
        IMAGE_SCN_MEM_EXECUTE);
  };
  return profile.input_poller_first_return_rva >= 10u &&
         profile.input_poller_last_return_rva >
             profile.input_poller_first_return_rva &&
         executable_rva(profile.embed_leaf_hook_rva) &&
         executable_rva(profile.text_traversal_rva,
                        sizeof(leaf_exact::kTextTraversalEntryBytes)) &&
         executable_rva(profile.raster_draw_rva,
                        sizeof(leaf_exact::kRasterDrawEntryBytes)) &&
         executable_rva(profile.glyph_dispatch_rva) &&
         executable_rva(profile.input_poller_first_return_rva) &&
         executable_rva(profile.input_poller_last_return_rva) &&
         executable_rva(profile.raster_glyph_return_rva) &&
         executable_rva(profile.glyph_single_return_rva) &&
         executable_rva(profile.glyph_double_first_return_rva) &&
         executable_rva(profile.glyph_double_second_return_rva) &&
         executable_rva(profile.quad_draw_return_rva) &&
         executable_rva(profile.alternate_quad_draw_return_rva) &&
         executable_rva(profile.voice_archive_read_return_rva) &&
         data_rva(profile.d3d9_device_pointer_rva, sizeof(uint32_t),
                  IMAGE_SCN_MEM_WRITE) &&
         data_rva(profile.stack_cookie_rva, sizeof(uint32_t),
                  IMAGE_SCN_MEM_WRITE) &&
         data_rva(profile.get_async_key_state_iat_rva, sizeof(uint32_t),
                  IMAGE_SCN_MEM_READ) &&
         data_rva(profile.read_file_iat_rva, sizeof(uint32_t),
                  IMAGE_SCN_MEM_READ);
}

// 一次完整的结构证明：锚点推导 → return site 解析 → 节角色。三段全过才产出 profile。
struct LeafStructureProof {
  LeafAnchorTrace anchors;
  LeafResolveTrace resolve;
  bool anchors_ok = false;
  bool resolve_ok = false;
  bool section_roles_ok = false;
};

inline bool ProveLeafStructure(const exact_lookup::LoadedPeImage& image,
                               LeafImageSource source,
                               LeafAquaplusProfile* out,
                               LeafStructureProof* proof) {
  LeafStructureProof local;
  LeafStructureProof& p = proof != nullptr ? *proof : local;
  p = {};
  if (out == nullptr || image.base == nullptr ||
      image.machine != IMAGE_FILE_MACHINE_I386 || image.pointer_bits != 32u) {
    return false;
  }
  DerivedAnchors anchors;
  p.anchors_ok = DeriveLeafAnchors(image, &anchors, &p.anchors, source);
  if (!p.anchors_ok) return false;
  LeafAquaplusProfile resolved;
  p.resolve_ok = ResolveLeafProfile(image, anchors, kMeasuredLeafAnchorDeltas,
                                    &resolved, &p.resolve);
  if (!p.resolve_ok) return false;
  p.section_roles_ok = LeafProfileSectionRolesValid(image, resolved);
  if (!p.section_roles_ok) return false;
  *out = resolved;
  return true;
}

// ── 磁盘代码是否「替运行期代码说了算」 ───────────────────────────────────
//
// 带壳 / 运行期解密的构建，磁盘上的可执行节要么没有原始数据（UPX 式空节，运行期才填），
// 要么是压缩 / 加密后的高熵字节。两种情况下对磁盘副本的结构证明都必然失败，但那不是
// 「这不是 Leaf」——真代码只在运行时映像里。这一判据与引擎无关（只看节表与字节分布），
// 只用来决定要不要转去运行时映像并按生命周期重扫，**从不**单独决定认领。
//
// 熵阈值：x86 机器码约 6~6.8 bit/byte（白2 实测 6.74），压缩 / 加密数据 ≥7.5。
inline constexpr double kLeafPackedEntropyBitsPerByte = 7.2;

inline double ShannonEntropyBitsPerByte(const uint8_t* bytes, size_t size) {
  if (bytes == nullptr || size == 0u) return 0.0;
  uint32_t counts[256] = {};
  for (size_t index = 0; index < size; ++index) ++counts[bytes[index]];
  double entropy = 0.0;
  const double total = static_cast<double>(size);
  for (uint32_t count : counts) {
    if (count == 0u) continue;
    const double p = static_cast<double>(count) / total;
    entropy -= p * std::log2(p);
  }
  return entropy;
}

inline bool LeafExecutableCodeLooksPacked(
    const exact_lookup::LoadedPeImage& image) {
  const auto* nt = NtHeaders32(image);
  if (nt == nullptr) return false;
  const uint64_t table =
      static_cast<uint64_t>(reinterpret_cast<const uint8_t*>(nt) - image.base) +
      offsetof(IMAGE_NT_HEADERS32, OptionalHeader) +
      nt->FileHeader.SizeOfOptionalHeader;
  const WORD count = nt->FileHeader.NumberOfSections;
  for (WORD index = 0; index < count; ++index) {
    const uint8_t* bytes =
        AtRva(image, table + index * sizeof(IMAGE_SECTION_HEADER),
              sizeof(IMAGE_SECTION_HEADER));
    if (bytes == nullptr) return false;
    IMAGE_SECTION_HEADER section;
    std::memcpy(&section, bytes, sizeof(section));
    if ((section.Characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u) continue;
    const uint32_t virtual_size = section.Misc.VirtualSize != 0u
                                      ? section.Misc.VirtualSize
                                      : section.SizeOfRawData;
    if (virtual_size == 0u) continue;
    if (section.SizeOfRawData == 0u) return true;  // 运行期才填的空代码节
    const uint32_t span = section.SizeOfRawData < virtual_size
                              ? section.SizeOfRawData
                              : virtual_size;
    const uint8_t* code = AtRva(image, section.VirtualAddress, span);
    if (code == nullptr) continue;
    if (ShannonEntropyBitsPerByte(code, span) >= kLeafPackedEntropyBitsPerByte)
      return true;
  }
  return false;
}

}  // namespace leaf_autoprofile
}  // namespace fushi_voice_hook
