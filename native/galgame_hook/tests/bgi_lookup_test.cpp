// Release builds define NDEBUG. Undefine it before every include so these
// assertions remain executable focused test code.
#undef NDEBUG

#include <windows.h>

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <vector>

#include "bgi_lookup_core.h"

namespace core = fushi_voice_hook::bgi_lookup;
namespace exact = fushi_voice_hook::exact_lookup;

namespace {

// ── synthetic x86 image: code [0, 0x8000), read-only data [0x8000, 0x10000) ─

constexpr uintptr_t kAbsoluteBase = 0x00400000u;
constexpr size_t kCodeEnd = 0x8000u;

class SyntheticImage {
 public:
  static constexpr size_t kSize = 0x10000u;
  explicit SyntheticImage(WORD machine = IMAGE_FILE_MACHINE_I386,
                          uint32_t bits = 32u) {
    base = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kSize, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE));
    assert(base != nullptr);
    std::memset(base, 0xcc, kCodeEnd);
    std::memset(base + kCodeEnd, 0x00, kSize - kCodeEnd);
    image.base = base;
    image.size = kSize;
    image.absolute_base = kAbsoluteBase;
    image.machine = machine;
    image.pointer_bits = static_cast<uint8_t>(bits);
    image.section_count = 2u;
    image.sections[0] = {base, kCodeEnd, 0u,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    image.sections[1] = {base + kCodeEnd, kSize - kCodeEnd,
                         static_cast<uint32_t>(kCodeEnd), IMAGE_SCN_MEM_READ};
  }
  ~SyntheticImage() { VirtualFree(base, 0u, MEM_RELEASE); }
  SyntheticImage(const SyntheticImage&) = delete;
  SyntheticImage& operator=(const SyntheticImage&) = delete;

  void Put(size_t rva, const uint8_t* bytes, size_t size) {
    assert(rva + size <= kSize);
    std::memcpy(base + rva, bytes, size);
  }
  void Put(size_t rva, std::initializer_list<uint8_t> bytes) {
    size_t at = rva;
    for (uint8_t byte : bytes) base[at++] = byte;
  }
  void Dword(size_t rva, uint32_t value) { std::memcpy(base + rva, &value, 4); }
  void Va(size_t rva, size_t target_rva) {
    Dword(rva, static_cast<uint32_t>(kAbsoluteBase + target_rva));
  }
  void Rel32(size_t at, size_t target) {  // `e8 rel32` at `at`
    base[at] = 0xe8u;
    const int32_t rel = static_cast<int32_t>(static_cast<intptr_t>(target) -
                                             static_cast<intptr_t>(at + 5u));
    std::memcpy(base + at + 1u, &rel, 4u);
  }
  void PutShape(size_t rva, const core::Shape& shape) {
    Put(rva, shape.bytes, shape.size);
  }

  uint8_t* base = nullptr;
  exact::LoadedPeImage image;
};

// Synthetic engine layout (RVAs).
constexpr size_t kImpl = 0x1000u;
constexpr size_t kLayout = 0x2000u;
constexpr size_t kWrapper = 0x2800u;
constexpr size_t kCallers = 0x3000u;
constexpr size_t kCtor = 0x3100u;
constexpr size_t kScreenCode = 0x3200u;
constexpr size_t kExVtable = 0x8100u;
constexpr size_t kDecoyVtable = 0x8200u;
constexpr size_t kScreenIndex = 0x8400u;
constexpr size_t kScreenWidths = 0x8404u;

void BuildImplThiscall(SyntheticImage* img) {
  img->PutShape(kImpl, core::kImplThis);
  img->base[kImpl + 2u] = 0x3cu;
  img->Put(kImpl + 0x0du, {0x8b, 0x4b, 0x20});
  img->Put(kImpl + 0xb2u,
           {0x8d, 0x73, 0x7c, 0x51, 0x52, 0x56, 0x8b, 0xcb, 0xff, 0x50, 0x30});
  img->Put(kImpl + 0x13du, {0xc2, 0x10, 0x00});
  img->Rel32(kCallers, kImpl);
}

