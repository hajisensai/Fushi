// P1 split: included inside dll_main.cpp's anonymous namespace.
//
// XAudio2 callbacks must not allocate, lock, log, decode, or touch the file
// system.  The old layout violated the useful part of that contract indirectly:
// four fixed 8 MiB slots meant a burst of hundreds of small ADPCM buffers
// silently retained only four.  Keep the same 32 MiB budget, but divide it into
// pages and let 1024 preallocated descriptors share those pages by actual byte
// occupancy.  HookWorker is the only decoder/consumer.
fushi_voice_hook::XAudioSourceFormatRegistry<512> g_xaudio_formats;
fushi_voice_hook::XAudioCompressedResourceDispatch
    g_xaudio_compressed_resource_dispatch;

bool RegisterXAudioCompressedResourceHandler(
    fushi_voice_hook::XAudioCompressedResourceHandler handler) {
  return g_xaudio_compressed_resource_dispatch.Register(handler);
}

void UnregisterXAudioCompressedResourceHandler(
    fushi_voice_hook::XAudioCompressedResourceHandler handler) {
  g_xaudio_compressed_resource_dispatch.Unregister(handler);
}

bool HasXAudioCompressedResourceHandler() {
  return g_xaudio_compressed_resource_dispatch.available();
}

constexpr size_t kXAudioCaptureJobCount = 1024;
constexpr uint32_t kXAudioCaptureArenaBytes = 32u * 1024u * 1024u;
constexpr uint32_t kXAudioCapturePageBytes = 16u * 1024u;
constexpr uint32_t kXAudioCapturePageCount =
    kXAudioCaptureArenaBytes / kXAudioCapturePageBytes;
constexpr uint32_t kMaxXAudioCaptureBytes = 8u * 1024u * 1024u;
constexpr uint32_t kInvalidXAudioPage = std::numeric_limits<uint32_t>::max();
constexpr size_t kXAudioDeferredOperationCount = 1024;
constexpr size_t kXAudioCommitEventCount = 1024;
static_assert(kXAudioCaptureArenaBytes % kXAudioCapturePageBytes == 0,
              "XAudio capture arena must be page aligned");

enum class XAudioDeferredOperationKind : uint32_t {
  kStart = 1,
  kStop = 2,
};

struct alignas(8) XAudioCaptureCounters {
  volatile LONG64 submit_succeeded = 0;
  volatile LONG64 submit_failed = 0;
  volatile LONG64 jobs_queued = 0;
  volatile LONG64 descriptor_exhausted = 0;
  volatile LONG64 arena_exhausted = 0;
  volatile LONG64 buffer_rejected = 0;
  volatile LONG64 registry_miss = 0;
  volatile LONG64 stale_invalidated = 0;
  volatile LONG64 decode_rejected = 0;
  volatile LONG64 pcm_published = 0;
  volatile LONG64 flush_observed = 0;
  volatile LONG64 destroy_observed = 0;
  volatile LONG64 deferred_queued = 0;
  volatile LONG64 deferred_exhausted = 0;
  volatile LONG64 commit_events_queued = 0;
  volatile LONG64 commit_events_exhausted = 0;
  volatile LONG64 commits_succeeded = 0;
  volatile LONG64 commits_failed = 0;
  volatile LONG64 unsupported_format = 0;
  volatile LONG64 registry_exhausted = 0;
  volatile LONG64 arena_bytes_in_use = 0;
  volatile LONG64 arena_high_water_bytes = 0;
};

struct XAudioCapturePage {
  std::atomic<uint32_t> next{kInvalidXAudioPage};
};

struct XAudioCaptureJob {
  volatile LONG state = 0;  // 0=free, 1=writing, 2=ready, 3=processing
  uint32_t first_page = kInvalidXAudioPage;
  uint32_t page_count = 0;
  uint32_t encoded_bytes = 0;
  // Arena occupancy includes the original xWMA `dpds` table after the audio
  // bytes. For PCM/ADPCM this equals encoded_bytes.
  uint32_t stored_bytes = 0;
  uint32_t play_begin = 0;
  uint32_t play_length = 0;
  uint32_t wma_packet_count = 0;
  uint32_t wma_decoded_bytes = 0;
  uint64_t submit_timestamp_ms = 0;
  uint64_t playback_timestamp_hint_ms = 0;
  uint32_t wait_trace_emitted = 0;
  fushi_voice_hook::XAudioSourceSnapshot source;
};

struct XAudioDeferredOperation {
  // 0=free, 1=writing, 2=staged around original call, 3=ready, 4=processing
  volatile LONG state = 0;
  uint64_t sequence = 0;
  uintptr_t engine = 0;
  uintptr_t source = 0;
  uint64_t source_generation = 0;
  uint32_t operation_set = 0;
  XAudioDeferredOperationKind kind = XAudioDeferredOperationKind::kStart;
};

struct XAudioCommitEvent {
  volatile LONG state = 0;  // 0=free, 1=writing, 2=ready, 3=processing
  uint64_t sequence = 0;
  uint64_t operation_sequence_fence = 0;
  uint64_t timestamp_ms = 0;
  uintptr_t engine = 0;
  uint32_t operation_set = 0;
};

XAudioCaptureCounters g_xaudio_capture_counters;
XAudioCapturePage g_xaudio_capture_pages[kXAudioCapturePageCount];
XAudioCaptureJob g_xaudio_capture_jobs[kXAudioCaptureJobCount];
XAudioDeferredOperation
    g_xaudio_deferred_operations[kXAudioDeferredOperationCount];
XAudioCommitEvent g_xaudio_commit_events[kXAudioCommitEventCount];
uint8_t* g_xaudio_capture_arena = nullptr;
alignas(8) volatile LONG64 g_xaudio_free_page_head = 0;
alignas(8) volatile LONG64 g_xaudio_deferred_sequence = 0;
alignas(8) volatile LONG64 g_xaudio_commit_sequence = 0;
volatile LONG g_xaudio_deferred_producers = 0;
volatile LONG g_xaudio_control_consumer = 0;
volatile LONG g_xaudio_capture_queue_state = 0;  // 0=off, 1=init, 2=ready

void DrainXAudioControlEvents();

void SetXAudioDiagnostic(uint32_t diagnostic) {
  if (g_header == nullptr) return;
  InterlockedOr(
      reinterpret_cast<volatile LONG*>(&g_header->xaudio_diagnostics),
      static_cast<LONG>(diagnostic));
}

// v20 起的第二个引擎诊断字。第一个字的 32 位已满（低 27 位既有 + HUNEX HFA 高 5 位），
// 见 voice_hook_ipc.h 的 (c) 段。位常量前缀是 kXAudioDiag2*，别和 kXAudioDiag* 混用：
// 用错设置器不会编译报错，只会让那一档诊断恒 0，真机看位才发现得了。
void SetXAudioDiagnostic2(uint32_t diagnostic) {
  if (g_header == nullptr) return;
  InterlockedOr(
      reinterpret_cast<volatile LONG*>(&g_header->xaudio_diagnostics2),
      static_cast<LONG>(diagnostic));
}

void IncrementXAudioCounter(volatile LONG64* counter) {
  InterlockedIncrement64(counter);
}

void PublishXAudioTrace(fushi_voice_hook::XAudioTraceEvent* event) {
  if (event == nullptr) return;
  if (event->timestamp_ms == 0) event->timestamp_ms = GetTickCount64();
  if (event->thread_id == 0) event->thread_id = GetCurrentThreadId();
  fushi_voice_hook::PublishXAudioTraceEvent(&FushiXAudioTraceV1, *event);
}

fushi_voice_hook::XAudioTraceEvent MakeXAudioSourceTrace(
    fushi_voice_hook::XAudioTraceEventKind kind,
    const fushi_voice_hook::XAudioSourceSnapshot* source = nullptr) {
  fushi_voice_hook::XAudioTraceEvent event =
      fushi_voice_hook::MakeXAudioTraceEvent(kind);
  if (source != nullptr) {
    event.source = source->source;
    event.engine = source->engine;
    event.source_generation = source->generation;
    event.queue_generation = source->queue_generation;
  }
  return event;
}

void CaptureNormalizedXAudioTraceFormat(
    const fushi_voice_hook::XAudioSourceFormat& source,
    fushi_voice_hook::XAudioTraceFormat* destination) {
  if (destination == nullptr) return;
  destination->present = 1;
  destination->parse_succeeded = 1;
  destination->normalized_encoding =
      static_cast<uint32_t>(source.encoding);
  destination->samples_per_sec = source.sample_rate;
  destination->channels = source.channels;
  destination->bits_per_sample = source.bits_per_sample;
  destination->block_align = source.block_align;
  destination->adpcm_samples_per_block = source.samples_per_block;
  destination->adpcm_coefficient_count = source.coefficient_count;
  destination->adpcm_coefficients_copied = (std::min)(
      source.coefficient_count,
      fushi_voice_hook::kXAudioTraceAdpcmCoefficientCount);
  for (uint32_t i = 0; i < destination->adpcm_coefficients_copied; ++i) {
    destination->adpcm_coefficients[i][0] = source.coefficients[i].first;
    destination->adpcm_coefficients[i][1] = source.coefficients[i].second;
  }
}

void PublishXAudioWorkerTrace(
    fushi_voice_hook::XAudioTraceEventKind kind,
    fushi_voice_hook::XAudioTraceOutcome outcome,
    const XAudioCaptureJob& job, uint32_t detail0 = 0,
    uint32_t detail1 = 0) {
  fushi_voice_hook::XAudioTraceEvent event =
      MakeXAudioSourceTrace(kind, &job.source);
  event.outcome = static_cast<uint32_t>(outcome);
  event.submit_timestamp_ms = job.submit_timestamp_ms;
  event.audio_bytes = job.encoded_bytes;
  event.play_begin = job.play_begin;
  event.play_length = job.play_length;
  event.detail0 = detail0;
  event.detail1 = detail1;
  CaptureNormalizedXAudioTraceFormat(job.source.format, &event.format);
  PublishXAudioTrace(&event);
}

uint64_t PackXAudioPageHead(uint32_t tag, uint32_t page) {
  return (static_cast<uint64_t>(tag) << 32) | page;
}

uint32_t XAudioPageFromHead(uint64_t head) {
  return static_cast<uint32_t>(head);
}

uint32_t XAudioTagFromHead(uint64_t head) {
  return static_cast<uint32_t>(head >> 32);
}

uint64_t LoadXAudioPageHead() {
  return static_cast<uint64_t>(InterlockedCompareExchange64(
      &g_xaudio_free_page_head, 0, 0));
}

