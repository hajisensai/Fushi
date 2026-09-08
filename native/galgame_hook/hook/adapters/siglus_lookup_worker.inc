// Windows Siglus transport consumer and lookup publication path.
// Included by the injected adapter and its production-path regression test.

bool ProcessSiglusLookupClickSubmissions();

// One retained transport event, not a timer/retry budget. The four-slot ring
// remains authoritative; overwritten entries can never be resurrected.
uint64_t g_siglus_lookup_waiting_click_seq = 0;
uint64_t g_siglus_lookup_waiting_glyph_seq = 0;

// Private diagnostic metadata only. This eight-record worker-owned ring does
// not extend SharedHeader, grant input, retain text, or alter publication.
enum class SiglusLookupRejectReason : uint32_t {
  kNone = 0,
  kPublished,
  kProfileUnavailable,
  kTextIdentity,
  kLayoutIncomplete,
  kGeometryGeneration,
  kSnapshotEpoch,
  kTextBody,
  kUnreadText,
  kEngineViewUnavailable,
  kEngineViewChanged,
  kWindowUnavailable,
  kForegroundChanged,
  kSampledWindowChanged,
  kClientUnavailable,
  kClientTransformChanged,
  kGlyphProjection,
  kGlyphRectangle,
  kGlyphMissing,
  kDuplicate,
  kHitPublicationRejected,  // Includes final encoding/IPC/registry validators.
  kRuntimeReset,
  kQueueOverwritten,
};
struct SiglusLookupWorkerDiagnostic {
  volatile LONG64 seq = 0;
  uint64_t first_queue_seq = 0;
  uint64_t queue_seq = 0;
  uint64_t event_id = 0;
  uint64_t current_event_id = 0;
  uint64_t geometry_generation = 0;
  uint64_t current_geometry_generation = 0;
  uint64_t snapshot_epoch = 0;
  uint64_t current_snapshot_epoch = 0;
  uint64_t glyph_frontier = 0;
  uint64_t consumed_glyph_frontier = 0;
  uint64_t text_frontier = 0;
  uint64_t consumed_text_frontier = 0;
  SiglusLookupRejectReason reason = SiglusLookupRejectReason::kNone;
  uint32_t reserved = 0;
};
constexpr size_t kSiglusLookupWorkerDiagnosticSlots = 8;
static_assert(sizeof(SiglusLookupWorkerDiagnostic) == 112,
              "Private read-only diagnostic record stride");
volatile SiglusLookupWorkerDiagnostic g_siglus_lookup_worker_diagnostics[
    kSiglusLookupWorkerDiagnosticSlots];
volatile LONG64 g_siglus_lookup_worker_diagnostic_count = 0;

void RecordSiglusLookupWorkerDiagnostic(uint64_t first_queue_seq,
    uint64_t queue_seq, const SiglusLookupPayload* payload,
    SiglusLookupRejectReason reason) {
  uint64_t next = static_cast<uint64_t>(InterlockedCompareExchange64(
      &g_siglus_lookup_worker_diagnostic_count, 0, 0)) + 1;
  if (next == 0) next = 1;
  auto& record = g_siglus_lookup_worker_diagnostics[
      next % kSiglusLookupWorkerDiagnosticSlots];
  InterlockedExchange64(&record.seq, 0);
  record.first_queue_seq = first_queue_seq;
  record.queue_seq = queue_seq;
  record.event_id = payload == nullptr ? 0 : payload->text_identity.event_id;
  record.current_event_id = g_siglus_lookup_text_identity.event_id;
  record.geometry_generation = payload == nullptr ? 0 : payload->geometry_generation;
  record.current_geometry_generation = g_siglus_lookup_layout.generation;
  record.snapshot_epoch = payload == nullptr ? 0 : payload->snapshot_epoch;
  record.current_snapshot_epoch = g_siglus_lookup_layout.snapshot_epoch;
  record.glyph_frontier = static_cast<uint64_t>(InterlockedCompareExchange64(
      &g_siglus_lookup_glyph_event_count, 0, 0));
  record.consumed_glyph_frontier = g_siglus_lookup_glyph_processed_seq;
  record.text_frontier = static_cast<uint64_t>(InterlockedCompareExchange64(
      &g_siglus_lookup_text_count, 0, 0));
  record.consumed_text_frontier = g_siglus_lookup_text_processed_seq;
  record.reason = reason;
  record.reserved = 0;
  InterlockedExchange64(&record.seq, static_cast<LONG64>(next));
  InterlockedExchange64(&g_siglus_lookup_worker_diagnostic_count,
                        static_cast<LONG64>(next));
}