void BuildImplStdcall(SyntheticImage* img) {
  img->PutShape(kImpl, core::kImplStd);
  img->base[kImpl + 8u] = 0x44u;
  img->Put(kImpl + 0x18u, {0x8b, 0x5d, 0x08});
  img->Put(kImpl + 0x1cu, {0x8b, 0x73, 0x20});
  img->Put(kImpl + 0xb2u, {0x8b, 0x03, 0x8b, 0x40, 0x34});
  img->Put(kImpl + 0xe9u, {0x8d, 0x73, 0x7c, 0x56, 0x8b, 0xcb, 0xff, 0xd0});
  img->Put(kImpl + 0x17cu, {0xc2, 0x14, 0x00});
  img->Rel32(kCallers, kImpl);
}

void BuildLayoutAndVtable(SyntheticImage* img, uint32_t slot_disp) {
  // Layout function with the control-byte switch 0x76 bytes in.
  img->Put(kLayout, {0x6a, 0xff, 0x68});
  img->PutShape(kLayout + 0x76u, core::kAnchor);
  img->base[kLayout + 0x76u + 3u] = 0x68u;
  img->base[kLayout + 0x76u + 14u] = 0x5du;
  img->Rel32(kCallers + 0x10u, kLayout);  // a direct caller elsewhere
  // Wrapper forwards the arguments and calls the layout.
  img->Put(kWrapper, {0x8b, 0x44, 0x24, 0x34});
  img->Rel32(kWrapper + 0x3au, kLayout);
  img->Put(kWrapper + 0x3fu, {0x83, 0xc4, 0x34, 0xc2, 0x34, 0x00});
  // Ex vtable (installed by a constructor store) and a decoy vtable whose
  // layout slot does not reach the layout.
  img->Va(kExVtable + slot_disp, kWrapper);
  img->Put(kCtor, {0xc7, 0x06});
  img->Va(kCtor + 2u, kExVtable);
  img->Va(kDecoyVtable + slot_disp, 0x2c00u);
  img->Put(0x2c00u, {0x33, 0xc0, 0xc3});
  img->Put(kCtor + 0x10u, {0xc7, 0x07});
  img->Va(kCtor + 0x12u, kDecoyVtable);
}

void BuildScreenTables(SyntheticImage* img, bool index_read = true) {
  const uint32_t widths[8] = {320, 640, 800, 1024, 1024, 1024, 1280, 1920};
  const uint32_t heights[8] = {240, 480, 600, 768, 576, 600, 720, 1080};
  img->Dword(kScreenIndex, 6u);
  img->Put(kScreenWidths, reinterpret_cast<const uint8_t*>(widths),
           sizeof(widths));
  img->Put(kScreenWidths + 0x20u, reinterpret_cast<const uint8_t*>(heights),
           sizeof(heights));
  img->Put(kScreenCode, {0x8b, 0x04, 0x85});
  img->Va(kScreenCode + 3u, kScreenWidths);
  img->Put(kScreenCode + 0x10u, {0x8b, 0x04, 0x85});
  img->Va(kScreenCode + 0x13u, kScreenWidths + 0x20u);
  if (index_read) {
    img->Put(kScreenCode + 0x20u, {0xa1});
    img->Va(kScreenCode + 0x21u, kScreenIndex);
  }
}

void BuildEngine(SyntheticImage* img, core::Generation generation) {
  if (generation == core::Generation::kThiscall) {
    BuildImplThiscall(img);
    BuildLayoutAndVtable(img, 0x30u);
  } else {
    BuildImplStdcall(img);
    BuildLayoutAndVtable(img, 0x34u);
  }
  BuildScreenTables(img);
}

