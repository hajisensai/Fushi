#undef NDEBUG
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <type_traits>

// Intercept only this translation unit's 32-bit shared-memory operations. The
// production implementation has no testing hook: pause after its first request
// snapshot has loaded its final sequence, before it can act on that snapshot.
LONG TestInterlockedCompareExchange(volatile LONG* destination, LONG exchange,
                                    LONG comparand);
#pragma push_macro("InterlockedCompareExchange")
#undef InterlockedCompareExchange
#define InterlockedCompareExchange TestInterlockedCompareExchange
#include "voice_hook_ipc.h"
#pragma pop_macro("InterlockedCompareExchange")

namespace {
using fushi_voice_hook::SharedHeader;

std::atomic<DWORD> g_paused_thread{0};
std::atomic<volatile LONG*> g_request_seq{nullptr};
std::atomic<unsigned> g_request_reads{0};
std::atomic<bool> g_gate_timed_out{false};
HANDLE g_snapshot_loaded = nullptr;
HANDLE g_resume_publisher = nullptr;
int g_checks = 0;

void Check(bool condition, const char* message) {
  ++g_checks;
  if (condition) return;
  std::fprintf(stderr, "game_stream_input_ipc_concurrency_test: %s\n", message);
  std::exit(EXIT_FAILURE);
}

void TestOldAckCannotPolluteNewRequest() {
  SharedHeader header{};
  const uint32_t a_seq = fushi_voice_hook::PublishGameStreamInputRequest(
      &header, 0x1010u, 1u, fushi_voice_hook::kGameStreamInputButtonLeft,
      10000u);
  const auto a = fushi_voice_hook::ReadGameStreamInputRequest(&header);
  Check(a_seq == 1u && a.valid, "A request must publish");

  g_snapshot_loaded = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  g_resume_publisher = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  Check(g_snapshot_loaded != nullptr && g_resume_publisher != nullptr,
        "test synchronization events must be created");
  g_request_seq.store(reinterpret_cast<volatile LONG*>(
      &header.game_stream_input_request_seq));
  g_request_reads.store(0);
  g_gate_timed_out.store(false);
  std::atomic<bool> a_published{true};
  std::thread old_publisher([&] {
    g_paused_thread.store(GetCurrentThreadId());
    a_published.store(fushi_voice_hook::PublishGameStreamInputStatus(
        &header, a, fushi_voice_hook::kGameStreamInputStatusApplied,
        fushi_voice_hook::kGameStreamInputButtonLeft));
  });
  Check(WaitForSingleObject(g_snapshot_loaded, 5000) == WAIT_OBJECT_0,
        "A must pause after loading its first complete request snapshot");

  // A's initial request-match check will use its already loaded A snapshot.
  // B becomes current and fully acknowledged while A is paused inside that
  // first check; invoking an old publisher only after B would miss this race.
  const uint32_t b_seq = fushi_voice_hook::PublishGameStreamInputRequest(
      &header, 0x1010u, 2u, 0u, 11000u);
  const auto b = fushi_voice_hook::ReadGameStreamInputRequest(&header);
  Check(b_seq == 2u && b.valid && b.transaction_id == 2u,
        "B request must publish after A");
  Check(fushi_voice_hook::PublishGameStreamInputStatus(
            &header, b, fushi_voice_hook::kGameStreamInputStatusExpired, 0u),
        "B status must publish");
  const uint32_t b_status_seq = header.game_stream_input_status_seq;
  Check(header.game_stream_input_applied_seq == b_seq &&
            header.game_stream_input_status ==
                fushi_voice_hook::kGameStreamInputStatusExpired &&
            header.game_stream_input_observed_buttons == 0,
        "B payload must be stable before stale A resumes");

  SetEvent(g_resume_publisher);
  old_publisher.join();
  g_paused_thread.store(0);
  g_request_seq.store(nullptr);
  CloseHandle(g_snapshot_loaded);
  CloseHandle(g_resume_publisher);
  Check(!g_gate_timed_out.load(), "A must resume only after B is acknowledged");
  Check(!a_published.load(), "A must be rejected after its initial stale check");
  Check(header.game_stream_input_status_seq == b_status_seq &&
            header.game_stream_input_applied_seq == b_seq &&
            header.game_stream_input_status ==
                fushi_voice_hook::kGameStreamInputStatusExpired &&
            header.game_stream_input_observed_buttons == 0,
        "resumed A must not overwrite B status/observed buttons/applied seq");
}

void TestStatusGenerationIsIndependentFromRequestSeq() {
  SharedHeader header{};
  const uint32_t request_seq = fushi_voice_hook::PublishGameStreamInputRequest(
      &header, 0x2020u, 7u, fushi_voice_hook::kGameStreamInputButtonLeft,
      12000u);
  const auto request = fushi_voice_hook::ReadGameStreamInputRequest(&header);
  Check(request_seq == 1u && request.valid, "request must publish");
  Check(fushi_voice_hook::PublishGameStreamInputStatus(
            &header, request, fushi_voice_hook::kGameStreamInputStatusApplied,
            fushi_voice_hook::kGameStreamInputButtonLeft),
        "first status publish must succeed");
  const uint32_t first_status_seq = header.game_stream_input_status_seq;
  Check(first_status_seq != 0,
        "status generation must publish a stable non-zero value");
  Check(fushi_voice_hook::PublishGameStreamInputStatus(
            &header, request, fushi_voice_hook::kGameStreamInputStatusRejectedTarget,
            0u),
        "second status publish for same request must succeed");
  Check(header.game_stream_input_status_seq != first_status_seq &&
            header.game_stream_input_applied_seq == request_seq &&
            header.game_stream_input_status ==
                fushi_voice_hook::kGameStreamInputStatusRejectedTarget &&
            header.game_stream_input_observed_buttons == 0,
        "same-request status update must advance status generation");
}

void TestBusyStatusWriterCannotOverwriteAcknowledgement() {
  SharedHeader header{};
  fushi_voice_hook::PublishGameStreamInputRequest(
      &header, 0x3030u, 9u, fushi_voice_hook::kGameStreamInputButtonLeft,
      13000u);
  const auto request = fushi_voice_hook::ReadGameStreamInputRequest(&header);
  fushi_voice_hook::AtomicStoreShared32(
      &header.game_stream_input_status_seq,
      fushi_voice_hook::kGameStreamInputRequestWriteInProgress | 3u);
  Check(!fushi_voice_hook::PublishGameStreamInputStatus(
            &header, request, fushi_voice_hook::kGameStreamInputStatusApplied,
            fushi_voice_hook::kGameStreamInputButtonLeft),
        "busy status writer must reject a competing publisher");
  Check(header.game_stream_input_status_seq ==
            (fushi_voice_hook::kGameStreamInputRequestWriteInProgress | 3u) &&
            header.game_stream_input_status == 0u &&
            header.game_stream_input_observed_buttons == 0u &&
            header.game_stream_input_applied_seq == 0u,
        "rejected publisher must leave the occupied status slot untouched");
}
}  // namespace

LONG TestInterlockedCompareExchange(volatile LONG* destination, LONG exchange,
                                    LONG comparand) {
  // The original Windows primitive is restored outside voice_hook_ipc.h.
  const LONG result = InterlockedCompareExchange(destination, exchange, comparand);
  if (exchange == 0 && comparand == 0 &&
      destination == g_request_seq.load() &&
      GetCurrentThreadId() == g_paused_thread.load() &&
      g_request_reads.fetch_add(1) == 1u) {
    SetEvent(g_snapshot_loaded);
    if (WaitForSingleObject(g_resume_publisher, 5000) != WAIT_OBJECT_0) {
      g_gate_timed_out.store(true);
    }
  }
  return result;
}

int main() {
  static_assert(std::is_standard_layout_v<SharedHeader>);
  TestOldAckCannotPolluteNewRequest();
  TestStatusGenerationIsIndependentFromRequestSeq();
  TestBusyStatusWriterCannotOverwriteAcknowledgement();
  std::printf("game_stream_input_ipc_concurrency_test: 3 cases, %d checks passed\n",
              g_checks);
  return 0;
}
