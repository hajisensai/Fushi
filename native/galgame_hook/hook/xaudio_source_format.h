#ifndef FUSHI_VOICE_HOOK_XAUDIO_SOURCE_FORMAT_H_
#define FUSHI_VOICE_HOOK_XAUDIO_SOURCE_FORMAT_H_

#include <mmreg.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

namespace fushi_voice_hook {

enum class XAudioSourceEncoding : uint32_t {
  kUnsupported = 0,
  kPcmInteger = 1,
  kPcmFloat = 2,
  kMicrosoftAdpcm = 3,
};

struct XAudioAdpcmCoefficient {
  int16_t first = 0;
  int16_t second = 0;
};

constexpr uint32_t kMaxXAudioAdpcmCoefficients = 32;

struct XAudioSourceFormat {
  XAudioSourceEncoding encoding = XAudioSourceEncoding::kUnsupported;
  uint32_t sample_rate = 0;
  uint32_t channels = 0;
  uint32_t bits_per_sample = 0;
  uint32_t block_align = 0;
  uint32_t samples_per_block = 0;
  uint32_t coefficient_count = 0;
  XAudioAdpcmCoefficient coefficients[kMaxXAudioAdpcmCoefficients] = {};
};

inline bool IsSaneXAudioBaseFormat(const WAVEFORMATEX* format) {
  return format != nullptr && format->nSamplesPerSec >= 8000 &&
         format->nSamplesPerSec <= 384000 && format->nChannels >= 1 &&
         format->nChannels <= 8 && format->nBlockAlign != 0;
}

inline bool ParseXAudioSourceFormat(const WAVEFORMATEX* format,
                                    XAudioSourceFormat* parsed) {
  if (parsed == nullptr || !IsSaneXAudioBaseFormat(format)) return false;

  XAudioSourceFormat result;
  result.sample_rate = format->nSamplesPerSec;
  result.channels = format->nChannels;
  result.bits_per_sample = format->wBitsPerSample;
  result.block_align = format->nBlockAlign;

  uint16_t normalized_tag = format->wFormatTag;
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    constexpr uint16_t kExtensibleBytes =
        sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    if (format->cbSize < kExtensibleBytes) return false;
    const auto* extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    normalized_tag = static_cast<uint16_t>(extensible->SubFormat.Data1);
  }

  if (normalized_tag == WAVE_FORMAT_PCM ||
      normalized_tag == WAVE_FORMAT_IEEE_FLOAT) {
    const bool is_float = normalized_tag == WAVE_FORMAT_IEEE_FLOAT;
    const bool valid_bits = is_float
                                ? format->wBitsPerSample == 32
                                : (format->wBitsPerSample == 8 ||
                                   format->wBitsPerSample == 16 ||
                                   format->wBitsPerSample == 24 ||
                                   format->wBitsPerSample == 32);
    const uint32_t expected_align =
        static_cast<uint32_t>(format->nChannels) *
        (static_cast<uint32_t>(format->wBitsPerSample) / 8u);
    if (!valid_bits || expected_align == 0 ||
        format->nBlockAlign != expected_align) {
      return false;
    }
    result.encoding = is_float ? XAudioSourceEncoding::kPcmFloat
                               : XAudioSourceEncoding::kPcmInteger;
    *parsed = result;
    return true;
  }

  if (normalized_tag != WAVE_FORMAT_ADPCM || format->wBitsPerSample != 4 ||
      format->nChannels > 2 || format->cbSize < 4) {
    return false;
  }

  const uint8_t* extra = reinterpret_cast<const uint8_t*>(format) +
                         sizeof(WAVEFORMATEX);
  uint16_t samples_per_block = 0;
  uint16_t coefficient_count = 0;
  std::memcpy(&samples_per_block, extra, sizeof(samples_per_block));
  std::memcpy(&coefficient_count, extra + 2, sizeof(coefficient_count));
  const uint32_t required_extra =
      4u + static_cast<uint32_t>(coefficient_count) * 4u;
  if (samples_per_block < 32 || samples_per_block > 512 ||
      coefficient_count == 0 ||
      coefficient_count > kMaxXAudioAdpcmCoefficients ||
      format->cbSize < required_extra ||
      format->nBlockAlign < 7u * format->nChannels) {
    return false;
  }

