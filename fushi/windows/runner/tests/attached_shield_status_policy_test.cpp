// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"（CI 的 C4189「变量没人引用」正是它漏出来的痕迹）。
// 与 attached_mouse_hook_nonblocking_source_test.cpp 同一写法。
#undef NDEBUG

#include "../attached_shield_status_policy.h"

#include <cassert>
#include <fstream>
#include <iterator>
#include <string>

#ifndef FUSHI_RUNNER_SOURCE_DIR
#error FUSHI_RUNNER_SOURCE_DIR must identify the Windows runner source tree
#endif

namespace policy = fushi::attached_shield_status_policy;

namespace {

std::string FunctionSlice(const std::string &source, const char *start,
                          const char *next) {
  const size_t begin = source.find(start);
  assert(begin != std::string::npos);
  const size_t end = source.find(next, begin + 1);
  assert(end != std::string::npos);
  return source.substr(begin, end - begin);
}

policy::StatusIdentity AcknowledgedProbe(uint64_t target, uint64_t transaction,
                                         uint32_t sequence) {
  policy::StatusIdentity status;
  status.available = true;
  status.request_seq = sequence;
  status.applied_seq = sequence;
  status.owner_kind = policy::kOwnerNativeGlyph;
  status.target_hwnd = target;
  status.transaction_id = transaction;
  return status;
}

void TestSamePidReplacementCannotBorrowOldFault() {
  constexpr policy::Epoch epoch{11u, 7u};
  constexpr uint64_t old_target = 0x100u;
  constexpr uint64_t new_target = 0x200u;
  constexpr uint64_t transaction = 0x700000001u;
  constexpr uint32_t sequence = 9u;
  const policy::HandshakeIdentity new_handshake{epoch, new_target, transaction,
                                                sequence};

  policy::StatusIdentity old_fault =
      AcknowledgedProbe(old_target, transaction, sequence);
  old_fault.status_flags = 0x8u;
  assert(
      policy::ClassifyHandshake(old_fault, new_handshake, epoch, new_target) ==
      policy::Attribution::kForeign);
  // The old request may be replaced only after its active tail is neutral.
  assert(policy::IsNeutralForRehandshake(old_fault));
  old_fault.active_buttons = 1u;
  assert(!policy::IsNeutralForRehandshake(old_fault));
}

void TestEpochAndTransactionFenceTheHandshake() {
  constexpr policy::Epoch current_epoch{12u, 4u};
  constexpr policy::Epoch old_epoch{12u, 3u};
  constexpr uint64_t target = 0x345u;
  constexpr uint64_t transaction = 0x400000001u;
  constexpr uint32_t sequence = 21u;
  const policy::HandshakeIdentity handshake{old_epoch, target, transaction,
                                            sequence};
  const policy::StatusIdentity status =
      AcknowledgedProbe(target, transaction, sequence);
  assert(policy::ClassifyHandshake(status, handshake, current_epoch, target) ==
         policy::Attribution::kForeign);

  const policy::HandshakeIdentity current{current_epoch, target, transaction,
                                          sequence};
  policy::StatusIdentity wrong_transaction = status;
  wrong_transaction.transaction_id++;
  assert(policy::ClassifyHandshake(wrong_transaction, current, current_epoch,
                                   target) == policy::Attribution::kForeign);
}

void TestPendingChallengeAndStuckTransactionRemainBlocked() {
  constexpr policy::Epoch epoch{13u, 2u};
  constexpr uint64_t target = 0x456u;
  constexpr uint64_t transaction = 0x200000001u;
  constexpr uint32_t sequence = 31u;
  const policy::HandshakeIdentity handshake{epoch, target, transaction,
                                            sequence};
  policy::StatusIdentity pending =
      AcknowledgedProbe(target, transaction, sequence);
  pending.applied_seq = sequence - 1u;
  assert(policy::ClassifyHandshake(pending, handshake, epoch, target) ==
         policy::Attribution::kPending);
  assert(!policy::IsNeutralForRehandshake(pending));

  pending.applied_seq = sequence;
  pending.status_flags = policy::kStatusTransactionActive;
  assert(!policy::IsNeutralForRehandshake(pending));
}

void TestAttachedRequestsNeedAnEstablishedEpochHandshake() {
  constexpr policy::Epoch epoch{14u, 8u};
  constexpr uint64_t target = 0x567u;
  constexpr policy::HandshakeIdentity handshake{epoch, target, 0x800000001u,
                                                41u};
  policy::StatusIdentity attached;
  attached.available = true;
  attached.request_seq = 42u;
  attached.applied_seq = 42u;
  attached.owner_kind = policy::kOwnerAttachedGlyph;
  attached.target_hwnd = target;
  attached.transaction_id = 0x900000001u;
  assert(policy::ClassifyAttachedAfterHandshake(attached, false, handshake,
                                                epoch, target) ==
         policy::Attribution::kForeign);
  assert(policy::ClassifyAttachedAfterHandshake(attached, true, handshake,
                                                epoch, target) ==
         policy::Attribution::kAcknowledged);
  attached.applied_seq--;
  assert(policy::ClassifyAttachedAfterHandshake(attached, true, handshake,
                                                epoch, target) ==
         policy::Attribution::kPending);
}

void TestVerifiedCoverageOverridesPersistedRiskPreference() {
  assert(!policy::EffectiveAllowRisk(true, true));
  assert(policy::EffectiveAllowRisk(true, false));
  assert(!policy::EffectiveAllowRisk(false, false));
}

void TestSurfaceWiresRebindAndEffectiveRiskPolicy() {
  std::ifstream input(std::string(FUSHI_RUNNER_SOURCE_DIR) +
                      "/attached_text_surface_window.cpp");
  assert(input.good());
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());

