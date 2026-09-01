// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <type_traits>

#include "voice_hook_ipc.h"

namespace {

using fushi_voice_hook::NativeLoopbackPolicyAction;
using fushi_voice_hook::NativeLoopbackRequestSnapshot;
using fushi_voice_hook::NativeLoopbackWorkerPhase;
using fushi_voice_hook::SharedHeader;

static_assert(std::is_standard_layout_v<SharedHeader>);
static_assert(std::is_trivially_copyable_v<SharedHeader>);

void Check(bool condition, const char* message) {
  if (condition) return;
  std::fprintf(stderr, "native_loopback_policy_test: %s\n", message);
  std::abort();
}

void TestV16AndV17TailAbiAndDefaultDeny() {
  SharedHeader header{};
  Check(fushi_voice_hook::kSharedVersion == 21,
        "shared ABI must be v21（native input admission 与 geometry discovery 分离）");
  Check(offsetof(SharedHeader, native_loopback_request_seq) ==
            offsetof(SharedHeader, native_loopback_requested) + 4,
        "request_seq must follow requested");
  Check(offsetof(SharedHeader, native_loopback_state) ==
            offsetof(SharedHeader, native_loopback_requested) + 8,
        "state must be the third v16 word");
  Check(offsetof(SharedHeader, native_loopback_applied_seq) ==
            offsetof(SharedHeader, native_loopback_requested) + 12,
        "applied_seq must be the final v16 word");
  // v17 appends the resident hook module digest right after the last v16 word;
  // nothing else may grow between them or after it.
  Check(offsetof(SharedHeader, hook_module_sha256) ==
            offsetof(SharedHeader, native_loopback_applied_seq) + 4,
        "v17 digest must directly follow the final v16 word");
  const size_t digest_end = offsetof(SharedHeader, hook_module_sha256) +
                            fushi_voice_hook::kHookModuleDigestChars;
  Check(offsetof(SharedHeader, lookup_geometry_active_kind) ==
            (digest_end + 3u) / 4u * 4u,
        "v19 fields must append after the naturally aligned v17 digest");
  // v19 在 v17 摘要之后追加了查词准入三字段，所以尾部不再是摘要。这里改锁"v16 policy
  // 与 v17 摘要之间没有任何东西长出来"，以及"v19 是紧接摘要的纯追加"——这条守卫要防的
  // 是**把字段插进既有布局**，不是禁止将来继续尾追加。
  Check(offsetof(SharedHeader, lookup_admission) >=
            offsetof(SharedHeader, hook_module_sha256) +
                fushi_voice_hook::kHookModuleDigestChars,
        "v19 admission must be appended after the v17 digest, never inserted");
  Check(sizeof(SharedHeader) ==
            ((offsetof(SharedHeader, lookup_executable_sha256) +
              fushi_voice_hook::kHookModuleDigestChars + 7u) /
             8u) * 8u,
        "v19 admission digest must be the exact SharedHeader tail (only 8-align padding)");
  Check(fushi_voice_hook::AtomicLoadShared32(
            &header.native_loopback_requested) ==
            fushi_voice_hook::kNativeLoopbackDeny,
        "zero-initialized header must fail closed");
  Check(!fushi_voice_hook::ReadNativeLoopbackRequest(&header).valid,
        "seq zero is not a published request");
  Check(header.hook_module_sha256[0] == '\0',
        "zero-initialized header must expose no resident hook digest");
}

void TestPublicationIsCoherentIdempotentAndStartsAtOne() {
  SharedHeader header{};
  const uint32_t first = fushi_voice_hook::PublishNativeLoopbackRequest(
      &header, fushi_voice_hook::kNativeLoopbackDeny);
  Check(first == 1, "fresh mapping must publish seq=1");
  auto request = fushi_voice_hook::ReadNativeLoopbackRequest(&header);
  Check(request.valid && request.seq == 1 &&
            request.requested == fushi_voice_hook::kNativeLoopbackDeny,
        "fresh deny request must round-trip");
  Check(fushi_voice_hook::PublishNativeLoopbackRequest(
            &header, fushi_voice_hook::kNativeLoopbackDeny) == 1,
        "idempotent reconnect must not create a new generation");

  Check(fushi_voice_hook::PublishNativeLoopbackRequest(
            &header, fushi_voice_hook::kNativeLoopbackAllow) == 2,
        "deny->allow must advance generation");
  Check(fushi_voice_hook::PublishNativeLoopbackRequest(
            &header, fushi_voice_hook::kNativeLoopbackDeny) == 3,
        "allow->deny must advance generation");
  Check(fushi_voice_hook::PublishNativeLoopbackRequest(
            &header, fushi_voice_hook::kNativeLoopbackAllow) == 4,
        "rapid deny->allow must retain a distinct generation");

  fushi_voice_hook::AtomicStoreShared32(
      &header.native_loopback_request_seq,
      fushi_voice_hook::kNativeLoopbackRequestWriteInProgress | 4u);
  Check(!fushi_voice_hook::ReadNativeLoopbackRequest(&header).valid,
        "reader must reject a writer-held seqlock");
  fushi_voice_hook::AtomicStoreShared32(
      &header.native_loopback_request_seq, 4u);
}

void TestOnlyExactAllowCanStart() {
  const NativeLoopbackRequestSnapshot unpublished{};
  Check(fushi_voice_hook::DecideNativeLoopbackPolicyAction(
            unpublished, NativeLoopbackWorkerPhase::kAbsent, false) ==
            NativeLoopbackPolicyAction::kNone,
        "unpublished policy must not start");

  const NativeLoopbackRequestSnapshot deny{
      fushi_voice_hook::kNativeLoopbackDeny, 1, true};
  Check(fushi_voice_hook::DecideNativeLoopbackPolicyAction(
            deny, NativeLoopbackWorkerPhase::kAbsent, false) ==
            NativeLoopbackPolicyAction::kAcknowledgeStopped,
        "deny without a worker must acknowledge stopped");
  Check(fushi_voice_hook::DecideNativeLoopbackPolicyAction(
            deny, NativeLoopbackWorkerPhase::kRunning, false) ==
            NativeLoopbackPolicyAction::kRequestStop,
        "deny with a worker must request stop");

  const NativeLoopbackRequestSnapshot unknown{99, 2, true};
  Check(fushi_voice_hook::DecideNativeLoopbackPolicyAction(
            unknown, NativeLoopbackWorkerPhase::kAbsent, false) ==
            NativeLoopbackPolicyAction::kAcknowledgeStopped,
        "unknown requested value must fail closed");

  const NativeLoopbackRequestSnapshot allow{
      fushi_voice_hook::kNativeLoopbackAllow, 3, true};
  Check(fushi_voice_hook::DecideNativeLoopbackPolicyAction(
            allow, NativeLoopbackWorkerPhase::kAbsent, false) ==
            NativeLoopbackPolicyAction::kStartWorker,
        "exact allow may start a worker");
  Check(fushi_voice_hook::DecideNativeLoopbackPolicyAction(
            allow, NativeLoopbackWorkerPhase::kRunning, false) ==
            NativeLoopbackPolicyAction::kAcknowledgeRunning,
        "running allow may be acknowledged");
  Check(fushi_voice_hook::DecideNativeLoopbackPolicyAction(
            allow, NativeLoopbackWorkerPhase::kAbsent, true) ==
            NativeLoopbackPolicyAction::kAcknowledgeFailed,
        "same failed generation must not restart forever");
}

void TestRapidDenyAllowForcesGenerationBarrier() {
  const NativeLoopbackRequestSnapshot worker_one{
      fushi_voice_hook::kNativeLoopbackAllow, 1, true};
  const NativeLoopbackRequestSnapshot latest_allow{
      fushi_voice_hook::kNativeLoopbackAllow, 3, true};
  Check(fushi_voice_hook::NativeLoopbackWorkerMayCapture(worker_one, 1),
        "worker may capture only its exact allow generation");
  Check(!fushi_voice_hook::NativeLoopbackWorkerMayCapture(latest_allow, 1),
        "allow1->deny2->allow3 must stop worker generation 1");
  Check(fushi_voice_hook::DecideNativeLoopbackPolicyAction(
            latest_allow, NativeLoopbackWorkerPhase::kStopping, false) ==
            NativeLoopbackPolicyAction::kPublishStopping,
        "latest allow cannot reuse a stopping old worker");
  Check(fushi_voice_hook::DecideNativeLoopbackPolicyAction(
            latest_allow, NativeLoopbackWorkerPhase::kAbsent, false) ==
            NativeLoopbackPolicyAction::kStartWorker,
        "latest allow may start only after old worker is reaped");
  Check(!fushi_voice_hook::NativeLoopbackWorkerFailureApplies(
            latest_allow, 1, false, 1),
        "generation 1 failure must not poison latest allow generation 3");
  Check(fushi_voice_hook::NativeLoopbackWorkerFailureApplies(
            latest_allow, 3, false, 1),
        "failure applies only to its exact current generation");
  Check(!fushi_voice_hook::NativeLoopbackWorkerFailureApplies(
            latest_allow, 3, true, 1),
        "policy-driven stop is not a startup failure");
}

void TestOldGenerationCannotAcknowledgeNewRequest() {
  SharedHeader header{};
  Check(fushi_voice_hook::PublishNativeLoopbackRequest(
            &header, fushi_voice_hook::kNativeLoopbackAllow) == 1,
        "fresh allow must be generation 1");
  const NativeLoopbackRequestSnapshot old =
      fushi_voice_hook::ReadNativeLoopbackRequest(&header);
  Check(fushi_voice_hook::PublishNativeLoopbackRequest(
            &header, fushi_voice_hook::kNativeLoopbackDeny) == 2,
        "deny must be generation 2");
  Check(!fushi_voice_hook::PublishNativeLoopbackApplied(
            &header, old, fushi_voice_hook::kNativeLoopbackStateRunning),
        "old worker must not acknowledge after a newer request");
  Check(fushi_voice_hook::AtomicLoadShared32(
            &header.native_loopback_applied_seq) == 0,
        "rejected old ack must not publish applied_seq");

  const NativeLoopbackRequestSnapshot deny =
      fushi_voice_hook::ReadNativeLoopbackRequest(&header);
  Check(fushi_voice_hook::PublishNativeLoopbackApplied(
            &header, deny, fushi_voice_hook::kNativeLoopbackStateStopped),
        "current deny may acknowledge only after stopped");
  Check(fushi_voice_hook::AtomicLoadShared32(
            &header.native_loopback_state) ==
            fushi_voice_hook::kNativeLoopbackStateStopped &&
            fushi_voice_hook::AtomicLoadShared32(
                &header.native_loopback_applied_seq) == 2,
        "state must precede matching applied seq");
}

void TestSequenceWrapUsesIdentityNotOrdering() {
  SharedHeader header{};
  fushi_voice_hook::AtomicStoreShared32(
      &header.native_loopback_requested,
      fushi_voice_hook::kNativeLoopbackDeny);
  fushi_voice_hook::AtomicStoreShared32(
      &header.native_loopback_request_seq,
      fushi_voice_hook::kNativeLoopbackRequestSequenceMask);
  Check(fushi_voice_hook::PublishNativeLoopbackRequest(
            &header, fushi_voice_hook::kNativeLoopbackAllow) == 1,
        "31-bit generation wrap must skip reserved zero");
  const auto request = fushi_voice_hook::ReadNativeLoopbackRequest(&header);
  Check(request.valid && request.seq == 1 &&
            fushi_voice_hook::NativeLoopbackWorkerMayCapture(request, 1),
        "wrapped generation is compared by identity, not greater-than");
}

}  // namespace

int main() {
  TestV16AndV17TailAbiAndDefaultDeny();
  TestPublicationIsCoherentIdempotentAndStartsAtOne();
  TestOnlyExactAllowCanStart();
  TestRapidDenyAllowForcesGenerationBarrier();
  TestOldGenerationCannotAcknowledgeNewRequest();
  TestSequenceWrapUsesIdentityNotOrdering();
  return 0;
}
