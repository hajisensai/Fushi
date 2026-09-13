// Private metadata for the admitted engine's first down edge. Never sampled
// each held frame, never used to grant input, and never shared through IPC.
enum class SiglusLookupPressReason : uint32_t {
  kNotEvaluated = 0, kLookupOwned, kPopupOwned, kUnsynchronized,
  kExistingTransaction, kRuntimeDisabled, kLiveViewRejected,
  kNativeAdmissionRejected, kCursorUnavailable, kTargetUnpublished,
  kTargetChanged, kTargetInvalid, kTargetIdentity, kTargetTextUnits,
  kTargetGlyphCount, kTargetGeneration, kTargetEpoch, kTargetTimestamp,
  kTargetExpired, kProfileUnavailable, kWindowMismatch, kWindowUnavailable,
  kForegroundMismatch, kPointWindowMismatch, kClientUnavailable,
  kClientChanged, kEngineViewChanged, kNoProjectedGlyph, kPointMiss,
  kCharacterIndex,
  kPendingUnavailable, kPendingTextIdentity, kPendingEpoch,
  kPendingGeneration, kPendingClient, kSampleEpochReset,
};
enum class SiglusLookupPressSurface : uint32_t {
  kKeyState = 1, kKeyboardState = 2, kEngineMessage = 3,
  kKeyStateCompletion = 4, kKeyboardStateCompletion = 5,
};
struct SiglusLookupPressDiagnostic {
  volatile LONG64 seq = 0;
  uint64_t tick = 0;
  uint64_t target_seq = 0;
  uint64_t event_id = 0;
  uint64_t thread_id = 0;
  uint64_t geometry_generation = 0;
  uint64_t snapshot_epoch = 0;
  uint64_t target_published_tick = 0;
  SiglusLookupPressSurface surface = SiglusLookupPressSurface::kKeyState;
  SiglusLookupPressReason reason = SiglusLookupPressReason::kNotEvaluated;
  // Positive observations only: unset may also mean short-circuited (e.g. WM
  // popup ownership does not read runtime admission). bit0 runtime true,
  // bit1 synchronized, bit2 native allowed, bit3 consume,
  // bit4 begin, bit5 popup, bit6 stable target metadata, bit7 fresh sample.
  uint32_t flags = 0;
  uint32_t sample_owner = 0;
  int32_t screen_x = 0;
  int32_t screen_y = 0;
  uint64_t game_window = 0;
  int32_t client_x = 0, client_y = 0, client_width = 0, client_height = 0;
  uint32_t target_valid = 0, text_units = 0;
  // Sampling lifecycle before its existing epoch-reset branch; zero for WM.
  uint32_t sample_epoch = 0, previous_sample_epoch = 0;
  uint64_t pending_event_id = 0, pending_thread_id = 0;
  uint64_t pending_geometry_generation = 0, pending_snapshot_epoch = 0;
};
static_assert(sizeof(SiglusLookupPressDiagnostic) == 160,
              "Private input diagnostic scalar stride");
constexpr size_t kSiglusLookupPressDiagnosticSlots = 8;
volatile SiglusLookupPressDiagnostic g_siglus_lookup_press_diagnostics[
    kSiglusLookupPressDiagnosticSlots];
volatile LONG64 g_siglus_lookup_press_diagnostic_count = 0;
volatile LONG64 g_siglus_lookup_press_diagnostic_dropped = 0;
SRWLOCK g_siglus_lookup_press_diagnostic_lock = SRWLOCK_INIT;
// These are diagnostic-only per-thread/API histories, not input ownership.
thread_local bool g_siglus_lookup_diagnostic_button_down[2] = {};
thread_local uint32_t g_siglus_lookup_diagnostic_epoch[2] = {};

void ResetSiglusLookupDiagnosticHistory() {
  g_siglus_lookup_diagnostic_button_down[0] = false;
  g_siglus_lookup_diagnostic_button_down[1] = false;
  g_siglus_lookup_diagnostic_epoch[0] = 0;
  g_siglus_lookup_diagnostic_epoch[1] = 0;
}

bool ObserveSiglusLookupDiagnosticDown(bool down, bool keyboard_table, uint32_t epoch) {
  const size_t lane = keyboard_table ? 1 : 0;
  bool& previous = g_siglus_lookup_diagnostic_button_down[lane];
  if (g_siglus_lookup_diagnostic_epoch[lane] != epoch) {
    previous = false;
    g_siglus_lookup_diagnostic_epoch[lane] = epoch;
  }
  const bool edge = down && !previous;
  previous = down;
  return edge;
}

void RecordSiglusLookupPressDiagnostic(const SiglusLookupPressDiagnostic& value) {
  if (!TryAcquireSRWLockExclusive(&g_siglus_lookup_press_diagnostic_lock)) {
    InterlockedIncrement64(&g_siglus_lookup_press_diagnostic_dropped);
    return;
  }
  uint64_t next = static_cast<uint64_t>(InterlockedCompareExchange64(
      &g_siglus_lookup_press_diagnostic_count, 0, 0)) + 1;
  if (next == 0) next = 1;
  auto& slot = g_siglus_lookup_press_diagnostics[
      next % kSiglusLookupPressDiagnosticSlots];
  InterlockedExchange64(&slot.seq, 0);
  // Sole lock-owning writer. The caller's record contains only fixed scalars;
  // seq stays invalid throughout the copy and count is published last.
  memcpy(reinterpret_cast<unsigned char*>(
             const_cast<SiglusLookupPressDiagnostic*>(&slot)) + sizeof(LONG64),
         reinterpret_cast<const unsigned char*>(&value) + sizeof(LONG64),
         sizeof(value) - sizeof(LONG64));
  InterlockedExchange64(&slot.seq, static_cast<LONG64>(next));
  InterlockedExchange64(&g_siglus_lookup_press_diagnostic_count,
                        static_cast<LONG64>(next));
  ReleaseSRWLockExclusive(&g_siglus_lookup_press_diagnostic_lock);
}

void SetSiglusLookupPressTarget(SiglusLookupPressDiagnostic* diagnostic,
                               const SiglusLookupClickTarget& target) {
  if (diagnostic == nullptr) return;
  diagnostic->target_seq = static_cast<uint64_t>(target.seq);
  diagnostic->event_id = target.text_identity.event_id;
  diagnostic->thread_id = target.text_identity.thread_id;
  diagnostic->geometry_generation = target.geometry_generation;
  diagnostic->snapshot_epoch = target.snapshot_epoch;
  diagnostic->target_published_tick = target.published_tick;
  diagnostic->game_window = target.game_window;
  diagnostic->client_x = target.client_screen_x;
  diagnostic->client_y = target.client_screen_y;
  diagnostic->client_width = target.client_width;
  diagnostic->client_height = target.client_height;
  diagnostic->target_valid = target.valid;
  diagnostic->text_units = target.text_units;
  diagnostic->flags |= 64u;
}

bool RejectSiglusLookupPress(SiglusLookupPressDiagnostic* diagnostic,
                             SiglusLookupPressReason reason) {
  if (diagnostic != nullptr) diagnostic->reason = reason;
  return false;
}