bool ReadSiglusLookupGlyphEvent(uint64_t seq, SiglusLookupGlyphEvent *copy) {
  if (seq == 0 || copy == nullptr)
    return false;
  SiglusLookupGlyphEvent *source =
      &g_siglus_lookup_glyph_events[seq % kSiglusLookupGlyphEventSlots];
  const uint64_t before =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (before != seq)
    return false;
  memcpy(copy, source, sizeof(*copy));
  const uint64_t after =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  return after == before && after != 0;
}

void QueueSiglusLookupClickSubmit(const SiglusLookupPayload &payload) {
  if (payload.text_units == 0 ||
      payload.text_units > kSiglusLookupMaxTextUnits ||
      payload.char_index >= payload.text_units) {
    return;
  }
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_siglus_lookup_click_event_count));
  SiglusLookupClickEvent *event =
      &g_siglus_lookup_click_events[next % kSiglusLookupClickEventSlots];
  InterlockedExchange64(&event->seq, 0);
  event->payload = payload;
  InterlockedExchange64(&event->seq, static_cast<LONG64>(next));
}

bool ReadNextSiglusLookupClickSubmit(SiglusLookupClickEvent *copy,
                                       uint64_t *seq) {
  if (copy == nullptr || seq == nullptr)
    return false;
  const uint64_t latest = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_click_event_count, 0, 0));
  if (latest == 0 || latest == g_siglus_lookup_click_processed_seq) {
    return false;
  }
  // Process surviving events in sequence order. If the producer overwrote the
  // bounded queue, discard the lost prefix; never read a newer slot as it.
  if (latest > kSiglusLookupClickEventSlots &&
      g_siglus_lookup_click_processed_seq < latest - kSiglusLookupClickEventSlots) {
    RecordSiglusLookupWorkerDiagnostic(g_siglus_lookup_click_processed_seq + 1,
        latest - kSiglusLookupClickEventSlots, nullptr,
        SiglusLookupRejectReason::kQueueOverwritten);
    g_siglus_lookup_click_processed_seq = latest - kSiglusLookupClickEventSlots;
    g_siglus_lookup_waiting_click_seq = 0;
    g_siglus_lookup_waiting_glyph_seq = 0;
  }
  const uint64_t next = g_siglus_lookup_click_processed_seq + 1;
  SiglusLookupClickEvent *source =
      &g_siglus_lookup_click_events[next % kSiglusLookupClickEventSlots];
  const uint64_t before =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (before != next)
    return false;
  memcpy(copy, source, sizeof(*copy));
  const uint64_t after =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (after != before || after == 0)
    return false;
  *seq = next;
  return true;
}

void ResetSiglusLookupRuntimeLayout() {
  // Session/window/sensor loss terminates queued transactions as well as the
  // layout. Re-enabling lookup must not revive an older physical release.
  const uint64_t latest_click = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_click_event_count, 0, 0));
  if (latest_click > g_siglus_lookup_click_processed_seq) {
    // A reset can retire releases before they reach the normal submission
    // branch. Preserve their sequence range; never guess overwritten identity.
    SiglusLookupPayload metadata;
    const SiglusLookupPayload* retained = nullptr;
    if (latest_click == g_siglus_lookup_click_processed_seq + 1) {
      auto& source = g_siglus_lookup_click_events[
          latest_click % kSiglusLookupClickEventSlots];
      const uint64_t before = static_cast<uint64_t>(InterlockedCompareExchange64(
          &source.seq, 0, 0));
      if (before == latest_click) {
        // Only identity fields, never the body, enter this diagnostic copy.
        metadata.text_identity = source.payload.text_identity;
        metadata.geometry_generation = source.payload.geometry_generation;
        metadata.snapshot_epoch = source.payload.snapshot_epoch;
        const uint64_t after = static_cast<uint64_t>(InterlockedCompareExchange64(
            &source.seq, 0, 0));
        if (after == before) retained = &metadata;
      }
    }
    RecordSiglusLookupWorkerDiagnostic(g_siglus_lookup_click_processed_seq + 1,
        latest_click, retained, SiglusLookupRejectReason::kRuntimeReset);
  }
  g_siglus_lookup_click_processed_seq = latest_click;
  g_siglus_lookup_waiting_click_seq = 0;
  g_siglus_lookup_waiting_glyph_seq = 0;
  // The bound text event remains the same committed occurrence. Fresh glyphs
  // are required after reset; preserving its ID does not revive old geometry.
  fushi_voice_hook::ResetSiglusLookupLayout(&g_siglus_lookup_layout);
  fushi_voice_hook::ClearSiglusLookupGlyphCapture(&g_siglus_lookup_glyph_captures);
  g_siglus_lookup_glyph_processed_seq = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_glyph_event_count, 0, 0));
  g_siglus_lookup_layout_window = nullptr;
  InvalidateSiglusLookupClickTarget();
}