bool PopXAudioCapturePage(uint32_t* page) {
  if (page == nullptr) return false;
  uint64_t observed = LoadXAudioPageHead();
  for (;;) {
    const uint32_t index = XAudioPageFromHead(observed);
    if (index == kInvalidXAudioPage) return false;
    const uint32_t next =
        g_xaudio_capture_pages[index].next.load(std::memory_order_relaxed);
    const uint64_t desired = PackXAudioPageHead(
        XAudioTagFromHead(observed) + 1u, next);
    const uint64_t exchanged = static_cast<uint64_t>(
        InterlockedCompareExchange64(
            &g_xaudio_free_page_head, static_cast<LONG64>(desired),
            static_cast<LONG64>(observed)));
    if (exchanged == observed) {
      *page = index;
      return true;
    }
    observed = exchanged;
  }
}

void PushXAudioCapturePage(uint32_t page) {
  if (page >= kXAudioCapturePageCount) return;
  uint64_t observed = LoadXAudioPageHead();
  for (;;) {
    g_xaudio_capture_pages[page].next.store(XAudioPageFromHead(observed),
                                             std::memory_order_relaxed);
    const uint64_t desired = PackXAudioPageHead(
        XAudioTagFromHead(observed) + 1u, page);
    const uint64_t exchanged = static_cast<uint64_t>(
        InterlockedCompareExchange64(
            &g_xaudio_free_page_head, static_cast<LONG64>(desired),
            static_cast<LONG64>(observed)));
    if (exchanged == observed) return;
    observed = exchanged;
  }
}

void ReleaseXAudioCapturePages(uint32_t first_page, uint32_t page_count) {
  uint32_t page = first_page;
  for (uint32_t i = 0; i < page_count && page != kInvalidXAudioPage; ++i) {
    const uint32_t next =
        g_xaudio_capture_pages[page].next.load(std::memory_order_relaxed);
    PushXAudioCapturePage(page);
    page = next;
  }
}

bool ReserveXAudioCapturePages(uint32_t page_count, uint32_t* first_page) {
  if (page_count == 0 || first_page == nullptr) return false;
  uint32_t first = kInvalidXAudioPage;
  uint32_t last = kInvalidXAudioPage;
  uint32_t reserved = 0;
  while (reserved < page_count) {
    uint32_t page = kInvalidXAudioPage;
    if (!PopXAudioCapturePage(&page)) {
      ReleaseXAudioCapturePages(first, reserved);
      return false;
    }
    g_xaudio_capture_pages[page].next.store(kInvalidXAudioPage,
                                             std::memory_order_relaxed);
    if (last == kInvalidXAudioPage) {
      first = page;
    } else {
      g_xaudio_capture_pages[last].next.store(page,
                                               std::memory_order_relaxed);
    }
    last = page;
    ++reserved;
  }
  *first_page = first;
  return true;
}

bool CopyToXAudioCapturePagesAt(uint32_t first_page, uint32_t destination_offset,
                                const uint8_t* source, uint32_t bytes) {
  if (source == nullptr || bytes == 0 || g_xaudio_capture_arena == nullptr) {
    return false;
  }
  uint32_t page = first_page;
  uint32_t page_offset = destination_offset;
  while (page != kInvalidXAudioPage && page_offset >= kXAudioCapturePageBytes) {
    page_offset -= kXAudioCapturePageBytes;
    page = g_xaudio_capture_pages[page].next.load(std::memory_order_relaxed);
  }
  uint32_t copied = 0;
  while (copied < bytes && page != kInvalidXAudioPage) {
    const uint32_t chunk = std::min<uint32_t>(
        kXAudioCapturePageBytes - page_offset, bytes - copied);
    memcpy(g_xaudio_capture_arena +
               static_cast<size_t>(page) * kXAudioCapturePageBytes +
               page_offset,
           source + copied, chunk);
    copied += chunk;
    page_offset = 0;
    page = g_xaudio_capture_pages[page].next.load(std::memory_order_relaxed);
  }
  return copied == bytes;
}

bool CopyToXAudioCapturePages(uint32_t first_page, const uint8_t* source,
                              uint32_t bytes) {
  return CopyToXAudioCapturePagesAt(first_page, 0, source, bytes);
}

bool CopyFromXAudioCapturePages(const XAudioCaptureJob& job,
                                std::vector<uint8_t>* encoded) {
  if (encoded == nullptr || job.stored_bytes == 0 ||
      g_xaudio_capture_arena == nullptr) {
    return false;
  }
  encoded->resize(job.stored_bytes);
  uint32_t page = job.first_page;
  uint32_t copied = 0;
  while (copied < job.stored_bytes && page != kInvalidXAudioPage) {
    const uint32_t chunk = std::min<uint32_t>(
        kXAudioCapturePageBytes, job.stored_bytes - copied);
    memcpy(encoded->data() + copied,
           g_xaudio_capture_arena +
               static_cast<size_t>(page) * kXAudioCapturePageBytes,
           chunk);
    copied += chunk;
    page = g_xaudio_capture_pages[page].next.load(std::memory_order_relaxed);
  }
  return copied == job.stored_bytes;
}

void AccountXAudioArenaBytes(uint32_t bytes) {
  const LONG64 current =
      InterlockedAdd64(&g_xaudio_capture_counters.arena_bytes_in_use, bytes);
  LONG64 high_water = InterlockedCompareExchange64(
      &g_xaudio_capture_counters.arena_high_water_bytes, 0, 0);
  while (current > high_water) {
    const LONG64 exchanged = InterlockedCompareExchange64(
        &g_xaudio_capture_counters.arena_high_water_bytes, current,
        high_water);
    if (exchanged == high_water) break;
    high_water = exchanged;
  }
}

void ReleaseXAudioCaptureJob(XAudioCaptureJob* job) {
  if (job == nullptr) return;
  const uint32_t bytes = job->stored_bytes;
  ReleaseXAudioCapturePages(job->first_page, job->page_count);
  job->first_page = kInvalidXAudioPage;
  job->page_count = 0;
  job->encoded_bytes = 0;
  job->stored_bytes = 0;
  job->wma_packet_count = 0;
  job->wma_decoded_bytes = 0;
  job->wait_trace_emitted = 0;
  job->source = fushi_voice_hook::XAudioSourceSnapshot{};
  if (bytes != 0) {
    InterlockedAdd64(&g_xaudio_capture_counters.arena_bytes_in_use,
                     -static_cast<LONG64>(bytes));
  }
  InterlockedExchange(&job->state, 0);
}

bool InitializeXAudioCaptureQueue() {
  const LONG state =
      InterlockedCompareExchange(&g_xaudio_capture_queue_state, 1, 0);
  if (state != 0) return state == 2;
  if (g_xaudio_capture_arena == nullptr) {
    g_xaudio_capture_arena = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kXAudioCaptureArenaBytes, MEM_COMMIT | MEM_RESERVE,
        PAGE_READWRITE));
  }
  if (g_xaudio_capture_arena == nullptr) {
    InterlockedExchange(&g_xaudio_capture_queue_state, 0);
    return false;
  }
  for (uint32_t i = 0; i < kXAudioCapturePageCount; ++i) {
    g_xaudio_capture_pages[i].next.store(
        i + 1u < kXAudioCapturePageCount ? i + 1u : kInvalidXAudioPage,
        std::memory_order_relaxed);
  }
  InterlockedExchange64(
      &g_xaudio_free_page_head,
      static_cast<LONG64>(PackXAudioPageHead(0, 0)));
  for (XAudioCaptureJob& job : g_xaudio_capture_jobs) {
    InterlockedExchange(&job.state, 0);
  }
  for (XAudioDeferredOperation& operation : g_xaudio_deferred_operations) {
    InterlockedExchange(&operation.state, 0);
  }
  for (XAudioCommitEvent& event : g_xaudio_commit_events) {
    InterlockedExchange(&event.state, 0);
  }
  InterlockedExchange(&g_xaudio_capture_queue_state, 2);
  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagQueueReady);
  return true;
}

void ShutdownXAudioCaptureQueue() {
  InterlockedExchange(&g_xaudio_capture_queue_state, 0);
  // The injected DLL is process-lifetime.  Do not VirtualFree here: disabling a
  // detour prevents new calls but does not join a callback that was already
  // copying.  The OS reclaims this fixed 32 MiB arena at process exit.
}

