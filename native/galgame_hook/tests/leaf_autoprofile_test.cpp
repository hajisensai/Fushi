// Leaf/AQUAPLUS 锚点自推导的合成夹具测试。
//
// 这里构造一份**最小但结构真实**的 32 位 PE（DOS/NT 头、节表、导入表、load config），
// 把五处掩码签名按选定 RVA 摆进可执行节，然后要求推导把它们全部找回来。夹具里不含任何
// 游戏内容——真实游戏二进制不入库，跨构建的正确性只能靠这种合成结构 + 真机自检来钉。
#include <windows.h>

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "exact_lookup_signature.h"
#include "leaf_aquaplus_autoprofile.h"
#include "leaf_aquaplus_profile.h"

namespace {

namespace el = fushi_voice_hook::exact_lookup;
namespace ap = fushi_voice_hook::leaf_autoprofile;
namespace lx = fushi_voice_hook::leaf_exact;

constexpr uint32_t kImageBase = 0x00400000u;
constexpr uint32_t kSectionAlign = 0x1000u;
constexpr uint32_t kTextRva = 0x1000u;
constexpr uint32_t kTextSize = 0x8000u;
constexpr uint32_t kDataRva = 0x9000u;
constexpr uint32_t kDataSize = 0x2000u;
constexpr uint32_t kImageSize = 0xC000u;

// 各签名在合成映像里的落点。故意不等于白2 的真实 RVA：测的是"能不能找回来"，
// 不是"能不能背出那份 profile"。
constexpr uint32_t kTraversalRva = 0x1400u;
constexpr uint32_t kRasterRva = 0x2400u;
constexpr uint32_t kPollerRva = 0x3400u;
constexpr uint32_t kEmbedRva = 0x4400u;
constexpr uint32_t kDeviceRva = 0x5400u;
constexpr uint32_t kCookieRva = 0x9100u;
constexpr uint32_t kDeviceSlotRva = 0x9200u;
constexpr uint32_t kImportDirRva = 0x9400u;
constexpr uint32_t kLoadConfigRva = 0x9800u;

class SyntheticImage {
 public:
  SyntheticImage() : bytes_(kImageSize, 0u) {
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(bytes_.data());
    dos->e_magic = IMAGE_DOS_SIGNATURE;
    dos->e_lfanew = 0x80;

    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS32*>(bytes_.data() + 0x80);
    nt->Signature = IMAGE_NT_SIGNATURE;
    nt->FileHeader.Machine = IMAGE_FILE_MACHINE_I386;
    nt->FileHeader.NumberOfSections = 2;
    nt->FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER32);
    nt->OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC;
    nt->OptionalHeader.ImageBase = kImageBase;
    nt->OptionalHeader.SectionAlignment = kSectionAlign;
    nt->OptionalHeader.FileAlignment = 0x200u;
    nt->OptionalHeader.SizeOfImage = kImageSize;
    nt->OptionalHeader.SizeOfHeaders = kSectionAlign;
    nt->OptionalHeader.NumberOfRvaAndSizes = IMAGE_NUMBEROF_DIRECTORY_ENTRIES;

    auto* section = IMAGE_FIRST_SECTION(nt);
    std::memcpy(section[0].Name, ".text", 5);
    section[0].VirtualAddress = kTextRva;
    section[0].Misc.VirtualSize = kTextSize;
    section[0].SizeOfRawData = kTextSize;
    section[0].Characteristics =
        IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ | IMAGE_SCN_CNT_CODE;
    std::memcpy(section[1].Name, ".data", 5);
    section[1].VirtualAddress = kDataRva;
    section[1].Misc.VirtualSize = kDataSize;
    section[1].SizeOfRawData = kDataSize;
    section[1].Characteristics = IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE;
  }

  IMAGE_NT_HEADERS32* nt() {
    return reinterpret_cast<IMAGE_NT_HEADERS32*>(bytes_.data() + 0x80);
  }
  uint8_t* at(uint32_t rva) { return bytes_.data() + rva; }
  uint8_t* data() { return bytes_.data(); }