void ConsumeSiglusLookupCaptures() {
  ConsumeSiglusLookupLunaScenarioText();
  bool changed = false;
  SiglusLookupTextSnapshot text_snapshot;
  uint64_t text_seq = 0;
  if (ReadLatestSiglusLookupText(&text_snapshot, &text_seq)) {
    g_siglus_lookup_text_processed_seq = text_seq;
    const bool identity_changed =
        !fushi_voice_hook::IsSiglusLookupTextIdentityCurrent(
            text_snapshot.identity, g_siglus_lookup_text_identity);
    if (identity_changed) {
      fushi_voice_hook::InvalidateSiglusLookupCurrentLayout(&g_siglus_lookup_layout);
      InvalidateSiglusLookupClickTarget();
      g_siglus_lookup_text_identity = text_snapshot.identity;
      changed = true;
    }
    const bool same =
        text_snapshot.text_units == g_siglus_lookup_active_line_units &&
        text_snapshot.text_units != 0 &&
        memcmp(text_snapshot.text, g_siglus_lookup_active_line,
               static_cast<size_t>(text_snapshot.text_units) *
                   sizeof(wchar_t)) == 0;
    if (!same) {
      g_siglus_lookup_active_line_units = text_snapshot.text_units;
      memcpy(g_siglus_lookup_active_line, text_snapshot.text,
             static_cast<size_t>(text_snapshot.text_units) * sizeof(wchar_t));
      fushi_voice_hook::ResetSiglusLookupLayout(&g_siglus_lookup_layout);
      InvalidateSiglusLookupClickTarget();
      fushi_voice_hook::g_geometry_provider_registry.Retire(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSiglus);
      changed = true;
    }
  }

  const uint64_t latest = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_glyph_event_count, 0, 0));
  if (latest != g_siglus_lookup_glyph_processed_seq) {
    uint64_t first = g_siglus_lookup_glyph_processed_seq + 1;
    if (latest >= kSiglusLookupGlyphEventSlots &&
        first <= latest - kSiglusLookupGlyphEventSlots) {
      first = latest - kSiglusLookupGlyphEventSlots + 1;
      // Lost transport may have contained a layout change. A later matching
      // redraw cannot certify a press spanning that unobserved interval.
      fushi_voice_hook::InvalidateSiglusLookupCurrentLayout(&g_siglus_lookup_layout);
      InvalidateSiglusLookupClickTarget();
      fushi_voice_hook::ClearSiglusLookupGlyphCapture(
          &g_siglus_lookup_glyph_captures);
    }
    uint64_t processed_through = first - 1u;
    for (uint64_t seq = first; seq <= latest; ++seq) {
      SiglusLookupGlyphEvent event;
      // The producer reserves its sequence before publishing the slot. Stop
      // at the first not-yet-published event so the next tick retries it;
      // advancing straight to `latest` would permanently drop a tail glyph.
      if (!ReadSiglusLookupGlyphEvent(seq, &event))
        break;
      fushi_voice_hook::AppendSiglusLookupGlyphCapture(
          static_cast<char16_t>(event.code_unit), event.design_x,
          event.design_y, event.extent, &g_siglus_lookup_glyph_captures);
      processed_through = seq;
      changed = true;
    }
    g_siglus_lookup_glyph_processed_seq = processed_through;
  }

  if (g_siglus_lookup_glyph_processed_seq != latest) {
    // A reserved but unpublished glyph is an incomplete snapshot too. Do not
    // republish the old click target merely because this tick appended none.
    fushi_voice_hook::InvalidateSiglusLookupCurrentLayout(&g_siglus_lookup_layout);
    InvalidateSiglusLookupClickTarget();
    return;
  }
  if (!changed || g_siglus_lookup_active_line_units == 0)
    return;
  const auto *profile = ActiveSiglusLookupProfile();
  if (profile == nullptr)
    return;
  if (fushi_voice_hook::UpdateSiglusLookupLayout(
          *profile, g_siglus_lookup_glyph_captures,
          reinterpret_cast<const char16_t *>(g_siglus_lookup_active_line),
          g_siglus_lookup_active_line_units, &g_siglus_lookup_layout)) {
    SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagGeometryObserved);
  } else {
    // A committed same-line provider/popup survives a split redraw, but no
    // older click target or press may be used while the capture is incomplete.
    InvalidateSiglusLookupClickTarget();
  }
}

