// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"（CI 的 C4189「变量没人引用」正是它漏出来的痕迹）。
// 与 attached_mouse_hook_nonblocking_source_test.cpp 同一写法。
#undef NDEBUG

#include "../attached_shield_status_policy.h"
#include "../lookup_geometry_snapshot.h"

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

void TestNativeInspectionNeedsNoAttachedRiskConfiguration() {
  // BUG-2154: a native provider reaches this policy after InspectTarget only,
  // with neither a saved profile nor a Configure/StartCalibration request.
  assert(policy::kRiskAlwaysAccepted);
  assert(policy::PermitsLookup(true, false, false));  // Partial / Unknown.
  assert(policy::EffectiveAllowRisk(false));
  assert(policy::PermitsLookup(true, false, true));
  assert(!policy::EffectiveAllowRisk(true));  // Never downgrade Verified.

  // Default acceptance must not bypass a pending/foreign handshake or fault,
  // even when a stale or contradictory snapshot advertises Verified.
  for (const bool verified : {false, true}) {
    assert(!policy::PermitsLookup(false, false, verified));
    assert(!policy::PermitsLookup(false, true, verified));
    assert(!policy::PermitsLookup(true, true, verified));
  }
}

void TestDefaultAcceptanceStillRequiresCurrentStrictProbe() {
  constexpr policy::Epoch epoch{15u, 1u};
  constexpr uint64_t target = 0x678u;
  constexpr policy::HandshakeIdentity handshake{epoch, target, 0x100000001u,
                                                51u};
  policy::StatusIdentity status =
      AcknowledgedProbe(target, handshake.transaction_id, handshake.request_seq);
  status.status_flags = 0x02u;  // Partial is deliberately not Verified.
  const auto permits = [&](const policy::Epoch &current_epoch,
                           uint64_t current_target) {
    const bool acknowledged =
        policy::ClassifyHandshake(status, handshake, current_epoch,
                                  current_target) ==
        policy::Attribution::kAcknowledged;
    return policy::PermitsLookup(acknowledged, false, false);
  };
  assert(permits(epoch, target));
  status.applied_seq--;
  assert(!permits(epoch, target));
  status.applied_seq++;
  status.allow_risk = true;
  assert(!permits(epoch, target));  // The challenge itself must stay strict.
  status.allow_risk = false;
  assert(!permits({epoch.session, epoch.surface + 1u}, target));
  assert(!permits({epoch.session + 1u, epoch.surface}, target));
  assert(!permits(epoch, target + 1u));
  assert(permits(epoch, target));
}

void TestSurfaceWiresRebindAndEffectiveRiskPolicy() {
  std::ifstream input(std::string(FUSHI_RUNNER_SOURCE_DIR) +
                      "/attached_text_surface_window.cpp");
  assert(input.good());
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());

  // No constructor, epoch reset or legacy Configure(false) may restore a
  // per-session consent gate. Keep the channel argument for wire compatibility.
  assert(source.find("risk_accepted_") == std::string::npos);
  assert(source.find("riskAcceptanceRequired") == std::string::npos);
  assert(source.find("risk_acceptance_required") == std::string::npos);
  assert(source.find("snapshot.risk_accepted =\n"
                     "      fushi::attached_shield_status_policy::"
                     "kRiskAlwaysAccepted;") != std::string::npos);
  const std::string permit = FunctionSlice(
      source, "bool AttachedTextSurfaceWindow::ShieldPermitsLookup() const {",
      "void AttachedTextSurfaceWindow::OnGeometryProviderStatusChanged()");
  assert(permit.find("fushi::attached_shield_status_policy::PermitsLookup(") !=
         std::string::npos);
  assert(permit.find("ShieldStatusBelongsToCurrentHandshake(), ShieldFaulted(), "
                     "ShieldVerified()") != std::string::npos);
  const std::string risk = FunctionSlice(
      source, "bool AttachedTextSurfaceWindow::EffectiveAllowRisk() const {",
      "void AttachedTextSurfaceWindow::RefreshGeometryProviderStatus()");
  assert(risk.find("fushi::attached_shield_status_policy::EffectiveAllowRisk(\n"
                   "      ShieldVerified())") != std::string::npos);
  const std::string handshake = FunctionSlice(
      source, "AttachedTextSurfaceWindow::EnsureShieldHandshake() {",
      "bool AttachedTextSurfaceWindow::ShieldStatusBelongsToCurrentHandshake()");
  assert(handshake.find("publish_shield_probe_(target_.hwnd, transaction_id, "
                        "false)") != std::string::npos);

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