  const uint32_t encoded_samples =
      2u + ((static_cast<uint32_t>(format->nBlockAlign) -
             7u * format->nChannels) *
            2u / format->nChannels);
  if (encoded_samples < samples_per_block) return false;

  result.encoding = XAudioSourceEncoding::kMicrosoftAdpcm;
  result.samples_per_block = samples_per_block;
  result.coefficient_count = coefficient_count;
  for (uint32_t i = 0; i < coefficient_count; ++i) {
    std::memcpy(&result.coefficients[i].first, extra + 4 + i * 4, 2);
    std::memcpy(&result.coefficients[i].second, extra + 6 + i * 4, 2);
  }
  *parsed = result;
  return true;
}

template <size_t Capacity>
class XAudioSourceFormatRegistry {
 public:
  bool Register(uintptr_t source, const XAudioSourceFormat& format) {
    if (source <= kReservedSource ||
        format.encoding == XAudioSourceEncoding::kUnsupported) {
      return false;
    }
    for (Slot& slot : slots_) {
      const uintptr_t current = slot.source.load(std::memory_order_acquire);
      if (current == source) {
        // CreateSourceVoice may reuse an address from the engine's voice pool.
        // Treat every registration as a fresh lifetime so a previous Start does
        // not make a newly preloaded buffer look as if it were already playing.
        slot.format = format;
        slot.last_start_ms.store(0, std::memory_order_release);
        slot.started.store(0, std::memory_order_release);
        return true;
      }
      if (current != 0) continue;
      uintptr_t expected = 0;
      if (!slot.source.compare_exchange_strong(
              expected, kReservedSource, std::memory_order_acq_rel)) {
        continue;
      }
      slot.format = format;
      slot.last_start_ms.store(0, std::memory_order_relaxed);
      slot.started.store(0, std::memory_order_relaxed);
      slot.source.store(source, std::memory_order_release);
      return true;
    }
    return false;
  }

  bool MarkStarted(uintptr_t source, uint64_t timestamp_ms) {
    if (source <= kReservedSource || timestamp_ms == 0) return false;
    for (Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      slot.last_start_ms.store(timestamp_ms, std::memory_order_release);
      slot.started.store(1, std::memory_order_release);
      return true;
    }
    return false;
  }

  bool MarkStopped(uintptr_t source) {
    if (source <= kReservedSource) return false;
    for (Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      // Keep last_start_ms: a one-shot voice may Stop before HookWorker has
      // published its pending decoded buffer. ResolvePlaybackTimestamp uses the
      // submit timestamp to reject an older lifetime's Start.
      slot.started.store(0, std::memory_order_release);
      return true;
    }
    return false;
  }

  uint64_t TimestampForSubmit(uintptr_t source,
                              uint64_t submit_timestamp_ms) const {
    if (source <= kReservedSource || submit_timestamp_ms == 0) return 0;
    for (const Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      return slot.started.load(std::memory_order_acquire) != 0
                 ? submit_timestamp_ms
                 : 0;
    }
    return 0;
  }

  uint64_t ResolvePlaybackTimestamp(uintptr_t source,
                                    uint64_t submit_timestamp_ms) const {
    if (source <= kReservedSource || submit_timestamp_ms == 0) return 0;
    for (const Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      const uint64_t start =
          slot.last_start_ms.load(std::memory_order_acquire);
      return start >= submit_timestamp_ms ? start : 0;
    }
    return 0;
  }

  bool Lookup(uintptr_t source, XAudioSourceFormat* format) const {
    if (source <= kReservedSource || format == nullptr) return false;
    for (const Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) == source) {
        *format = slot.format;
        return true;
      }
    }
    return false;
  }

 private:
  static constexpr uintptr_t kReservedSource = 1;
  struct Slot {
    std::atomic<uintptr_t> source{0};
    XAudioSourceFormat format;
    std::atomic<uint64_t> last_start_ms{0};
    std::atomic<uint32_t> started{0};
  };
  Slot slots_[Capacity];
};

inline int16_t ClampAdpcmSample(int32_t value) {
  return static_cast<int16_t>(std::max<int32_t>(
      std::numeric_limits<int16_t>::min(),
      std::min<int32_t>(std::numeric_limits<int16_t>::max(), value)));
}

