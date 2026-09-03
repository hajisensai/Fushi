#ifndef FUSHI_VOICE_HOOK_XAUDIO_TRACE_H_
#define FUSHI_VOICE_HOOK_XAUDIO_TRACE_H_

#include <windows.h>
#include <mmreg.h>
#include <xaudio2.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>

namespace fushi_voice_hook {

// This diagnostic ABI is intentionally separate from SharedHeader.  A probe
// locates the exported object in the remote hook DLL by PE export RVA and reads
// it with ReadProcessMemory, so adding trace fields never changes the host IPC
// layout or protocol version.
constexpr uint32_t kXAudioTraceMagic = 0x58545243u;  // "XTRC"
constexpr uint32_t kXAudioTraceVersion = 1;
constexpr uint32_t kXAudioTraceCapacity = 2048;
constexpr uint32_t kXAudioTraceExtraPrefixBytes = 32;
constexpr uint32_t kXAudioTraceAdpcmCoefficientCount = 32;
constexpr char kXAudioTraceExportName[] = "FushiXAudioTraceV1";

enum class XAudioTraceEventKind : uint32_t {
  kCreate = 1,
  kSubmit = 2,
  kStart = 3,
  kStop = 4,
  kFlush = 5,
  kDestroy = 6,
  kCommit = 7,
  kWorkerWait = 8,
  kWorkerPublish = 9,
  kWorkerInvalidate = 10,
};

// One field covers the final disposition of an event.  Numeric stability is
// useful when a newer probe reads an older DLL, so append rather than reorder.
enum class XAudioTraceOutcome : uint32_t {
  kNone = 0,
  kSucceeded = 1,
  kOriginalFailed = 2,
  kFormatUnsupported = 3,
  kRegistryRegistered = 4,
  kRegistryExhausted = 5,
  kLookupMiss = 6,
  kQueued = 7,
  kRejectedNullBuffer = 8,
  kRejectedNullAudioData = 9,
  kRejectedZeroBytes = 10,
  kRejectedTooLarge = 11,
  kRejectedQueueNotReady = 12,
  kRejectedDescriptorExhausted = 13,
  kRejectedArenaExhausted = 14,
  kRejectedCopyFailed = 15,
  kCaptureDisabled = 16,
  kImmediateApplied = 17,
  kDeferredStaged = 18,
  kDeferredStageFailed = 19,
  kDeferredApplied = 20,
  kDeferredInvalidated = 21,
  kQueueGenerationAdvanced = 22,
  kWaitingForStart = 23,
  kPublished = 24,
  kStaleInvalidated = 25,
  kDecodeRejected = 26,
  kCommitQueued = 27,
  kCommitApplied = 28,
  kCommitQueueExhausted = 29,
};

enum class XAudioTraceLookupResult : uint32_t {
  kNotAttempted = 0,
  kRegistered = 1,
  kMissing = 2,
};

enum class XAudioTraceCommitPhase : uint32_t {
  kObserved = 1,
  kApplied = 2,
};

struct XAudioTraceFormat {
  uint32_t present = 0;
  uint32_t parse_succeeded = 0;
  uint32_t normalized_encoding = 0;

  // Complete WAVEFORMATEX base fields, widened to fixed-width integers so this
  // exported layout is identical in x86 and x64 DLLs.
  uint32_t format_tag = 0;
  uint32_t channels = 0;
  uint32_t samples_per_sec = 0;
  uint32_t avg_bytes_per_sec = 0;
  uint32_t block_align = 0;
  uint32_t bits_per_sample = 0;
  uint32_t cb_size = 0;

  // WAVEFORMATEXTENSIBLE metadata.  GUID fields are kept separately to avoid
  // depending on compiler-specific GUID packing in the exported ABI.
  uint32_t extensible_valid_bits = 0;
  uint32_t extensible_channel_mask = 0;
  uint32_t subformat_data1 = 0;
  uint32_t subformat_data2 = 0;
  uint32_t subformat_data3 = 0;
  uint8_t subformat_data4[8] = {};

