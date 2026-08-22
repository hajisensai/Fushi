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
  kWmaudio2 = 4,
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
  uint32_t avg_bytes_per_second = 0;
  uint32_t samples_per_block = 0;
  uint32_t coefficient_count = 0;
  XAudioAdpcmCoefficient coefficients[kMaxXAudioAdpcmCoefficients] = {};
};

// A SourceVoice pointer is not a lifetime identity: engines commonly destroy a
// pooled voice and later receive the same address from CreateSourceVoice.  Jobs
// therefore carry both the monotonically increasing voice generation and the
// queue generation.  FlushSourceBuffers advances only the latter, invalidating
// submitted buffers without pretending that the voice itself was recreated.
struct XAudioSourceSnapshot {
  uintptr_t source = 0;
  uintptr_t engine = 0;
  uint64_t generation = 0;
  uint64_t queue_generation = 0;
  uint64_t last_start_ms = 0;
  bool started = false;
  XAudioSourceFormat format;
};

inline bool IsSaneXAudioBaseFormat(const WAVEFORMATEX* format) {
  return format != nullptr && format->nSamplesPerSec >= 8000 &&
         format->nSamplesPerSec <= 384000 && format->nChannels >= 1 &&
         format->nChannels <= 8 && format->nBlockAlign != 0;
}

inline bool IsCanonicalWaveFormatSubtype(const GUID& subtype,
                                         uint16_t format_tag) {
  // KSDATAFORMAT_SUBTYPE_* wave formats all use
  // {000000xx-0000-0010-8000-00aa00389b71}.  Checking Data1 alone can turn an
  // unrelated custom subtype into PCM/float, and truncating it to 16 bits is
  // even less restrictive.
  static constexpr uint8_t kWaveSubtypeTail[8] = {
      0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71,
  };
  return subtype.Data1 == static_cast<uint32_t>(format_tag) &&
         subtype.Data2 == 0 && subtype.Data3 == 0x0010 &&
         std::memcmp(subtype.Data4, kWaveSubtypeTail,
                     sizeof(kWaveSubtypeTail)) == 0;
}