  void PlaceSignature(uint32_t rva, const el::MaskedPattern& pattern) {
    // 掩码位置随便填个不会与签名冲突的字节；被掩掉的字节不参与匹配。
    std::memcpy(at(rva), pattern.bytes, pattern.size);
  }

  void PlaceOperand(uint32_t rva, uint32_t value) {
    std::memcpy(at(rva), &value, sizeof(value));
  }

  // 一个只含 user32/kernel32 两条目的导入表。
  void BuildImports(uint32_t gaks_slot_rva, uint32_t readfile_slot_rva) {
    struct Layout {
      uint32_t descriptors;  // 3 * IMAGE_IMPORT_DESCRIPTOR
      uint32_t user32_name;
      uint32_t kernel32_name;
      uint32_t user32_lookup;
      uint32_t kernel32_lookup;
      uint32_t gaks_name;
      uint32_t readfile_name;
    } l{};
    l.descriptors = kImportDirRva;
    l.user32_name = kImportDirRva + 0x100u;
    l.kernel32_name = kImportDirRva + 0x120u;
    l.user32_lookup = kImportDirRva + 0x140u;
    l.kernel32_lookup = kImportDirRva + 0x160u;
    l.gaks_name = kImportDirRva + 0x180u;
    l.readfile_name = kImportDirRva + 0x1c0u;

    std::memcpy(at(l.user32_name), "USER32.dll", 11);
    std::memcpy(at(l.kernel32_name), "KERNEL32.dll", 13);
    // IMAGE_IMPORT_BY_NAME：2 字节 Hint + NUL 结尾名字。
    std::memcpy(at(l.gaks_name) + 2, "GetAsyncKeyState", 17);
    std::memcpy(at(l.readfile_name) + 2, "ReadFile", 9);

    // 各自的 lookup 表：先塞一个别的符号，确保索引推进被真正测到。
    const uint32_t decoy = l.gaks_name;  // 内容不重要，名字不匹配即可
    (void)decoy;
    uint32_t user32_thunks[2] = {l.gaks_name, 0u};
    uint32_t kernel32_thunks[2] = {l.readfile_name, 0u};
    std::memcpy(at(l.user32_lookup), user32_thunks, sizeof(user32_thunks));
    std::memcpy(at(l.kernel32_lookup), kernel32_thunks, sizeof(kernel32_thunks));

    auto* desc = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(at(l.descriptors));
    desc[0].OriginalFirstThunk = l.user32_lookup;
    desc[0].Name = l.user32_name;
    desc[0].FirstThunk = gaks_slot_rva;
    desc[1].OriginalFirstThunk = l.kernel32_lookup;
    desc[1].Name = l.kernel32_name;
    desc[1].FirstThunk = readfile_slot_rva;
    std::memset(&desc[2], 0, sizeof(desc[2]));

    nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT]
        .VirtualAddress = kImportDirRva;
    nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].Size =
        3u * sizeof(IMAGE_IMPORT_DESCRIPTOR);
  }

  void BuildLoadConfig(uint32_t cookie_va) {
    PlaceOperand(kLoadConfigRva + 0x3cu, cookie_va);
    nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG]
        .VirtualAddress = kLoadConfigRva;
    nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG].Size =
        0x40u;
  }

  void ClearLoadConfig() {
    nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG]
        .VirtualAddress = 0u;
    nt()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG].Size =
        0u;
  }

  el::LoadedPeImage Open() {
    el::LoadedPeImage image;
    const bool ok =
        el::OpenLoadedPeImage(reinterpret_cast<HMODULE>(bytes_.data()), &image);
    assert(ok);
    (void)ok;
    image.absolute_base = kImageBase;
    return image;
  }

 private:
  std::vector<uint8_t> bytes_;
};

constexpr uint32_t kGaksSlotRva = 0x9600u;
constexpr uint32_t kReadFileSlotRva = 0x9640u;