void TestResolvesThiscallGeneration() {
  SyntheticImage img;
  BuildEngine(&img, core::Generation::kThiscall);
  core::Sites sites;
  assert(core::ResolveSites(img.image, &sites) == core::SiteResult::kResolved);
  assert(sites.generation == core::Generation::kThiscall);
  assert(sites.set_text_impl == kImpl);
  assert(sites.owner_offset == 0x20u);
  assert(sites.list_offset == 0x7cu);
  assert(sites.layout_slot_disp == 0x30u);
  assert(sites.ex_vtable == kExVtable);
  assert(sites.layout == kLayout);
  assert(sites.screen_widths == kScreenWidths);
  assert(sites.screen_index == kScreenIndex);
  int32_t w = 0, h = 0;
  assert(core::DesignSizeFrom(
      core::ReadU32(img.base + kScreenIndex),
      reinterpret_cast<const uint32_t*>(img.base + kScreenWidths),
      reinterpret_cast<const uint32_t*>(img.base + kScreenWidths + 0x20u), &w,
      &h));
  assert(w == 1280 && h == 720);
}

void TestResolvesStdcallGeneration() {
  SyntheticImage img;
  BuildEngine(&img, core::Generation::kStdcall);
  core::Sites sites;
  assert(core::ResolveSites(img.image, &sites) == core::SiteResult::kResolved);
  assert(sites.generation == core::Generation::kStdcall);
  assert(sites.set_text_impl == kImpl);
  assert(sites.owner_offset == 0x20u);
  assert(sites.list_offset == 0x7cu);
  assert(sites.layout_slot_disp == 0x34u);
  assert(sites.ex_vtable == kExVtable);
}

void TestResolutionFailsClosed() {
  core::Sites sites;
  {  // x64 image
    SyntheticImage img(IMAGE_FILE_MACHINE_AMD64, 64u);
    BuildEngine(&img, core::Generation::kThiscall);
    assert(core::ResolveSites(img.image, &sites) == core::SiteResult::kNotX86);
  }
  {  // no vcall at all
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kThiscall);
    img.base[kImpl + 0xb2u] = 0x90u;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kVcallMissing);
  }
  {  // two vcalls (one of each generation)
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kThiscall);
    img.Put(0x4000u, {0x8d, 0x73, 0x7c, 0x56, 0x8b, 0xcb, 0xff, 0xd0});
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kVcallAmbiguous);
  }
  {  // the enclosing function lacks the generation's prologue
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kThiscall);
    img.base[kImpl + 5u] = 0x90u;  // not `mov ebx,ecx`
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kImplMissing);
  }
  {  // stdcall prologue on a thiscall vcall
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kThiscall);
    img.PutShape(kImpl, core::kImplStd);
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kImplMissing);
  }
  {  // no owner load
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kThiscall);
    img.base[kImpl + 0x0eu] = 0x90u;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kImplShape);
  }
  {  // wrong return (thiscall needs ret 0x10)
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kThiscall);
    img.base[kImpl + 0x13eu] = 0x14u;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kImplShape);
  }
  {  // stdcall: `this` load missing
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kStdcall);
    img.base[kImpl + 0x19u] = 0x90u;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kImplShape);
  }
  {  // stdcall: slot load missing
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kStdcall);
    img.base[kImpl + 0xb3u] = 0x90u;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kImplShape);
  }
  {  // no anchor
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kThiscall);
    img.base[kLayout + 0x76u] = 0x90u;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kAnchorMissing);
  }
  {  // the vtable slot does not reach the anchored layout
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kThiscall);
    img.base[kWrapper + 0x3au] = 0x90u;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kVtableMissing);
  }
  {  // the Impl's slot is not the wrapper's slot
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kThiscall);
    img.base[kImpl + 0xb2u + 10u] = 0x2cu;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kVtableMissing);
  }
  {  // a vtable without a constructor store is not a class
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kThiscall);
    img.base[kCtor] = 0x90u;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kVtableMissing);
  }
  {  // two classes whose layout slot calls the layout
    SyntheticImage img;
    BuildEngine(&img, core::Generation::kThiscall);
    img.Va(kDecoyVtable + 0x30u, kWrapper);
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kVtableAmbiguous);
  }
  {  // screen tables without the index read
    SyntheticImage img;
    BuildImplThiscall(&img);
    BuildLayoutAndVtable(&img, 0x30u);
    BuildScreenTables(&img, false);
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kScreenMissing);
  }
  {  // implausible design sizes
    const uint32_t widths[8] = {0, 0, 0, 0, 0, 0, 20000, 0};
    const uint32_t heights[8] = {0, 0, 0, 0, 0, 0, 720, 0};
    int32_t w = 0, h = 0;
    assert(!core::DesignSizeFrom(6u, widths, heights, &w, &h));
    assert(!core::DesignSizeFrom(8u, widths, heights, &w, &h));
  }
}