inline bool ParseXAudioSourceFormat(const WAVEFORMATEX* format,
                                    XAudioSourceFormat* parsed) {
  if (parsed == nullptr || !IsSaneXAudioBaseFormat(format)) return false;

  XAudioSourceFormat result;
  result.sample_rate = format->nSamplesPerSec;
  result.channels = format->nChannels;
  result.bits_per_sample = format->wBitsPerSample;
  result.block_align = format->nBlockAlign;
  result.avg_bytes_per_second = format->nAvgBytesPerSec;

  uint16_t normalized_tag = format->wFormatTag;
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    constexpr uint16_t kExtensibleBytes =
        sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    if (format->cbSize < kExtensibleBytes) return false;
    const auto* extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    if (IsCanonicalWaveFormatSubtype(extensible->SubFormat,
                                     WAVE_FORMAT_PCM)) {
      normalized_tag = WAVE_FORMAT_PCM;
    } else if (IsCanonicalWaveFormatSubtype(extensible->SubFormat,
                                            WAVE_FORMAT_IEEE_FLOAT)) {
      normalized_tag = WAVE_FORMAT_IEEE_FLOAT;
    } else {
      return false;
    }
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

  // xWMA/XAudio2 voices use WMAudio2 frames plus an XAUDIO2_BUFFER_WMA
  // cumulative decoded-byte table.  SGRE's dialogue voices use the canonical
  // mono 44.1 kHz form with no codec-private extension.  Retain the compressed
  // format here; Media Foundation decoding happens later on HookWorker, never
  // on the game's SubmitSourceBuffer thread.
  if (format->wFormatTag == WAVE_FORMAT_WMAUDIO2 &&
      normalized_tag == WAVE_FORMAT_WMAUDIO2 && format->nChannels <= 2 &&
      format->wBitsPerSample == 16 && format->nAvgBytesPerSec != 0 &&
      format->cbSize == 0) {
    result.encoding = XAudioSourceEncoding::kWmaudio2;
    *parsed = result;
    return true;
  }

  // WAVEFORMATEXTENSIBLE has a different extra-data layout.  Microsoft ADPCM
  // coefficients are valid only in ADPCMWAVEFORMAT, never by interpreting the
  // extensible Samples/channel-mask/GUID fields as ADPCM metadata.
  if (format->wFormatTag != WAVE_FORMAT_ADPCM ||
      normalized_tag != WAVE_FORMAT_ADPCM || format->wBitsPerSample != 4 ||
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
    return Register(source, 0, format, nullptr);
  }

  bool Register(uintptr_t source, uintptr_t engine,
                const XAudioSourceFormat& format,
                XAudioSourceSnapshot* registered) {
    if (source <= kReservedSource ||
        format.encoding == XAudioSourceEncoding::kUnsupported) {
      return false;
    }
    for (Slot& slot : slots_) {
      const uintptr_t current = slot.source.load(std::memory_order_acquire);
      if (current == source) {
        uint64_t locked_state = 0;
        if (!LockSlotForAnyGeneration(&slot, source, &locked_state)) {
          return false;
        }
        PublishRegistration(&slot, source, engine, format, registered);
        return true;
      }
      if (current != 0) continue;
      uintptr_t expected = 0;
      if (!slot.source.compare_exchange_strong(
              expected, source, std::memory_order_acq_rel)) {
        // A concurrent registration of the same pointer owns that lifetime.
        // Do not continue into another free slot and create a duplicate source.
        if (expected == source) return false;
        continue;
      }
      PublishRegistration(&slot, source, engine, format, registered);
      return true;
    }
    return false;
  }

  bool MarkStarted(uintptr_t source, uint64_t generation,
                   uint64_t timestamp_ms) {
    if (source <= kReservedSource || !IsValidGeneration(generation) ||
        timestamp_ms == 0) {
      return false;
    }
    for (Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      uint64_t locked_state = 0;
      if (!LockSlotForGeneration(&slot, source, generation, &locked_state)) {
        return false;
      }
      slot.last_start_ms.store(timestamp_ms, std::memory_order_release);
      slot.state.store((locked_state & ~kStateLockMask) | kStartedMask,
                       std::memory_order_release);
      return true;
    }
    return false;
  }

  bool MarkStopped(uintptr_t source, uint64_t generation) {
    if (source <= kReservedSource || !IsValidGeneration(generation)) {
      return false;
    }
    for (Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      uint64_t locked_state = 0;
      if (!LockSlotForGeneration(&slot, source, generation, &locked_state)) {
        return false;
      }
      // Keep last_start_ms: a one-shot voice may Stop before HookWorker has
      // decoded its queued buffer. ResolvePlaybackTimestamp uses the submit
      // timestamp to reject an older Start within the same voice lifetime.
      slot.state.store((locked_state & ~kStateLockMask) & ~kStartedMask,
                       std::memory_order_release);
      return true;
    }
    return false;
  }

  uint64_t TimestampForSubmit(const XAudioSourceSnapshot& snapshot,
                              uint64_t submit_timestamp_ms) const {
    return submit_timestamp_ms != 0 && snapshot.started
               ? submit_timestamp_ms
               : 0;
  }

  uint64_t ResolvePlaybackTimestamp(uintptr_t source,
                                    uint64_t generation,
                                    uint64_t queue_generation,
                                    uint64_t submit_timestamp_ms) const {
    if (source <= kReservedSource || !IsValidGeneration(generation) ||
        !IsValidQueueGeneration(queue_generation) ||
        submit_timestamp_ms == 0) {
      return 0;
    }
    for (const Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      const uint64_t before = slot.state.load(std::memory_order_acquire);
      if (StateIsLocked(before) ||
          GenerationFromState(before) != generation ||
          QueueGenerationFromState(before) != queue_generation) {
        return 0;
      }
      const uint64_t start =
          slot.last_start_ms.load(std::memory_order_acquire);
      const uint64_t after = slot.state.load(std::memory_order_acquire);
      if (before != after ||
          slot.source.load(std::memory_order_acquire) != source) {
        return 0;
      }
      return start >= submit_timestamp_ms ? start : 0;
    }
    return 0;
  }

  bool Lookup(uintptr_t source, XAudioSourceSnapshot* snapshot) const {
    if (source <= kReservedSource || snapshot == nullptr) return false;
    for (const Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      const uint64_t before = slot.state.load(std::memory_order_acquire);
      if (StateIsLocked(before)) return false;
      const uint64_t generation = GenerationFromState(before);
      const uint64_t queue_generation = QueueGenerationFromState(before);
      if (generation == 0 || queue_generation == 0) return false;

      XAudioSourceSnapshot result;
      result.source = source;
      result.engine = slot.engine.load(std::memory_order_relaxed);
      result.generation = generation;
      result.queue_generation = queue_generation;
      result.last_start_ms =
          slot.last_start_ms.load(std::memory_order_relaxed);
      result.started = StateIsStarted(before);
      result.format = slot.format.Load();

      const uint64_t after = slot.state.load(std::memory_order_acquire);
      if (before != after ||
          slot.source.load(std::memory_order_acquire) != source) {
        return false;
      }
      *snapshot = result;
      return true;
    }
    return false;
  }

  bool Lookup(uintptr_t source, XAudioSourceFormat* format) const {
    if (format == nullptr) return false;
    XAudioSourceSnapshot snapshot;
    if (!Lookup(source, &snapshot)) return false;
    *format = snapshot.format;
    return true;
  }

  bool IsCurrent(uintptr_t source, uint64_t generation,
                 uint64_t queue_generation) const {
    if (source <= kReservedSource || !IsValidGeneration(generation) ||
        !IsValidQueueGeneration(queue_generation)) {
      return false;
    }
    for (const Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      const uint64_t before = slot.state.load(std::memory_order_acquire);
      if (StateIsLocked(before)) return false;
      const uint64_t after = slot.state.load(std::memory_order_acquire);
      if (before != after ||
          slot.source.load(std::memory_order_acquire) != source) {
        return false;
      }
      return GenerationFromState(before) == generation &&
             QueueGenerationFromState(before) == queue_generation;
    }
    return false;
  }

  bool IsCurrentSource(uintptr_t source, uint64_t generation) const {
    if (source <= kReservedSource || !IsValidGeneration(generation)) {
      return false;
    }
    for (const Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      const uint64_t before = slot.state.load(std::memory_order_acquire);
      if (StateIsLocked(before)) return false;
      const uint64_t after = slot.state.load(std::memory_order_acquire);
      if (before != after ||
          slot.source.load(std::memory_order_acquire) != source) {
        return false;
      }
      return GenerationFromState(before) == generation;
    }
    return false;
  }

  bool AdvanceQueueGeneration(uintptr_t source, uint64_t generation,
                              uint64_t* advanced_generation = nullptr) {
    if (source <= kReservedSource || !IsValidGeneration(generation)) {
      return false;
    }
    for (Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      uint64_t locked_state = 0;
      if (!LockSlotForGeneration(&slot, source, generation, &locked_state)) {
        return false;
      }
      const uint64_t current = QueueGenerationFromState(locked_state);
      const uint64_t next = current == kQueueGenerationMask ? 1 : current + 1;
      const uint64_t released =
          ((locked_state & ~kStateLockMask) & ~kQueueGenerationFieldMask) |
          (next << kQueueGenerationShift);
      slot.state.store(released, std::memory_order_release);
      if (advanced_generation != nullptr) *advanced_generation = next;
      return true;
    }
    return false;
  }

  bool Unregister(uintptr_t source, uint64_t generation) {
    if (source <= kReservedSource || !IsValidGeneration(generation)) {
      return false;
    }
    for (Slot& slot : slots_) {
      if (slot.source.load(std::memory_order_acquire) != source) continue;
      uint64_t locked_state = 0;
      if (!LockSlotForGeneration(&slot, source, generation, &locked_state)) {
        // DestroyVoice must invalidate the lifetime even if another nonblocking
        // writer currently owns the packed state. Tombstoning the source makes
        // every reader/job generation check fail closed. The rare contested
        // slot is intentionally not recycled while that writer may still
        // publish its old state.
        const uint64_t observed = slot.state.load(std::memory_order_acquire);
        if (GenerationFromState(observed) != generation) return false;
        uintptr_t expected = source;
        return slot.source.compare_exchange_strong(
            expected, kReservedSource, std::memory_order_acq_rel,
            std::memory_order_acquire);
      }
      uintptr_t expected = source;
      if (!slot.source.compare_exchange_strong(
              expected, kReservedSource, std::memory_order_acq_rel)) {
        slot.state.store(locked_state & ~kStateLockMask,
                         std::memory_order_release);
        return false;
      }
      slot.last_start_ms.store(0, std::memory_order_relaxed);
      slot.engine.store(0, std::memory_order_relaxed);
      slot.format.Store(XAudioSourceFormat{});
      slot.state.store(0, std::memory_order_release);
      slot.source.store(0, std::memory_order_release);
      return true;
    }
    return false;
  }

 private:
  static constexpr uintptr_t kReservedSource = 1;

  // One atomic state word is the lifetime identity for every mutable field:
  // [writer lock:1][generation:31][queue generation:31][started:1].  A stale
  // operation can acquire the writer bit only when its generation still
  // matches, so it cannot pass validation and then write into a replacement
  // SourceVoice at the same address.
  static constexpr uint64_t kStartedMask = 1;
  static constexpr uint32_t kQueueGenerationShift = 1;
  static constexpr uint64_t kQueueGenerationMask = 0x7fffffffull;
  static constexpr uint64_t kQueueGenerationFieldMask =
      kQueueGenerationMask << kQueueGenerationShift;
  static constexpr uint32_t kGenerationShift = 32;
  static constexpr uint64_t kGenerationMask = 0x7fffffffull;
  static constexpr uint64_t kStateLockMask = uint64_t{1} << 63;

  static uint64_t PackState(uint64_t generation, uint64_t queue_generation,
                            bool started, bool locked = false) {
    return ((generation & kGenerationMask) << kGenerationShift) |
           ((queue_generation & kQueueGenerationMask)
            << kQueueGenerationShift) |
           (started ? kStartedMask : 0) |
           (locked ? kStateLockMask : 0);
  }

  static uint64_t GenerationFromState(uint64_t state) {
    return (state >> kGenerationShift) & kGenerationMask;
  }

  static uint64_t QueueGenerationFromState(uint64_t state) {
    return (state >> kQueueGenerationShift) & kQueueGenerationMask;
  }

  static bool StateIsStarted(uint64_t state) {
    return (state & kStartedMask) != 0;
  }

  static bool StateIsLocked(uint64_t state) {
    return (state & kStateLockMask) != 0;
  }

  static bool IsValidGeneration(uint64_t generation) {
    return generation != 0 && generation <= kGenerationMask;
  }

  static bool IsValidQueueGeneration(uint64_t generation) {
    return generation != 0 && generation <= kQueueGenerationMask;
  }

  struct AtomicFormat {
    std::atomic<uint32_t> encoding{0};
    std::atomic<uint32_t> sample_rate{0};
    std::atomic<uint32_t> channels{0};
    std::atomic<uint32_t> bits_per_sample{0};
    std::atomic<uint32_t> block_align{0};
    std::atomic<uint32_t> samples_per_block{0};
    std::atomic<uint32_t> coefficient_count{0};
    std::atomic<uint32_t> coefficients[kMaxXAudioAdpcmCoefficients] = {};

    void Store(const XAudioSourceFormat& value) {
      encoding.store(static_cast<uint32_t>(value.encoding),
                     std::memory_order_relaxed);
      sample_rate.store(value.sample_rate, std::memory_order_relaxed);
      channels.store(value.channels, std::memory_order_relaxed);
      bits_per_sample.store(value.bits_per_sample, std::memory_order_relaxed);
      block_align.store(value.block_align, std::memory_order_relaxed);
      samples_per_block.store(value.samples_per_block,
                              std::memory_order_relaxed);
      coefficient_count.store(value.coefficient_count,
                              std::memory_order_relaxed);
      for (uint32_t i = 0; i < kMaxXAudioAdpcmCoefficients; ++i) {
        const uint32_t packed =
            static_cast<uint16_t>(value.coefficients[i].first) |
            (static_cast<uint32_t>(
                 static_cast<uint16_t>(value.coefficients[i].second))
             << 16);
        coefficients[i].store(packed, std::memory_order_relaxed);
      }
    }

    XAudioSourceFormat Load() const {
      XAudioSourceFormat result;
      result.encoding = static_cast<XAudioSourceEncoding>(
          encoding.load(std::memory_order_relaxed));
      result.sample_rate = sample_rate.load(std::memory_order_relaxed);
      result.channels = channels.load(std::memory_order_relaxed);
      result.bits_per_sample =
          bits_per_sample.load(std::memory_order_relaxed);
      result.block_align = block_align.load(std::memory_order_relaxed);
      result.samples_per_block =
          samples_per_block.load(std::memory_order_relaxed);
      result.coefficient_count =
          coefficient_count.load(std::memory_order_relaxed);
      for (uint32_t i = 0; i < kMaxXAudioAdpcmCoefficients; ++i) {
        const uint32_t packed =
            coefficients[i].load(std::memory_order_relaxed);
        const uint16_t first = static_cast<uint16_t>(packed);
        const uint16_t second = static_cast<uint16_t>(packed >> 16);
        std::memcpy(&result.coefficients[i].first, &first, sizeof(first));
        std::memcpy(&result.coefficients[i].second, &second, sizeof(second));
      }
      return result;
    }
  };

  struct Slot {
    std::atomic<uintptr_t> source{0};
    std::atomic<uint64_t> state{0};
    std::atomic<uintptr_t> engine{0};
    AtomicFormat format;
    std::atomic<uint64_t> last_start_ms{0};
  };

  static bool LockSlotForGeneration(Slot* slot, uintptr_t source,
                                    uint64_t generation,
                                    uint64_t* locked_state) {
    if (slot == nullptr || locked_state == nullptr) return false;
    if (slot->source.load(std::memory_order_acquire) != source) return false;
    uint64_t observed = slot->state.load(std::memory_order_acquire);
    if (GenerationFromState(observed) != generation ||
        StateIsLocked(observed)) {
      return false;
    }
    const uint64_t desired = observed | kStateLockMask;
    if (!slot->state.compare_exchange_strong(
            observed, desired, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      return false;
    }
    *locked_state = desired;
    return true;
  }

  static bool LockSlotForAnyGeneration(Slot* slot, uintptr_t source,
                                       uint64_t* locked_state) {
    if (slot == nullptr || locked_state == nullptr) return false;
    if (slot->source.load(std::memory_order_acquire) != source) return false;
    uint64_t observed = slot->state.load(std::memory_order_acquire);
    if (GenerationFromState(observed) == 0 ||
        QueueGenerationFromState(observed) == 0 ||
        StateIsLocked(observed)) {
      return false;
    }
    const uint64_t desired = observed | kStateLockMask;
    if (!slot->state.compare_exchange_strong(
            observed, desired, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      return false;
    }
    *locked_state = desired;
    return true;
  }

  uint64_t NextGeneration() {
    const uint64_t ordinal =
        next_generation_.fetch_add(1, std::memory_order_acq_rel);
    return (ordinal % kGenerationMask) + 1;
  }

  void PublishRegistration(Slot* slot, uintptr_t source, uintptr_t engine,
                           const XAudioSourceFormat& format,
                           XAudioSourceSnapshot* registered) {
    const uint64_t generation = NextGeneration();
    slot->engine.store(engine, std::memory_order_relaxed);
    slot->format.Store(format);
    slot->last_start_ms.store(0, std::memory_order_relaxed);
    slot->state.store(PackState(generation, 1, false),
                      std::memory_order_release);
    slot->source.store(source, std::memory_order_release);
    if (registered != nullptr) {
      registered->source = source;
      registered->engine = engine;
      registered->generation = generation;
      registered->queue_generation = 1;
      registered->last_start_ms = 0;
      registered->started = false;
      registered->format = format;
    }
  }

  Slot slots_[Capacity];
  std::atomic<uint64_t> next_generation_{0};
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
