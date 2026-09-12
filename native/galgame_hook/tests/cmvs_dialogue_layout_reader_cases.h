#pragma once
#include "../hook/adapters/cmvs_dialogue_layout_reader.h"
#include "../hook/adapters/cmvs_dialogue_text_resolver.h"
#include <cassert>
#include <vector>

namespace cmvs_reader_test {
using namespace fushi_voice_hook::cmvs_layout;
constexpr uint64_t kBase = 0x140000000;
constexpr uint64_t kRoot = 0x1000, kOwner = 0x3000, kNodes = 0x4000;
struct Memory {
  std::vector<uint8_t> bytes = std::vector<uint8_t>(0x10000);
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
}
}  // namespace cmvs_reader_test