  const std::string rebind =
      FunctionSlice(source, "bool AttachedTextSurfaceWindow::TryRebindTarget(",
                    "bool AttachedTextSurfaceWindow::RefreshTargetClient(");
  const size_t hide = rebind.find("HideSurface();");
  const size_t reset = rebind.find("ResetShieldHandshake();");
  const size_t replace = rebind.find("target_ = std::move(rebound);");
  assert(hide != std::string::npos && reset > hide && replace > reset);

  const std::string sync =
      FunctionSlice(source, "void AttachedTextSurfaceWindow::SyncToTarget() {",
                    "void AttachedTextSurfaceWindow::HideSurface() {");
  assert(sync.find("EnsureShieldHandshake()") != std::string::npos);
  assert(sync.find("shieldHandshakePending") != std::string::npos);

  const std::string publish = FunctionSlice(
      source, "bool AttachedTextSurfaceWindow::PublishInteractiveSnapshot(",
      "void AttachedTextSurfaceWindow::RenderLayerBitmap(");
  assert(publish.find("const bool effective_allow_risk = "
                      "EffectiveAllowRisk();") != std::string::npos);
  assert(publish.find("published_snapshot_allow_risk_ = "
                      "effective_allow_risk;") != std::string::npos);

  const std::string adopt = FunctionSlice(
      source, "bool AttachedTextSurfaceWindow::AdoptShieldTransaction(",
      "void AttachedTextSurfaceWindow::ReleaseShieldTransaction(");
  assert(adopt.find("allow_risk = published_snapshot_allow_risk_") !=
         std::string::npos);
}

} // namespace

int main() {
  TestSamePidReplacementCannotBorrowOldFault();
  TestEpochAndTransactionFenceTheHandshake();
  TestPendingChallengeAndStuckTransactionRemainBlocked();
  TestAttachedRequestsNeedAnEstablishedEpochHandshake();
  TestVerifiedCoverageOverridesPersistedRiskPreference();
  TestSurfaceWiresRebindAndEffectiveRiskPolicy();
  return 0;
}
