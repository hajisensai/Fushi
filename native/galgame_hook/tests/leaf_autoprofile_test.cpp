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
  d.glyph_dispatch_from_traversal = 0;  // 由解码得到，不参与
  d.raster_glyph_return_from_traversal = 0x100;
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

PlantedSites PlantCallShapes(SyntheticImage& image, int32_t shift) {
  const ap::LeafAnchorDeltas d = SyntheticDeltas();
  const uint32_t poller_anchor = kPollerRva;
  const uint32_t embed_anchor = kEmbedRva;
  PlantedSites s;
  s.raster_glyph_return = static_cast<uint32_t>(
      kTraversalRva + d.raster_glyph_return_from_traversal + shift);
  s.glyph_single_return = static_cast<uint32_t>(
      kTraversalRva + d.glyph_single_return_from_traversal + shift);
  s.glyph_double_first = static_cast<uint32_t>(
      kTraversalRva + d.glyph_double_first_return_from_traversal + shift);
  s.glyph_double_second = static_cast<uint32_t>(
      kTraversalRva + d.glyph_double_second_return_from_traversal + shift);
  s.quad_draw_return =
      static_cast<uint32_t>(kRasterRva + d.quad_draw_return_from_raster + shift);
  s.alternate_quad_draw_return = static_cast<uint32_t>(
      kRasterRva + d.alternate_quad_draw_return_from_raster + shift);
  s.poller_last_return = static_cast<uint32_t>(
      poller_anchor + d.input_poller_last_return_from_anchor + shift);
  s.voice_read_return = static_cast<uint32_t>(
      embed_anchor + d.voice_archive_read_return_from_embed_anchor + shift);

  PlaceRel32Call(image, s.raster_glyph_return, kRasterRva);
  PlaceRel32Call(image, s.glyph_single_return, kDispatchRva);
  PlaceRel32Call(image, s.glyph_double_first, kDispatchRva);
  PlaceRel32Call(image, s.glyph_double_second, kDispatchRva);
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
  return 0;
}