bool PublishSiglusLookupHit(const SiglusLookupPayload &payload) {
  if (g_header == nullptr || payload.text_units == 0 ||
      payload.text_units > kSiglusLookupMaxTextUnits ||
      payload.char_index >= payload.text_units) {
    return false;
  }
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  const int bytes = WideCharToMultiByte(
      CP_UTF8, 0, payload.text, static_cast<int>(payload.text_units), utf8,
      static_cast<int>(sizeof(utf8)), nullptr, nullptr);
  if (bytes <= 0 || payload.geometry_generation == 0)
    return false;
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id =
      fushi_voice_hook::kLookupGeometryProviderIdSiglus;
  publication.char_index = payload.char_index;
  publication.source_length = fushi_voice_hook::LookupUtf16SourceLength(
      payload.text, payload.text_units, payload.char_index);
  publication.char_count = payload.text_units;
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.text_generation = payload.text_identity.event_id;
  publication.geometry_generation = payload.geometry_generation;
  publication.glyph_x = payload.rect.x;
  publication.glyph_y = payload.rect.y;
  publication.glyph_w = payload.rect.width;
  publication.glyph_h = payload.rect.height;
  publication.view_w = payload.client_width;
  publication.view_h = payload.client_height;
  publication.flags = fushi_voice_hook::kLookupHitFlagSubmit;
  publication.line_utf8 = reinterpret_cast<const uint8_t *>(utf8);
  publication.line_bytes = static_cast<uint32_t>(bytes);
  return fushi_voice_hook::g_geometry_provider_registry.PublishHit(g_header, publication);
}