inline int32_t SignedAdpcmNibble(uint8_t nibble) {
  return nibble < 8 ? nibble : static_cast<int32_t>(nibble) - 16;
}

inline bool DecodeMicrosoftAdpcm(const XAudioSourceFormat& format,
                                 const uint8_t* encoded,
                                 size_t encoded_bytes,
                                 std::vector<int16_t>* decoded) {
  if (decoded == nullptr || encoded == nullptr || encoded_bytes == 0 ||
      format.encoding != XAudioSourceEncoding::kMicrosoftAdpcm ||
      format.channels == 0 || format.channels > 2 ||
      format.block_align < 7u * format.channels ||
      format.samples_per_block < 2 || format.coefficient_count == 0) {
    return false;
  }

  static constexpr int32_t kAdaptation[16] = {
      230, 230, 230, 230, 307, 409, 512, 614,
      768, 614, 512, 409, 307, 230, 230, 230,
  };
  decoded->clear();
  const size_t block_count =
      (encoded_bytes + format.block_align - 1u) / format.block_align;
  decoded->reserve(block_count * format.samples_per_block * format.channels);

  size_t block_offset = 0;
  while (block_offset < encoded_bytes) {
    const size_t block_bytes =
        std::min<size_t>(format.block_align, encoded_bytes - block_offset);
    const size_t header_bytes = 7u * format.channels;
    if (block_bytes < header_bytes) return false;
    const uint8_t* block = encoded + block_offset;

    uint8_t predictor[2] = {};
    int32_t delta[2] = {};
    int32_t sample1[2] = {};
    int32_t sample2[2] = {};
    size_t cursor = 0;
    for (uint32_t channel = 0; channel < format.channels; ++channel) {
      predictor[channel] = block[cursor++];
      if (predictor[channel] >= format.coefficient_count) return false;
    }
    for (uint32_t channel = 0; channel < format.channels; ++channel) {
      int16_t value = 0;
      std::memcpy(&value, block + cursor, 2);
      cursor += 2;
      delta[channel] = std::max<int32_t>(16, value);
    }
    for (uint32_t channel = 0; channel < format.channels; ++channel) {
      int16_t value = 0;
      std::memcpy(&value, block + cursor, 2);
      cursor += 2;
      sample1[channel] = value;
    }
    for (uint32_t channel = 0; channel < format.channels; ++channel) {
      int16_t value = 0;
      std::memcpy(&value, block + cursor, 2);
      cursor += 2;
      sample2[channel] = value;
    }

    for (uint32_t channel = 0; channel < format.channels; ++channel) {
      decoded->push_back(static_cast<int16_t>(sample2[channel]));
    }
    for (uint32_t channel = 0; channel < format.channels; ++channel) {
      decoded->push_back(static_cast<int16_t>(sample1[channel]));
    }
    uint32_t frames_in_block = 2;

    auto decode_nibble = [&](uint32_t channel, uint8_t nibble) {
      const XAudioAdpcmCoefficient coefficient =
          format.coefficients[predictor[channel]];
      const int32_t prediction =
          (sample1[channel] * coefficient.first +
           sample2[channel] * coefficient.second) /
              256 +
          SignedAdpcmNibble(nibble) * delta[channel];
      const int16_t next = ClampAdpcmSample(prediction);
      sample2[channel] = sample1[channel];
      sample1[channel] = next;
      delta[channel] =
          std::max<int32_t>(16, kAdaptation[nibble & 0x0f] * delta[channel] /
                                    256);
      return next;
    };

    while (cursor < block_bytes &&
           frames_in_block < format.samples_per_block) {
      const uint8_t packed = block[cursor++];
      if (format.channels == 1) {
        decoded->push_back(decode_nibble(0, packed >> 4));
        ++frames_in_block;
        if (frames_in_block < format.samples_per_block) {
          decoded->push_back(decode_nibble(0, packed & 0x0f));
          ++frames_in_block;
        }
      } else {
        decoded->push_back(decode_nibble(0, packed >> 4));
        decoded->push_back(decode_nibble(1, packed & 0x0f));
        ++frames_in_block;
      }
    }
    block_offset += block_bytes;
  }
  return !decoded->empty();
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_VOICE_HOOK_XAUDIO_SOURCE_FORMAT_H_