XAudioCaptureJob* PrepareXAudioCaptureJob(
    const fushi_voice_hook::XAudioSourceSnapshot& source,
    const XAUDIO2_BUFFER* buffer, const XAUDIO2_BUFFER_WMA* wma,
    uint64_t submit_timestamp_ms,
    fushi_voice_hook::XAudioTraceOutcome* rejection) {
  if (rejection != nullptr) {
    *rejection = fushi_voice_hook::XAudioTraceOutcome::kNone;
  }
  fushi_voice_hook::XAudioTraceOutcome reject =
      fushi_voice_hook::XAudioTraceOutcome::kNone;
  uint32_t wma_table_bytes = 0;
  if (source.format.encoding ==
      fushi_voice_hook::XAudioSourceEncoding::kWmaudio2) {
    const uint64_t table_bytes =
        wma == nullptr ? 0 : static_cast<uint64_t>(wma->PacketCount) * 4u;
    if (wma == nullptr || wma->PacketCount == 0 ||
        wma->pDecodedPacketCumulativeBytes == nullptr ||
        table_bytes > kMaxXAudioCaptureBytes) {
      reject = fushi_voice_hook::XAudioTraceOutcome::kRejectedCopyFailed;
    } else {
      wma_table_bytes = static_cast<uint32_t>(table_bytes);
    }
  }
  if (buffer == nullptr) {
    reject = fushi_voice_hook::XAudioTraceOutcome::kRejectedNullBuffer;
  } else if (buffer->pAudioData == nullptr) {
    reject = fushi_voice_hook::XAudioTraceOutcome::kRejectedNullAudioData;
  } else if (buffer->AudioBytes == 0) {
    reject = fushi_voice_hook::XAudioTraceOutcome::kRejectedZeroBytes;
  } else if (buffer->AudioBytes > kMaxXAudioCaptureBytes) {
    reject = fushi_voice_hook::XAudioTraceOutcome::kRejectedTooLarge;
  } else if (static_cast<uint64_t>(buffer->AudioBytes) + wma_table_bytes >
             kMaxXAudioCaptureBytes) {
    reject = fushi_voice_hook::XAudioTraceOutcome::kRejectedTooLarge;
  } else if (InterlockedCompareExchange(&g_xaudio_capture_queue_state, 0, 0) !=
             2) {
    reject = fushi_voice_hook::XAudioTraceOutcome::kRejectedQueueNotReady;
  }
  if (reject != fushi_voice_hook::XAudioTraceOutcome::kNone) {
    if (rejection != nullptr) *rejection = reject;
    IncrementXAudioCounter(&g_xaudio_capture_counters.buffer_rejected);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagBufferRejected);
    return nullptr;
  }

  XAudioCaptureJob* claimed = nullptr;
  for (XAudioCaptureJob& job : g_xaudio_capture_jobs) {
    if (InterlockedCompareExchange(&job.state, 1, 0) == 0) {
      claimed = &job;
      break;
    }
  }
  if (claimed == nullptr) {
    if (rejection != nullptr) {
      *rejection =
          fushi_voice_hook::XAudioTraceOutcome::kRejectedDescriptorExhausted;
    }
    IncrementXAudioCounter(&g_xaudio_capture_counters.descriptor_exhausted);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagDescriptorExhausted);
    return nullptr;
  }

  const uint32_t stored_bytes = buffer->AudioBytes + wma_table_bytes;
  const uint32_t page_count =
      (stored_bytes + kXAudioCapturePageBytes - 1u) /
      kXAudioCapturePageBytes;
  uint32_t first_page = kInvalidXAudioPage;
  if (!ReserveXAudioCapturePages(page_count, &first_page)) {
    if (rejection != nullptr) {
      *rejection =
          fushi_voice_hook::XAudioTraceOutcome::kRejectedArenaExhausted;
    }
    IncrementXAudioCounter(&g_xaudio_capture_counters.arena_exhausted);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagArenaExhausted);
    InterlockedExchange(&claimed->state, 0);
    return nullptr;
  }
  if (!CopyToXAudioCapturePages(first_page, buffer->pAudioData,
                                buffer->AudioBytes)) {
    if (rejection != nullptr) {
      *rejection = fushi_voice_hook::XAudioTraceOutcome::kRejectedCopyFailed;
    }
    ReleaseXAudioCapturePages(first_page, page_count);
    IncrementXAudioCounter(&g_xaudio_capture_counters.buffer_rejected);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagBufferRejected);
    InterlockedExchange(&claimed->state, 0);
    return nullptr;
  }
  if (wma_table_bytes != 0 &&
      !CopyToXAudioCapturePagesAt(
          first_page, buffer->AudioBytes,
          reinterpret_cast<const uint8_t*>(
              wma->pDecodedPacketCumulativeBytes),
          wma_table_bytes)) {
    if (rejection != nullptr) {
      *rejection = fushi_voice_hook::XAudioTraceOutcome::kRejectedCopyFailed;
    }
    ReleaseXAudioCapturePages(first_page, page_count);
    IncrementXAudioCounter(&g_xaudio_capture_counters.buffer_rejected);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagBufferRejected);
    InterlockedExchange(&claimed->state, 0);
    return nullptr;
  }

  claimed->first_page = first_page;
  claimed->page_count = page_count;
  claimed->encoded_bytes = buffer->AudioBytes;
  claimed->stored_bytes = stored_bytes;
  claimed->play_begin = buffer->PlayBegin;
  claimed->play_length = buffer->PlayLength;
  if (wma != nullptr && wma->pDecodedPacketCumulativeBytes != nullptr &&
      wma->PacketCount != 0) {
    claimed->wma_packet_count = wma->PacketCount;
    claimed->wma_decoded_bytes =
        wma->pDecodedPacketCumulativeBytes[wma->PacketCount - 1u];
  } else {
    claimed->wma_packet_count = 0;
    claimed->wma_decoded_bytes = 0;
  }
  claimed->submit_timestamp_ms = submit_timestamp_ms;
  claimed->playback_timestamp_hint_ms =
      g_xaudio_formats.TimestampForSubmit(source, submit_timestamp_ms);
  claimed->wait_trace_emitted = 0;
  claimed->source = source;
  AccountXAudioArenaBytes(stored_bytes);
  return claimed;
}

void PublishXAudioCaptureJob(XAudioCaptureJob* job) {
  if (job == nullptr) return;
  IncrementXAudioCounter(&g_xaudio_capture_counters.jobs_queued);
  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagJobQueued);
  InterlockedExchange(&job->state, 2);
}

XAudioDeferredOperation* PrepareDeferredXAudioOperation(
    const fushi_voice_hook::XAudioSourceSnapshot& source,
    uint32_t operation_set, XAudioDeferredOperationKind kind) {
  if (operation_set == XAUDIO2_COMMIT_NOW || source.engine == 0 ||
      source.source == 0 || source.generation == 0) {
    return nullptr;
  }
  InterlockedIncrement(&g_xaudio_deferred_producers);
  for (XAudioDeferredOperation& operation : g_xaudio_deferred_operations) {
    if (InterlockedCompareExchange(&operation.state, 1, 0) != 0) continue;
    operation.sequence = static_cast<uint64_t>(
        InterlockedIncrement64(&g_xaudio_deferred_sequence));
    operation.engine = source.engine;
    operation.source = source.source;
    operation.source_generation = source.generation;
    operation.operation_set = operation_set;
    operation.kind = kind;
    InterlockedExchange(&operation.state, 2);
    InterlockedDecrement(&g_xaudio_deferred_producers);
    return &operation;
  }
  InterlockedDecrement(&g_xaudio_deferred_producers);
  IncrementXAudioCounter(&g_xaudio_capture_counters.deferred_exhausted);
  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagDeferredExhausted);
  return nullptr;
}

void PublishDeferredXAudioOperation(XAudioDeferredOperation* operation) {
  if (operation == nullptr) return;
  IncrementXAudioCounter(&g_xaudio_capture_counters.deferred_queued);
  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagDeferredQueued);
  InterlockedExchange(&operation->state, 3);
  DrainXAudioControlEvents();
}

void CancelDeferredXAudioOperation(XAudioDeferredOperation* operation) {
  if (operation == nullptr) return;
  InterlockedExchange(&operation->state, 0);
  DrainXAudioControlEvents();
}

struct XAudioDeferredCommitResult {
  uint32_t matched = 0;
  uint32_t applied = 0;
  uint32_t invalidated = 0;
};

XAudioDeferredCommitResult CommitDeferredXAudioOperations(
    uintptr_t engine, uint32_t operation_set, uint64_t sequence_fence,
    uint64_t timestamp_ms) {
  XAudioDeferredCommitResult result;
  XAudioDeferredOperation* matching[kXAudioDeferredOperationCount] = {};
  size_t matching_count = 0;
  for (XAudioDeferredOperation& operation : g_xaudio_deferred_operations) {
    // The control drain is the only consumer, but producers are concurrent.
    // Claim the descriptor before reading any producer-owned field so a slot
    // cannot be recycled underneath this scan.
    if (InterlockedCompareExchange(&operation.state, 4, 3) != 3) continue;
    if (operation.engine == engine && operation.sequence <= sequence_fence &&
        (operation_set == XAUDIO2_COMMIT_ALL ||
         operation.operation_set == operation_set)) {
      matching[matching_count++] = &operation;
    } else {
      InterlockedExchange(&operation.state, 3);
    }
  }
  std::sort(matching, matching + matching_count,
            [](const XAudioDeferredOperation* left,
               const XAudioDeferredOperation* right) {
              return left->sequence < right->sequence;
            });
  for (size_t i = 0; i < matching_count; ++i) {
    XAudioDeferredOperation* operation = matching[i];
    ++result.matched;
    bool applied = false;
    if (g_xaudio_formats.IsCurrentSource(operation->source,
                                         operation->source_generation)) {
      if (operation->kind == XAudioDeferredOperationKind::kStart) {
        applied = g_xaudio_formats.MarkStarted(
            operation->source, operation->source_generation, timestamp_ms);
      } else {
        applied = g_xaudio_formats.MarkStopped(
            operation->source, operation->source_generation);
      }
    }
    if (!applied) {
      ++result.invalidated;
      IncrementXAudioCounter(&g_xaudio_capture_counters.stale_invalidated);
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagStaleInvalidated);
    } else {
      ++result.applied;
    }
    fushi_voice_hook::XAudioTraceEvent trace = MakeXAudioSourceTrace(
        operation->kind == XAudioDeferredOperationKind::kStart
            ? fushi_voice_hook::XAudioTraceEventKind::kStart
            : fushi_voice_hook::XAudioTraceEventKind::kStop);
    trace.timestamp_ms = timestamp_ms;
    trace.engine = operation->engine;
    trace.source = operation->source;
    trace.source_generation = operation->source_generation;
    trace.operation_set = operation->operation_set;
    trace.outcome = static_cast<uint32_t>(
        applied ? fushi_voice_hook::XAudioTraceOutcome::kDeferredApplied
                : fushi_voice_hook::XAudioTraceOutcome::kDeferredInvalidated);
    PublishXAudioTrace(&trace);
    InterlockedExchange(&operation->state, 0);
  }
  return result;
}

void DiscardStaleDeferredXAudioOperations() {
  for (XAudioDeferredOperation& operation : g_xaudio_deferred_operations) {
    if (InterlockedCompareExchange(&operation.state, 4, 3) != 3) continue;
    if (g_xaudio_formats.IsCurrentSource(operation.source,
                                         operation.source_generation)) {
      InterlockedExchange(&operation.state, 3);
      continue;
    }
    fushi_voice_hook::XAudioTraceEvent trace = MakeXAudioSourceTrace(
        operation.kind == XAudioDeferredOperationKind::kStart
            ? fushi_voice_hook::XAudioTraceEventKind::kStart
            : fushi_voice_hook::XAudioTraceEventKind::kStop);
    trace.engine = operation.engine;
    trace.source = operation.source;
    trace.source_generation = operation.source_generation;
    trace.operation_set = operation.operation_set;
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kDeferredInvalidated);
    PublishXAudioTrace(&trace);
    IncrementXAudioCounter(&g_xaudio_capture_counters.stale_invalidated);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagStaleInvalidated);
    InterlockedExchange(&operation.state, 0);
  }
}

bool EnqueueXAudioCommitEvent(uintptr_t engine, uint32_t operation_set,
                              uint64_t operation_sequence_fence,
                              uint64_t timestamp_ms) {
  for (XAudioCommitEvent& event : g_xaudio_commit_events) {
    if (InterlockedCompareExchange(&event.state, 1, 0) != 0) continue;
    event.sequence = static_cast<uint64_t>(
        InterlockedIncrement64(&g_xaudio_commit_sequence));
    event.operation_sequence_fence = operation_sequence_fence;
    event.timestamp_ms = timestamp_ms;
    event.engine = engine;
    event.operation_set = operation_set;
    IncrementXAudioCounter(&g_xaudio_capture_counters.commit_events_queued);
    InterlockedExchange(&event.state, 2);
    return true;
  }
  IncrementXAudioCounter(&g_xaudio_capture_counters.commit_events_exhausted);
  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagCommitQueueExhausted);
  return false;
}