SyntheticImage MakeLeafLikeImage() {
  SyntheticImage image;
  image.PlaceSignature(kTraversalRva, lx::kTextTraversalEntryPattern);
  image.PlaceOperand(kTraversalRva + lx::kTextTraversalCookieOperandOffset,
                     kImageBase + kCookieRva);
  image.PlaceSignature(kRasterRva, lx::kRasterDrawEntryPattern);
  image.PlaceOperand(kRasterRva + lx::kRasterDrawCookieOperandOffset,
                     kImageBase + kCookieRva);
  image.PlaceSignature(kPollerRva, lx::kInputPollerEntryPattern);
  image.PlaceOperand(kPollerRva + lx::kInputPollerIatOperandOffset,
                     kImageBase + kGaksSlotRva);
  image.PlaceSignature(kEmbedRva, lx::kEmbedLoopAnchorPattern);
  image.PlaceSignature(kDeviceRva, lx::kD3dDeviceAccessPattern);
  image.PlaceOperand(kDeviceRva + lx::kD3dDevicePointerOperandOffset,
                     kImageBase + kDeviceSlotRva);
  image.BuildImports(kGaksSlotRva, kReadFileSlotRva);
  image.BuildLoadConfig(kImageBase + kCookieRva);
  return image;
}

void ExpectDerived(const ap::DerivedAnchors& d) {
  assert(d.stack_cookie_rva == kCookieRva);
  assert(d.get_async_key_state_iat_rva == kGaksSlotRva);
  assert(d.read_file_iat_rva == kReadFileSlotRva);
  assert(d.text_traversal_rva == kTraversalRva);
  assert(d.raster_draw_rva == kRasterRva);
  assert(d.input_poller_first_return_rva == kPollerRva + 10u);
  assert(d.embed_leaf_hook_rva == kEmbedRva + lx::kEmbedHookOffsetFromAnchor);
  assert(d.d3d9_device_pointer_rva == kDeviceSlotRva);
}

// 全部锚点都能从二进制自身推出来，不依赖任何硬编码 RVA。
void DerivesEveryAnchorFromTheBinary() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors derived;
  assert(ap::DeriveLeafAnchors(image, &derived));
  ExpectDerived(derived);
}

// 老工具链的 load config 可能没有 SecurityCookie：此时 cookie 由两个**互相独立**的
// 签名读出的操作数取一致来定。白2 这份 exe 走的正是这条路。
void DerivesCookieWithoutLoadConfig() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  synthetic.ClearLoadConfig();
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors derived;
  assert(ap::DeriveLeafAnchors(image, &derived));
  ExpectDerived(derived);
}

// 两个签名读出的 cookie 不一致 = 识别不可信，必须拒绝而不是挑一个用。
void RejectsDisagreeingCookieOperands() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  synthetic.PlaceOperand(kRasterRva + lx::kRasterDrawCookieOperandOffset,
                         kImageBase + kCookieRva + 0x10u);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors derived;
  assert(!ap::DeriveLeafAnchors(image, &derived));
}

// load config 明确给了 cookie，却与签名读出的不一致：同样拒绝。
void RejectsLoadConfigContradiction() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  synthetic.BuildLoadConfig(kImageBase + kCookieRva + 0x40u);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors derived;
  assert(!ap::DeriveLeafAnchors(image, &derived));
}

// 输入轮询签名里的 IAT 操作数必须正好是导入表推出来的那个槽。
void RejectsInputPollerPointingElsewhere() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  synthetic.PlaceOperand(kPollerRva + lx::kInputPollerIatOperandOffset,
                         kImageBase + kGaksSlotRva + 4u);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors derived;
  assert(!ap::DeriveLeafAnchors(image, &derived));
}

// 没有导入 GetAsyncKeyState 的二进制不是这套引擎：不得认领。
void RejectsMissingImports() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  synthetic.nt()
      ->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT]
      .VirtualAddress = 0u;
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors derived;
  assert(!ap::DeriveLeafAnchors(image, &derived));
}

// 签名不唯一（同一模式出现两次）时必须拒绝，不能挑第一个。
void RejectsNonUniqueSignature() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  synthetic.PlaceSignature(kTraversalRva + 0x800u,
                           lx::kTextTraversalEntryPattern);
  synthetic.PlaceOperand(
      kTraversalRva + 0x800u + lx::kTextTraversalCookieOperandOffset,
      kImageBase + kCookieRva);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors derived;
  assert(!ap::DeriveLeafAnchors(image, &derived));
}

