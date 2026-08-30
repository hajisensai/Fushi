#ifndef RUNNER_ATTACHED_SHIELD_STATUS_POLICY_H_
#define RUNNER_ATTACHED_SHIELD_STATUS_POLICY_H_

#include <cstdint>

namespace fushi::attached_shield_status_policy {

inline constexpr uint32_t kOwnerNativeGlyph = 1u;
inline constexpr uint32_t kOwnerAttachedGlyph = 2u;
inline constexpr uint32_t kStatusTransactionActive = 0x00000020u;

struct Epoch {
  uint64_t session = 0;
  uint64_t surface = 0;
};

struct StatusIdentity {
  bool available = false;
  uint32_t request_seq = 0;
  uint32_t applied_seq = 0;
  uint32_t owner_kind = 0;
  uint64_t target_hwnd = 0;
  uint64_t transaction_id = 0;
  uint32_t active_buttons = 0;
  bool allow_risk = false;
  uint32_t status_flags = 0;
};

struct HandshakeIdentity {
  Epoch epoch;
  uint64_t target_hwnd = 0;
  uint64_t transaction_id = 0;
  uint32_t request_seq = 0;
};

enum class Attribution {
  kForeign,
  kPending,
  kAcknowledged,
};

inline bool SameEpoch(const Epoch &left, const Epoch &right) {
  return left.session == right.session && left.surface == right.surface &&
         left.session != 0 && left.surface != 0;
}

// A neutral NativeGlyph request is a target/epoch challenge. Its request
// identity is retained only in the runner and reset whenever either logical
// epoch or HWND changes, so an acknowledged status cannot be borrowed from a
// destroyed same-PID window (or from an older surface epoch on the same HWND).
inline Attribution ClassifyHandshake(const StatusIdentity &status,
                                     const HandshakeIdentity &handshake,
                                     const Epoch &current_epoch,
                                     uint64_t current_target_hwnd) {
  if (!status.available || !SameEpoch(handshake.epoch, current_epoch) ||
      handshake.target_hwnd == 0 ||
      handshake.target_hwnd != current_target_hwnd ||
      handshake.transaction_id == 0 || handshake.request_seq == 0 ||
      status.owner_kind != kOwnerNativeGlyph ||
      status.target_hwnd != handshake.target_hwnd ||
      status.transaction_id != handshake.transaction_id ||
      status.request_seq != handshake.request_seq || status.allow_risk) {
    return Attribution::kForeign;
  }
  return status.applied_seq == status.request_seq ? Attribution::kAcknowledged
                                                  : Attribution::kPending;
}

// Once the exact challenge above was acknowledged, subsequent AttachedGlyph
// down/release requests for the same HWND remain attributable to that local
// epoch. A new epoch/HWND must establish its own challenge before this rule is
// admitted.
inline Attribution ClassifyAttachedAfterHandshake(
    const StatusIdentity &status, bool handshake_established,
    const HandshakeIdentity &handshake, const Epoch &current_epoch,
    uint64_t current_target_hwnd) {
  if (!handshake_established || !SameEpoch(handshake.epoch, current_epoch) ||
      handshake.target_hwnd != current_target_hwnd || !status.available ||
      status.owner_kind != kOwnerAttachedGlyph ||
      status.target_hwnd != current_target_hwnd || status.request_seq == 0) {
    return Attribution::kForeign;
  }
  return status.applied_seq == status.request_seq ? Attribution::kAcknowledged
                                                  : Attribution::kPending;
}

// Re-handshake may replace only a globally neutral, acknowledged request.
// This is intentionally independent of target attribution: an old dead-HWND
// fault may be superseded after its release was acknowledged, while an active,
// unacknowledged or stuck transaction continues to block the new surface.
inline bool IsNeutralForRehandshake(const StatusIdentity &status) {
  return status.available && status.active_buttons == 0 &&
         (status.request_seq == 0 ||
          status.request_seq == status.applied_seq) &&
         (status.status_flags & kStatusTransactionActive) == 0;
}

inline bool EffectiveAllowRisk(bool risk_accepted, bool shield_verified) {
  return risk_accepted && !shield_verified;
}

} // namespace fushi::attached_shield_status_policy

#endif // RUNNER_ATTACHED_SHIELD_STATUS_POLICY_H_