// ── owner ABI ──────────────────────────────────────────────────────────────

// A flat fake address space for vtables and functions.
class FakeMemory {
 public:
  explicit FakeMemory(uintptr_t base) : base_(base), bytes_(0x4000u, 0xccu) {}
  void Put(uintptr_t address, std::initializer_list<uint8_t> bytes) {
    size_t at = address - base_;
    for (uint8_t byte : bytes) bytes_[at++] = byte;
  }
  void Put(uintptr_t address, const core::Shape& shape) {
    std::memcpy(bytes_.data() + (address - base_), shape.bytes, shape.size);
  }
  void Dword(uintptr_t address, uint32_t value) {
    std::memcpy(bytes_.data() + (address - base_), &value, 4u);
  }
  void Call(uintptr_t at, uintptr_t target) {
    bytes_[at - base_] = 0xe8u;
    const int32_t rel = static_cast<int32_t>(target - (at + 5u));
    std::memcpy(bytes_.data() + (at - base_) + 1u, &rel, 4u);
  }
  const uint8_t* Read(uintptr_t address, size_t size) const {
    if (address < base_ || address - base_ + size > bytes_.size()) {
      return nullptr;
    }
    return bytes_.data() + (address - base_);
  }
  uint8_t& At(uintptr_t address) { return bytes_[address - base_]; }

 private:
  uintptr_t base_;
  std::vector<uint8_t> bytes_;
};

constexpr uintptr_t kMem = 0x10000000u;
constexpr uintptr_t kOwnerVt = kMem + 0x100u;
constexpr uintptr_t kStub = kMem + 0x1000u;
constexpr uintptr_t kDrawable = kMem + 0x1100u;
constexpr uintptr_t kPos = kMem + 0x1200u;
constexpr uintptr_t kOff1 = kMem + 0x1240u;
constexpr uintptr_t kOff2 = kMem + 0x1280u;
constexpr uintptr_t kCameraFn = kMem + 0x12c0u;
constexpr uintptr_t kDisplay = kMem + 0x1300u;

void FillVtable(FakeMemory* mem, uintptr_t vtable, uint32_t display_slot) {
  mem->Put(kStub, {0xc3});
  for (uint32_t slot = 0u; slot < core::kOwnerVtableSlots; ++slot) {
    mem->Dword(vtable + slot * 4u, static_cast<uint32_t>(kStub));
  }
  mem->Dword(vtable + 8u, static_cast<uint32_t>(kDrawable));
  mem->Dword(vtable + (display_slot - 1u) * 4u, static_cast<uint32_t>(kPos));
  mem->Dword(vtable + display_slot * 4u, static_cast<uint32_t>(kDisplay));
}

void BuildThiscallOwner(FakeMemory* mem) {
  mem->Put(kDrawable, core::kDrawableThis);
  mem->At(kDrawable + 2u) = 0x08u;
  mem->At(kDrawable + 9u) = 0x04u;
  const uint32_t alpha = 0x98u;
  std::memcpy(&mem->At(kDrawable + 16u), &alpha, 4u);
  auto getter = [mem](uintptr_t at, uint8_t field) {
    mem->Put(at, core::kPairStack);
    mem->At(at + 6u) = field;
    mem->At(at + 11u) = static_cast<uint8_t>(field + 4u);
  };
  getter(kPos, 0x1cu);
  getter(kOff1, 0x24u);
  getter(kOff2, 0x2cu);
  mem->Put(kDisplay, {0x83, 0xec, 0x10, 0x56, 0x8b, 0x74, 0x24, 0x18, 0x57,
                      0x56, 0x8b, 0xf9});
  mem->Call(kDisplay + 0x0cu, kPos);
  mem->Put(kDisplay + 0x11u, {0x8d, 0x44, 0x24, 0x08, 0x8b, 0xcf, 0x50});
  mem->Call(kDisplay + 0x18u, kOff1);
  mem->Put(kDisplay + 0x1du, {0x8d, 0x44, 0x24, 0x10, 0x50});
  mem->Call(kDisplay + 0x22u, kOff2);
  mem->Put(kDisplay + 0x27u, {0x5f, 0x5e, 0x83, 0xc4, 0x10, 0xc2, 0x04, 0x00});
  FillVtable(mem, kOwnerVt, 11u);
}

