#pragma once

#include <cstddef>
#include <cstdint>

#include "xaudio_source_format.h"

namespace fushi_voice_hook {

// Stable worker-side seam between generic XAudio capture and an engine
// profile that can prove a compressed submission belongs to a voice archive.
// The SubmitSourceBuffer detour only copies bytes into the bounded arena; this
// handler is invoked later on HookWorker, where archive IO is permitted.
struct XAudioCompressedResourceSubmission {
  XAudioSourceSnapshot source;
  const uint8_t* payload = nullptr;
  uint32_t payload_bytes = 0;
  const uint8_t* packet_cumulative_bytes = nullptr;
  uint32_t packet_count = 0;
  uint64_t playback_timestamp_ms = 0;
};

using XAudioCompressedResourceHandler = bool (*)(
    const XAudioCompressedResourceSubmission& submission);

class XAudioCompressedResourceDispatch {
 public:
  bool Register(XAudioCompressedResourceHandler handler) {
    if (handler == nullptr || handler_ != nullptr) return false;
    handler_ = handler;
    return true;
  }

  void Unregister(XAudioCompressedResourceHandler handler) {
    if (handler_ == handler) handler_ = nullptr;
  }

  bool available() const { return handler_ != nullptr; }

  bool Dispatch(const XAudioCompressedResourceSubmission& submission) const {
    return handler_ != nullptr && handler_(submission);
  }

 private:
  XAudioCompressedResourceHandler handler_ = nullptr;
};

}  // namespace fushi_voice_hook
