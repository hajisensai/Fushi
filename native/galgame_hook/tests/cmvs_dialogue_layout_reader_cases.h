#pragma once
#include "../hook/adapters/cmvs_dialogue_layout_reader.h"
#include "../hook/adapters/cmvs_dialogue_text_resolver.h"
#include "../hook/adapters/cmvs_presentation_reader.h"
#include "../hook/adapters/cmvs_sprite_geometry_reader.h"
#include "../hook/adapters/cmvs_hook_installation.h"
#include <cassert>
#include <vector>

namespace cmvs_reader_test {
using namespace fushi_voice_hook::cmvs_layout;
constexpr uint64_t kBase = 0x140000000;
constexpr uint64_t kRoot = 0x1000, kOwner = 0x3000, kNodes = 0x4000;
struct Memory {
  std::vector<uint8_t> bytes = std::vector<uint8_t>(0x20000);
  uint64_t changed_address = 0;
  size_t reads_at_changed = 0;
  template <typename T> void Put(uint64_t address, T value) {
    std::memcpy(bytes.data() + address, &value, sizeof(value));
  }
  static bool Read(void* context, uint64_t address, void* out, size_t size) {
    auto& memory = *static_cast<Memory*>(context);
    if (address > memory.bytes.size() || size > memory.bytes.size() - address)
      return false;
    std::memcpy(out, memory.bytes.data() + address, size);
    if (address == memory.changed_address && ++memory.reads_at_changed == 2)
      static_cast<uint8_t*>(out)[0] ^= 1;
    return true;
  }
  explicit Memory(size_t count = 2) {
    Put(kRoot, kBase + kRootVtableRva);
    Put(kRoot + 0x1020, kOwner);
    Put(kOwner, uint64_t{0x2800});
    Put(kOwner + 8, int32_t{100});
    Put(kOwner + 0xc, int32_t{200});
    Put(kOwner + 0x158, int32_t{1280});
    Put(kOwner + 0x15c, int32_t{720});
    Put(kOwner + 0xa8, count ? kNodes : uint64_t{0});
    for (size_t i = 0; i < count; ++i) {
      const uint64_t n = kNodes + i * 0x48;
      Put(n, i + 1 == count ? uint64_t{0} : n + 0x48);
      Put(n + 8, static_cast<int32_t>(i));
      Put(n + 0xc, uint16_t{0x28});
      Put(n + 0xe, i == 0 ? uint16_t{0x82a0} : uint16_t{0x41});
      Put(n + 0x18, static_cast<int32_t>(30 + i * 30));
      Put(n + 0x1c, int32_t{45});
      Put(n + 0x20, int32_t{30});
    }
  }
};
inline void Run() {
  // The real HookFn failure contract: CreateHook populates the trampoline,
  // EnableHook fails, and HookFn returns false without clearing the pointer.
  int hook_target = 0, hook_detour = 0;
  void* trampoline = nullptr;
  HookInstallation failed_install;
  const auto create_then_fail_enable = [](void* target, void*, void** original) {
    *original = target;
    return false;
  };
  assert(!failed_install.Install(create_then_fail_enable, &hook_target,
                                 &hook_detour, &trampoline));
  assert(trampoline == &hook_target && !failed_install.enabled());
  // A subsequent availability/install query must not reinterpret that nonnull
  // trampoline as success or retry an unresolved installation implicitly.
  const auto unexpected_retry = [](void*, void*, void**) -> bool {
    assert(false && "failed installation must stay failed");
    return true;
  };
  assert(!failed_install.Install(unexpected_retry, &hook_target,
                                 &hook_detour, &trampoline));
  HookInstallation successful_install;
  const auto enable_success = [](void* target, void*, void** original) {
    *original = target;
    return true;
  };
  assert(successful_install.Install(enable_success, &hook_target,
                                    &hook_detour, &trampoline));
  assert(successful_install.enabled());
  successful_install.Shutdown();
  assert(!successful_install.enabled() && trampoline != nullptr);
  HookInstallation missing_trampoline;
  trampoline = nullptr;
  const auto success_without_forwarding = [](void*, void*, void**) { return true; };
  assert(!missing_trampoline.Install(success_without_forwarding, &hook_target,
                                     &hook_detour, &trampoline));
  Snapshot result{};
  const auto capture = [&](Memory& memory) {
    return Capture(Memory::Read, &memory, kBase, kRoot, 0, &result);
  };
  Memory good;
  assert(capture(good) == Result::kCaptured);
  assert(result.count == 2 && result.owner == kOwner);
  assert(result.glyphs[0].cp932 == 0x82a0 && result.glyphs[1].cp932 == 0x41);
  assert(result.origin_x == 100 && result.glyphs[1].x == 60);
  TextIdentity identity{};
  assert(ResolveSelectedText(result, L"\x3042\nA", 3, &identity));
  assert(identity.count == 2 && identity.source_indices[0] == 0 &&
         identity.source_indices[1] == 2);
  assert(!ResolveSelectedText(result, L"\x3042", 1, &identity));
  assert(identity.count == 0);
  assert(!ResolveSelectedText(result, L"x\x3042" L"A", 3, &identity));
  assert(!ResolveSelectedText(result, L"\x3042" L"AB", 3, &identity));
  assert(!ResolveSelectedText(result, L"\x3042" L"B", 2, &identity));
  Memory empty(0);
  assert(capture(empty) == Result::kEmpty && result.count == 0);
  Memory cycle;
  cycle.Put(kNodes + 0x48, kNodes);
  assert(capture(cycle) == Result::kCycle);
  Memory over_limit(kMaxGlyphs + 1);
  assert(capture(over_limit) == Result::kTooManyGlyphs);
  Memory inaccessible;
  inaccessible.Put(kNodes, uint64_t{0xfffffffffffffff0});
  assert(capture(inaccessible) == Result::kUnreadable);
  Memory changed;
  changed.changed_address = kNodes;
  assert(capture(changed) == Result::kChanged && result.count == 0);
  Memory changed_owner;
  changed_owner.changed_address = kRoot + 0x1020;
  assert(capture(changed_owner) == Result::kChanged);
  Memory duplicate;
  duplicate.Put(kNodes + 0x48 + 8, int32_t{0});
  assert(capture(duplicate) == Result::kInvalidNode);
  Memory wrong_family;
  wrong_family.Put(kRoot + 0x1020, uint64_t{0});
  wrong_family.Put(kRoot + 0x10e8, kOwner);
  assert(capture(wrong_family) == Result::kEmpty);
  Memory wrong_root;
  wrong_root.Put(kRoot, kBase + kRootVtableRva + 8);
  assert(capture(wrong_root) == Result::kWrongRoot);
  Memory invalid_cp932;
  invalid_cp932.Put(kNodes + 0xe, uint16_t{0x817f});
  assert(capture(invalid_cp932) == Result::kInvalidNode);
  assert(Capture(Memory::Read, &good, kBase, kRoot, kSlotCount, &result) ==
         Result::kInvalidArgument);
  Memory view;
  view.Put(kRoot + 0x7b0, uint64_t{0xd000});
  view.Put(0xd000, uint64_t{0xe000});
  view.Put(0xd008, uint64_t{0xe200});
  view.Put(0xe218, int32_t{1280});
  view.Put(0xe21c, int32_t{720});
  view.Put(0xe268, int32_t{3840}); // stale fullscreen destination
  view.Put(0xe26c, int32_t{2160});
  Presentation presentation{};
  assert(CapturePresentation(Memory::Read, &view, kBase, kRoot, 1280, 720,
                             &presentation) == Result::kCaptured);
  assert(presentation.destination.width == 1280);
  assert(CapturePresentation(Memory::Read, &view, kBase, kRoot, 852, 480,
                             &presentation) == Result::kInvalidNode);
  view.Put(0xe120, uint64_t{0xe400});
  view.Put(0xe400, kBase + 0xd6f78);
  view.Put(0xe408, int32_t{1});
  view.Put(0xe2b8, int32_t{1});
  view.Put(0xe2c8, int32_t{3840});
  view.Put(0xe2cc, int32_t{2160});
  view.Put(0xe258, int32_t{1280});
  view.Put(0xe25c, int32_t{720});
  assert(CapturePresentation(Memory::Read, &view, kBase, kRoot, 3840, 2160,
                             &presentation) == Result::kCaptured);
  assert(presentation.source.width == 1280 &&
         presentation.destination.width == 3840);
  view.Put(0xe268, int32_t{3841});
  assert(CapturePresentation(Memory::Read, &view, kBase, kRoot, 3840, 2160,
                             &presentation) == Result::kInvalidNode);
  view.Put(0xe268, int32_t{3840});
  view.changed_address = 0xe120;
  assert(CapturePresentation(Memory::Read, &view, kBase, kRoot, 3840, 2160,
                             &presentation) == Result::kChanged);
  Memory sprites(1);
  sprites.Put(kOwner, uint64_t{0x10000});
  assert(capture(sprites) == Result::kCaptured);
  sprites.Put(0x11808, uint64_t{0x13000});
  sprites.Put(0x11830, uint64_t{0x12000});
  sprites.Put(0x13008, int32_t{0});
  sprites.Put(0x13010, uint64_t{0x14000});
  sprites.Put(0x14000, uint64_t{0x10000});
  sprites.Put(0x15830, uint64_t{0x16000});
  for (uint64_t sprite : {uint64_t{0x10000}, uint64_t{0x14000}}) {
    sprites.Put(sprite + 0x1860, int32_t{1});
    sprites.Put(sprite + 0x1864, int32_t{1});
    sprites.Put(sprite + 0x1868, int32_t{1});
    sprites.Put(sprite + 0x186c, 1.0f);
  }
  for (uint64_t state : {uint64_t{0x12000}, uint64_t{0x16000}}) {
    sprites.Put(state + 0x44, int32_t{255});
    sprites.Put(state + 0x48, 1.0f);
    sprites.Put(state + 0x4c, 1.0f);
    sprites.Put(state + 0x54, int32_t{256});
  }
  sprites.Put(0x12020, int32_t{100});
  sprites.Put(0x12024, int32_t{200});
  sprites.Put(0x16020, int32_t{28});
  sprites.Put(0x16024, int32_t{43});
  sprites.Put(0x16010, int32_t{34});
  sprites.Put(0x16014, int32_t{34});
  Presentation pixels{{0, 0, 1280, 720}, {0, 0, 3840, 2160}, 3840, 2160};
  std::array<PixelRect, kMaxGlyphs> quads{};
  assert(CaptureQuads(Memory::Read, &sprites, result, pixels, &quads) == Result::kCaptured);
  assert(quads[0].x == 384 && quads[0].y == 729 && quads[0].width == 102);
  sprites.Put(0x11864, int32_t{0});
  assert(CaptureQuads(Memory::Read, &sprites, result, pixels, &quads) == Result::kInvalidNode);
  assert(quads[0].width == 0);
  sprites.Put(0x11864, int32_t{1});
  sprites.Put(0x16044, int32_t{0});
  assert(CaptureQuads(Memory::Read, &sprites, result, pixels, &quads) == Result::kInvalidNode);
  sprites.Put(0x16044, int32_t{255});
  sprites.Put(0x16050, int32_t{90});
  assert(CaptureQuads(Memory::Read, &sprites, result, pixels, &quads) == Result::kInvalidNode);
}
}  // namespace cmvs_reader_test