void BuildStdcallOwner(FakeMemory* mem) {
  mem->Put(kDrawable, core::kDrawableStd);
  mem->At(kDrawable + 2u) = 0x20u;
  mem->At(kDrawable + 8u) = 0x10u;
  mem->At(kDrawable + 14u) = 0x18u;
  const uint32_t alpha = 0xc4u;
  const uint32_t opacity = 0xc8u;
  std::memcpy(&mem->At(kDrawable + 20u), &alpha, 4u);
  std::memcpy(&mem->At(kDrawable + 32u), &opacity, 4u);
  mem->Put(kPos, core::kPairFrame);
  mem->At(kPos + 5u) = 0x3cu;
  mem->At(kPos + 13u) = 0x40u;
  auto reg = [mem](uintptr_t at, uint8_t field) {
    mem->Put(at, core::kPairReg);
    mem->At(at + 2u) = field;
    mem->At(at + 7u) = static_cast<uint8_t>(field + 4u);
  };
  reg(kOff1, 0x44u);
  reg(kOff2, 0x4cu);
  mem->Put(kCameraFn, core::kCamera);
  mem->At(kCameraFn + 4u) = 0x54u;
  mem->Put(kDisplay, {0x55, 0x8b, 0xec, 0x83, 0xec, 0x10, 0x53, 0x56, 0x8b,
                      0x75, 0x08, 0x57, 0x56, 0x8b, 0xf9});
  mem->Call(kDisplay + 0x0fu, kPos);
  mem->Call(kDisplay + 0x19u, kOff1);
  mem->Call(kDisplay + 0x30u, kOff2);
  mem->Call(kDisplay + 0x4bu, kCameraFn);
  mem->Put(kDisplay + 0x62u, {0x5f, 0x5e, 0x5b, 0x8b, 0xe5, 0x5d, 0xc2, 0x04,
                              0x00});
  FillVtable(mem, kOwnerVt, 13u);
}

void TestDecodesThiscallOwner() {
  FakeMemory mem(kMem);
  BuildThiscallOwner(&mem);
  auto read = [&mem](uintptr_t address, size_t size) {
    return mem.Read(address, size);
  };
  core::OwnerAbi abi;
  assert(core::DecodeOwnerAbi(kOwnerVt, read, &abi));
  assert(abi.valid && abi.display_slot == 11u);
  assert(abi.drawable_count == 3u);
  assert(abi.position_count == 3u && abi.position[0] == 0x1cu &&
         abi.position[1] == 0x24u && abi.position[2] == 0x2cu);
  assert(!abi.has_camera);

  std::vector<uint8_t> owner(0x100u, 0u);
  auto put = [&owner](size_t offset, int32_t value) {
    std::memcpy(owner.data() + offset, &value, 4u);
  };
  put(0x04u, 1);
  put(0x08u, 1);
  put(0x1cu, 300);
  put(0x20u, 560);
  int32_t x = 0, y = 0;
  assert(core::EvaluateDrawable(abi, owner.data(), owner.size()));
  assert(core::EvaluatePosition(abi, owner.data(), owner.size(), &x, &y));
  assert(x == 300 && y == 560);
  put(0x24u, 5);   // shake offset
  put(0x30u, -3);
  assert(core::EvaluatePosition(abi, owner.data(), owner.size(), &x, &y));
  assert(x == 305 && y == 557);
  put(0x98u, 256);  // faded out (window hidden / backlog)
  assert(!core::EvaluateDrawable(abi, owner.data(), owner.size()));
  put(0x98u, 0);
  put(0x08u, 0);
  assert(!core::EvaluateDrawable(abi, owner.data(), owner.size()));
  assert(!core::EvaluateDrawable(abi, owner.data(), 0x40u));  // short read
}

