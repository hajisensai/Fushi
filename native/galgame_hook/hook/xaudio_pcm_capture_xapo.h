#ifndef FUSHI_VOICE_HOOK_XAUDIO_PCM_CAPTURE_XAPO_H_
#define FUSHI_VOICE_HOOK_XAUDIO_PCM_CAPTURE_XAPO_H_

#include <windows.h>
#include <xapobase.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "xaudio_source_format.h"

namespace fushi_voice_hook {

inline const XAPO_REGISTRATION_PROPERTIES kPcmCaptureXapoProperties = {
    {0x2e5fe37a, 0xf11d, 0x4f81,
     {0x94, 0x85, 0xc2, 0x0d, 0x5b, 0x0e, 0x55, 0x93}},
    L"Fushi XAudio PCM capture",
    L"Fushi",
    1,
    0,
    XAPO_FLAG_CHANNELS_MUST_MATCH | XAPO_FLAG_FRAMERATE_MUST_MATCH |
        XAPO_FLAG_BITSPERSAMPLE_MUST_MATCH |
        XAPO_FLAG_BUFFERCOUNT_MUST_MATCH | XAPO_FLAG_INPLACE_SUPPORTED,
    1,
    1,
    1,
    1,
};

struct XAudioPcmCaptureView {
  const uint8_t* bytes = nullptr;
  uint32_t byte_count = 0;
  uint32_t sample_rate = 0;
  uint32_t channels = 0;
  uint32_t bits_per_sample = 0;
  uint32_t is_float = 0;
  uint64_t first_process_timestamp_ms = 0;
};

// XAudio2 invokes this effect after it has decoded xWMA and before the source
// reaches the game mix.  Process is real-time safe: fixed virtual memory,
// atomics and bounded memcpy only.  Publishing into Fushi's shared ring waits
// until DestroyVoice has synchronously stopped all Process callbacks.
class XAudioPcmCaptureXapo final : public CXAPOBase {
 public:
  static constexpr uint32_t kCapacity = 4u * 1024u * 1024u;

  XAudioPcmCaptureXapo()
      : CXAPOBase(&kPcmCaptureXapoProperties),
        bytes_(static_cast<uint8_t*>(VirtualAlloc(
            nullptr, kCapacity, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE))) {}

  ~XAudioPcmCaptureXapo() override {
    if (bytes_ != nullptr) VirtualFree(bytes_, 0, MEM_RELEASE);
  }

  bool ready() const { return bytes_ != nullptr; }

  // SGRE submits xWMA with a cumulative decoded-byte table.  Runtime evidence
  // separates its phone/UI sounds (100/410/560 ms) from character utterances
  // (1.37--6.04 s).  Keep this classification beside the exact source voice so
  // no ADPCM or short UI clip can later win UserHook1's timestamp match.
  void ObserveWmaSubmission(uint32_t packet_count,
                            uint32_t decoded_bytes,
                            uint32_t sample_rate,
                            uint32_t channels,
                            uint32_t bits_per_sample) {
    InterlockedExchange(&classified_, 1);
    const uint64_t bytes_per_second =
        static_cast<uint64_t>(sample_rate) * channels * bits_per_sample / 8u;
    if (packet_count != 0 && decoded_bytes != 0 && bytes_per_second != 0 &&
        static_cast<uint64_t>(decoded_bytes) * 1000u >=
            bytes_per_second * 700u) {
      InterlockedExchange(&role_voice_candidate_, 1);
    }
  }

  uint32_t clip_flags() const {
    uint32_t flags = 0;
    if (InterlockedCompareExchange(
            const_cast<volatile LONG*>(&classified_), 0, 0) != 0) {
      flags |= kVoiceClipFlagClassified;
    }
    if (InterlockedCompareExchange(
            const_cast<volatile LONG*>(&role_voice_candidate_), 0, 0) != 0) {
      flags |= kVoiceClipFlagRoleVoice;
    }
    return flags;
  }

