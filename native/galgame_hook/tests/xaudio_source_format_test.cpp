#include <windows.h>
#include <mmreg.h>

#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "xaudio_source_format.h"

namespace {

constexpr int16_t kCoefficients[7][2] = {
    {256, 0},   {512, -256}, {0, 0},      {192, 64},
    {240, 0},   {460, -208}, {392, -232},
};

std::vector<uint8_t> MakeMonoFormat() {
  std::vector<uint8_t> bytes(sizeof(WAVEFORMATEX) + 4 + sizeof(kCoefficients));
  auto* wave = reinterpret_cast<WAVEFORMATEX*>(bytes.data());
  wave->wFormatTag = WAVE_FORMAT_ADPCM;
  wave->nChannels = 1;
  wave->nSamplesPerSec = 47968;
  wave->nAvgBytesPerSec = 32978;
  wave->nBlockAlign = 22;
  wave->wBitsPerSample = 4;
  wave->cbSize = 4 + sizeof(kCoefficients);
  uint16_t samples_per_block = 32;
  uint16_t coefficient_count = 7;
  std::memcpy(bytes.data() + sizeof(WAVEFORMATEX), &samples_per_block, 2);
  std::memcpy(bytes.data() + sizeof(WAVEFORMATEX) + 2, &coefficient_count, 2);
  std::memcpy(bytes.data() + sizeof(WAVEFORMATEX) + 4, kCoefficients,
              sizeof(kCoefficients));
  return bytes;
}

}  // namespace

int main() {
  const std::vector<uint8_t> format_bytes = MakeMonoFormat();
  const auto* wave =
      reinterpret_cast<const WAVEFORMATEX*>(format_bytes.data());
  fushi_voice_hook::XAudioSourceFormat format;
  assert(fushi_voice_hook::ParseXAudioSourceFormat(wave, &format));
  assert(format.encoding ==
         fushi_voice_hook::XAudioSourceEncoding::kMicrosoftAdpcm);
  assert(format.sample_rate == 47968);
  assert(format.channels == 1);
  assert(format.bits_per_sample == 4);
  assert(format.block_align == 22);
  assert(format.samples_per_block == 32);
  assert(format.coefficient_count == 7);

  fushi_voice_hook::XAudioSourceFormatRegistry<4> registry;
  assert(registry.Register(0x1234, format));
  fushi_voice_hook::XAudioSourceFormat looked_up;
  assert(registry.Lookup(0x1234, &looked_up));
  assert(looked_up.samples_per_block == 32);
  assert(!registry.Lookup(0x5678, &looked_up));
  const uint64_t submit_before_start = 1000;
  assert(registry.TimestampForSubmit(0x1234, submit_before_start) == 0);
  assert(registry.ResolvePlaybackTimestamp(0x1234, submit_before_start) == 0);
  assert(registry.MarkStarted(0x1234, 1400));
  assert(registry.ResolvePlaybackTimestamp(0x1234, submit_before_start) ==
         1400);
  assert(registry.TimestampForSubmit(0x1234, 1500) == 1500);
  assert(registry.MarkStopped(0x1234));
  assert(registry.TimestampForSubmit(0x1234, 1600) == 0);
  assert(registry.ResolvePlaybackTimestamp(0x1234, 1600) == 0);
  assert(registry.MarkStarted(0x1234, 1700));
  assert(registry.ResolvePlaybackTimestamp(0x1234, 1600) == 1700);
  // A reused source address is a new lifetime and must not inherit Start.
  assert(registry.Register(0x1234, format));
  assert(registry.TimestampForSubmit(0x1234, 1800) == 0);
  assert(registry.ResolvePlaybackTimestamp(0x1234, 1800) == 0);

  std::vector<uint8_t> block(22, 0);
  block[0] = 0;
  block[1] = 16;
  block[3] = 0xe8;
  block[4] = 0x03;
  block[5] = 0x84;
  block[6] = 0x03;
  block[7] = 0x10;
  std::vector<int16_t> decoded;
  assert(fushi_voice_hook::DecodeMicrosoftAdpcm(
      format, block.data(), block.size(), &decoded));
  assert(decoded.size() == 32);
  assert(decoded[0] == 900);
  assert(decoded[1] == 1000);
  assert(decoded[2] == 1016);
  assert(decoded[3] == 1016);

  std::vector<uint8_t> malformed = format_bytes;
  reinterpret_cast<WAVEFORMATEX*>(malformed.data())->cbSize = 3;
  assert(!fushi_voice_hook::ParseXAudioSourceFormat(
      reinterpret_cast<const WAVEFORMATEX*>(malformed.data()), &format));
  return 0;
}
