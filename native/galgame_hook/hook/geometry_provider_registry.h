#ifndef FUSHI_GALGAME_HOOK_GEOMETRY_PROVIDER_REGISTRY_H_
#define FUSHI_GALGAME_HOOK_GEOMETRY_PROVIDER_REGISTRY_H_

#include <windows.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "voice_hook_ipc.h"

namespace fushi_voice_hook {

// One complete lookup publication. Text identity and geometry travel together;
// the registry never accepts either half independently.
struct LookupGeometryHitPublication {
  uint32_t provider_kind = kLookupGeometryProviderUnknown;
  uint32_t provider_id = kLookupGeometryProviderIdUnknown;
  uint32_t char_index = 0;
  uint32_t source_length = 0;
  uint32_t char_count = 0;
  uint32_t coordinate_space = kLookupCoordinateSpaceUnknown;
  uint32_t writing_mode = kLookupWritingModeUnknown;
  uint64_t text_generation = 0;
  uint64_t geometry_generation = 0;
  int32_t glyph_x = 0;
  int32_t glyph_y = 0;
  int32_t glyph_w = 0;
  int32_t glyph_h = 0;
  int32_t view_w = 0;
  int32_t view_h = 0;
  uint32_t flags = kLookupHitFlagSubmit;
  const uint8_t* line_utf8 = nullptr;
  uint32_t line_bytes = 0;
};

inline constexpr uint32_t LookupGeometryProviderPriority(uint32_t kind) {
  switch (kind) {
    case kLookupGeometryProviderRuntimeLayout:
      return 0;
    case kLookupGeometryProviderEngineExactLayout:
      return 1;
    case kLookupGeometryProviderPositionedTextApi:
      return 2;
    case kLookupGeometryProviderAttachedCalibrated:
      return 3;
    case kLookupGeometryProviderPixelTemplateExperimental:
      return 4;
    case kLookupGeometryProviderTypewriterDiffExperimental:
      return 5;
    default:
      return UINT32_MAX;
  }
}

struct LookupGeometryProviderIdentity {
  uint32_t kind;
  uint32_t id;
};

// Production kind/id pairs are an allow-list, not two independently valid
// enums.  That distinction is important: an arbitrary id paired with
// runtime_layout must not inherit the highest priority, and a real id paired
// with the wrong kind must not impersonate another provider class.  Entries
// for later milestones reserve their contract identity only; without an
// adapter OfferReady call they can never become active or publish a hit.
inline constexpr LookupGeometryProviderIdentity
    kLookupGeometryProductionProviderPairs[] = {
        {kLookupGeometryProviderRuntimeLayout,
         kLookupGeometryProviderIdKirikiri},
        {kLookupGeometryProviderRuntimeLayout,
         kLookupGeometryProviderIdRenpy},
        {kLookupGeometryProviderRuntimeLayout,
         kLookupGeometryProviderIdTyranoDom},
        {kLookupGeometryProviderRuntimeLayout,
         kLookupGeometryProviderIdUnityTmp},
        {kLookupGeometryProviderRuntimeLayout,
         kLookupGeometryProviderIdUnityUgui},
        {kLookupGeometryProviderEngineExactLayout,
         kLookupGeometryProviderIdSiglus},
        {kLookupGeometryProviderEngineExactLayout,
         kLookupGeometryProviderIdLeafAquaplus},
        {kLookupGeometryProviderEngineExactLayout,
         kLookupGeometryProviderIdSgre},
        {kLookupGeometryProviderEngineExactLayout,
         kLookupGeometryProviderIdHunexGge},
        {kLookupGeometryProviderEngineExactLayout,
         kLookupGeometryProviderIdSmashFzmedia},
        {kLookupGeometryProviderPositionedTextApi,
         kLookupGeometryProviderIdGdiPositioned},
        {kLookupGeometryProviderPositionedTextApi,
         kLookupGeometryProviderIdDwritePositioned},
        {kLookupGeometryProviderAttachedCalibrated,
         kLookupGeometryProviderIdAttachedCalibrated},
};

inline constexpr size_t kLookupGeometryProductionProviderCount =
    sizeof(kLookupGeometryProductionProviderPairs) /
    sizeof(kLookupGeometryProductionProviderPairs[0]);

inline constexpr int LookupGeometryProductionProviderIndex(uint32_t kind,
                                                            uint32_t id) {
  for (size_t index = 0;
       index < kLookupGeometryProductionProviderCount; ++index) {
    if (kLookupGeometryProductionProviderPairs[index].kind == kind &&
        kLookupGeometryProductionProviderPairs[index].id == id) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

inline constexpr bool IsLookupGeometryProductionProviderPair(uint32_t kind,
                                                             uint32_t id) {
  return LookupGeometryProductionProviderIndex(kind, id) >= 0;
}

// Providers whose injected code consumes a physical left click itself (a
// sampled-state detour or a window-procedure subclass) instead of leaving the
// down to the host's low-level hook.  For these, consuming the click and
// publishing the resulting hit are both gated on the host having applied a
// NativeInputAllowed admission; every other production provider publishes
// geometry only and never eats input, so the extra gate would be meaningless
// for it.  Same allow-list discipline as the production pairs: kind and id
// are checked together.
inline constexpr LookupGeometryProviderIdentity
    kLookupGeometryNativeInputGatedProviders[] = {
        {kLookupGeometryProviderEngineExactLayout,
         kLookupGeometryProviderIdHunexGge},
        {kLookupGeometryProviderEngineExactLayout,
         kLookupGeometryProviderIdSmashFzmedia},
};

inline constexpr bool IsLookupGeometryNativeInputGatedProvider(uint32_t kind,
                                                               uint32_t id) {
  for (const LookupGeometryProviderIdentity& identity :
       kLookupGeometryNativeInputGatedProviders) {
    if (identity.kind == kind && identity.id == id) {
      return IsLookupGeometryProductionProviderPair(kind, id);
    }
  }
  return false;
}

inline uint32_t LookupUtf16SourceLength(const wchar_t* text,
                                        uint32_t char_count,
                                        uint32_t char_index) {
  if (text == nullptr || char_index >= char_count) return 0;
  const uint16_t first = static_cast<uint16_t>(text[char_index]);
  if (first >= 0xd800u && first <= 0xdbffu && char_index + 1u < char_count) {
    const uint16_t second = static_cast<uint16_t>(text[char_index + 1u]);
    if (second >= 0xdc00u && second <= 0xdfffu) return 2;
  }
  // Publishing half a surrogate pair would make the source interval point at
  // a non-character.  Exact adapters fail closed rather than silently turning
  // malformed/unpaired UTF-16 into a one-unit hit.
  if (first >= 0xd800u && first <= 0xdfffu) return 0;
  return 1;
}

class GeometryProviderRegistry {
 public:
  GeometryProviderRegistry() = default;
  GeometryProviderRegistry(const GeometryProviderRegistry&) = delete;
  GeometryProviderRegistry& operator=(const GeometryProviderRegistry&) =
      delete;

  void Reset(SharedHeader* header) {
    AcquireSRWLockExclusive(&lock_);
    std::memset(ready_offers_, 0, sizeof(ready_offers_));
    active_kind_ = kLookupGeometryProviderUnknown;
    active_id_ = kLookupGeometryProviderIdUnknown;
    active_status_ = kLookupGeometryStatusUnavailable;
    active_retire_pending_ = false;
    active_retire_status_ = kLookupGeometryStatusUnavailable;
    text_generation_ = 0;
    geometry_generation_ = 0;
    next_hit_seq_ = 0;
    if (header != nullptr) {
      InvalidatePublishedHitLocked(header);
      PublishProviderStateLocked(header);
    }
    ReleaseSRWLockExclusive(&lock_);
  }

  // A provider offers readiness only after it has a current, usable horizontal
  // layout snapshot.  The offer is remembered even when a mouse transaction
  // temporarily prevents it from pre-empting the current provider.
  bool OfferReady(SharedHeader* header, uint32_t provider_kind,
                  uint32_t provider_id) {
    const int provider_index =
        LookupGeometryProductionProviderIndex(provider_kind, provider_id);
    // attached_calibrated is a host-owned implicit offer.  Letting injected
    // code OfferReady for that identity would bypass the host's calibrated
    // profile/risk decision and defeat single-owner arbitration.
    if (provider_index < 0 ||
        provider_kind == kLookupGeometryProviderAttachedCalibrated ||
        !IsHeaderSane(header, true)) {
      return false;
    }

    AcquireSRWLockExclusive(&lock_);
    if (AtomicLoadShared32(&header->lookup_enabled) == 0) {
      ReleaseSRWLockExclusive(&lock_);
      return false;
    }
    ready_offers_[provider_index] = true;
    if (provider_kind == active_kind_ && provider_id == active_id_ &&
        active_retire_pending_) {
      // Recovery before the old transaction tail drains cancels retirement
      // without changing provider identity or generation.
      active_retire_pending_ = false;
      active_retire_status_ = kLookupGeometryStatusUnavailable;
      active_status_ = geometry_generation_ == 0
                           ? kLookupGeometryStatusReady
                           : kLookupGeometryStatusActive;
      PublishProviderStateLocked(header);
    }
    ReconcileLocked(header);
    ReleaseSRWLockExclusive(&lock_);
    return true;
  }

  // Retiring an offered provider is explicit.  If it owns an in-flight mouse
  // transaction, its identity and last immutable hit remain published until
  // every shield surface acknowledges the neutral tail; only then may the
  // registry activate the best remaining offer (or clear to unavailable).
  bool Retire(SharedHeader* header, uint32_t provider_kind,
              uint32_t provider_id,
              uint32_t retire_status = kLookupGeometryStatusUnavailable) {
    const int provider_index =
        LookupGeometryProductionProviderIndex(provider_kind, provider_id);
    if (provider_index < 0 ||
        provider_kind == kLookupGeometryProviderAttachedCalibrated ||
        !IsRetireStatus(retire_status) ||
        !IsHeaderSane(header, false)) {
      return false;
    }

    AcquireSRWLockExclusive(&lock_);
    ready_offers_[provider_index] = false;
    if (provider_kind == active_kind_ && provider_id == active_id_) {
      active_retire_pending_ = true;
      active_retire_status_ = retire_status;
    }
    ReconcileLocked(header);
    ReleaseSRWLockExclusive(&lock_);
    return true;
  }

  // HookWorker calls this every poll so a switch deferred by down/up/tail can
  // complete even if the retiring adapter no longer receives callbacks.
  bool Reconcile(SharedHeader* header) {
    if (!IsHeaderSane(header, false)) return false;
    AcquireSRWLockExclusive(&lock_);
    if (AtomicLoadShared32(&header->lookup_enabled) == 0) {
      std::memset(ready_offers_, 0, sizeof(ready_offers_));
      if (active_kind_ != kLookupGeometryProviderUnknown) {
        active_retire_pending_ = true;
        active_retire_status_ = kLookupGeometryStatusUnavailable;
      }
    }
    const bool settled = ReconcileLocked(header);
    ReleaseSRWLockExclusive(&lock_);
    return settled;
  }

  // Input hooks must not treat lookup_enabled as permission to consume a
  // button. That bit also keeps text sensors alive while risk acceptance or a
  // provider hand-off is pending. This query proves that the requested native
  // provider is the registry's current Ready/Active owner under a native
  // admission mode and the host has separately admitted native input before a
  // down transaction is allowed to begin. Geometry discovery remains live
  // while risk acceptance is pending; only click consumption stays closed.
  bool OwnsReadyProvider(SharedHeader* header, uint32_t provider_kind,
                         uint32_t provider_id) {
    const int provider_index =
        LookupGeometryProductionProviderIndex(provider_kind, provider_id);
    if (provider_index < 0 ||
        provider_kind == kLookupGeometryProviderAttachedCalibrated ||
        !IsHeaderSane(header, true)) {
      return false;
    }
    const LookupGeometryAdmissionSnapshot admission =
        ReadLookupGeometryAdmission(header);
    if (!admission.valid || !admission.native_input_allowed() ||
        (admission.mode != kLookupGeometryAdmissionAuto &&
         admission.mode != kLookupGeometryAdmissionNativeOnly)) {
      return false;
    }

    AcquireSRWLockShared(&lock_);
    const bool owns =
        AtomicLoadShared32(&header->lookup_enabled) != 0 &&
        ready_offers_[provider_index] && provider_kind == active_kind_ &&
        provider_id == active_id_ && !active_retire_pending_ &&
        (active_status_ == kLookupGeometryStatusReady ||
         active_status_ == kLookupGeometryStatusActive);
    ReleaseSRWLockShared(&lock_);
    return owns;
  }

  // Compatibility wrapper for existing callers.  New lifecycle code should
  // use OfferReady/Retire so readiness and retirement cannot drift apart.
  bool SetActiveProviderStatus(SharedHeader* header, uint32_t provider_kind,
                               uint32_t provider_id, uint32_t status) {
    if (status == kLookupGeometryStatusReady) {
      return OfferReady(header, provider_kind, provider_id);
    }
    if (IsRetireStatus(status)) {
      return Retire(header, provider_kind, provider_id, status);
    }
    if (status != kLookupGeometryStatusActive ||
        !IsHeaderSane(header, false)) {
      return false;
    }
    AcquireSRWLockExclusive(&lock_);
    ReconcileLocked(header);
    const bool matches = provider_kind == active_kind_ &&
                         provider_id == active_id_ &&
                         !active_retire_pending_;
    if (matches) {
      active_status_ = status;
      PublishProviderStateLocked(header);
    }
    ReleaseSRWLockExclusive(&lock_);
    return matches;
  }

  // Fail-closed semantic-input gate for the native-input-gated providers
  // (kLookupGeometryNativeInputGatedProviders).  OfferReady/provider discovery
  // must remain independent from host risk admission; consuming the semantic
  // click is allowed only after the host request (including
  // NativeInputAllowed) is fully applied and this exact provider is the
  // stable active owner.  Any other provider identity is denied outright.
  bool NativeInputAllowed(const SharedHeader* header, uint32_t provider_kind,
                          uint32_t provider_id) {
    if (!IsLookupGeometryNativeInputGatedProvider(provider_kind,
                                                  provider_id) ||
        !IsHeaderSane(header, true)) {
      return false;
    }

    uint32_t admission_seq = 0;
    if (!NativeInputAdmissionApplied(header, &admission_seq) ||
        !TryAcquireSRWLockShared(&lock_)) {
      return false;
    }
    const int provider_index = LookupGeometryProductionProviderIndex(
        provider_kind, provider_id);
    const bool active =
        provider_index >= 0 && ready_offers_[provider_index] &&
        provider_kind == active_kind_ && provider_id == active_id_ &&
        !active_retire_pending_ &&
        (active_status_ == kLookupGeometryStatusReady ||
         (active_status_ == kLookupGeometryStatusActive &&
          text_generation_ != 0 && geometry_generation_ != 0));
    ReleaseSRWLockShared(&lock_);
    if (!active) return false;

    // Close the host-disable race across the registry snapshot.  A changed or
    // writer-held request, or an ack for any other generation, fails closed.
    uint32_t confirmed_seq = 0;
    return NativeInputAdmissionApplied(header, &confirmed_seq) &&
           confirmed_seq == admission_seq;
  }

  bool PublishHit(SharedHeader* header,
                  const LookupGeometryHitPublication& publication,
                  uint64_t* published_seq = nullptr) {
    if (published_seq != nullptr) *published_seq = 0;
    if (!IsPublicationSane(header, publication)) return false;

    AcquireSRWLockExclusive(&lock_);
    const int provider_index = LookupGeometryProductionProviderIndex(
        publication.provider_kind, publication.provider_id);
    if (provider_index < 0 || !ready_offers_[provider_index] ||
        AtomicLoadShared32(&header->lookup_enabled) == 0) {
      ReleaseSRWLockExclusive(&lock_);
      return false;
    }
    ReconcileLocked(header);
    const bool same_provider =
        publication.provider_kind == active_kind_ &&
        publication.provider_id == active_id_;
    const bool native_input_allowed =
        !IsLookupGeometryNativeInputGatedProvider(publication.provider_kind,
                                                  publication.provider_id) ||
        NativeInputAdmissionApplied(header);
    if (!same_provider || active_retire_pending_ ||
        !native_input_allowed ||
        publication.text_generation < text_generation_ ||
        publication.geometry_generation < geometry_generation_) {
      ReleaseSRWLockExclusive(&lock_);
      return false;
    }

    LookupHitSlot* slot = LookupHitOf(header);
    if (slot == nullptr) {
      ReleaseSRWLockExclusive(&lock_);
      return false;
    }

    active_kind_ = publication.provider_kind;
    active_id_ = publication.provider_id;
    active_status_ = kLookupGeometryStatusActive;
    text_generation_ = publication.text_generation;
    geometry_generation_ = publication.geometry_generation;

    const uint64_t shared_count =
        AtomicLoadPreview64(&header->lookup_hit_count);
    next_hit_seq_ = (std::max)(next_hit_seq_, shared_count) + 1u;
    if (next_hit_seq_ == 0) next_hit_seq_ = 1;

    // Single-slot seqlock: invalidate the previous payload, populate every
    // field, publish slot seq, then publish the matching count.
    AtomicStorePreview64(&slot->seq, 0);
    slot->provider_kind = publication.provider_kind;
    slot->provider_id = publication.provider_id;
    slot->char_index = publication.char_index;
    slot->source_length = publication.source_length;
    slot->char_count = publication.char_count;
    slot->coordinate_space = publication.coordinate_space;
    slot->writing_mode = publication.writing_mode;
    slot->text_generation = publication.text_generation;
    slot->geometry_generation = publication.geometry_generation;
    slot->glyph_x = publication.glyph_x;
    slot->glyph_y = publication.glyph_y;
    slot->glyph_w = publication.glyph_w;
    slot->glyph_h = publication.glyph_h;
    slot->view_w = publication.view_w;
    slot->view_h = publication.view_h;
    slot->flags = publication.flags;
    slot->line_bytes = publication.line_bytes;
    std::memset(slot->line_utf8, 0, sizeof(slot->line_utf8));
    std::memcpy(slot->line_utf8, publication.line_utf8,
                publication.line_bytes);

    PublishProviderStateLocked(header);
    AtomicStorePreview64(&slot->seq, next_hit_seq_);
    AtomicStorePreview64(&header->lookup_hit_count, next_hit_seq_);
    AtomicOrShared32(&header->lookup_diag,
                     kLookupDiagGeometryObserved | kLookupDiagHitSubmitted);
    if (published_seq != nullptr) *published_seq = next_hit_seq_;
    ReleaseSRWLockExclusive(&lock_);
    return true;
  }

 private:
  static bool IsHeaderSane(const SharedHeader* header, bool require_enabled) {
    return header != nullptr && header->magic == kSharedMagic &&
           header->version == kSharedVersion && HasLookupRegion(header) &&
           (!require_enabled ||
            AtomicLoadShared32(&header->lookup_enabled) != 0);
  }

  static bool IsRetireStatus(uint32_t status) {
    return status == kLookupGeometryStatusUnavailable ||
           status == kLookupGeometryStatusSuspended ||
           status == kLookupGeometryStatusFaulted;
  }

  struct ShieldSwitchFence {
    LookupShieldRequestSnapshot request;
    uint32_t stable_seq = 0;
    bool claimed = false;
  };

  // Provider selection and a new low-level mouse down must be mutually
  // exclusive.  Merely reading active_buttons leaves a check-then-switch race:
  // the host can publish down after the check but before provider state is
  // replaced.  Reuse the request seqlock's writer bit as a very short switch
  // fence.  A WH_MOUSE_LL publisher that loses this CAS fails open; a registry
  // switch that loses it retries after the host has published the transaction.
  static bool TryAcquireShieldSwitchFence(SharedHeader* header,
                                          ShieldSwitchFence* fence) {
    if (header == nullptr || fence == nullptr) return false;
    *fence = ShieldSwitchFence{};
    auto* seq = reinterpret_cast<volatile LONG*>(
        &header->lookup_shield_request_seq);
    for (int attempt = 0; attempt < 8; ++attempt) {
      const uint32_t raw =
          AtomicLoadShared32(&header->lookup_shield_request_seq);
      if ((raw & kLookupShieldRequestWriteInProgress) != 0) return false;

      LookupShieldRequestSnapshot request;
      if (raw != 0) {
        request = ReadLookupShieldRequest(header);
        if (!request.valid || request.seq != raw) continue;
      } else {
        MemoryBarrier();
        if (AtomicLoadShared32(&header->lookup_shield_request_seq) != 0) {
          continue;
        }
      }

      const uint32_t token = raw | kLookupShieldRequestWriteInProgress;
      const LONG observed = InterlockedCompareExchange(
          seq, static_cast<LONG>(token), static_cast<LONG>(raw));
      if (static_cast<uint32_t>(observed) != raw) continue;
      fence->request = request;
      fence->stable_seq = raw;
      fence->claimed = true;
      return true;
    }
    return false;
  }

  static void ReleaseShieldSwitchFence(SharedHeader* header,
                                       ShieldSwitchFence* fence) {
    if (header == nullptr || fence == nullptr || !fence->claimed) return;
    AtomicStoreShared32(&header->lookup_shield_request_seq,
                        fence->stable_seq);
    fence->claimed = false;
  }

  static bool ShieldTransactionActiveUnderFence(
      const SharedHeader* header,
      const LookupShieldRequestSnapshot& request) {
    if (request.valid && request.active_buttons != 0) return true;
    if (request.valid && request.transaction_id != 0 &&
        AtomicLoadShared32(&header->lookup_shield_applied_seq) != request.seq) {
      return true;
    }
    return (AtomicLoadShared32(&header->lookup_shield_status_flags) &
            kLookupShieldStatusTransactionActive) != 0;
  }

  int ActiveProviderIndexLocked() const {
    return LookupGeometryProductionProviderIndex(active_kind_, active_id_);
  }

  int BestNativeReadyProviderIndexLocked() const {
    int best = -1;
    const int active = ActiveProviderIndexLocked();
    if (active >= 0 &&
        kLookupGeometryProductionProviderPairs[active].kind !=
            kLookupGeometryProviderAttachedCalibrated &&
        ready_offers_[active] && !active_retire_pending_) {
      best = active;
    }
    for (size_t index = 0;
         index < kLookupGeometryProductionProviderCount; ++index) {
      if (kLookupGeometryProductionProviderPairs[index].kind ==
              kLookupGeometryProviderAttachedCalibrated ||
          !ready_offers_[index]) {
        continue;
      }
      if (best < 0 ||
          LookupGeometryProviderPriority(
              kLookupGeometryProductionProviderPairs[index].kind) <
              LookupGeometryProviderPriority(
                  kLookupGeometryProductionProviderPairs[best].kind)) {
        best = static_cast<int>(index);
      }
    }
    return best;
  }

  int BestReadyProviderIndexLocked(
      const LookupGeometryAdmissionSnapshot& admission) const {
    if (admission.mode == kLookupGeometryAdmissionDisabled) return -1;
    const int attached = LookupGeometryProductionProviderIndex(
        kLookupGeometryProviderAttachedCalibrated,
        kLookupGeometryProviderIdAttachedCalibrated);
    if (admission.mode == kLookupGeometryAdmissionAttachedOnly) {
      return admission.attached_ready() ? attached : -1;
    }
    const int native = BestNativeReadyProviderIndexLocked();
    if (native >= 0 ||
        admission.mode == kLookupGeometryAdmissionNativeOnly) {
      return native;
    }
    return admission.attached_ready() ? attached : -1;
  }

  void InvalidatePublishedHitLocked(SharedHeader* header) {
    LookupHitSlot* slot = LookupHitOf(header);
    if (slot != nullptr) AtomicStorePreview64(&slot->seq, 0);
  }

  void PublishProviderStateLocked(SharedHeader* header) {
    AtomicStoreShared32(&header->lookup_geometry_active_kind, active_kind_);
    AtomicStoreShared32(&header->lookup_geometry_active_id, active_id_);
    AtomicStoreShared32(&header->lookup_geometry_status, active_status_);
    AtomicStorePreview64(&header->lookup_geometry_text_generation,
                         text_generation_);
    // geometry_generation is the provider-state completion marker.
    AtomicStorePreview64(&header->lookup_geometry_generation,
                         geometry_generation_);
  }

  void ActivateReadyProviderLocked(SharedHeader* header, int provider_index) {
    InvalidatePublishedHitLocked(header);
    const auto& identity =
        kLookupGeometryProductionProviderPairs[provider_index];
    active_kind_ = identity.kind;
    active_id_ = identity.id;
    active_status_ = kLookupGeometryStatusReady;
    active_retire_pending_ = false;
    active_retire_status_ = kLookupGeometryStatusUnavailable;
    text_generation_ = 0;
    geometry_generation_ = 0;
    PublishProviderStateLocked(header);
  }

  void ClearActiveProviderLocked(SharedHeader* header) {
    InvalidatePublishedHitLocked(header);
    active_kind_ = kLookupGeometryProviderUnknown;
    active_id_ = kLookupGeometryProviderIdUnknown;
    active_status_ = kLookupGeometryStatusUnavailable;
    active_retire_pending_ = false;
    active_retire_status_ = kLookupGeometryStatusUnavailable;
    text_generation_ = 0;
    geometry_generation_ = 0;
    PublishProviderStateLocked(header);
  }

  bool ReconcileLocked(SharedHeader* header) {
    LookupGeometryAdmissionSnapshot admission =
        ReadLookupGeometryAdmission(header);
    if (!admission.valid) {
      const uint32_t raw_seq = AtomicLoadShared32(
          &header->lookup_geometry_admission_request_seq);
      // Never interpret a writer-held request as a disable edge: doing so
      // could retire the current owner between payload and request_seq.
      if ((raw_seq & kLookupGeometryAdmissionWriteInProgress) != 0) {
        return false;
      }
      // Zero/unrecognised admission is fail-closed.  A malformed non-zero
      // request is deliberately not acknowledged.
      admission = LookupGeometryAdmissionSnapshot{};
      admission.mode = kLookupGeometryAdmissionDisabled;
    }
    const bool runtime_enabled =
        AtomicLoadShared32(&header->lookup_enabled) != 0;
    LookupGeometryAdmissionSnapshot effective = admission;
    if (!runtime_enabled) {
      effective.mode = kLookupGeometryAdmissionDisabled;
      effective.flags = 0;
    }
    const int active = ActiveProviderIndexLocked();
    const int best = BestReadyProviderIndexLocked(effective);
    const bool already_best = active >= 0 && active == best &&
                              !active_retire_pending_;
    bool settled = already_best || (active < 0 && best < 0);

    ShieldSwitchFence shield_fence;
    if (!settled && !TryAcquireShieldSwitchFence(header, &shield_fence)) {
      return false;
    }
    if (!settled && ShieldTransactionActiveUnderFence(
                        header, shield_fence.request)) {
      if (active_retire_pending_) {
        active_status_ =
            active_retire_status_ == kLookupGeometryStatusFaulted
                ? kLookupGeometryStatusFaulted
                : kLookupGeometryStatusSuspended;
        PublishProviderStateLocked(header);
      }
      ReleaseShieldSwitchFence(header, &shield_fence);
      return false;
    }

    if (!settled) {
      if (best >= 0) {
        ActivateReadyProviderLocked(header, best);
      } else {
        ClearActiveProviderLocked(header);
      }
      settled = true;
    }
    // An admission request is applied only once its owner policy is true.
    // Auto/native/attached requests remain pending while lookup runtime is
    // disabled; Disabled itself may be acknowledged after the old tail has
    // drained and the registry is empty.
    if (settled && admission.valid &&
        (runtime_enabled ||
         admission.mode == kLookupGeometryAdmissionDisabled)) {
      AtomicStoreShared32(&header->lookup_geometry_admission_applied_seq,
                          admission.seq);
    }
    ReleaseShieldSwitchFence(header, &shield_fence);
    return settled;
  }

  static bool IsPublicationSane(
      const SharedHeader* header,
      const LookupGeometryHitPublication& publication) {
    if (!IsHeaderSane(header, true)) {
      return false;
    }
    if (!IsLookupGeometryProductionProviderPair(publication.provider_kind,
                                                publication.provider_id)) {
      return false;
    }
    if (publication.char_count == 0 ||
        publication.char_index >= publication.char_count ||
        publication.source_length == 0 ||
        publication.source_length >
            publication.char_count - publication.char_index) {
      return false;
    }
    if (publication.coordinate_space == kLookupCoordinateSpaceUnknown ||
        publication.coordinate_space > kLookupCoordinateSpaceLayoutLocal ||
        publication.writing_mode != kLookupWritingModeHorizontal ||
        publication.text_generation == 0 ||
        publication.geometry_generation == 0) {
      return false;
    }
    if (publication.glyph_w <= 0 || publication.glyph_h <= 0 ||
        publication.view_w <= 0 || publication.view_h <= 0) {
      return false;
    }
    if ((publication.flags & kLookupHitFlagSubmit) == 0 ||
        (publication.flags & ~kLookupHitFlagSubmit) != 0) {
      return false;
    }
    return publication.line_utf8 != nullptr && publication.line_bytes != 0 &&
           publication.line_bytes <= kLookupLineBytes;
  }

  static bool NativeInputAdmissionApplied(const SharedHeader* header,
                                          uint32_t* stable_seq = nullptr) {
    if (stable_seq != nullptr) *stable_seq = 0;
    if (header == nullptr ||
        AtomicLoadShared32(&header->lookup_enabled) == 0) {
      return false;
    }
    const LookupGeometryAdmissionSnapshot admission =
        ReadLookupGeometryAdmission(header);
    if (!admission.valid || !admission.native_input_allowed() ||
        AtomicLoadShared32(&header->lookup_geometry_admission_applied_seq) !=
            admission.seq) {
      return false;
    }
    MemoryBarrier();
    const LookupGeometryAdmissionSnapshot confirmed =
        ReadLookupGeometryAdmission(header);
    if (!confirmed.valid || confirmed.seq != admission.seq ||
        !confirmed.native_input_allowed() ||
        AtomicLoadShared32(&header->lookup_geometry_admission_applied_seq) !=
            confirmed.seq ||
        AtomicLoadShared32(&header->lookup_enabled) == 0) {
      return false;
    }
    if (stable_seq != nullptr) *stable_seq = confirmed.seq;
    return true;
  }

  SRWLOCK lock_ = SRWLOCK_INIT;
  bool ready_offers_[kLookupGeometryProductionProviderCount] = {};
  uint32_t active_kind_ = kLookupGeometryProviderUnknown;
  uint32_t active_id_ = kLookupGeometryProviderIdUnknown;
  uint32_t active_status_ = kLookupGeometryStatusUnavailable;
  bool active_retire_pending_ = false;
  uint32_t active_retire_status_ = kLookupGeometryStatusUnavailable;
  uint64_t text_generation_ = 0;
  uint64_t geometry_generation_ = 0;
  uint64_t next_hit_seq_ = 0;
};

// The injected DLL has exactly one authoritative registry.  An inline
// variable keeps adapter include fragments from depending on a second global
// declaration in dll_main.cpp while retaining one process-wide instance.
inline GeometryProviderRegistry g_geometry_provider_registry;

}  // namespace fushi_voice_hook

#endif  // FUSHI_GALGAME_HOOK_GEOMETRY_PROVIDER_REGISTRY_H_