bool HasReadyXAudioCommitEvent() {
  for (XAudioCommitEvent& event : g_xaudio_commit_events) {
    if (InterlockedCompareExchange(&event.state, 0, 0) == 2) return true;
  }
  return false;
}

bool HasStagedXAudioOperation(const XAudioCommitEvent& event) {
  if (InterlockedCompareExchange(&g_xaudio_deferred_producers, 0, 0) != 0) {
    return true;
  }
  for (XAudioDeferredOperation& operation : g_xaudio_deferred_operations) {
    if (InterlockedCompareExchange(&operation.state, 0, 0) != 2) continue;
    if (operation.engine == event.engine &&
        operation.sequence <= event.operation_sequence_fence &&
        (event.operation_set == XAUDIO2_COMMIT_ALL ||
         operation.operation_set == event.operation_set)) {
      return true;
    }
  }
  return false;
}

bool ProcessReadyXAudioCommitEvents() {
  XAudioCommitEvent* ready[kXAudioCommitEventCount] = {};
  size_t ready_count = 0;
  bool unresolved = false;
  for (XAudioCommitEvent& event : g_xaudio_commit_events) {
    if (InterlockedCompareExchange(&event.state, 3, 2) == 2) {
      ready[ready_count++] = &event;
    }
  }
  std::sort(ready, ready + ready_count,
            [](const XAudioCommitEvent* left,
               const XAudioCommitEvent* right) {
              return left->sequence < right->sequence;
            });
  for (size_t i = 0; i < ready_count; ++i) {
    XAudioCommitEvent* event = ready[i];
    if (unresolved || HasStagedXAudioOperation(*event)) {
      InterlockedExchange(&event->state, 2);
      unresolved = true;
      continue;
    }
    const XAudioDeferredCommitResult result = CommitDeferredXAudioOperations(
        event->engine, event->operation_set,
        event->operation_sequence_fence, event->timestamp_ms);
    fushi_voice_hook::XAudioTraceEvent trace = MakeXAudioSourceTrace(
        fushi_voice_hook::XAudioTraceEventKind::kCommit);
    trace.timestamp_ms = event->timestamp_ms;
    trace.engine = event->engine;
    trace.operation_set = event->operation_set;
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kCommitApplied);
    trace.detail0 = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceCommitPhase::kApplied);
    trace.detail1 = result.matched;
    trace.detail2 = result.applied;
    PublishXAudioTrace(&trace);
    InterlockedExchange(&event->state, 0);
  }
  return unresolved;
}

void DrainXAudioControlEvents() {
  if (InterlockedCompareExchange(&g_xaudio_control_consumer, 1, 0) != 0) {
    return;
  }
  for (;;) {
    const bool unresolved = ProcessReadyXAudioCommitEvents();
    DiscardStaleDeferredXAudioOperations();
    InterlockedExchange(&g_xaudio_control_consumer, 0);
    // Close the enqueue-after-empty race without making a concurrent XAudio2
    // API caller wait.  Whichever caller wins this CAS becomes the sole drain;
    // losers leave their preallocated event for that owner or HookWorker.
    if (unresolved || !HasReadyXAudioCommitEvent() ||
        InterlockedCompareExchange(&g_xaudio_control_consumer, 1, 0) != 0) {
      return;
    }
  }
}

void ProcessPendingXAudioCaptureJobs() {
  DrainXAudioControlEvents();
  std::vector<uint8_t> encoded;
  std::vector<int16_t> decoded;
  // 复用同一个缓冲跨作业：这条循环跑在 HookWorker 上，每作业新建一个 vector 只会
  // 把分配器打得更热，没有任何收益。
  std::vector<uint8_t> resource;
  for (XAudioCaptureJob& job : g_xaudio_capture_jobs) {
    // Claim before reading producer-owned fields.  Interlocked exchange is the
    // publication/acquire edge for the descriptor and its page chain.
    if (InterlockedCompareExchange(&job.state, 3, 2) != 2) continue;
    if (!g_xaudio_formats.IsCurrent(
            job.source.source, job.source.generation,
            job.source.queue_generation)) {
      PublishXAudioWorkerTrace(
          fushi_voice_hook::XAudioTraceEventKind::kWorkerInvalidate,
          fushi_voice_hook::XAudioTraceOutcome::kStaleInvalidated, job);
      IncrementXAudioCounter(&g_xaudio_capture_counters.stale_invalidated);
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagStaleInvalidated);
      ReleaseXAudioCaptureJob(&job);
      continue;
    }

    uint64_t playback_timestamp = job.playback_timestamp_hint_ms;
    if (playback_timestamp == 0) {
      playback_timestamp = g_xaudio_formats.ResolvePlaybackTimestamp(
          job.source.source, job.source.generation,
          job.source.queue_generation, job.submit_timestamp_ms);
    }
    // A preloaded buffer remains in the arena until Start actually applies.
    // Flush/Destroy generation invalidation, not an arbitrary wall-clock TTL,
    // decides whether it is still owned by XAudio2.
    if (playback_timestamp == 0) {
      if (job.wait_trace_emitted == 0) {
        job.wait_trace_emitted = 1;
        PublishXAudioWorkerTrace(
            fushi_voice_hook::XAudioTraceEventKind::kWorkerWait,
            fushi_voice_hook::XAudioTraceOutcome::kWaitingForStart, job);
      }
      InterlockedExchange(&job.state, 2);
      continue;
    }

    if (!g_xaudio_formats.IsCurrent(
            job.source.source, job.source.generation,
            job.source.queue_generation) ||
        !CopyFromXAudioCapturePages(job, &encoded) ||
        job.source.format.channels == 0 ||
        job.source.format.block_align == 0) {
      if (!g_xaudio_formats.IsCurrent(
              job.source.source, job.source.generation,
              job.source.queue_generation)) {
        PublishXAudioWorkerTrace(
            fushi_voice_hook::XAudioTraceEventKind::kWorkerInvalidate,
            fushi_voice_hook::XAudioTraceOutcome::kStaleInvalidated, job);
        IncrementXAudioCounter(&g_xaudio_capture_counters.stale_invalidated);
        SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagStaleInvalidated);
      } else {
        PublishXAudioWorkerTrace(
            fushi_voice_hook::XAudioTraceEventKind::kWorkerInvalidate,
            fushi_voice_hook::XAudioTraceOutcome::kDecodeRejected, job);
        IncrementXAudioCounter(&g_xaudio_capture_counters.decode_rejected);
        SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagDecodeRejected);
      }
      ReleaseXAudioCaptureJob(&job);
      continue;
    }

    if (job.source.format.encoding ==
        fushi_voice_hook::XAudioSourceEncoding::kWmaudio2) {
      const uint64_t table_bytes =
          static_cast<uint64_t>(job.wma_packet_count) * 4u;
      const bool complete_submission =
          table_bytes != 0 &&
          static_cast<uint64_t>(job.encoded_bytes) + table_bytes ==
              encoded.size();
      if (complete_submission) {
        fushi_voice_hook::XAudioCompressedResourceSubmission submission;
        submission.source = job.source;
        submission.payload = encoded.data();
        submission.payload_bytes = job.encoded_bytes;
        submission.packet_cumulative_bytes =
            encoded.data() + job.encoded_bytes;
        submission.packet_count = job.wma_packet_count;
        submission.playback_timestamp_ms = playback_timestamp;
        if (g_xaudio_compressed_resource_dispatch.available()) {
          // 有引擎 profile 认领了这条 seam：判决**完全**归它。归档没命中就是
          // 「这不是角色语音」，不能再拿通用回退去兜——那会把 BGM/SE 也当资源发出去，
          // 正好抹掉归档路径唯一比时长判据强的地方。
          g_xaudio_compressed_resource_dispatch.Dispatch(submission);
        } else {
          // 没有任何引擎 profile 认领这条 seam。
          //
          // 丢弃**不是**合法出路：xWMA 是这类引擎语音的唯一出口，本进程里没有 WMA
          // 解码器，下面的 legacy job 路径（ADPCM 解码 / PCM 直通）对它无能为力。
          // 丢掉就等于「任何其它用 xWMA 语音的引擎，语音在制卡链路上彻底消失」。
          //
          // 这里重建的 RIFF/XWMA 全部取自**这次提交自己**：fmt 由 XAudio2 报的源格式
          // 合成、dpds 用 XAUDIO2_BUFFER_WMA 的原表、压缩负载逐字节原样。不解码、不
          // 重分类、不读任何引擎专属资产——共享中间件的边界没有被越过。
          //
          // 时长预筛把逐块流入的 BGM/SE 挡在外面：没有归档可比对时，它是唯一还能
          // 区分「一整句」和「一小块背景音」的判据。
          uint32_t decoded_bytes = 0;
          std::memcpy(&decoded_bytes,
                      submission.packet_cumulative_bytes +
                          (static_cast<size_t>(job.wma_packet_count) - 1u) * 4u,
                      sizeof(decoded_bytes));
          if (fushi_voice_hook::IsLikelyVoiceWmaSubmission(
                  job.source.format, job.wma_packet_count, decoded_bytes) &&
              fushi_voice_hook::BuildXwmaResource(
                  job.source.format, encoded.data(), job.encoded_bytes,
                  submission.packet_cumulative_bytes, job.wma_packet_count,
                  &resource) &&
              resource.size() <= std::numeric_limits<uint32_t>::max()) {
            wchar_t storage_name[128] = {};
            swprintf_s(storage_name, L"xwma-%p-%llu-%llu-%llu.xwma",
                       reinterpret_cast<void*>(job.source.source),
                       static_cast<unsigned long long>(job.source.generation),
                       static_cast<unsigned long long>(
                           job.source.queue_generation),
                       static_cast<unsigned long long>(playback_timestamp));
            if (WriteVoiceOggAt(resource.data(),
                                static_cast<uint32_t>(resource.size()),
                                storage_name, playback_timestamp)) {
              SetXAudioDiagnostic(
                  fushi_voice_hook::kXAudioDiagRuntimeXwmaPublished);
            }
          }
        }
      }
      // 压缩 WMA 在共享中间件里既不解码也不重新分类：认领它的引擎 profile 通过 worker
      // seam 证明并发布原始资源，没人认领就退回上面那条纯运行时重建。两条路都不产出
      // PCM——把压缩字节当 PCM 送进环形缓冲只会得到噪声。
      ReleaseXAudioCaptureJob(&job);
      continue;
    }

    const bool is_adpcm =
        job.source.format.encoding ==
        fushi_voice_hook::XAudioSourceEncoding::kMicrosoftAdpcm;
    const uint8_t* pcm = nullptr;
    uint64_t total_frames = 0;
    uint32_t output_block_align = job.source.format.block_align;
    uint32_t output_bits = job.source.format.bits_per_sample;
    uint32_t output_is_float =
        job.source.format.encoding ==
                fushi_voice_hook::XAudioSourceEncoding::kPcmFloat
            ? 1u
            : 0u;
    if (is_adpcm) {
      if (!fushi_voice_hook::DecodeMicrosoftAdpcm(
              job.source.format, encoded.data(), encoded.size(), &decoded)) {
        PublishXAudioWorkerTrace(
            fushi_voice_hook::XAudioTraceEventKind::kWorkerInvalidate,
            fushi_voice_hook::XAudioTraceOutcome::kDecodeRejected, job);
        IncrementXAudioCounter(&g_xaudio_capture_counters.decode_rejected);
        SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagDecodeRejected);
        ReleaseXAudioCaptureJob(&job);
        continue;
      }
      output_block_align =
          job.source.format.channels * static_cast<uint32_t>(sizeof(int16_t));
      output_bits = 16;
      output_is_float = 0;
      total_frames = decoded.size() / job.source.format.channels;
      pcm = reinterpret_cast<const uint8_t*>(decoded.data());
    } else if (job.source.format.encoding ==
                   fushi_voice_hook::XAudioSourceEncoding::kPcmInteger ||
               job.source.format.encoding ==
                   fushi_voice_hook::XAudioSourceEncoding::kPcmFloat) {
      total_frames = encoded.size() / output_block_align;
      pcm = encoded.data();
    } else {
      PublishXAudioWorkerTrace(
          fushi_voice_hook::XAudioTraceEventKind::kWorkerInvalidate,
          fushi_voice_hook::XAudioTraceOutcome::kDecodeRejected, job);
      IncrementXAudioCounter(&g_xaudio_capture_counters.decode_rejected);
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagDecodeRejected);
      ReleaseXAudioCaptureJob(&job);
      continue;
    }

    const uint64_t begin = std::min<uint64_t>(job.play_begin, total_frames);
    const uint64_t available = total_frames - begin;
    const uint64_t frame_count =
        job.play_length == 0
            ? available
            : std::min<uint64_t>(job.play_length, available);
    const uint64_t byte_len = frame_count * output_block_align;
    if (byte_len == 0 || byte_len > g_ring_capacity ||
        byte_len > std::numeric_limits<uint32_t>::max() ||
        !g_capture_enabled || g_header == nullptr ||
        !g_xaudio_formats.IsCurrent(
            job.source.source, job.source.generation,
            job.source.queue_generation)) {
      if (!g_xaudio_formats.IsCurrent(
              job.source.source, job.source.generation,
              job.source.queue_generation)) {
        PublishXAudioWorkerTrace(
            fushi_voice_hook::XAudioTraceEventKind::kWorkerInvalidate,
            fushi_voice_hook::XAudioTraceOutcome::kStaleInvalidated, job);
        IncrementXAudioCounter(&g_xaudio_capture_counters.stale_invalidated);
        SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagStaleInvalidated);
      } else if (!g_capture_enabled || g_header == nullptr) {
        PublishXAudioWorkerTrace(
            fushi_voice_hook::XAudioTraceEventKind::kWorkerInvalidate,
            fushi_voice_hook::XAudioTraceOutcome::kCaptureDisabled, job);
      } else {
        PublishXAudioWorkerTrace(
            fushi_voice_hook::XAudioTraceEventKind::kWorkerInvalidate,
            fushi_voice_hook::XAudioTraceOutcome::kDecodeRejected, job);
        IncrementXAudioCounter(&g_xaudio_capture_counters.decode_rejected);
        SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagDecodeRejected);
      }
      ReleaseXAudioCaptureJob(&job);
      continue;
    }

    MaybeRecordPcmFormat(job.source.format.sample_rate,
                         job.source.format.channels, output_bits,
                         output_is_float);
    const uint32_t length = static_cast<uint32_t>(byte_len);
    const uint32_t offset = RingAppendVoice(
        pcm + static_cast<size_t>(begin) * output_block_align, length);
    const uint64_t total_at_write = g_header->total_written;
    RecordVoiceClipFmt(offset, length, job.source.source,
                       job.source.format.sample_rate,
                       job.source.format.channels, output_bits,
                       output_is_float,
                       playback_timestamp, total_at_write);
    PublishXAudioWorkerTrace(
        fushi_voice_hook::XAudioTraceEventKind::kWorkerPublish,
        fushi_voice_hook::XAudioTraceOutcome::kPublished, job, length,
        static_cast<uint32_t>((std::min)(total_frames,
                                        static_cast<uint64_t>(
                                            std::numeric_limits<uint32_t>::max()))));
    if (is_adpcm) {
      InterlockedOr(reinterpret_cast<volatile LONG*>(
                        &g_header->reserved_hook_diagnostics),
                    static_cast<LONG>(
                        fushi_voice_hook::kDiagXAudioAdpcmPcmCaptured));
    }
    IncrementXAudioCounter(&g_xaudio_capture_counters.pcm_published);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagPcmPublished);
    ReleaseXAudioCaptureJob(&job);
  }
}