void TestDecodesStdcallOwner() {
  FakeMemory mem(kMem);
  BuildStdcallOwner(&mem);
  auto read = [&mem](uintptr_t address, size_t size) {
    return mem.Read(address, size);
  };
  core::OwnerAbi abi;
  assert(core::DecodeOwnerAbi(kOwnerVt, read, &abi));
  assert(abi.display_slot == 13u && abi.drawable_count == 5u);
  assert(abi.position_count == 3u && abi.position[0] == 0x3cu &&
         abi.position[1] == 0x44u && abi.position[2] == 0x4cu);
  assert(abi.has_camera && abi.camera_flag == 0x54u);

  std::vector<uint8_t> owner(0x100u, 0u);
  auto put = [&owner](size_t offset, int32_t value) {
    std::memcpy(owner.data() + offset, &value, 4u);
  };
  put(0x20u, 1);
  put(0x10u, 1);
  put(0xc8u, 256);
  put(0x3cu, 100);
  put(0x40u, 400);
  int32_t x = 0, y = 0;
  assert(core::EvaluateDrawable(abi, owner.data(), owner.size()));
  assert(core::EvaluatePosition(abi, owner.data(), owner.size(), &x, &y));
  assert(x == 100 && y == 400);
  put(0x18u, 1);  // the "must be zero" flag
  assert(!core::EvaluateDrawable(abi, owner.data(), owner.size()));
  put(0x18u, 0);
  put(0xc8u, 0);  // fully transparent
  assert(!core::EvaluateDrawable(abi, owner.data(), owner.size()));
  put(0x54u, 1);  // camera offset applies: not modelled
  assert(!core::EvaluatePosition(abi, owner.data(), owner.size(), &x, &y));
}

void TestOwnerDecodingFailsClosed() {
  auto decode = [](FakeMemory& mem) {
    auto read = [&mem](uintptr_t address, size_t size) {
      return mem.Read(address, size);
    };
    core::OwnerAbi abi;
    return core::DecodeOwnerAbi(kOwnerVt, read, &abi);
  };
  {  // unknown drawable shape
    FakeMemory mem(kMem);
    BuildThiscallOwner(&mem);
    mem.At(kDrawable + 3u) = 0x90u;
    assert(!decode(mem));
  }
  {  // display function calls something that is not a pair getter
    FakeMemory mem(kMem);
    BuildThiscallOwner(&mem);
    mem.Call(kDisplay + 0x22u, kStub);
    assert(!decode(mem));
  }
  {  // a getter reading a non-adjacent pair
    FakeMemory mem(kMem);
    BuildThiscallOwner(&mem);
    mem.At(kOff1 + 11u) = 0x30u;
    assert(!decode(mem));
  }
  {  // no return inside the scan window
    FakeMemory mem(kMem);
    BuildThiscallOwner(&mem);
    mem.At(kDisplay + 0x2cu) = 0x90u;
    assert(!decode(mem));
  }
  {  // the same display function in a following vtable is not ambiguous...
    FakeMemory mem(kMem);
    BuildThiscallOwner(&mem);
    mem.Dword(kOwnerVt + 30u * 4u, static_cast<uint32_t>(kDisplay));
    assert(decode(mem));
    // ...but a second distinct qualifying function is.
    mem.Put(kDisplay + 0x200u, {0x83, 0xec, 0x10});
    mem.Call(kDisplay + 0x203u, kPos);
    mem.Call(kDisplay + 0x208u, kOff1);
    mem.Put(kDisplay + 0x20du, {0xc2, 0x04, 0x00});
    mem.Dword(kOwnerVt + 31u * 4u, static_cast<uint32_t>(kDisplay + 0x200u));
    assert(!decode(mem));
  }
}

// ── text ───────────────────────────────────────────────────────────────────