// 一份完全不含这些签名的二进制（跨引擎负向）不得被认领。
void RejectsUnrelatedBinary() {
  SyntheticImage synthetic;
  synthetic.BuildImports(kGaksSlotRva, kReadFileSlotRva);
  synthetic.BuildLoadConfig(kImageBase + kCookieRva);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors derived;
  assert(!ap::DeriveLeafAnchors(image, &derived));
}


// ── ResolveLeafProfile：位移起点 + 调用形状校验 ────────────────────────────
//
// 位移只是搜索起点，采信与否由形状判定决定。合成夹具用自己的小位移（真实位移是按白2 那份
// 构建量的，放不进这个小映像），测的是机制：起点命中、整体位移后窗口内唯一命中、形状缺失
// 拒绝、窗口内多解拒绝、三个 glyph 返回点必须调向同一目标。

constexpr uint32_t kDispatchRva = 0x1800u;

ap::LeafAnchorDeltas SyntheticDeltas() {
  ap::LeafAnchorDeltas d;
  d.glyph_dispatch_from_traversal = 0x400;  // kDispatchRva - kTraversalRva
  d.raster_glyph_return_from_traversal = 0x500;  // 派发函数体内
  d.glyph_single_return_from_traversal = 0x200;
  d.glyph_double_first_return_from_traversal = 0x300;
  d.glyph_double_second_return_from_traversal = 0x400;
  d.quad_draw_return_from_raster = 0x100;
  d.alternate_quad_draw_return_from_raster = 0x200;
  d.input_poller_last_return_from_anchor = 0x100;
  d.voice_archive_read_return_from_embed_anchor = 0x100;
  return d;
}

struct PlantedSites {
  uint32_t raster_glyph_return = 0;
  uint32_t glyph_single_return = 0;
  uint32_t glyph_double_first = 0;
  uint32_t glyph_double_second = 0;
  uint32_t quad_draw_return = 0;
  uint32_t alternate_quad_draw_return = 0;
  uint32_t poller_last_return = 0;
  uint32_t voice_read_return = 0;
};

void PlaceRel32Call(SyntheticImage& image, uint32_t return_rva,
                    uint32_t target_rva) {
  uint8_t* call = image.at(return_rva - 5u);
  call[0] = 0xe8u;
  const int32_t displacement =
      static_cast<int32_t>(target_rva) - static_cast<int32_t>(return_rva);
  std::memcpy(call + 1, &displacement, sizeof(displacement));
}

// 派发调用点前的「0x100 字节文字状态按值拷进参数区」帧形状。
void PlaceStateCopyBeforeCall(SyntheticImage& image, uint32_t return_rva) {
  static constexpr uint8_t kCopy[] = {0x81, 0xec, 0x00, 0x01, 0x00, 0x00,
                                      0xb9, 0x40, 0x00, 0x00, 0x00, 0x8b,
                                      0xfc, 0xf3, 0xa5};
  std::memcpy(image.at(return_rva - 5u - sizeof(kCopy)), kCopy, sizeof(kCopy));
}

// raster 调用之后的 `add esp, 8; ret`。
void PlaceFramelessReturnAfter(SyntheticImage& image, uint32_t return_rva) {
  static constexpr uint8_t kTail[] = {0x83, 0xc4, 0x08, 0xc3};
  std::memcpy(image.at(return_rva), kTail, sizeof(kTail));
}

void PlaceRegisterIndirect(SyntheticImage& image, uint32_t return_rva,
                           uint8_t modrm) {
  uint8_t* call = image.at(return_rva - 2u);
  call[0] = 0xffu;
  call[1] = modrm;
}

void PlaceAbsoluteIndirect(SyntheticImage& image, uint32_t return_rva,
                           uint32_t slot_va) {
  uint8_t* call = image.at(return_rva - 6u);
  call[0] = 0xffu;
  call[1] = 0x15u;
  std::memcpy(call + 2, &slot_va, sizeof(slot_va));
}

