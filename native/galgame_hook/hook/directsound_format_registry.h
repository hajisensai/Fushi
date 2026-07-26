#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>

namespace hibiki_voice_hook {

struct DirectSoundPcmFormat {
  uint32_t sample_rate = 0;
  uint32_t channels = 0;
  uint32_t bits_per_sample = 0;
  uint32_t is_float = 0;
};

// SetFrequency changes a DirectSound buffer's effective playback sample rate
// without changing its creation-time WAVEFORMATEX. Registration runs outside
// the audio callback; lookup and frequency updates stay bounded and lock-free.
template <size_t Capacity>
class DirectSoundFormatRegistry {
 public:
  static_assert(Capacity >= 2, "registry needs at least two slots");
  static_assert((Capacity & (Capacity - 1)) == 0,
                "registry capacity must be a power of two");
  static_assert(std::atomic<uintptr_t>::is_always_lock_free,
                "source lookup must stay lock-free");
  static_assert(std::atomic<uint32_t>::is_always_lock_free,
                "format lookup must stay lock-free");

  bool Register(uintptr_t source, const DirectSoundPcmFormat& format) {
    if (!IsValidSource(source) || !IsValidFormat(format)) {
      return false;
    }

    const size_t start = StartIndex(source);
    for (size_t probe = 0; probe < kProbeLimit; ++probe) {
      Slot& slot = slots_[(start + probe) & (Capacity - 1)];
      uintptr_t observed = slot.source.load(std::memory_order_acquire);
      if (observed != source && observed != kEmpty) {
        continue;
      }
      if (!slot.source.compare_exchange_strong(
              observed, kWriting, std::memory_order_acq_rel,
              std::memory_order_acquire)) {
        continue;
      }
      Publish(slot, source, format);
      return true;
    }
    return false;
  }

  bool SetFrequency(uintptr_t source, uint32_t requested_rate) {
    if (!IsValidSource(source)) {
      return false;
    }

    const size_t start = StartIndex(source);
    for (size_t probe = 0; probe < kProbeLimit; ++probe) {
      Slot& slot = slots_[(start + probe) & (Capacity - 1)];
      if (slot.source.load(std::memory_order_acquire) != source) {
        continue;
      }
      const uint32_t base_rate =
          slot.base_sample_rate.load(std::memory_order_relaxed);
      slot.effective_sample_rate.store(
          requested_rate == 0 ? base_rate : requested_rate,
          std::memory_order_release);
      return slot.source.load(std::memory_order_acquire) == source;
    }
    return false;
  }

  bool Lookup(uintptr_t source, DirectSoundPcmFormat* format) const {
    if (!IsValidSource(source) || format == nullptr) {
      return false;
    }

    const size_t start = StartIndex(source);
    for (size_t probe = 0; probe < kProbeLimit; ++probe) {
      const Slot& slot = slots_[(start + probe) & (Capacity - 1)];
      if (slot.source.load(std::memory_order_acquire) != source) {
        continue;
      }

      DirectSoundPcmFormat snapshot;
      snapshot.sample_rate =
          slot.effective_sample_rate.load(std::memory_order_acquire);
      snapshot.channels = slot.channels.load(std::memory_order_relaxed);
      snapshot.bits_per_sample =
          slot.bits_per_sample.load(std::memory_order_relaxed);
      snapshot.is_float = slot.is_float.load(std::memory_order_relaxed);
      if (slot.source.load(std::memory_order_acquire) != source ||
          !IsValidFormat(snapshot)) {
        return false;
      }
      *format = snapshot;
      return true;
    }
    return false;
  }

 private:
  static constexpr uintptr_t kEmpty = 0;
  static constexpr uintptr_t kWriting = 1;
  static constexpr size_t kProbeLimit = Capacity < 16 ? Capacity : 16;

  struct Slot {
    std::atomic<uintptr_t> source{kEmpty};
    std::atomic<uint32_t> base_sample_rate{0};
    std::atomic<uint32_t> effective_sample_rate{0};
    std::atomic<uint32_t> channels{0};
    std::atomic<uint32_t> bits_per_sample{0};
    std::atomic<uint32_t> is_float{0};
  };

  static bool IsValidSource(uintptr_t source) {
    return source != kEmpty && source != kWriting;
  }

  static bool IsValidFormat(const DirectSoundPcmFormat& format) {
    return format.sample_rate != 0 && format.channels != 0 &&
           format.bits_per_sample != 0;
  }

  static size_t StartIndex(uintptr_t source) {
    uintptr_t mixed = source >> 4;
    mixed ^= mixed >> 17;
    mixed *= static_cast<uintptr_t>(0x9E3779B1u);
    mixed ^= mixed >> 11;
    return static_cast<size_t>(mixed) & (Capacity - 1);
  }

  static void Publish(Slot& slot, uintptr_t source,
                      const DirectSoundPcmFormat& format) {
    slot.base_sample_rate.store(format.sample_rate,
                                std::memory_order_relaxed);
    slot.effective_sample_rate.store(format.sample_rate,
                                     std::memory_order_relaxed);
    slot.channels.store(format.channels, std::memory_order_relaxed);
    slot.bits_per_sample.store(format.bits_per_sample,
                               std::memory_order_relaxed);
    slot.is_float.store(format.is_float, std::memory_order_relaxed);
    slot.source.store(source, std::memory_order_release);
  }

  Slot slots_[Capacity];
};

}  // namespace hibiki_voice_hook