std::vector<uint8_t> Cp932(const wchar_t* text) {
  const int bytes =
      WideCharToMultiByte(932, 0, text, -1, nullptr, 0, nullptr, nullptr);
  std::vector<uint8_t> out(static_cast<size_t>(bytes));
  WideCharToMultiByte(932, 0, text, -1, reinterpret_cast<char*>(out.data()),
                      bytes, nullptr, nullptr);
  return out;
}

void TestParsesLines() {
  {
    const auto line = Cp932(L"「っ……！？」");
    const auto parsed = core::ParseLine(line.data(), line.size());
    assert(parsed.count == 7u && !parsed.markup && parsed.auto_prefix == 0u);
    for (uint32_t i = 0u; i < parsed.count; ++i) {
      assert(parsed.units[i].length == 2u && parsed.units[i].source);
    }
  }
  {  // leading control byte 4: the engine inserts 「 (a displayed unit that
     // is not part of the published text)
    std::vector<uint8_t> line = {0x04};
    const auto body = Cp932(L"はい");
    line.insert(line.end(), body.begin(), body.end());
    const auto parsed = core::ParseLine(line.data(), line.size());
    assert(parsed.auto_prefix == 4u && parsed.count == 3u);
    assert(!parsed.units[0].source && parsed.units[1].source);
    assert(parsed.units[1].offset == 1u);
  }
  {  // flag control bytes 2/3 are not displayed
    std::vector<uint8_t> line = {0x02, 'A', 'B', 0x00};
    const auto parsed = core::ParseLine(line.data(), line.size());
    assert(parsed.count == 2u && parsed.auto_prefix == 0u);
  }
  {  // ruby: base text kept, reading dropped, geometry unmappable
    const auto line = Cp932(L"<r\x3042\x3044>\x611b</r>です");
    const auto parsed = core::ParseLine(line.data(), line.size());
    assert(parsed.markup && parsed.count == 3u);
  }
  {  // escape, newline, half-width
    const uint8_t line[] = {'\\', '<', '\n', 0xb1, 'x', 0x00};
    const auto parsed = core::ParseLine(line, sizeof(line));
    assert(!parsed.markup && parsed.count == 3u);
    assert(parsed.units[0].offset == 1u && parsed.units[1].offset == 3u);
  }
  {  // bounded by the buffer even without a terminator
    const uint8_t line[] = {'a', 'b', 'c'};
    assert(core::ParseLine(line, 2u).count == 2u);
    assert(core::ParseLine(nullptr, 4u).count == 0u);
  }
}

// ── page mapping, projection, hit test, claim ──────────────────────────────