HRESULT STDMETHODCALLTYPE Detour_SourceVoiceStart(IXAudio2SourceVoice* self,
                                                   UINT32 Flags,
                                                   UINT32 OperationSet) {
  fushi_voice_hook::XAudioSourceSnapshot source;
  const bool registered =
      g_xaudio_formats.Lookup(reinterpret_cast<uintptr_t>(self), &source);
  fushi_voice_hook::XAudioTraceEvent trace = MakeXAudioSourceTrace(
      fushi_voice_hook::XAudioTraceEventKind::kStart,
      registered ? &source : nullptr);
  trace.source = reinterpret_cast<uintptr_t>(self);
  trace.operation_set = OperationSet;
  trace.buffer_flags = Flags;
  trace.detail0 = static_cast<uint32_t>(
      registered ? fushi_voice_hook::XAudioTraceLookupResult::kRegistered
                 : fushi_voice_hook::XAudioTraceLookupResult::kMissing);
  XAudioDeferredOperation* staged = nullptr;
  if (registered && OperationSet != XAUDIO2_COMMIT_NOW) {
    staged = PrepareDeferredXAudioOperation(
        source, OperationSet, XAudioDeferredOperationKind::kStart);
  }
  const HRESULT hr = g_orig_SourceVoiceStart(self, Flags, OperationSet);
  trace.hresult = static_cast<int32_t>(hr);
  if (SUCCEEDED(hr)) {
    if (!registered) {
      trace.outcome = static_cast<uint32_t>(
          fushi_voice_hook::XAudioTraceOutcome::kLookupMiss);
      IncrementXAudioCounter(&g_xaudio_capture_counters.registry_miss);
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagRegistryMiss);
    } else if (OperationSet == XAUDIO2_COMMIT_NOW) {
      const bool applied = g_xaudio_formats.MarkStarted(
          source.source, source.generation, GetTickCount64());
      trace.outcome = static_cast<uint32_t>(
          applied ? fushi_voice_hook::XAudioTraceOutcome::kImmediateApplied
                  : fushi_voice_hook::XAudioTraceOutcome::kStaleInvalidated);
    } else {
      PublishDeferredXAudioOperation(staged);
      trace.outcome = static_cast<uint32_t>(
          staged != nullptr
              ? fushi_voice_hook::XAudioTraceOutcome::kDeferredStaged
              : fushi_voice_hook::XAudioTraceOutcome::kDeferredStageFailed);
    }
  } else {
    CancelDeferredXAudioOperation(staged);
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kOriginalFailed);
  }
  PublishXAudioTrace(&trace);
  return hr;
}

HRESULT STDMETHODCALLTYPE Detour_SourceVoiceStop(IXAudio2SourceVoice* self,
                                                  UINT32 Flags,
                                                  UINT32 OperationSet) {
  fushi_voice_hook::XAudioSourceSnapshot source;
  const bool registered =
      g_xaudio_formats.Lookup(reinterpret_cast<uintptr_t>(self), &source);
  fushi_voice_hook::XAudioTraceEvent trace = MakeXAudioSourceTrace(
      fushi_voice_hook::XAudioTraceEventKind::kStop,
      registered ? &source : nullptr);
  trace.source = reinterpret_cast<uintptr_t>(self);
  trace.operation_set = OperationSet;
  trace.buffer_flags = Flags;
  trace.detail0 = static_cast<uint32_t>(
      registered ? fushi_voice_hook::XAudioTraceLookupResult::kRegistered
                 : fushi_voice_hook::XAudioTraceLookupResult::kMissing);
  XAudioDeferredOperation* staged = nullptr;
  if (registered && OperationSet != XAUDIO2_COMMIT_NOW) {
    staged = PrepareDeferredXAudioOperation(
        source, OperationSet, XAudioDeferredOperationKind::kStop);
  }
  const HRESULT hr = g_orig_SourceVoiceStop(self, Flags, OperationSet);
  trace.hresult = static_cast<int32_t>(hr);
  if (SUCCEEDED(hr)) {
    if (!registered) {
      trace.outcome = static_cast<uint32_t>(
          fushi_voice_hook::XAudioTraceOutcome::kLookupMiss);
      IncrementXAudioCounter(&g_xaudio_capture_counters.registry_miss);
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagRegistryMiss);
    } else if (OperationSet == XAUDIO2_COMMIT_NOW) {
      const bool applied =
          g_xaudio_formats.MarkStopped(source.source, source.generation);
      trace.outcome = static_cast<uint32_t>(
          applied ? fushi_voice_hook::XAudioTraceOutcome::kImmediateApplied
                  : fushi_voice_hook::XAudioTraceOutcome::kStaleInvalidated);
    } else {
      PublishDeferredXAudioOperation(staged);
      trace.outcome = static_cast<uint32_t>(
          staged != nullptr
              ? fushi_voice_hook::XAudioTraceOutcome::kDeferredStaged
              : fushi_voice_hook::XAudioTraceOutcome::kDeferredStageFailed);
    }
  } else {
    CancelDeferredXAudioOperation(staged);
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kOriginalFailed);
  }
  PublishXAudioTrace(&trace);
  return hr;
}