  // A bounded prefix makes custom/xWMA extra data identifiable without ever
  // retaining an unbounded caller pointer.  Microsoft ADPCM metadata is also
  // decoded into numeric fields, including every coefficient accepted by the
  // production parser.
  uint32_t extra_bytes_copied = 0;
  uint8_t extra_prefix[kXAudioTraceExtraPrefixBytes] = {};
  uint32_t adpcm_samples_per_block = 0;
  uint32_t adpcm_coefficient_count = 0;
  uint32_t adpcm_coefficients_copied = 0;
  int16_t adpcm_coefficients[kXAudioTraceAdpcmCoefficientCount][2] = {};
};

struct alignas(8) XAudioTraceEvent {
  uint64_t timestamp_ms = 0;
  uint64_t thread_id = 0;
  uint64_t source = 0;
  uint64_t engine = 0;
  uint64_t source_generation = 0;
  uint64_t queue_generation = 0;
  uint64_t submit_timestamp_ms = 0;

  uint32_t kind = 0;
  uint32_t outcome = 0;
  int32_t hresult = 0;
  uint32_t operation_set = 0;
  uint32_t buffer_flags = 0;
  uint32_t audio_bytes = 0;
  uint32_t play_begin = 0;
  uint32_t play_length = 0;
  uint32_t wma_present = 0;
  uint32_t wma_packet_count = 0;
  uint32_t wma_decoded_range_present = 0;
  uint32_t wma_first_decoded_bytes = 0;
  uint32_t wma_last_decoded_bytes = 0;
  uint32_t buffer_context_present = 0;
  // Event-specific numeric details.  Submit uses lookup/staging rejection/
  // stale-after-submit; Commit uses phase/matched/applied; worker uses
  // decoded/published byte data.
  uint32_t detail0 = 0;
  uint32_t detail1 = 0;
  uint32_t detail2 = 0;

  XAudioTraceFormat format;