// shift：整体位移（所有 return site 一起动）。glyph_body_shift：只在 traversal 函数体内
// 插入代码（三个 glyph 返回点一起动、派发函数与其余站点不动）——实测另一个白2 构建正是
// 这种差异（+0x13）。
PlantedSites PlantCallShapes(SyntheticImage& image, int32_t shift,
                             int32_t glyph_body_shift = 0) {
  const ap::LeafAnchorDeltas d = SyntheticDeltas();
  const uint32_t poller_anchor = kPollerRva;
  const uint32_t embed_anchor = kEmbedRva;
  PlantedSites s;
  s.raster_glyph_return = static_cast<uint32_t>(
      kTraversalRva + d.raster_glyph_return_from_traversal + shift);
  s.glyph_single_return =
      static_cast<uint32_t>(kTraversalRva + d.glyph_single_return_from_traversal +
                            shift + glyph_body_shift);
  s.glyph_double_first = static_cast<uint32_t>(
      kTraversalRva + d.glyph_double_first_return_from_traversal + shift +
      glyph_body_shift);
  s.glyph_double_second = static_cast<uint32_t>(
      kTraversalRva + d.glyph_double_second_return_from_traversal + shift +
      glyph_body_shift);
  s.quad_draw_return =
      static_cast<uint32_t>(kRasterRva + d.quad_draw_return_from_raster + shift);
  s.alternate_quad_draw_return = static_cast<uint32_t>(
      kRasterRva + d.alternate_quad_draw_return_from_raster + shift);
  s.poller_last_return = static_cast<uint32_t>(
      poller_anchor + d.input_poller_last_return_from_anchor + shift);
  s.voice_read_return = static_cast<uint32_t>(
      embed_anchor + d.voice_archive_read_return_from_embed_anchor + shift);

  PlaceRel32Call(image, s.raster_glyph_return, kRasterRva);
  PlaceFramelessReturnAfter(image, s.raster_glyph_return);
  for (uint32_t glyph_return :
       {s.glyph_single_return, s.glyph_double_first, s.glyph_double_second}) {
    PlaceStateCopyBeforeCall(image, glyph_return);
    PlaceRel32Call(image, glyph_return, kDispatchRva);
  }
  PlaceRegisterIndirect(image, s.quad_draw_return, 0xd0u);
  PlaceRegisterIndirect(image, s.alternate_quad_draw_return, 0xd0u);
  PlaceRegisterIndirect(image, s.poller_last_return, 0xd6u);
  PlaceAbsoluteIndirect(image, s.voice_read_return, kImageBase + kReadFileSlotRva);
  return s;
}

void ExpectResolved(const fushi_voice_hook::LeafAquaplusProfile& p,
                    const PlantedSites& s) {
  assert(p.glyph_dispatch_rva == kDispatchRva);
  assert(p.raster_glyph_return_rva == s.raster_glyph_return);
  assert(p.glyph_single_return_rva == s.glyph_single_return);
  assert(p.glyph_double_first_return_rva == s.glyph_double_first);
  assert(p.glyph_double_second_return_rva == s.glyph_double_second);
  assert(p.quad_draw_return_rva == s.quad_draw_return);
  assert(p.alternate_quad_draw_return_rva == s.alternate_quad_draw_return);
  assert(p.input_poller_last_return_rva == s.poller_last_return);
  assert(p.voice_archive_read_return_rva == s.voice_read_return);
  // 解析出来的 profile 不冒充已测量身份。
  for (uint8_t byte : p.executable_sha256) assert(byte == 0u);
}

void ResolvesEveryReturnSiteFromShapes() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  const PlantedSites planted = PlantCallShapes(synthetic, 0);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors anchors;
  assert(ap::DeriveLeafAnchors(image, &anchors));
  fushi_voice_hook::LeafAquaplusProfile resolved{};
  assert(ap::ResolveLeafProfile(image, anchors, SyntheticDeltas(), &resolved));
  ExpectResolved(resolved, planted);
}