HRESULT STDMETHODCALLTYPE Detour_FlushSourceBuffers(
    IXAudio2SourceVoice* self) {
  fushi_voice_hook::XAudioSourceSnapshot source;
  const bool registered =
      g_xaudio_formats.Lookup(reinterpret_cast<uintptr_t>(self), &source);
  fushi_voice_hook::XAudioTraceEvent trace = MakeXAudioSourceTrace(
      fushi_voice_hook::XAudioTraceEventKind::kFlush,
      registered ? &source : nullptr);
  trace.source = reinterpret_cast<uintptr_t>(self);
  trace.detail0 = static_cast<uint32_t>(
      registered ? fushi_voice_hook::XAudioTraceLookupResult::kRegistered
                 : fushi_voice_hook::XAudioTraceLookupResult::kMissing);
  const FlushSourceBuffers_t original =
      OriginalHookForVtableSlot<FlushSourceBuffers_t>(
          self, kIdxFlushSourceBuffers, g_flush_source_buffers_originals);
  const HRESULT hr =
      original != nullptr ? original(self) : XAUDIO2_E_INVALID_CALL;
  trace.hresult = static_cast<int32_t>(hr);
  if (SUCCEEDED(hr) && registered) {
    if (g_xaudio_formats.AdvanceQueueGeneration(source.source,
                                                 source.generation)) {
      trace.outcome = static_cast<uint32_t>(
          fushi_voice_hook::XAudioTraceOutcome::kQueueGenerationAdvanced);
      IncrementXAudioCounter(&g_xaudio_capture_counters.flush_observed);
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagFlushObserved);
    } else {
      trace.outcome = static_cast<uint32_t>(
          fushi_voice_hook::XAudioTraceOutcome::kStaleInvalidated);
      IncrementXAudioCounter(&g_xaudio_capture_counters.stale_invalidated);
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagStaleInvalidated);
    }
  } else if (FAILED(hr)) {
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kOriginalFailed);
  } else {
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kLookupMiss);
  }
  PublishXAudioTrace(&trace);
  return hr;
}

void STDMETHODCALLTYPE Detour_DestroyVoice(IXAudio2Voice* self) {
  fushi_voice_hook::XAudioSourceSnapshot source;
  const bool registered =
      g_xaudio_formats.Lookup(reinterpret_cast<uintptr_t>(self), &source);
  fushi_voice_hook::XAudioTraceEvent trace = MakeXAudioSourceTrace(
      fushi_voice_hook::XAudioTraceEventKind::kDestroy,
      registered ? &source : nullptr);
  trace.source = reinterpret_cast<uintptr_t>(self);
  trace.detail0 = static_cast<uint32_t>(
      registered ? fushi_voice_hook::XAudioTraceLookupResult::kRegistered
                 : fushi_voice_hook::XAudioTraceLookupResult::kMissing);
  if (registered) {
    // DestroyVoice returns void and invalidates the object synchronously.  Make
    // the lifetime unreachable before entering the original implementation;
    // queued work then fails closed on generation validation.
    if (g_xaudio_formats.Unregister(source.source, source.generation)) {
      trace.outcome = static_cast<uint32_t>(
          fushi_voice_hook::XAudioTraceOutcome::kSucceeded);
      IncrementXAudioCounter(&g_xaudio_capture_counters.destroy_observed);
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagDestroyObserved);
    } else {
      trace.outcome = static_cast<uint32_t>(
          fushi_voice_hook::XAudioTraceOutcome::kStaleInvalidated);
      IncrementXAudioCounter(&g_xaudio_capture_counters.stale_invalidated);
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagStaleInvalidated);
    }
  } else {
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kLookupMiss);
  }
  g_orig_DestroyVoice(self);
  PublishXAudioTrace(&trace);
}

HRESULT STDMETHODCALLTYPE Detour_CommitChanges(IXAudio2* self,
                                                UINT32 OperationSet) {
  fushi_voice_hook::XAudioTraceEvent trace = MakeXAudioSourceTrace(
      fushi_voice_hook::XAudioTraceEventKind::kCommit);
  trace.engine = reinterpret_cast<uintptr_t>(self);
  trace.operation_set = OperationSet;
  trace.detail0 = static_cast<uint32_t>(
      fushi_voice_hook::XAudioTraceCommitPhase::kObserved);
  const uint64_t sequence_fence = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_xaudio_deferred_sequence, 0, 0));
  trace.detail1 = static_cast<uint32_t>(sequence_fence);
  trace.detail2 = static_cast<uint32_t>(sequence_fence >> 32);
  const HRESULT hr = g_orig_CommitChanges(self, OperationSet);
  trace.hresult = static_cast<int32_t>(hr);
  if (SUCCEEDED(hr)) {
    IncrementXAudioCounter(&g_xaudio_capture_counters.commits_succeeded);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagCommitObserved);
    const bool queued = EnqueueXAudioCommitEvent(
        reinterpret_cast<uintptr_t>(self), OperationSet, sequence_fence,
        GetTickCount64());
    trace.outcome = static_cast<uint32_t>(
        queued ? fushi_voice_hook::XAudioTraceOutcome::kCommitQueued
               : fushi_voice_hook::XAudioTraceOutcome::kCommitQueueExhausted);
    // Publish the API observation before a synchronous control drain emits the
    // corresponding applied event, preserving the causal order in the trace.
    PublishXAudioTrace(&trace);
    DrainXAudioControlEvents();
  } else {
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kOriginalFailed);
    IncrementXAudioCounter(&g_xaudio_capture_counters.commits_failed);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagCommitFailed);
    PublishXAudioTrace(&trace);
  }
  return hr;
}

// ── C.2 detour：IXAudio2SourceVoice::SubmitSourceBuffer ──────────────────────
// 语音送进混音前的最后一跳。零阻塞红线：只读 pBuffer 字段 + 换算字节 + RingAppendVoice，
// 绝不加锁/分配/IO/日志。PlayBegin/PlayLength 单位是**样本(每通道)**，PlayLength==0 表示到
// buffer 尾。按 block_align 换算成字节段 [PlayBegin, PlayBegin+PlayLength)。
HRESULT STDMETHODCALLTYPE Detour_SubmitSourceBuffer(
    IXAudio2SourceVoice* self, const XAUDIO2_BUFFER* pBuffer,
    const XAUDIO2_BUFFER_WMA* pBufferWMA) {
  fushi_voice_hook::XAudioTraceEvent trace = MakeXAudioSourceTrace(
      fushi_voice_hook::XAudioTraceEventKind::kSubmit);
  trace.source = reinterpret_cast<uintptr_t>(self);
  trace.submit_timestamp_ms = trace.timestamp_ms;
  if (pBuffer != nullptr) {
    trace.buffer_flags = pBuffer->Flags;
    trace.audio_bytes = pBuffer->AudioBytes;
    trace.play_begin = pBuffer->PlayBegin;
    trace.play_length = pBuffer->PlayLength;
    trace.buffer_context_present = pBuffer->pContext != nullptr ? 1u : 0u;
  }
  fushi_voice_hook::CaptureXAudioTraceWma(pBufferWMA, &trace);

  fushi_voice_hook::XAudioSourceSnapshot source;
  const bool registered =
      g_xaudio_formats.Lookup(reinterpret_cast<uintptr_t>(self), &source);
  trace.detail0 = static_cast<uint32_t>(
      registered ? fushi_voice_hook::XAudioTraceLookupResult::kRegistered
                 : fushi_voice_hook::XAudioTraceLookupResult::kMissing);
  if (registered) {
    trace.engine = source.engine;
    trace.source_generation = source.generation;
    trace.queue_generation = source.queue_generation;
    CaptureNormalizedXAudioTraceFormat(source.format, &trace.format);
  }

  // Stage while the caller unquestionably owns pAudioData.  A fast engine can
  // invoke OnBufferEnd on another thread before the original call returns, so
  // reading the caller's buffer after success is a use-after-release race.  The
  // staged descriptor remains invisible to HookWorker until success publishes
  // it; failure releases the private copy.
  XAudioCaptureJob* staged = nullptr;
  fushi_voice_hook::XAudioTraceOutcome rejection =
      fushi_voice_hook::XAudioTraceOutcome::kNone;
  if (pBuffer == nullptr) {
    rejection = fushi_voice_hook::XAudioTraceOutcome::kRejectedNullBuffer;
  } else if (pBuffer->pAudioData == nullptr) {
    rejection =
        fushi_voice_hook::XAudioTraceOutcome::kRejectedNullAudioData;
  } else if (pBuffer->AudioBytes == 0) {
    rejection = fushi_voice_hook::XAudioTraceOutcome::kRejectedZeroBytes;
    if (g_capture_enabled && g_header != nullptr) {
      if (registered) {
        IncrementXAudioCounter(&g_xaudio_capture_counters.buffer_rejected);
        SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagBufferRejected);
      } else {
        IncrementXAudioCounter(&g_xaudio_capture_counters.registry_miss);
        SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagRegistryMiss);
      }
    }
  } else if (pBuffer->AudioBytes > kMaxXAudioCaptureBytes) {
    rejection = fushi_voice_hook::XAudioTraceOutcome::kRejectedTooLarge;
    if (g_capture_enabled && g_header != nullptr) {
      if (registered) {
        IncrementXAudioCounter(&g_xaudio_capture_counters.buffer_rejected);
        SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagBufferRejected);
      } else {
        IncrementXAudioCounter(&g_xaudio_capture_counters.registry_miss);
        SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagRegistryMiss);
      }
    }
  } else if (!g_capture_enabled || g_header == nullptr) {
    rejection = fushi_voice_hook::XAudioTraceOutcome::kCaptureDisabled;
  } else if (!registered) {
    rejection = fushi_voice_hook::XAudioTraceOutcome::kLookupMiss;
    IncrementXAudioCounter(&g_xaudio_capture_counters.registry_miss);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagRegistryMiss);
  } else if (source.format.encoding ==
                 fushi_voice_hook::XAudioSourceEncoding::kWmaudio2 &&
             !HasXAudioCompressedResourceHandler()) {
    rejection = fushi_voice_hook::XAudioTraceOutcome::kFormatUnsupported;
  } else {
    staged = PrepareXAudioCaptureJob(source, pBuffer, pBufferWMA,
                                     trace.timestamp_ms, &rejection);
  }
  trace.detail1 = static_cast<uint32_t>(rejection);

  const SubmitSourceBuffer_t original =
      OriginalHookForVtableSlot<SubmitSourceBuffer_t>(
          self, kIdxSubmitSourceBuffer, g_submit_source_buffer_originals);
  const HRESULT hr = original != nullptr
                         ? original(self, pBuffer, pBufferWMA)
                         : XAUDIO2_E_INVALID_CALL;
  trace.hresult = static_cast<int32_t>(hr);
  if (FAILED(hr)) {
    if (staged != nullptr) ReleaseXAudioCaptureJob(staged);
    IncrementXAudioCounter(&g_xaudio_capture_counters.submit_failed);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagSubmitFailed);
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kOriginalFailed);
    PublishXAudioTrace(&trace);
    return hr;
  }
  IncrementXAudioCounter(&g_xaudio_capture_counters.submit_succeeded);
  if (staged != nullptr &&
      !g_xaudio_formats.IsCurrent(
          staged->source.source, staged->source.generation,
          staged->source.queue_generation)) {
    IncrementXAudioCounter(&g_xaudio_capture_counters.stale_invalidated);
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagStaleInvalidated);
    ReleaseXAudioCaptureJob(staged);
    trace.detail2 = 1;
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kStaleInvalidated);
  } else if (staged != nullptr) {
    PublishXAudioCaptureJob(staged);
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kQueued);
  } else {
    trace.outcome = static_cast<uint32_t>(rejection);
  }
  PublishXAudioTrace(&trace);
  // TODO(C.3 校准模式)：此切片捕获所有 source voice 的 SubmitSourceBuffer（先打通「有语音
  // 进环形缓冲」）。逐 callsite 精筛（按 game.exe SHA + callsite RVA 只留角色语音 voice、
  // BGM/SE 连 memcpy 都不做）需真实游戏抓调用栈标定，留给 C.3。
  return hr;
}

