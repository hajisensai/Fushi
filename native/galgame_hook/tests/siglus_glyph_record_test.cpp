#ifdef NDEBUG
#undef NDEBUG
#endif

#include "../hook/adapters/siglus_glyph_record.h"
#include "../hook/adapters/siglus_lookup.h"

#include <array>
#include <cstdlib>
#include <cstdio>
#include <limits>

namespace {
size_t checks = 0;
#define CHECK(condition) do { ++checks; if (!(condition)) { \
  std::fprintf(stderr, "check failed at line %d: %s\n", __LINE__, #condition); \
  std::exit(1); } } while (false)
template <typename T, size_t N>
void Put(std::array<uint8_t, N>& bytes, size_t offset, T value) {
  CHECK(offset + sizeof(value) <= bytes.size());
  std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

void CheckLayout(fushi_voice_hook::SiglusGlyphLayoutAbi abi, size_t offset) {
  using namespace fushi_voice_hook;
  // The two position pairs deliberately disagree to catch ABI conflation.
  std::array<uint8_t, 0x70> bytes{};
  for (size_t at : {0x58u, 0x5cu, 0x60u}) Put(bytes, at, 1.0f);
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
  CHECK(decode());
  CHECK(glyph.code_unit == 0x3042 && glyph.extent == 30);
  CHECK(glyph.x == (offset == 0x34 ? 240 : 400));
  CHECK(glyph.y == (offset == 0x34 ? 560 : 300));
  for (size_t size = 0; size < SiglusGlyphRecordBytes(abi); ++size) {
    CHECK(!DecodeSiglusGlyphRecord(abi, bytes.data(), size, 1280, 720, &glyph));
    CHECK(glyph.code_unit == 0);
  }
  CHECK(DecodeSiglusGlyphRecord(abi, bytes.data(), SiglusGlyphRecordBytes(abi),
                                 1280, 720, &glyph));
  for (float bad : {std::numeric_limits<float>::quiet_NaN(),
                    std::numeric_limits<float>::infinity(),
                    std::numeric_limits<float>::max(), -1.0f, 1280.0f}) {
    Put(bytes, offset, bad);
    CHECK(!decode());
    CHECK(glyph.code_unit == 0 && glyph.x == 0);
  }
  Put(bytes, offset, 1279.4f);
  Put(bytes, offset + 4, 719.4f);
  CHECK(decode() && glyph.x == 1279 && glyph.y == 719);
  Put(bytes, offset, 1279.5f);
  CHECK(!decode());
  Put(bytes, offset, 10.0f);
  Put(bytes, offset + 4, 719.5f);
  CHECK(!decode());
  Put(bytes, offset + 4, 10.0f);
  for (uint32_t invalid : {0u, 0x10000u, 0x80003042u}) {
    Put(bytes, 4, invalid);
    CHECK(!decode());
  }
  Put(bytes, 4, uint32_t{0x3042});
  for (int32_t invalid : {-1, 0, 257}) {
    Put(bytes, 8, invalid);
    CHECK(!decode());
  }
  Put(bytes, 8, int32_t{256});
  CHECK(decode());
  CHECK(!DecodeSiglusGlyphRecord(abi, bytes.data(), bytes.size(), 0, 720, &glyph));
  CHECK(!DecodeSiglusGlyphRecord(abi, bytes.data(), bytes.size(), 1280, -1, &glyph));
  CHECK(!DecodeSiglusGlyphRecord(abi, nullptr, bytes.size(), 1280, 720, &glyph));
  CHECK(!DecodeSiglusGlyphRecord(abi, bytes.data(), bytes.size(), 1280, 720, nullptr));
}
void CheckEightArgumentTransform() {
  using namespace fushi_voice_hook;
  std::array<uint8_t, 0x70> bytes{};
  Put(bytes, 4, uint32_t{0x3042});
  Put(bytes, 8, int32_t{26});
  Put(bytes, 0x40, 285.0f);
  Put(bytes, 0x44, 572.0f);
  for (size_t at : {0x58u, 0x5cu, 0x60u}) Put(bytes, at, 1.0f);
  SiglusGlyphRecord glyph;
  const auto decode = [&] {
    glyph = {7, 7, 7, 7};
    return DecodeSiglusGlyphRecord(SiglusGlyphLayoutAbi::kEcxEightArguments,
        bytes.data(), bytes.size(), 1280, 720, &glyph);
  };
  CHECK(SiglusGlyphRecordBytes(SiglusGlyphLayoutAbi::kEcxEightArguments) == 0x70);
  CHECK(decode());
  // Already transformed logical position and original font extent: decoding
  // must not apply either scene translation or the OS's physical DPI scale.
  CHECK(glyph.x == 285 && glyph.y == 572 && glyph.extent == 26);
  for (size_t at : {0x58u, 0x5cu, 0x60u}) {
    for (float bad : {0.0f, -1.0f, 0.75f, 2.0f,
        std::nextafter(1.0f, 0.0f), std::nextafter(1.0f, 2.0f),
        std::numeric_limits<float>::infinity(),
        -std::numeric_limits<float>::infinity(),
        std::numeric_limits<float>::quiet_NaN()}) {
      Put(bytes, at, bad);
      CHECK(!decode());
      CHECK(glyph.code_unit == 0 && glyph.extent == 0 && glyph.x == 0 && glyph.y == 0);
    }
    Put(bytes, at, 1.0f);
    CHECK(decode());
  }
  for (size_t at : {0x64u, 0x68u, 0x6cu}) {
    for (float bad : {1.0f, -1.0f, 360.0f,
        std::numeric_limits<float>::denorm_min(),
        std::numeric_limits<float>::infinity(),
        std::numeric_limits<float>::quiet_NaN()}) {
      Put(bytes, at, bad);
      CHECK(!decode());
      CHECK(glyph.code_unit == 0 && glyph.extent == 0 && glyph.x == 0 && glyph.y == 0);
    }
    Put(bytes, at, -0.0f);
    CHECK(decode()); // Signed zero is the same neutral angle.
  }
  // The new trailing fields have no meaning in the existing ten/sixteen ABI.
  for (size_t at : {0x58u, 0x5cu, 0x60u, 0x64u, 0x68u, 0x6cu})
    Put(bytes, at, std::numeric_limits<float>::quiet_NaN());
  Put(bytes, 0x34, 240.0f); Put(bytes, 0x38, 560.0f);
  for (auto abi : {SiglusGlyphLayoutAbi::kEcxTenArguments,
                  SiglusGlyphLayoutAbi::kStackSixteenArguments}) {
    CHECK(DecodeSiglusGlyphRecord(abi, bytes.data(), SiglusGlyphRecordBytes(abi),
                                 1280, 720, &glyph));
    CHECK(glyph.extent == 26);
  }
}
}  // namespace