// 补丁版最常见的变化是整体位移：起点不再命中，窗口内唯一命中仍能定位。
void ResolvesAfterASmallShift() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  const PlantedSites planted = PlantCallShapes(synthetic, 0x11);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors anchors;
  assert(ap::DeriveLeafAnchors(image, &anchors));
  fushi_voice_hook::LeafAquaplusProfile resolved{};
  assert(ap::ResolveLeafProfile(image, anchors, SyntheticDeltas(), &resolved));
  ExpectResolved(resolved, planted);
}

// 形状根本不存在（codegen 变了）时必须拒绝，不能退回位移硬猜。
void RejectsWhenAShapeIsAbsent() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  PlantCallShapes(synthetic, 0);
  const ap::LeafAnchorDeltas d = SyntheticDeltas();
  const uint32_t poller_last =
      static_cast<uint32_t>(kPollerRva + d.input_poller_last_return_from_anchor);
  std::memset(synthetic.at(poller_last - 2u), 0, 2u);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors anchors;
  assert(ap::DeriveLeafAnchors(image, &anchors));
  fushi_voice_hook::LeafAquaplusProfile resolved{};
  assert(!ap::ResolveLeafProfile(image, anchors, SyntheticDeltas(), &resolved));
}

// 窗口内出现第二个同形状候选 = 判据不足以定位，拒绝而不是挑一个。
void RejectsAmbiguousWindow() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  PlantCallShapes(synthetic, 0x11);
  const ap::LeafAnchorDeltas d = SyntheticDeltas();
  const uint32_t candidate =
      static_cast<uint32_t>(kRasterRva + d.quad_draw_return_from_raster);
  PlaceRegisterIndirect(synthetic, candidate + 0x21u, 0xd0u);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors anchors;
  assert(ap::DeriveLeafAnchors(image, &anchors));
  fushi_voice_hook::LeafAquaplusProfile resolved{};
  assert(!ap::ResolveLeafProfile(image, anchors, SyntheticDeltas(), &resolved));
}

// 三个 glyph 返回点必须调向同一个派发函数；有一个不是就说明识别错了。
void RejectsGlyphReturnsWithDifferentTargets() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  const PlantedSites planted = PlantCallShapes(synthetic, 0);
  PlaceRel32Call(synthetic, planted.glyph_double_first, kDispatchRva + 0x40u);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors anchors;
  assert(ap::DeriveLeafAnchors(image, &anchors));
  fushi_voice_hook::LeafAquaplusProfile resolved{};
  assert(!ap::ResolveLeafProfile(image, anchors, SyntheticDeltas(), &resolved));
}

// traversal 函数体内插入代码：三个 glyph 返回点整体后移、派发函数不动。旧判据（窗口内
// 「任意 rel32 call」定单字节返回点）在真实函数体里会撞上多条 call 而整体拒绝；新判据
// 先由调用图定派发函数，再找调向它的调用。
void ResolvesAfterCodeInsertedInsideTheTraversalBody() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  const PlantedSites planted = PlantCallShapes(synthetic, 0, 0x13);
  // 单字节起点附近再放几条调向别处的 call：真实 traversal 每几个字节就一条。
  PlaceRel32Call(synthetic, planted.glyph_single_return - 0x20u, kRasterRva);
  PlaceRel32Call(synthetic, planted.glyph_single_return - 0x30u, kPollerRva);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors anchors;
  assert(ap::DeriveLeafAnchors(image, &anchors));
  fushi_voice_hook::LeafAquaplusProfile resolved{};
  assert(ap::ResolveLeafProfile(image, anchors, SyntheticDeltas(), &resolved));
  ExpectResolved(resolved, planted);
}

