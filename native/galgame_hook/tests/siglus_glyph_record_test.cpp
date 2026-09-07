#ifdef NDEBUG
#undef NDEBUG
#endif

#include "../hook/adapters/siglus_glyph_record.h"
#include "../hook/adapters/siglus_lookup.h"

#include <array>
#include <cassert>
#include <cstdio>
#include <limits>

namespace {
template <typename T, size_t N>
void Put(std::array<uint8_t, N>& bytes, size_t offset, T value) {
  assert(offset + sizeof(value) <= bytes.size());
  std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

void CheckLayout(fushi_voice_hook::SiglusGlyphLayoutAbi abi, size_t offset) {
  using namespace fushi_voice_hook;
  // The two position pairs deliberately disagree to catch ABI conflation.
  std::array<uint8_t, 0x48> bytes{};
  Put(bytes, 4, uint32_t{0x3042});
  Put(bytes, 8, int32_t{30});
  Put(bytes, 0x34, 240.0f);
  Put(bytes, 0x38, 560.0f);
  Put(bytes, 0x40, 400.0f);
  Put(bytes, 0x44, 300.0f);
  SiglusGlyphRecord glyph;
  const auto decode = [&] {
    return DecodeSiglusGlyphRecord(abi, bytes.data(), bytes.size(),
                                   1280, 720, &glyph);
  };
  assert(decode());
  assert(glyph.code_unit == 0x3042 && glyph.extent == 30);
  assert(glyph.x == (offset == 0x34 ? 240 : 400));
  assert(glyph.y == (offset == 0x34 ? 560 : 300));
  for (size_t size = 0; size < SiglusGlyphRecordBytes(abi); ++size) {
    assert(!DecodeSiglusGlyphRecord(abi, bytes.data(), size, 1280, 720, &glyph));
    assert(glyph.code_unit == 0);
  }
  assert(DecodeSiglusGlyphRecord(abi, bytes.data(), SiglusGlyphRecordBytes(abi),
                                 1280, 720, &glyph));
  for (float bad : {std::numeric_limits<float>::quiet_NaN(),
                    std::numeric_limits<float>::infinity(),
                    std::numeric_limits<float>::max(), -1.0f, 1280.0f}) {
    Put(bytes, offset, bad);
    assert(!decode());
    assert(glyph.code_unit == 0 && glyph.x == 0);
  }
  Put(bytes, offset, 1279.4f);
  Put(bytes, offset + 4, 719.4f);
  assert(decode() && glyph.x == 1279 && glyph.y == 719);
  Put(bytes, offset, 1279.5f);
  assert(!decode());
  Put(bytes, offset, 10.0f);
  Put(bytes, offset + 4, 719.5f);
  assert(!decode());
  Put(bytes, offset + 4, 10.0f);
  for (uint32_t invalid : {0u, 0x10000u, 0x80003042u}) {
    Put(bytes, 4, invalid);
    assert(!decode());
  }
  Put(bytes, 4, uint32_t{0x3042});
  for (int32_t invalid : {-1, 0, 257}) {
    Put(bytes, 8, invalid);
    assert(!decode());
  }
  Put(bytes, 8, int32_t{256});
  assert(decode());
  assert(!DecodeSiglusGlyphRecord(abi, bytes.data(), bytes.size(), 0, 720, &glyph));
  assert(!DecodeSiglusGlyphRecord(abi, bytes.data(), bytes.size(), 1280, -1, &glyph));
  assert(!DecodeSiglusGlyphRecord(abi, nullptr, bytes.size(), 1280, 720, &glyph));
  assert(!DecodeSiglusGlyphRecord(abi, bytes.data(), bytes.size(), 1280, 720, nullptr));
}
}  // namespace

int main() {
  using namespace fushi_voice_hook;
  CheckLayout(SiglusGlyphLayoutAbi::kEcxTenArguments, 0x40);
  CheckLayout(SiglusGlyphLayoutAbi::kStackSixteenArguments, 0x34);
  SiglusGlyphRecord glyph{1, 1, 1, 1};
  const auto unknown = static_cast<SiglusGlyphLayoutAbi>(255);
  assert(SiglusGlyphRecordBytes(unknown) == 0);
  assert(!DecodeSiglusGlyphRecord(unknown, nullptr, 100, 1280, 720, &glyph));
  assert(glyph.code_unit == 0);
  // Measured modern anchors cannot be reinterpreted under the older ABI.
  auto profile = kAnemoiSiglusLookupProfile;
  assert(MatchesSiglusLookupProfile(profile, profile.executable_sha256.data(),
                                    32, profile.pe_machine));
  for (auto abi : {SiglusGlyphLayoutAbi::kStackSixteenArguments, unknown}) {
    profile.glyph_abi = abi;
    assert(!MatchesSiglusLookupProfile(profile, profile.executable_sha256.data(),
                                       32, profile.pe_machine));
  }
  std::puts("Siglus glyph records: two layouts, bounds and ABI isolation passed");
}