void TestGeometryReadConflictIsNotAConfirmedMissingProvider() {
  namespace geometry = fushi::lookup_geometry_snapshot;
  const geometry::Identity ready{2u, 3u, 1u, 0u, 0u};
  geometry::Identity accepted = ready;
  int reads = 0;
  const bool sampled = geometry::TryRead([&reads, &ready]() {
    geometry::Identity changing = ready;
    // Ownership changes on every read, including while generation is zero.
    changing.provider_id += static_cast<uint32_t>(++reads);
    return changing;
  }, &accepted);
  assert(!sampled);
  assert(reads == 8);  // The reader remains bounded; it never waits for a writer.
  assert(geometry::SameIdentity(accepted, ready));

  // A real, coherent None must replace the preceding Ready immediately.
  const geometry::Identity none{};
  assert(geometry::TryRead([&none]() { return none; }, &accepted));
  assert(geometry::SameIdentity(accepted, none));
  assert(geometry::TryRead([&ready]() { return ready; }, &accepted));
  assert(geometry::SameIdentity(accepted, ready));

  // Changes of lifecycle/text generation also invalidate a sample even when
  // the provider pair itself is unchanged.
  for (int field = 0; field < 3; ++field) {
    reads = 0;
    assert(!geometry::TryRead([&]() {
      geometry::Identity changing = ready;
      const uint32_t revision = static_cast<uint32_t>(++reads);
      if (field == 0) changing.provider_status = revision;
      if (field == 1) changing.text_generation = revision;
      if (field == 2) changing.generation = revision;
      return changing;
    }, &accepted));
    assert(geometry::SameIdentity(accepted, ready));
  }
}

void TestGeometryConflictIsDroppedBeforeHostMetadataPublication() {
  const auto read = [](const char* name) {
    std::ifstream input(std::string(FUSHI_RUNNER_SOURCE_DIR) + name);
    assert(input.good());
    return std::string((std::istreambuf_iterator<char>(input)),
                       std::istreambuf_iterator<char>());
  };
  const std::string reader = read("/voice_hook_reader.cpp");
  const std::string sample = FunctionSlice(
      reader, "VoiceHookLookupGeometryStatus VoiceHookReader::LookupGeometryStatus() {",
      "bool VoiceHookReader::PollLookupHit(");
  assert(sample.find("out.error = LookupGateLocked(h, false);") !=
         std::string::npos);
  assert(sample.find("if (out.error != VoiceHookLookupError::kNone) return out;") !=
         std::string::npos);  // Session errors are not classified as conflicts.
  assert(sample.find("out.error = VoiceHookLookupError::kGeometrySnapshotConflicted;") !=
         std::string::npos);
  assert(reader.find("geometry.error != VoiceHookLookupError::kGeometrySnapshotConflicted") !=
         std::string::npos);
  const std::string bridge = read("/flutter_window.cpp");
  const std::string geometry_bridge = FunctionSlice(
      bridge, "SetGeometryProviderStatusCallback([]() {",
      "SetLookupGeometryStatusSink(");
  assert(geometry_bridge.find("attached.snapshot_conflicted =") !=
         std::string::npos);
  const std::string surface = read("/attached_text_surface_window.cpp");
  const std::string refresh = FunctionSlice(
      surface, "void AttachedTextSurfaceWindow::RefreshGeometryProviderStatus() {",
      "fushi::attached_overlayability::Evaluation");
  assert(refresh.find("if (!sample.snapshot_conflicted) provider_status_ = sample;") !=
         std::string::npos);
  // Only conflicts are ignored. Confirmed None and unavailable/session errors
  // replace cached metadata; a new surface epoch never inherits old Ready.
  const std::string reset = FunctionSlice(
      surface, "void AttachedTextSurfaceWindow::AdoptNewEpoch(",
      "AttachedTextSurfaceWindow::AcceptRequest(");
  assert(reset.find("provider_status_ = GeometryProviderStatus{};") !=
         std::string::npos);
}

} // namespace

int main() {
  TestGeometryReadConflictIsNotAConfirmedMissingProvider();
  TestGeometryConflictIsDroppedBeforeHostMetadataPublication();
  TestSamePidReplacementCannotBorrowOldFault();
  TestEpochAndTransactionFenceTheHandshake();
  TestPendingChallengeAndStuckTransactionRemainBlocked();
  TestAttachedRequestsNeedAnEstablishedEpochHandshake();
  TestNativeInspectionNeedsNoAttachedRiskConfiguration();
  TestDefaultAcceptanceStillRequiresCurrentStrictProbe();
  TestSurfaceWiresRebindAndEffectiveRiskPolicy();
  return 0;
}
