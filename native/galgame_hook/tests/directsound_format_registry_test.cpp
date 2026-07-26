#include <cassert>
#include <cstdint>

#include "directsound_format_registry.h"

int main() {
  using hibiki_voice_hook::DirectSoundFormatRegistry;
  using hibiki_voice_hook::DirectSoundPcmFormat;

  DirectSoundFormatRegistry<32> registry;
  const uintptr_t bgm = 0x1000;
  const uintptr_t voice = 0x2000;

  assert(registry.Register(bgm, {48000, 2, 16, 0}));
  assert(registry.Register(voice, {24000, 1, 16, 0}));

  DirectSoundPcmFormat format;
  assert(registry.Lookup(bgm, &format));
  assert(format.sample_rate == 48000);
  assert(format.channels == 2);

  assert(registry.Lookup(voice, &format));
  assert(format.sample_rate == 24000);
  assert(format.channels == 1);

  // DirectSound can retain a 48 kHz base WAVEFORMATEX while selecting the
  // source's real 44.1 kHz playback frequency.
  assert(registry.SetFrequency(bgm, 44100));
  assert(registry.Lookup(bgm, &format));
  assert(format.sample_rate == 44100);
  assert(format.channels == 2);

  // DSBFREQUENCY_ORIGINAL is zero and restores the creation-time rate.
  assert(registry.SetFrequency(bgm, 0));
  assert(registry.Lookup(bgm, &format));
  assert(format.sample_rate == 48000);

  // Updating one engine source must not contaminate another source/format.
  assert(registry.Lookup(voice, &format));
  assert(format.sample_rate == 24000);
  assert(format.channels == 1);
  assert(!registry.Lookup(0x3000, &format));
  assert(!registry.SetFrequency(0x3000, 22050));

  // A recycled COM pointer is re-registered before capture and replaces the
  // previous lifetime's format atomically.
  assert(registry.Register(voice, {22050, 1, 16, 0}));
  assert(registry.Lookup(voice, &format));
  assert(format.sample_rate == 22050);
  assert(format.channels == 1);

  return 0;
}