void TestPageGlyphs() {
  // 「ab」 laid out at pen x 16 + 27 * i, 29x29 surfaces.
  core::Cell cells[4];
  for (int i = 0; i < 4; ++i) cells[i] = {16 + 27 * i, 12, 29, 29};
  const uint32_t codepoints[4] = {L'「', L'a', L'b', L'」'};
  const uint16_t sources[4] = {core::kNoSource, 0, 1, 2};
  core::LineGlyph glyphs[4];
  assert(core::BuildPageGlyphs(cells, 4u, codepoints, sources, 4u, 300, 560,
                               glyphs, 4u) == 4u);
  assert(glyphs[0].x == 316 && glyphs[0].y == 572 && glyphs[0].w == 27 &&
         glyphs[0].h == 29);
  assert(glyphs[3].w == 29);  // last glyph keeps its surface width
  assert(glyphs[0].source_index == core::kNoSource &&
         glyphs[1].source_index == 0u);
  // Count mismatch / implausible cell / overflow → unmappable.
  assert(core::BuildPageGlyphs(cells, 4u, codepoints, sources, 3u, 0, 0,
                               glyphs, 4u) == 0u);
  assert(core::BuildPageGlyphs(cells, 4u, codepoints, sources, 4u, 0, 0,
                               glyphs, 3u) == 0u);
  core::Cell bad[1] = {{0, 0, 0, 29}};
  assert(core::BuildPageGlyphs(bad, 1u, codepoints, sources, 1u, 0, 0, glyphs,
                               4u) == 0u);

  // The selected line matches the whole page (the published text excludes
  // the engine-inserted 「).
  core::BuildPageGlyphs(cells, 4u, codepoints, sources, 4u, 300, 560, glyphs,
                        4u);
  const wchar_t line[] = L"ab」";
  assert(core::MapSelectedSuffix(glyphs, 4u, line, 3u) == 1u);
  assert(glyphs[0].source_index == core::kNoSource);
  assert(glyphs[1].source_index == 0u && glyphs[3].source_index == 2u);
  const wchar_t other[] = L"xb」";
  assert(core::MapSelectedSuffix(glyphs, 4u, other, 3u) == 4u);
  for (const auto& glyph : glyphs) assert(glyph.source_index == core::kNoSource);
  const wchar_t spaced[] = L" a b」\n";
  assert(core::MapSelectedSuffix(glyphs, 4u, spaced, 6u) == 1u);

  // Projection: 1280x720 design on a 2560x1440 physical client.
  core::MapSelectedSuffix(glyphs, 4u, line, 3u);
  core::PixelRect rect;
  assert(core::ClientMatchesDesign(2560, 1440, 1280, 720));
  assert(!core::ClientMatchesDesign(2560, 1600, 1280, 720));
  assert(core::ProjectCell(glyphs[1], 1280, 720, 2560, 1440, &rect));
  assert(rect.x == 686 && rect.y == 1144 && rect.w == 54 && rect.h == 58);
  core::LineGlyph outside = glyphs[1];
  outside.x = 1270;
  assert(!core::ProjectCell(outside, 1280, 720, 2560, 1440, &rect));

  // Hit test in design pixels; the unmapped 「 is never a hit.
  int32_t x = 0, y = 0;
  assert(core::ClientToDesign(700, 590, 1280, 720, 1280, 720, &x, &y));
  size_t hit = 99u;
  assert(core::HitTestLine(glyphs, 4u, 344, 580, &hit) && hit == 1u);
  assert(!core::HitTestLine(glyphs, 4u, 320, 580, &hit));  // 「
  assert(!core::HitTestLine(glyphs, 4u, 344, 700, &hit));
  assert(!core::ClientToDesign(1280, 10, 1280, 720, 1280, 720, &x, &y));
}

void TestClaim() {
  core::ClaimState claim;
  auto d = core::DecideMessage(core::kMessageLeftDown, true, &claim);
  assert(d.evaluate && d.swallow && d.submit && claim.owned);
  d = core::DecideMessage(core::kMessageLeftUp, false, &claim);
  assert(d.swallow && !d.submit && !claim.owned);
  // Unclaimed presses and their releases pass through.
  d = core::DecideMessage(core::kMessageLeftDown, false, &claim);
  assert(!d.swallow && !claim.owned);
  d = core::DecideMessage(core::kMessageLeftUp, false, &claim);
  assert(!d.swallow);
  // A double click is a press too; a lost release cannot make a later press
  // sticky.
  d = core::DecideMessage(core::kMessageLeftDouble, true, &claim);
  assert(d.swallow && claim.owned);
  d = core::DecideMessage(core::kMessageLeftDown, false, &claim);
  assert(!d.swallow && !claim.owned);
  d = core::DecideMessage(WM_MOUSEMOVE, true, &claim);
  assert(!d.evaluate && !d.swallow);
}

void TestLaneIdentity() {
  const uint64_t box = core::LaneIdentity(0x9ef90u, 300, 560);
  assert(box == core::LaneIdentity(0x9ef90u, 300, 560));
  assert(box != core::LaneIdentity(0x9ef90u, 300, 520));  // name plate
  assert(box != core::LaneIdentity(0x9ef28u, 300, 560));  // other class
}

}  // namespace

int main() {
  TestResolvesThiscallGeneration();
  TestResolvesStdcallGeneration();
  TestResolutionFailsClosed();
  TestDecodesThiscallOwner();
  TestDecodesStdcallOwner();
  TestOwnerDecodingFailsClosed();
  TestParsesLines();
  TestPageGlyphs();
  TestClaim();
  TestLaneIdentity();
  std::puts("fushi_bgi_lookup_test: all passed");
  return 0;
}
