#undef NDEBUG
#include <cmath>
#include <cstddef>
#include <iostream>

#include "../audio_duck_gain.h"

// 「只静音扬声器、录音照常」约定（游戏串流静音主机 / 网页视频制卡 silent）的纯计算部分。
namespace {

int g_assertions = 0;

bool Expect(bool condition, const char* message) {
  ++g_assertions;
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    return false;
  }
  return true;
}

bool Near(float a, float b) {
  return std::fabs(a - b) <= 1e-6f * (std::fabs(b) > 1.0f ? std::fabs(b) : 1.0f);
}

bool TestDuckedVolumeMarker() {
  bool ok = true;
  ok &= Expect(fushi::IsDuckedVolume(fushi::kSilentDuckLevel),
               "the duck level itself is ducked");
  ok &= Expect(fushi::IsDuckedVolume(fushi::kDuckedThreshold),
               "the threshold still counts as ducked (crash residue)");
  ok &= Expect(!fushi::IsDuckedVolume(0.0f),
               "a mixer slider dragged to zero is the user's own choice");
  ok &= Expect(!fushi::IsDuckedVolume(0.01f),
               "the smallest mixer step (1 %) is not a duck");
  ok &= Expect(!fushi::IsDuckedVolume(1.0f), "full volume is not ducked");
  return ok;
}

bool TestRestoresDuckedSamplesToFullLevel() {
  bool ok = true;
  const float original[] = {0.5f, -0.25f, 1.0f, -1.0f, 0.0f};
  constexpr size_t kCount = sizeof(original) / sizeof(original[0]);
  float samples[kCount];
  for (size_t i = 0; i < kCount; ++i) {
    samples[i] = original[i] * fushi::kSilentDuckLevel;
  }
  fushi::RestoreDuckedGain(samples, kCount);
  for (size_t i = 0; i < kCount; ++i) {
    ok &= Expect(Near(samples[i], original[i]),
                 "a ducked sample is scaled back to its original level");
  }
  return ok;
}

bool TestUnduckedSamplesAreSilencedNotClipped() {
  bool ok = true;
  // Between the duck lifting and the capturer noticing, full-level samples
  // arrive while the inverse gain is still on: they must become silence, not
  // a 100 dB burst.
  float samples[] = {0.3f, -0.8f, fushi::kSilentDuckLevel * 2.0f,
                     -fushi::kSilentDuckLevel * 2.0f};
  fushi::RestoreDuckedGain(samples, 4);
  ok &= Expect(samples[0] == 0.0f, "positive full-level sample silenced");
  ok &= Expect(samples[1] == 0.0f, "negative full-level sample silenced");
  ok &= Expect(samples[2] == 0.0f, "sample above the ducked ceiling silenced");
  ok &= Expect(samples[3] == 0.0f,
               "negative sample below the ducked floor silenced");
  // Slightly hot game output (> 0 dBFS float) still survives the duck.
  float hot[] = {1.2f * fushi::kSilentDuckLevel};
  fushi::RestoreDuckedGain(hot, 1);
  ok &= Expect(Near(hot[0], 1.2f), "float overs up to +3.5 dB are kept");
  return ok;
}

}  // namespace

int main() {
  bool ok = true;
  ok &= TestDuckedVolumeMarker();
  ok &= TestRestoresDuckedSamplesToFullLevel();
  ok &= TestUnduckedSamplesAreSilencedNotClipped();
  std::cout << (ok ? "PASS" : "FAIL") << " audio_duck_gain_test (" << g_assertions
            << " assertions)\n";
  return ok ? 0 : 1;
}