// 三点间距是那段单 / 双字节分支自身的长度：窗口各自挑中了间距不对的调用 = 认错了。
void RejectsGlyphReturnsWithWrongSpacing() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  const PlantedSites planted = PlantCallShapes(synthetic, 0);
  std::memset(synthetic.at(planted.glyph_double_second - 20u), 0, 20u);
  PlaceStateCopyBeforeCall(synthetic, planted.glyph_double_second + 0x10u);
  PlaceRel32Call(synthetic, planted.glyph_double_second + 0x10u, kDispatchRva);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors anchors;
  assert(ap::DeriveLeafAnchors(image, &anchors));
  fushi_voice_hook::LeafAquaplusProfile resolved{};
  ap::LeafResolveTrace trace;
  assert(!ap::ResolveLeafProfile(image, anchors, SyntheticDeltas(), &resolved,
                                 &trace));
  assert(trace.failed_at == ap::LeafResolveStage::kGlyphDoubleReturns);
}

// 派发调用前没有 0x100 字节状态拷贝：栈偏移 0x110 失去结构依据，拒绝。
void RejectsGlyphCallWithoutStateCopyFrame() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  const PlantedSites planted = PlantCallShapes(synthetic, 0);
  std::memset(synthetic.at(planted.glyph_single_return - 20u), 0x90, 15u);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors anchors;
  assert(ap::DeriveLeafAnchors(image, &anchors));
  fushi_voice_hook::LeafAquaplusProfile resolved{};
  ap::LeafResolveTrace trace;
  assert(!ap::ResolveLeafProfile(image, anchors, SyntheticDeltas(), &resolved,
                                 &trace));
  assert(trace.failed_at == ap::LeafResolveStage::kGlyphSingleReturn);
}

// raster 调用之后不是 `add esp, 8; ret`：父返回槽偏移 0x0c 失去依据，拒绝。
void RejectsRasterCallWithoutFramelessReturn() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  const PlantedSites planted = PlantCallShapes(synthetic, 0);
  synthetic.at(planted.raster_glyph_return)[2] = 0x0cu;  // add esp, 0x0c
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors anchors;
  assert(ap::DeriveLeafAnchors(image, &anchors));
  fushi_voice_hook::LeafAquaplusProfile resolved{};
  ap::LeafResolveTrace trace;
  assert(!ap::ResolveLeafProfile(image, anchors, SyntheticDeltas(), &resolved,
                                 &trace));
  assert(trace.failed_at == ap::LeafResolveStage::kRasterGlyphReturn);
}

void PlaceJmp(SyntheticImage& image, uint32_t at_rva, int64_t target_rva) {
  uint8_t* jmp = image.at(at_rva);
  jmp[0] = 0xe9u;
  const int32_t displacement =
      static_cast<int32_t>(target_rva - static_cast<int64_t>(at_rva) - 5);
  std::memcpy(jmp + 1, &displacement, sizeof(displacement));
}

// 文本 hook 点已被注入模块 detour（跳出主映像）：运行时映像上这是同一个 hook 点，认；
// 磁盘原始映像上不可能出现，不认。
void EmbedSiteDetourIsAcceptedOnlyOnTheRuntimeImage() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  const uint32_t hook = kEmbedRva + lx::kEmbedHookOffsetFromAnchor;
  PlaceJmp(synthetic, hook, static_cast<int64_t>(kImageSize) + 0x10000000);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors derived;
  ap::LeafAnchorTrace trace;
  assert(!ap::DeriveLeafAnchors(image, &derived, &trace,
                                ap::LeafImageSource::kPristineFile));
  assert(trace.embed_hits == 1u && trace.embed_site_detoured_rejected);
  assert(ap::DeriveLeafAnchors(image, &derived, &trace,
                               ap::LeafImageSource::kRuntimeImage));
  ExpectDerived(derived);
}

// 跳回主映像内部的 jmp 不是 detour 形状：运行时映像上也不认。
void EmbedSiteJumpInsideTheImageIsRejected() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  const uint32_t hook = kEmbedRva + lx::kEmbedHookOffsetFromAnchor;
  PlaceJmp(synthetic, hook, kRasterRva);
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors derived;
  assert(!ap::DeriveLeafAnchors(image, &derived, nullptr,
                                ap::LeafImageSource::kRuntimeImage));
}