// ── C.2 detour：IXAudio2::CreateSourceVoice ─────────────────────────────────
// 每次创建 source voice：先调原函数拿到 voice，成功后 ① 首次记格式，② vtable-hook 这个新
// voice 的 SubmitSourceBuffer（同一实现共享 vtable，HookFn 去重只装一次）。
HRESULT STDMETHODCALLTYPE Detour_CreateSourceVoice(
    IXAudio2* self, IXAudio2SourceVoice** ppSourceVoice,
    const WAVEFORMATEX* pSourceFormat, UINT32 Flags, float MaxFrequencyRatio,
    IXAudio2VoiceCallback* pCallback, const XAUDIO2_VOICE_SENDS* pSendList,
    const XAUDIO2_EFFECT_CHAIN* pEffectChain) {
  fushi_voice_hook::XAudioTraceEvent trace = MakeXAudioSourceTrace(
      fushi_voice_hook::XAudioTraceEventKind::kCreate);
  trace.engine = reinterpret_cast<uintptr_t>(self);
  trace.buffer_flags = Flags;
  fushi_voice_hook::XAudioSourceFormat format;
  const bool has_format =
      fushi_voice_hook::ParseXAudioSourceFormat(pSourceFormat, &format);
  fushi_voice_hook::CaptureXAudioTraceFormat(
      pSourceFormat, has_format,
      has_format ? static_cast<uint32_t>(format.encoding) : 0u,
      &trace.format);
  const HRESULT hr = g_orig_CreateSourceVoice(
      self, ppSourceVoice, pSourceFormat, Flags, MaxFrequencyRatio, pCallback,
      pSendList, pEffectChain);
  trace.hresult = static_cast<int32_t>(hr);
  if (SUCCEEDED(hr) && ppSourceVoice != nullptr && *ppSourceVoice != nullptr) {
    trace.source = reinterpret_cast<uintptr_t>(*ppSourceVoice);
    if (has_format) {
      fushi_voice_hook::XAudioSourceSnapshot registered;
      if (g_xaudio_formats.Register(
              reinterpret_cast<uintptr_t>(*ppSourceVoice),
              reinterpret_cast<uintptr_t>(self), format, &registered)) {
        trace.source_generation = registered.generation;
        trace.queue_generation = registered.queue_generation;
        trace.outcome = static_cast<uint32_t>(
            fushi_voice_hook::XAudioTraceOutcome::kRegistryRegistered);
        if (format.encoding ==
            fushi_voice_hook::XAudioSourceEncoding::kMicrosoftAdpcm) {
          if (g_header != nullptr) {
            InterlockedOr(reinterpret_cast<volatile LONG*>(
                              &g_header->reserved_hook_diagnostics),
                          static_cast<LONG>(
                              fushi_voice_hook::kDiagXAudioAdpcmObserved));
          }
        } else {
          MaybeRecordPcmFormat(
              format.sample_rate, format.channels, format.bits_per_sample,
              format.encoding ==
                      fushi_voice_hook::XAudioSourceEncoding::kPcmFloat
                  ? 1u
                  : 0u);
        }
      } else {
        trace.outcome = static_cast<uint32_t>(
            fushi_voice_hook::XAudioTraceOutcome::kRegistryExhausted);
        IncrementXAudioCounter(&g_xaudio_capture_counters.registry_exhausted);
        SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagRegistryExhausted);
      }
    } else {
      trace.outcome = static_cast<uint32_t>(
          fushi_voice_hook::XAudioTraceOutcome::kFormatUnsupported);
      IncrementXAudioCounter(&g_xaudio_capture_counters.unsupported_format);
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagUnsupportedFormat);
    }
    HookFnWithOriginalRegistry(
        VtableSlot(*ppSourceVoice, kIdxSubmitSourceBuffer),
        reinterpret_cast<void*>(&Detour_SubmitSourceBuffer),
        &g_submit_source_buffer_originals);
    HookFn(VtableSlot(*ppSourceVoice, kIdxSourceVoiceStart),
           reinterpret_cast<void*>(&Detour_SourceVoiceStart),
           reinterpret_cast<void**>(&g_orig_SourceVoiceStart));
    HookFn(VtableSlot(*ppSourceVoice, kIdxSourceVoiceStop),
           reinterpret_cast<void*>(&Detour_SourceVoiceStop),
           reinterpret_cast<void**>(&g_orig_SourceVoiceStop));
    HookFnWithOriginalRegistry(
        VtableSlot(*ppSourceVoice, kIdxFlushSourceBuffers),
        reinterpret_cast<void*>(&Detour_FlushSourceBuffers),
        &g_flush_source_buffers_originals);
    HookFn(VtableSlot(*ppSourceVoice, kIdxDestroyVoice),
           reinterpret_cast<void*>(&Detour_DestroyVoice),
           reinterpret_cast<void**>(&g_orig_DestroyVoice));
  } else {
    trace.outcome = static_cast<uint32_t>(
        fushi_voice_hook::XAudioTraceOutcome::kOriginalFailed);
  }
  PublishXAudioTrace(&trace);
  return hr;
}

// 对一个 IXAudio2 实例 vtable-hook 其 CreateSourceVoice（去重：所有实例共享同一 vtable）。
void HookCreateSourceVoiceOn(IXAudio2* x) {
  if (x == nullptr) {
    return;
  }
  HookFn(VtableSlot(x, kIdxCreateSourceVoice),
         reinterpret_cast<void*>(&Detour_CreateSourceVoice),
         reinterpret_cast<void**>(&g_orig_CreateSourceVoice));
  HookFn(VtableSlot(x, kIdxCommitChanges),
         reinterpret_cast<void*>(&Detour_CommitChanges),
         reinterpret_cast<void**>(&g_orig_CommitChanges));
}

// ── C.2 detour：导出的 XAudio2Create（xaudio2_9/8.dll）──────────────────────
// 先调原函数拿到 IXAudio2*，再包裹它的 CreateSourceVoice。2.9 / 2.8 各一份（不同 DLL 不同
// 地址、各自 trampoline）。
HRESULT WINAPI Detour_XAudio2Create9(IXAudio2** ppXAudio2, UINT32 Flags,
                                     XAUDIO2_PROCESSOR XAudio2Processor) {
  const HRESULT hr = g_orig_XAudio2Create9(ppXAudio2, Flags, XAudio2Processor);
  if (SUCCEEDED(hr) && ppXAudio2 != nullptr) {
    HookCreateSourceVoiceOn(*ppXAudio2);
  }
  return hr;
}
HRESULT WINAPI Detour_XAudio2Create8(IXAudio2** ppXAudio2, UINT32 Flags,
                                     XAUDIO2_PROCESSOR XAudio2Processor) {
  const HRESULT hr = g_orig_XAudio2Create8(ppXAudio2, Flags, XAudio2Processor);
  if (SUCCEEDED(hr) && ppXAudio2 != nullptr) {
    HookCreateSourceVoiceOn(*ppXAudio2);
  }
  return hr;
}

// hook 导出的 XAudio2Create。用 GetModuleHandle 拿已加载的 xaudio2 模块；未加载则 LoadLibrary
// 强制解析导出（系统有则 refcount+1，游戏随后调 XAudio2Create 命中同一地址触发 detour；无则
// 跳过）。2.9 优先（Win10 主流），2.8 兜底（Win8 引擎）。
//
// 局限（需真实游戏验证）：只捕获注入**之后**创建的 XAudio2/voice——若游戏在注入前已建好引擎
// 与全部 source voice，会漏掉（需 hook LoadLibrary 或注入更早，留待 C.3/C.4）。
void TryHookXAudio2Create() {
  struct Candidate {
    const wchar_t* dll;
    void* detour;
    void** original;
  };
  const Candidate cands[] = {
      {L"xaudio2_9.dll", reinterpret_cast<void*>(&Detour_XAudio2Create9),
       reinterpret_cast<void**>(&g_orig_XAudio2Create9)},
      {L"xaudio2_8.dll", reinterpret_cast<void*>(&Detour_XAudio2Create8),
       reinterpret_cast<void**>(&g_orig_XAudio2Create8)},
  };
  for (const auto& c : cands) {
    HMODULE mod = GetModuleHandleW(c.dll);
    if (mod == nullptr) {
      mod = LoadLibraryW(c.dll);
    }
    if (mod == nullptr) {
      continue;
    }
    void* fn = reinterpret_cast<void*>(GetProcAddress(mod, "XAudio2Create"));
    HookFn(fn, c.detour, c.original);
  }
}
// ══ C.2b DirectSound 捕获链（旧引擎 KiriKiri/吉里吉里等）══════════════════════════
// XAudio2 之外的另一条混音前干净语音路径，装法与 XAudio2 同构：hook 导出的 DirectSoundCreate8/
// DirectSoundCreate 拿到 IDirectSound8*，包裹它的 CreateSoundBuffer(槽3)；每建一个 secondary
// buffer 就 vtable-hook 该 buffer 的 Unlock(槽19)，在游戏写完 PCM、Unlock 回锁前 memcpy 走。