int main() {
  using namespace fushi_voice_hook;
  CheckLayout(SiglusGlyphLayoutAbi::kEcxTenArguments, 0x40);
  CheckLayout(SiglusGlyphLayoutAbi::kStackSixteenArguments, 0x34);
  CheckLayout(SiglusGlyphLayoutAbi::kEcxEightArguments, 0x40);
  CheckEightArgumentTransform();
  SiglusGlyphRecord glyph{1, 1, 1, 1};
  const auto unknown = static_cast<SiglusGlyphLayoutAbi>(255);
  CHECK(SiglusGlyphRecordBytes(unknown) == 0);
  CHECK(!DecodeSiglusGlyphRecord(unknown, nullptr, 100, 1280, 720, &glyph));
  CHECK(glyph.code_unit == 0);
  // Measured modern anchors cannot be reinterpreted under the older ABI.
  auto profile = kAnemoiSiglusLookupProfile;
  CHECK(MatchesSiglusLookupProfile(profile, profile.executable_sha256.data(),
                                    32, profile.pe_machine));
  for (auto abi : {SiglusGlyphLayoutAbi::kStackSixteenArguments,
                  SiglusGlyphLayoutAbi::kEcxEightArguments, unknown}) {
    profile.glyph_abi = abi;
    CHECK(!MatchesSiglusLookupProfile(profile, profile.executable_sha256.data(),
                                       32, profile.pe_machine));
  }
  std::printf("Siglus glyph records: %zu checks passed\n", checks);
}