  STDMETHOD(LockForProcess)(
      UINT32 input_count,
      const XAPO_LOCKFORPROCESS_BUFFER_PARAMETERS* input,
      UINT32 output_count,
      const XAPO_LOCKFORPROCESS_BUFFER_PARAMETERS* output) override {
    const HRESULT hr = CXAPOBase::LockForProcess(
        input_count, input, output_count, output);
    if (FAILED(hr) || input_count != 1 || output_count != 1 ||
        input == nullptr || output == nullptr || input[0].pFormat == nullptr ||
        output[0].pFormat == nullptr) {
      return FAILED(hr) ? hr : E_INVALIDARG;
    }
    const WAVEFORMATEX* format = input[0].pFormat;
    sample_rate_ = format->nSamplesPerSec;
    channels_ = format->nChannels;
    bits_per_sample_ = format->wBitsPerSample;
    block_align_ = format->nBlockAlign;
    is_float_ = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT ? 1u : 0u;
    if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
        format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
      const auto* extensible =
          reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
      is_float_ = IsCanonicalWaveFormatSubtype(
                      extensible->SubFormat, WAVE_FORMAT_IEEE_FLOAT)
                      ? 1u
                      : 0u;
    }
    return sample_rate_ != 0 && channels_ != 0 && block_align_ != 0 &&
                   bits_per_sample_ != 0
               ? S_OK
               : E_INVALIDARG;
  }

  STDMETHOD_(void, Process)(
      UINT32 input_count,
      const XAPO_PROCESS_BUFFER_PARAMETERS* input,
      UINT32 output_count,
      XAPO_PROCESS_BUFFER_PARAMETERS* output,
      BOOL is_enabled) override {
    UNREFERENCED_PARAMETER(is_enabled);
    if (input_count != 1 || output_count != 1 || input == nullptr ||
        output == nullptr) {
      return;
    }
    const XAPO_PROCESS_BUFFER_PARAMETERS& source = input[0];
    XAPO_PROCESS_BUFFER_PARAMETERS& destination = output[0];
    destination.ValidFrameCount = source.ValidFrameCount;
    destination.BufferFlags = source.BufferFlags;
    if (source.BufferFlags != XAPO_BUFFER_VALID || source.pBuffer == nullptr ||
        destination.pBuffer == nullptr || source.ValidFrameCount == 0 ||
        block_align_ == 0) {
      return;
    }

    const uint64_t byte_count =
        static_cast<uint64_t>(source.ValidFrameCount) * block_align_;
    if (byte_count <= kCapacity) {
      const LONG64 end = InterlockedAdd64(
          &written_, static_cast<LONG64>(byte_count));
      const uint64_t begin =
          static_cast<uint64_t>(end) - static_cast<uint64_t>(byte_count);
      if (begin + byte_count <= kCapacity && bytes_ != nullptr) {
        if (InterlockedCompareExchange64(&first_process_timestamp_ms_, 0, 0) ==
            0) {
          InterlockedCompareExchange64(
              &first_process_timestamp_ms_,
              static_cast<LONG64>(GetTickCount64()), 0);
        }
        std::memcpy(bytes_ + begin, source.pBuffer,
                    static_cast<size_t>(byte_count));
      } else {
        InterlockedExchange(&overflowed_, 1);
      }
    } else {
      InterlockedExchange(&overflowed_, 1);
    }

    if (destination.pBuffer != source.pBuffer) {
      std::memcpy(destination.pBuffer, source.pBuffer,
                  static_cast<size_t>(byte_count));
    }
  }

  bool GetCapture(XAudioPcmCaptureView* capture) const {
    if (capture == nullptr || bytes_ == nullptr ||
        InterlockedCompareExchange(
            const_cast<volatile LONG*>(&overflowed_), 0, 0) != 0) {
      return false;
    }
    const LONG64 written = InterlockedCompareExchange64(
        const_cast<volatile LONG64*>(&written_), 0, 0);
    if (written <= 0 || static_cast<uint64_t>(written) > kCapacity) {
      return false;
    }
    capture->bytes = bytes_;
    capture->byte_count = static_cast<uint32_t>(written);
    capture->sample_rate = sample_rate_;
    capture->channels = channels_;
    capture->bits_per_sample = bits_per_sample_;
    capture->is_float = is_float_;
    capture->first_process_timestamp_ms = static_cast<uint64_t>(
        InterlockedCompareExchange64(
            const_cast<volatile LONG64*>(&first_process_timestamp_ms_), 0,
            0));
    return true;
  }

 private:
  uint8_t* bytes_ = nullptr;
  volatile LONG64 written_ = 0;
  volatile LONG64 first_process_timestamp_ms_ = 0;
  volatile LONG overflowed_ = 0;
  volatile LONG classified_ = 0;
  volatile LONG role_voice_candidate_ = 0;
  uint32_t sample_rate_ = 0;
  uint32_t channels_ = 0;
  uint32_t bits_per_sample_ = 0;
  uint32_t block_align_ = 0;
  uint32_t is_float_ = 0;
};

}  // namespace fushi_voice_hook

#endif  // FUSHI_VOICE_HOOK_XAUDIO_PCM_CAPTURE_XAPO_H_