// ── detour：IDirectSoundBuffer::Unlock（槽19）─────────────────────────────────
// 游戏把 PCM 写进锁定区后调 Unlock 交还；pv1/cb1（+回绕段 pv2/cb2）正是刚写完的字节区与实际
// 字节数，无需和 Lock 关联、无需 map，直接 memcpy 进环形缓冲。零阻塞红线：只 RingAppendVoice，
// 绝不加锁/分配/IO/日志。
HRESULT STDMETHODCALLTYPE Detour_DsbUnlock(IDirectSoundBuffer* self, LPVOID pv1,
                                           DWORD cb1, LPVOID pv2, DWORD cb2) {
  if (g_capture_enabled && g_header != nullptr) {
    fushi_voice_hook::DirectSoundPcmFormat format;
    if (!g_dsound_formats.Lookup(reinterpret_cast<uintptr_t>(self), &format)) {
      return g_orig_DsbUnlock(self, pv1, cb1, pv2, cb2);
    }
    // C.3：一次 Unlock = 一段语音；pv2/cb2 是 DS 缓冲回绕的第二片，与 pv1 须在环形里连续，合成
    // 一条 clip。多写者下必须**一次预留整段**再分段写入，否则并发写者可能插进 pv1/pv2 之间，
    // 破坏 [ring_offset, byte_len) 的连续性。
    uint32_t seg_len = 0;
    if (pv1 != nullptr && cb1 != 0) {
      seg_len += cb1;
    }
    if (pv2 != nullptr && cb2 != 0) {
      seg_len += cb2;
    }
    if (seg_len != 0 && seg_len <= g_ring_capacity) {
      const uint32_t off = RingReserve(seg_len);
      uint32_t at = off;
      if (pv1 != nullptr && cb1 != 0) {
        RingWriteAt(at, reinterpret_cast<const uint8_t*>(pv1), cb1);
        at += cb1;
      }
      if (pv2 != nullptr && cb2 != 0) {
        RingWriteAt(at, reinterpret_cast<const uint8_t*>(pv2), cb2);
      }
      RecordVoiceClipFmt(off, seg_len, reinterpret_cast<uint64_t>(self),
                         format.sample_rate, format.channels,
                         format.bits_per_sample, format.is_float);
    }
  }
  return g_orig_DsbUnlock(self, pv1, cb1, pv2, cb2);
}

// SetFrequency 改变的是该 buffer 的实际播放采样率，WAVEFORMATEX 本身不会随之变化；格式表还
// 必须同步这个有效采样率，不能退回首个 buffer 的全局格式。
HRESULT STDMETHODCALLTYPE Detour_DsbSetFrequency(IDirectSoundBuffer* self,
                                                 DWORD frequency) {
  const HRESULT hr = g_orig_DsbSetFrequency(self, frequency);
  if (SUCCEEDED(hr)) {
    // DSBFREQUENCY_ORIGINAL == 0；registry 用 0 恢复创建时采样率。
    g_dsound_formats.SetFrequency(reinterpret_cast<uintptr_t>(self),
                                  static_cast<uint32_t>(frequency));
  }
  return hr;
}

// ── detour：IDirectSound8::CreateSoundBuffer（槽3）────────────────────────────
// 先调原函数建 buffer，成功后按两道门决定是否 hook 它的 Unlock：
//  ① 跳过主缓冲（DSBCAPS_PRIMARYBUFFER）：主缓冲是最终混音目标，抓它=抓混音不干净；只要
//     secondary（每个音单独的流）。
//  ② 记录每个 secondary 自己的格式，并跟踪 SetFrequency 的实际播放采样率。Unlock 的 vtable
//     实现由不同 buffer 共享，装一次 detour 后会命中所有 buffer，不能靠“只给同格式对象装 hook”
//     做对象级门控。共享环可混存不同格式，因为每条 VoiceClip 都携带独立格式；host 按 source
//     分组后再合成。
HRESULT STDMETHODCALLTYPE Detour_CreateSoundBuffer(IDirectSound8* self,
                                                   LPCDSBUFFERDESC pcDesc,
                                                   LPDIRECTSOUNDBUFFER* ppBuf,
                                                   LPUNKNOWN pUnkOuter) {
  const HRESULT hr = g_orig_CreateSoundBuffer(self, pcDesc, ppBuf, pUnkOuter);
  if (SUCCEEDED(hr) && pcDesc != nullptr && ppBuf != nullptr &&
      *ppBuf != nullptr && g_header != nullptr) {
    const bool is_primary = (pcDesc->dwFlags & DSBCAPS_PRIMARYBUFFER) != 0;
    const WAVEFORMATEX* fmt = pcDesc->lpwfxFormat;
    if (!is_primary && fmt != nullptr) {
      MaybeRecordFormat(fmt);
      uint32_t is_float = 0;
      if (fmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        is_float = 1;
      } else if (fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
                 fmt->cbSize >=
                     sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
        const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(fmt);
        if (ext->SubFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT) {
          is_float = 1;
        }
      }
      const fushi_voice_hook::DirectSoundPcmFormat format{
          fmt->nSamplesPerSec, fmt->nChannels, fmt->wBitsPerSample, is_float};
      if (g_dsound_formats.Register(
              reinterpret_cast<uintptr_t>(*ppBuf), format)) {
        HookFn(VtableSlot(*ppBuf, kIdxDsbSetFrequency),
               reinterpret_cast<void*>(&Detour_DsbSetFrequency),
               reinterpret_cast<void**>(&g_orig_DsbSetFrequency));
        HookFn(VtableSlot(*ppBuf, kIdxDsbUnlock),
               reinterpret_cast<void*>(&Detour_DsbUnlock),
               reinterpret_cast<void**>(&g_orig_DsbUnlock));
      }
    }
  }
  return hr;
}

// 对一个 IDirectSound(8) 实例 vtable-hook 其 CreateSoundBuffer（去重：dsound 对象共享同一
// vtable）。参数用 void*：DirectSoundCreate 返回 IDirectSound*、DirectSoundCreate8 返回
// IDirectSound8*，两者 CreateSoundBuffer 都在槽 3、同一实现地址。
void HookCreateSoundBufferOn(void* ds) {
  if (ds == nullptr) {
    return;
  }
  HookFn(VtableSlot(ds, kIdxCreateSoundBuffer),
         reinterpret_cast<void*>(&Detour_CreateSoundBuffer),
         reinterpret_cast<void**>(&g_orig_CreateSoundBuffer));
}

// ── detour：导出的 DirectSoundCreate8 / DirectSoundCreate ─────────────────────
// 先调原函数拿到 IDirectSound(8)*，成功后包裹它的 CreateSoundBuffer。两个导出各一份（不同
// 地址、各自 trampoline）；返回对象的 CreateSoundBuffer 都在槽 3。
HRESULT WINAPI Detour_DirectSoundCreate8(LPCGUID pcGuidDevice,
                                         LPDIRECTSOUND8* ppDS8,
                                         LPUNKNOWN pUnkOuter) {
  const HRESULT hr = g_orig_DirectSoundCreate8(pcGuidDevice, ppDS8, pUnkOuter);
  if (SUCCEEDED(hr) && ppDS8 != nullptr && *ppDS8 != nullptr) {
    HookCreateSoundBufferOn(*ppDS8);
  }
  return hr;
}
HRESULT WINAPI Detour_DirectSoundCreate(LPCGUID pcGuidDevice,
                                        LPDIRECTSOUND* ppDS,
                                        LPUNKNOWN pUnkOuter) {
  const HRESULT hr = g_orig_DirectSoundCreate(pcGuidDevice, ppDS, pUnkOuter);
  if (SUCCEEDED(hr) && ppDS != nullptr && *ppDS != nullptr) {
    HookCreateSoundBufferOn(*ppDS);
  }
  return hr;
}

// SiglusEngine 1.1.x 不走 DirectSoundCreate(8) 导出，而是经 COM 创建 DirectSound 对象。
// 捕获 CLSID_DirectSound/CLSID_DirectSound8 的返回接口后，复用同一 CreateSoundBuffer vtable
// hook。这样既给 raw OVK 路径提供 status/混音兜底，也覆盖其它采用 COM 建 DS 的引擎。
constexpr GUID kClsidDirectSound = {
    0x47d4d946, 0x62e8, 0x11cf, {0x93, 0xbc, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00}};
constexpr GUID kClsidDirectSound8 = {
    0x3901cc3f, 0x84b5, 0x4fa4, {0xba, 0x35, 0xaa, 0x81, 0x72, 0xb8, 0xa0, 0x9b}};

bool SameGuid(REFCLSID a, const GUID& b) {
  return memcmp(&a, &b, sizeof(GUID)) == 0;
}

HRESULT WINAPI Detour_CoCreateInstance(REFCLSID rclsid, LPUNKNOWN pUnkOuter,
                                        DWORD dwClsContext, REFIID riid,
                                        LPVOID* ppv) {
  const HRESULT hr = g_orig_CoCreateInstance(rclsid, pUnkOuter, dwClsContext,
                                              riid, ppv);
  if (SUCCEEDED(hr) && ppv != nullptr && *ppv != nullptr &&
      (SameGuid(rclsid, kClsidDirectSound) ||
       SameGuid(rclsid, kClsidDirectSound8))) {
    if (g_header != nullptr) {
      g_header->reserved_luna |= 0x08000000u;
    }
    HookCreateSoundBufferOn(*ppv);
  }
  return hr;
}

// hook 导出的 DirectSoundCreate8 + DirectSoundCreate（dsound.dll，未加载则 LoadLibrary 强制
// 解析导出）。
//
// 局限（需真实游戏验证，保留诚实）：只捕获注入**之后**创建的 DS 对象/buffer（注入前已建好的
// 漏掉）；捕获**所有同格式 secondary buffer**——BGM/语音/SE 若同格式会一起进环形缓冲，按
// callsite/音量精筛只留角色语音留给 C.3；跨格式 buffer 已被格式门控排除。
void TryHookDirectSoundCreate() {
  HMODULE mod = GetModuleHandleW(L"dsound.dll");
  if (mod == nullptr) {
    mod = LoadLibraryW(L"dsound.dll");
  }
  if (mod == nullptr) {
    return;
  }
  void* c8 = reinterpret_cast<void*>(GetProcAddress(mod, "DirectSoundCreate8"));
  HookFn(c8, reinterpret_cast<void*>(&Detour_DirectSoundCreate8),
         reinterpret_cast<void**>(&g_orig_DirectSoundCreate8));
  void* c0 = reinterpret_cast<void*>(GetProcAddress(mod, "DirectSoundCreate"));
  HookFn(c0, reinterpret_cast<void*>(&Detour_DirectSoundCreate),
         reinterpret_cast<void**>(&g_orig_DirectSoundCreate));

  HMODULE ole = GetModuleHandleW(L"ole32.dll");
  if (ole == nullptr) {
    ole = LoadLibraryW(L"ole32.dll");
  }
  if (ole != nullptr) {
    HookFn(reinterpret_cast<void*>(GetProcAddress(ole, "CoCreateInstance")),
           reinterpret_cast<void*>(&Detour_CoCreateInstance),
           reinterpret_cast<void**>(&g_orig_CoCreateInstance));
  }
}
