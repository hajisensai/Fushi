#ifndef RUNNER_ATTACHED_OVERLAYABILITY_H_
#define RUNNER_ATTACHED_OVERLAYABILITY_H_

#include <cstdint>

namespace fushi::attached_overlayability {

// A target-specific VidPN ownership probe is preferred.  When that API is not
// available, the runtime may prove kNotExclusive only when the system-wide
// ownership probe reports that no display source is exclusively owned.
enum class ExclusiveOwnership {
  kUnknown,
  kNotExclusive,
  kExclusive,
};

enum class Failure {
  kNone,
  kCompositionQueryUnavailable,
  kCompositionDisabled,
  kSourceWindowInvalid,
  kPresentationWindowInvalid,
  kPresentationSourceMismatch,
  kPresentationHidden,
  kSourceMinimized,
  kPresentationMinimized,
  kSourceCloakUnknown,
  kSourceCloaked,
  kPresentationCloakUnknown,
  kPresentationCloaked,
  kClientUnavailable,
  kTargetExclusive,
  kExclusiveOwnershipUnknown,
  kPresentationFrameUnavailable,
  kPresentationFrameInvalid,
};

struct Facts {
  bool composition_query_succeeded = false;
  bool composition_enabled = false;
  bool source_window_valid = false;
  bool presentation_window_valid = false;
  bool presentation_matches_source = false;
  bool presentation_visible = false;
  bool source_minimized = true;
  bool presentation_minimized = true;
  bool source_cloak_query_succeeded = false;
  bool source_cloaked = true;
  bool presentation_cloak_query_succeeded = false;
  bool presentation_cloaked = true;
  bool client_has_area = false;
  ExclusiveOwnership exclusive_ownership = ExclusiveOwnership::kUnknown;
  bool presentation_frame_query_succeeded = false;
  bool presentation_frame_has_area = false;
};

struct Evaluation {
  bool overlayable = false;
  Failure failure = Failure::kSourceWindowInvalid;
};

inline Evaluation Evaluate(const Facts &facts) {
  if (!facts.composition_query_succeeded)
    return {false, Failure::kCompositionQueryUnavailable};
  if (!facts.composition_enabled)
    return {false, Failure::kCompositionDisabled};
  if (!facts.source_window_valid)
    return {false, Failure::kSourceWindowInvalid};
  if (!facts.presentation_window_valid)
    return {false, Failure::kPresentationWindowInvalid};
  if (!facts.presentation_matches_source)
    return {false, Failure::kPresentationSourceMismatch};
  if (!facts.presentation_visible)
    return {false, Failure::kPresentationHidden};
  if (facts.source_minimized)
    return {false, Failure::kSourceMinimized};
  if (facts.presentation_minimized)
    return {false, Failure::kPresentationMinimized};
  if (!facts.source_cloak_query_succeeded)
    return {false, Failure::kSourceCloakUnknown};
  if (facts.source_cloaked)
    return {false, Failure::kSourceCloaked};
  if (!facts.presentation_cloak_query_succeeded)
    return {false, Failure::kPresentationCloakUnknown};
  if (facts.presentation_cloaked)
    return {false, Failure::kPresentationCloaked};
  if (!facts.client_has_area)
    return {false, Failure::kClientUnavailable};
  if (facts.exclusive_ownership == ExclusiveOwnership::kExclusive)
    return {false, Failure::kTargetExclusive};
  if (facts.exclusive_ownership == ExclusiveOwnership::kUnknown)
    return {false, Failure::kExclusiveOwnershipUnknown};
  if (!facts.presentation_frame_query_succeeded)
    return {false, Failure::kPresentationFrameUnavailable};
  if (!facts.presentation_frame_has_area)
    return {false, Failure::kPresentationFrameInvalid};
  return {true, Failure::kNone};
}

inline const char *FailureReason(Failure failure) {
  switch (failure) {
  case Failure::kNone:
    return "";
  case Failure::kCompositionQueryUnavailable:
    return "dwm_composition_query_unavailable";
  case Failure::kCompositionDisabled:
    return "dwm_composition_unavailable";
  case Failure::kSourceWindowInvalid:
    return "overlay_source_window_invalid";
  case Failure::kPresentationWindowInvalid:
    return "overlay_presentation_window_invalid";
  case Failure::kPresentationSourceMismatch:
    return "overlay_presentation_source_mismatch";
  case Failure::kPresentationHidden:
    return "overlay_presentation_hidden";
  case Failure::kSourceMinimized:
    return "overlay_source_minimized";
  case Failure::kPresentationMinimized:
    return "overlay_presentation_minimized";
  case Failure::kSourceCloakUnknown:
    return "overlay_source_cloak_unknown";
  case Failure::kSourceCloaked:
    return "overlay_source_cloaked";
  case Failure::kPresentationCloakUnknown:
    return "overlay_presentation_cloak_unknown";
  case Failure::kPresentationCloaked:
    return "overlay_presentation_cloaked";
  case Failure::kClientUnavailable:
    return "overlay_client_unavailable";
  case Failure::kTargetExclusive:
    return "target_vidpn_exclusive";
  case Failure::kExclusiveOwnershipUnknown:
    return "target_vidpn_ownership_unknown";
  case Failure::kPresentationFrameUnavailable:
    return "overlay_presentation_dwm_frame_unavailable";
  case Failure::kPresentationFrameInvalid:
    return "overlay_presentation_dwm_frame_invalid";
  }
  return "overlayability_unknown";
}

// Only failures caused by the desktop overlay transport may be bypassed by a
// provider that renders both the hit feedback and popup inside the game render
// tree.  Invalid/stale/hidden target identity is never bypassable.
inline bool CanUseInProcessNativeWhenAttachedUnavailable(
    const Evaluation &evaluation, bool has_in_process_render_tree_presenter) {
  if (evaluation.overlayable || !has_in_process_render_tree_presenter)
    return false;
  switch (evaluation.failure) {
  case Failure::kCompositionQueryUnavailable:
  case Failure::kCompositionDisabled:
  case Failure::kTargetExclusive:
  case Failure::kExclusiveOwnershipUnknown:
  case Failure::kPresentationFrameUnavailable:
  case Failure::kPresentationFrameInvalid:
    return true;
  default:
    return false;
  }
}

// Stable v19 wire identities/diagnostics are repeated here intentionally so
// the runner stays independent from the injected DLL ABI header.  A KiriKiri
// provider becomes eligible only after its TJS expression and live sensor have
// both succeeded; merely seeing an engine/provider id is not presentation
// capability.
inline bool HasInProcessRenderTreePresenter(uint32_t provider_kind,
                                            uint32_t provider_id,
                                            uint32_t lookup_diag) {
  constexpr uint32_t kRuntimeLayout = 1u;
  constexpr uint32_t kKirikiri = 1u;
  constexpr uint32_t kSensorInstalled = 0x00000001u;
  constexpr uint32_t kExpressionReady = 0x00000040u;
  constexpr uint32_t kRequired = kSensorInstalled | kExpressionReady;
  return provider_kind == kRuntimeLayout && provider_id == kKirikiri &&
         (lookup_diag & kRequired) == kRequired;
}

} // namespace fushi::attached_overlayability

#endif // RUNNER_ATTACHED_OVERLAYABILITY_H_