  // Publication marker.  Producers write every other field first and publish
  // this value last with InterlockedExchange64.  Readers accept a slot only if
  // it equals the expected global sequence before and after the remote read.
  volatile uint64_t sequence = 0;
};

struct alignas(8) XAudioTraceSlot {
  // Try-claim only: a producer that encounters a busy wrap slot increments the
  // dropped counter and returns immediately.  No callback waits or spins, and
  // two producers can never memcpy the same payload concurrently.
  volatile LONG writing = 0;
  uint32_t reserved = 0;
  XAudioTraceEvent event;
};

struct alignas(8) XAudioTraceBuffer {
  uint32_t magic = kXAudioTraceMagic;
  uint32_t version = kXAudioTraceVersion;
  uint32_t event_size = sizeof(XAudioTraceEvent);
  uint32_t slot_size = sizeof(XAudioTraceSlot);
  uint32_t capacity = kXAudioTraceCapacity;
  uint32_t reserved = 0;
  alignas(8) volatile LONG64 next_sequence = 0;
  alignas(8) volatile LONG64 dropped_busy = 0;
  XAudioTraceSlot slots[kXAudioTraceCapacity] = {};
};

static_assert(offsetof(XAudioTraceEvent, sequence) + sizeof(uint64_t) ==
                  sizeof(XAudioTraceEvent),
              "XAudio trace sequence must be the final published field");
static_assert(std::is_standard_layout<XAudioTraceFormat>::value &&
                  std::is_trivially_copyable<XAudioTraceFormat>::value,
              "XAudio trace format must be a plain cross-process ABI");
static_assert(std::is_standard_layout<XAudioTraceEvent>::value &&
                  std::is_trivially_copyable<XAudioTraceEvent>::value,
              "XAudio trace event must be a plain cross-process ABI");
static_assert(sizeof(XAudioTraceFormat) == 244,
              "XAudio trace format ABI changed; bump its version");
static_assert(offsetof(XAudioTraceEvent, format) == 124,
              "XAudio trace format offset changed; bump its version");
static_assert(offsetof(XAudioTraceEvent, sequence) == 368,
              "XAudio trace sequence offset changed; bump its version");
static_assert(sizeof(XAudioTraceEvent) == 376,
              "XAudio trace event ABI changed; bump its version");
static_assert(offsetof(XAudioTraceSlot, event) == 8,
              "XAudio trace slot payload offset changed; bump its version");
static_assert(sizeof(XAudioTraceSlot) == 384,
              "XAudio trace slot ABI changed; bump its version");
static_assert(offsetof(XAudioTraceBuffer, slots) == 40,
              "XAudio trace header ABI changed; bump its version");
static_assert(sizeof(XAudioTraceBuffer) == 786472,
              "XAudio trace buffer ABI changed; bump its version");
static_assert(alignof(XAudioTraceEvent) >= 8,
              "XAudio trace event publication must be 64-bit aligned");
static_assert(alignof(XAudioTraceBuffer) >= 8,
              "XAudio trace counter must be 64-bit aligned");
static_assert(offsetof(XAudioTraceSlot, event) % alignof(XAudioTraceEvent) == 0,
              "XAudio trace event must stay naturally aligned in its slot");

inline XAudioTraceEvent MakeXAudioTraceEvent(XAudioTraceEventKind kind) {
  XAudioTraceEvent event;
  event.timestamp_ms = GetTickCount64();
  event.thread_id = GetCurrentThreadId();
  event.kind = static_cast<uint32_t>(kind);
  return event;
}

inline void CaptureXAudioTraceWma(const XAUDIO2_BUFFER_WMA* source,
                                  XAudioTraceEvent* destination) {
  if (source == nullptr || destination == nullptr) return;
  destination->wma_present = 1;
  destination->wma_packet_count = source->PacketCount;
  // XAudio2 owns no copy of this caller table before SubmitSourceBuffer.  Take
  // the two bounded numeric samples while the caller still owns it, and never
  // index an absent or empty table.  These endpoints expose cumulative-table
  // shape/decoded total without retaining a pointer or copying PacketCount
  // elements into the fixed trace ABI.
  if (source->pDecodedPacketCumulativeBytes == nullptr ||
      source->PacketCount == 0) {
    return;
  }
  destination->wma_decoded_range_present = 1;
  destination->wma_first_decoded_bytes =
      source->pDecodedPacketCumulativeBytes[0];
  destination->wma_last_decoded_bytes =
      source->pDecodedPacketCumulativeBytes[source->PacketCount - 1u];
}

inline void CaptureXAudioTraceFormat(const WAVEFORMATEX* source,
                                     bool parse_succeeded,
                                     uint32_t normalized_encoding,
                                     XAudioTraceFormat* destination) {
  if (destination == nullptr) return;
  *destination = XAudioTraceFormat{};
  if (source == nullptr) return;

  destination->present = 1;
  destination->parse_succeeded = parse_succeeded ? 1u : 0u;
  destination->normalized_encoding = normalized_encoding;
  destination->format_tag = source->wFormatTag;
  destination->channels = source->nChannels;
  destination->samples_per_sec = source->nSamplesPerSec;
  destination->avg_bytes_per_sec = source->nAvgBytesPerSec;
  destination->block_align = source->nBlockAlign;
  destination->bits_per_sample = source->wBitsPerSample;
  destination->cb_size = source->cbSize;

  const uint8_t* extra = reinterpret_cast<const uint8_t*>(source) +
                         sizeof(WAVEFORMATEX);
  destination->extra_bytes_copied = (std::min)(
      static_cast<uint32_t>(source->cbSize), kXAudioTraceExtraPrefixBytes);
  if (destination->extra_bytes_copied != 0) {
    std::memcpy(destination->extra_prefix, extra,
                destination->extra_bytes_copied);
  }

  constexpr uint32_t kExtensibleExtraBytes =
      sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
  if (source->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      source->cbSize >= kExtensibleExtraBytes) {
    const auto* extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(source);
    destination->extensible_valid_bits =
        extensible->Samples.wValidBitsPerSample;
    destination->extensible_channel_mask = extensible->dwChannelMask;
    destination->subformat_data1 = extensible->SubFormat.Data1;
    destination->subformat_data2 = extensible->SubFormat.Data2;
    destination->subformat_data3 = extensible->SubFormat.Data3;
    std::memcpy(destination->subformat_data4, extensible->SubFormat.Data4,
                sizeof(destination->subformat_data4));
  }

  if (source->wFormatTag != WAVE_FORMAT_ADPCM || source->cbSize < 4) {
    return;
  }
  uint16_t samples_per_block = 0;
  uint16_t coefficient_count = 0;
  std::memcpy(&samples_per_block, extra, sizeof(samples_per_block));
  std::memcpy(&coefficient_count, extra + 2, sizeof(coefficient_count));
  destination->adpcm_samples_per_block = samples_per_block;
  destination->adpcm_coefficient_count = coefficient_count;
  const uint32_t available_coefficients =
      (static_cast<uint32_t>(source->cbSize) - 4u) / 4u;
  destination->adpcm_coefficients_copied = (std::min)(
      (std::min)(static_cast<uint32_t>(coefficient_count),
                 available_coefficients),
      kXAudioTraceAdpcmCoefficientCount);
  for (uint32_t i = 0; i < destination->adpcm_coefficients_copied; ++i) {
    std::memcpy(&destination->adpcm_coefficients[i][0], extra + 4 + i * 4, 2);
    std::memcpy(&destination->adpcm_coefficients[i][1], extra + 6 + i * 4, 2);
  }
}

// Multi-producer, nonblocking publication used directly by XAudio2 API detours.
// It performs one atomic sequence reservation, one try-claim, bounded numeric
// memcpy, and one final atomic publication.  It never waits, allocates, takes a
// mutex/critical section, logs, decodes, or does file/network IPC.  A busy wrap
// slot is dropped rather than allowing two callback writers to race over the
// same numeric payload.
inline uint64_t PublishXAudioTraceEvent(XAudioTraceBuffer* trace,
                                        const XAudioTraceEvent& event) {
  if (trace == nullptr || trace->magic != kXAudioTraceMagic ||
      trace->version != kXAudioTraceVersion ||
      trace->event_size != sizeof(XAudioTraceEvent) ||
      trace->slot_size != sizeof(XAudioTraceSlot) ||
      trace->capacity != kXAudioTraceCapacity) {
    return 0;
  }
  const uint64_t sequence = static_cast<uint64_t>(
      InterlockedIncrement64(&trace->next_sequence));
  XAudioTraceSlot* slot =
      &trace->slots[(sequence - 1u) % kXAudioTraceCapacity];
  if (InterlockedCompareExchange(&slot->writing, 1, 0) != 0) {
    InterlockedIncrement64(&trace->dropped_busy);
    return 0;
  }
  InterlockedExchange64(
      reinterpret_cast<volatile LONG64*>(&slot->event.sequence), 0);
  std::memcpy(&slot->event, &event, offsetof(XAudioTraceEvent, sequence));
  MemoryBarrier();
  InterlockedExchange64(
      reinterpret_cast<volatile LONG64*>(&slot->event.sequence),
      static_cast<LONG64>(sequence));
  InterlockedExchange(&slot->writing, 0);
  return sequence;
}

}  // namespace fushi_voice_hook

// The object is defined exactly once by hook/dll_main.cpp before the adapter
// include that publishes into it.  No extern declaration belongs here: MSVC
// treats a later dllexport definition as a conflicting storage class, while
// the probe deliberately resolves the C export name without linking to it.

#endif  // FUSHI_VOICE_HOOK_XAUDIO_TRACE_H_