bool IsSiglusLookupPayloadEligible(const SiglusLookupPayload &payload,
    SiglusLookupRejectReason* rejection = nullptr) {
  if (rejection != nullptr) *rejection = SiglusLookupRejectReason::kNone;
  const auto reject = [rejection](SiglusLookupRejectReason reason) {
    if (rejection != nullptr) *rejection = reason;
    return false;
  };
  const auto *profile = ActiveSiglusLookupProfile();
  const uint64_t latest_text = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_text_count, 0, 0));
  if (profile == nullptr ||
      !fushi_voice_hook::IsSiglusLookupTextIdentityCurrent(
          payload.text_identity, g_siglus_lookup_text_identity) ||
      !fushi_voice_hook::IsSiglusLookupLayoutSubmissionCurrent(
          g_siglus_lookup_layout, payload.geometry_generation,
          payload.snapshot_epoch) || payload.text_units == 0 ||
      latest_text != g_siglus_lookup_text_processed_seq ||
      payload.text_units != g_siglus_lookup_active_line_units ||
      payload.char_index >= payload.text_units ||
      memcmp(payload.text, g_siglus_lookup_active_line,
             static_cast<size_t>(payload.text_units) * sizeof(wchar_t)) != 0) {
    if (profile == nullptr) return reject(SiglusLookupRejectReason::kProfileUnavailable);
    if (!fushi_voice_hook::IsSiglusLookupTextIdentityCurrent(
            payload.text_identity, g_siglus_lookup_text_identity))
      return reject(SiglusLookupRejectReason::kTextIdentity);
    if (!g_siglus_lookup_layout.current_valid)
      return reject(SiglusLookupRejectReason::kLayoutIncomplete);
    if (payload.geometry_generation == 0 ||
        payload.geometry_generation != g_siglus_lookup_layout.generation)
      return reject(SiglusLookupRejectReason::kGeometryGeneration);
    if (payload.snapshot_epoch == 0 ||
        payload.snapshot_epoch != g_siglus_lookup_layout.snapshot_epoch)
      return reject(SiglusLookupRejectReason::kSnapshotEpoch);
    if (payload.text_units == 0) return reject(SiglusLookupRejectReason::kTextBody);
    if (latest_text != g_siglus_lookup_text_processed_seq)
      return reject(SiglusLookupRejectReason::kUnreadText);
    return reject(SiglusLookupRejectReason::kTextBody);
  }

  const HWND game = reinterpret_cast<HWND>(payload.game_window);
  fushi_voice_hook::SiglusLookupEngineView engine_view;
  if (!ReadSiglusLookupEngineView(game, &engine_view))
    return reject(SiglusLookupRejectReason::kEngineViewUnavailable);
  if (!fushi_voice_hook::SameSiglusLookupEngineView(engine_view, payload.engine_view))
    return reject(SiglusLookupRejectReason::kEngineViewChanged);
  RECT client = {};
  POINT origin = {0, 0};
  if (game == nullptr || !IsWindow(game))
    return reject(SiglusLookupRejectReason::kWindowUnavailable);
  if (GetForegroundWindow() != game)
    return reject(SiglusLookupRejectReason::kForegroundChanged);
  if (g_siglus_sampled_input_game_window.load(std::memory_order_acquire) != game)
    return reject(SiglusLookupRejectReason::kSampledWindowChanged);
  if (!GetClientRect(game, &client) || !ClientToScreen(game, &origin))
    return reject(SiglusLookupRejectReason::kClientUnavailable);
  const fushi_voice_hook::SiglusLookupClientSnapshot active_client = {
      reinterpret_cast<uintptr_t>(game), origin.x, origin.y,
      client.right - client.left, client.bottom - client.top};
  if (!fushi_voice_hook::MatchesSiglusLookupGenerationAndClient(
          payload.geometry_generation,
          SiglusLookupPayloadClientSnapshot(payload),
          g_siglus_lookup_layout.generation, active_client)) {
    return reject(SiglusLookupRejectReason::kClientTransformChanged);
  }

  for (size_t index = 0;
       index < g_siglus_lookup_layout.geometry.glyph_count; ++index) {
    const auto &glyph = g_siglus_lookup_layout.geometry.glyphs[index];
    if (glyph.char_index != payload.char_index)
      continue;
    fushi_voice_hook::SiglusLookupRect expected;
    if (!fushi_voice_hook::ProjectSiglusLookupRect(
            *profile, engine_view, glyph.rect, active_client.width, active_client.height,
            &expected)) {
      return reject(SiglusLookupRejectReason::kGlyphProjection);
    }
    const bool same = payload.rect.x == expected.x && payload.rect.y == expected.y &&
           payload.rect.width == expected.width &&
           payload.rect.height == expected.height;
    return same || reject(SiglusLookupRejectReason::kGlyphRectangle);
  }
  return reject(SiglusLookupRejectReason::kGlyphMissing);
}

enum class SiglusLookupSubmissionResult {
  kRejected,
  kAwaitingCapture,
  kReady,
  kPublished,
};

SiglusLookupSubmissionResult CheckSiglusLookupSubmission(
    const SiglusLookupPayload &payload, uint64_t* awaiting_glyph_seq,
    SiglusLookupRejectReason* rejection = nullptr) {
  *awaiting_glyph_seq = 0;
  if (!IsSiglusLookupPayloadEligible(payload, rejection))
    return SiglusLookupSubmissionResult::kRejected;
  const uint64_t latest_glyph = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_glyph_event_count, 0, 0));
  if (latest_glyph != g_siglus_lookup_glyph_processed_seq) {
    *awaiting_glyph_seq = latest_glyph;
    return SiglusLookupSubmissionResult::kAwaitingCapture;
  }
  return SiglusLookupSubmissionResult::kReady;
}