// 总入口：锚点 → return site → 节角色，全过才产出 profile；设备槽落进可执行节即拒绝。
void ProvesStructureEndToEndAndChecksSectionRoles() {
  SyntheticImage synthetic = MakeLeafLikeImage();
  PlantCallShapes(synthetic, 0);
  // 总入口用的是已测量位移；合成映像放不下，故这里直接走分段 API 再查节角色。
  el::LoadedPeImage image = synthetic.Open();
  ap::DerivedAnchors anchors;
  assert(ap::DeriveLeafAnchors(image, &anchors));
  fushi_voice_hook::LeafAquaplusProfile resolved{};
  assert(ap::ResolveLeafProfile(image, anchors, SyntheticDeltas(), &resolved));
  assert(ap::LeafProfileSectionRolesValid(image, resolved));
  fushi_voice_hook::LeafAquaplusProfile wrong = resolved;
  wrong.d3d9_device_pointer_rva = kTraversalRva;  // 可执行节
  assert(!ap::LeafProfileSectionRolesValid(image, wrong));
  wrong = resolved;
  wrong.voice_archive_read_return_rva = kCookieRva;  // 数据节
  assert(!ap::LeafProfileSectionRolesValid(image, wrong));
  // 已测量位移在这份小映像里全部落空：总入口必须拒绝而不是退回猜测。
  fushi_voice_hook::LeafAquaplusProfile proven{};
  ap::LeafStructureProof proof;
  assert(!ap::ProveLeafStructure(image, ap::LeafImageSource::kPristineFile,
                                 &proven, &proof));
  assert(proof.anchors_ok && !proof.resolve_ok);
}

// 带壳判据：可执行节无原始数据，或原始字节高熵。普通代码字节不算。
void DetectsPackedExecutableCode() {
  {
    SyntheticImage synthetic = MakeLeafLikeImage();
    PlantCallShapes(synthetic, 0);
    el::LoadedPeImage image = synthetic.Open();
    assert(!ap::LeafExecutableCodeLooksPacked(image));
  }
  {
    SyntheticImage synthetic = MakeLeafLikeImage();
    IMAGE_SECTION_HEADER* text = IMAGE_FIRST_SECTION(synthetic.nt());
    text->SizeOfRawData = 0u;  // UPX 式：运行期才填
    el::LoadedPeImage image = synthetic.Open();
    assert(ap::LeafExecutableCodeLooksPacked(image));
  }
  {
    SyntheticImage synthetic = MakeLeafLikeImage();
    uint32_t state = 0x12345678u;
    for (uint32_t rva = kTextRva; rva < kTextRva + kTextSize; ++rva) {
      state = state * 1664525u + 1013904223u;
      *synthetic.at(rva) = static_cast<uint8_t>(state >> 24);
    }
    el::LoadedPeImage image = synthetic.Open();
    assert(ap::LeafExecutableCodeLooksPacked(image));
    // 加密后的代码里自然也找不到任何锚点。
    ap::DerivedAnchors derived;
    assert(!ap::DeriveLeafAnchors(image, &derived));
  }
}
}  // namespace

int main() {
  DerivesEveryAnchorFromTheBinary();
  DerivesCookieWithoutLoadConfig();
  RejectsDisagreeingCookieOperands();
  RejectsLoadConfigContradiction();
  RejectsInputPollerPointingElsewhere();
  RejectsMissingImports();
  RejectsNonUniqueSignature();
  RejectsUnrelatedBinary();
  ResolvesEveryReturnSiteFromShapes();
  ResolvesAfterASmallShift();
  RejectsWhenAShapeIsAbsent();
  RejectsAmbiguousWindow();
  RejectsGlyphReturnsWithDifferentTargets();
  ResolvesAfterCodeInsertedInsideTheTraversalBody();
  RejectsGlyphReturnsWithWrongSpacing();
  RejectsGlyphCallWithoutStateCopyFrame();
  RejectsRasterCallWithoutFramelessReturn();
  EmbedSiteDetourIsAcceptedOnlyOnTheRuntimeImage();
  EmbedSiteJumpInsideTheImageIsRejected();
  ProvesStructureEndToEndAndChecksSectionRoles();
  DetectsPackedExecutableCode();
  return 0;
}