SiglusLookupSubmissionResult TryPublishSiglusLookupPayload(
    const SiglusLookupPayload &payload, uint64_t* awaiting_glyph_seq,
    SiglusLookupRejectReason* rejection = nullptr) {
  const auto initial = CheckSiglusLookupSubmission(payload, awaiting_glyph_seq, rejection);
  if (initial != SiglusLookupSubmissionResult::kReady)
    return initial;
  const ULONGLONG now = GetTickCount64();
  uint64_t identity = 1469598103934665603ull;
  const auto hash_value = [&identity](uint64_t value) {
    identity ^= value;
    identity *= 1099511628211ull;
  };
  hash_value(payload.text_units);
  for (uint32_t index = 0; index < payload.text_units; ++index) {
    hash_value(static_cast<uint32_t>(payload.text[index]));
  }
  hash_value(payload.char_index);
  hash_value(static_cast<uint32_t>(payload.rect.x));
  hash_value(static_cast<uint32_t>(payload.rect.y));
  if (identity == g_siglus_lookup_last_hit_identity &&
      now >= g_siglus_lookup_last_hit_tick &&
      now - g_siglus_lookup_last_hit_tick <=
          kSiglusLookupDuplicateHitWindowMs) {
    if (rejection != nullptr) *rejection = SiglusLookupRejectReason::kDuplicate;
    return SiglusLookupSubmissionResult::kRejected;
  }
  const auto confirmed = CheckSiglusLookupSubmission(payload, awaiting_glyph_seq, rejection);
  if (confirmed != SiglusLookupSubmissionResult::kReady)
    return confirmed;
  if (!PublishSiglusLookupHit(payload)) {
    if (rejection != nullptr) *rejection = SiglusLookupRejectReason::kHitPublicationRejected;
    return SiglusLookupSubmissionResult::kRejected;
  }
  g_siglus_lookup_last_hit_identity = identity;
  g_siglus_lookup_last_hit_tick = now;
  return SiglusLookupSubmissionResult::kPublished;
}

bool PublishSiglusLookupPayload(const SiglusLookupPayload &payload) {
  uint64_t awaiting_glyph_seq = 0;
  return TryPublishSiglusLookupPayload(payload, &awaiting_glyph_seq) ==
      SiglusLookupSubmissionResult::kPublished;
}

bool ProcessSiglusLookupClickSubmissions() {
  SiglusLookupClickEvent click_event;
  uint64_t click_seq = 0;
  if (!ReadNextSiglusLookupClickSubmit(&click_event, &click_seq)) return false;
  if (g_siglus_lookup_waiting_click_seq == click_seq &&
      g_siglus_lookup_glyph_processed_seq < g_siglus_lookup_waiting_glyph_seq &&
      IsSiglusLookupPayloadEligible(click_event.payload)) {
    // No capture progress: do not re-attempt the same publication. Eligibility
    // is still checked so text/epoch/window changes terminate waiting at once.
    return false;
  }
  uint64_t awaiting_glyph_seq = 0;
  SiglusLookupRejectReason rejection = SiglusLookupRejectReason::kNone;
  const auto result =
      TryPublishSiglusLookupPayload(click_event.payload, &awaiting_glyph_seq, &rejection);
  if (result == SiglusLookupSubmissionResult::kAwaitingCapture) {
    g_siglus_lookup_waiting_click_seq = click_seq;
    g_siglus_lookup_waiting_glyph_seq = awaiting_glyph_seq;
    return false;
  }
  RecordSiglusLookupWorkerDiagnostic(click_seq, click_seq, &click_event.payload,
      result == SiglusLookupSubmissionResult::kPublished
          ? SiglusLookupRejectReason::kPublished : rejection);
  g_siglus_lookup_click_processed_seq = click_seq;
  g_siglus_lookup_waiting_click_seq = 0;
  g_siglus_lookup_waiting_glyph_seq = 0;
  return result == SiglusLookupSubmissionResult::kPublished;
}
