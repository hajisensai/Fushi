// The eight-argument family owns clicks at its proved engine WM sink. A full
// down/up can pass between two GetKeyState polls; sampling cannot complete it.
struct SiglusLookupMessageTransaction {
  SiglusLookupPayload payload;
  uint32_t epoch = 0;
  DWORD thread_id = 0;
  bool pending = false;
};
SiglusLookupMessageTransaction g_siglus_lookup_message_transaction;
thread_local fushi_voice_hook::SiglusLookupClickSampleState
    g_siglus_lookup_message_popup_sample;
thread_local uint32_t g_siglus_lookup_message_popup_epoch = 0;

bool IsSiglusLookupMessageTransactionProfile() {
  const auto* profile = ActiveSiglusLookupProfile();
  return profile != nullptr && profile->glyph_abi ==
      fushi_voice_hook::SiglusGlyphLayoutAbi::kEcxEightArguments;
}

SHORT FilterSiglusLookupMessageTransactionSample(SHORT raw, bool popup_shield,
    bool direct_shield, bool bitmap_popup_visible, HWND game) {
  const bool down = (static_cast<uint16_t>(raw) & 0x8000u) != 0;
  const uint32_t epoch = g_siglus_lookup_click_epoch.load(std::memory_order_acquire);
  if (epoch != g_siglus_lookup_message_popup_epoch) {
    g_siglus_lookup_message_popup_epoch = epoch;
    g_siglus_lookup_message_popup_sample = {};
  }
  const auto popup_decision = fushi_voice_hook::AdvanceSiglusLookupClickSample(
      false, down, popup_shield, fushi_voice_hook::kSiglusLookupNoGlyph,
      &g_siglus_lookup_message_popup_sample);
  const bool message_owned = g_siglus_lookup_message_left_button_latched.load(
      std::memory_order_acquire);
  const bool sampled_tail = g_siglus_lookup_left_button_filter_latched.load(
      std::memory_order_acquire);
  if (down && popup_shield)
    g_siglus_lookup_left_button_filter_latched.store(true, std::memory_order_release);
  if (popup_decision.begin && popup_decision.popup_transaction &&
      !direct_shield && bitmap_popup_visible &&
      game != nullptr && GetForegroundWindow() == game) {
    POINT pointer = {};
    if (GetCursorPos(&pointer)) {
      const HWND point_window = WindowFromPoint(pointer);
      if (point_window != nullptr &&
          (point_window == game || IsChild(game, point_window)))
        RequestLookupOverlayOutsideDismiss();
    }
  }
  // An up sample cannot release an in-flight WM transaction. After WM up,
  // retain the filter through this sample itself, then rearm the next press.
  const SHORT filtered = fushi_voice_hook::FilterSiglusLookupGetKeyState(
      raw, popup_shield || message_owned || sampled_tail);
  if (!down && !message_owned)
    g_siglus_lookup_left_button_filter_latched.store(false, std::memory_order_release);
  return filtered;
}

bool ConsumeSiglusLookupMessageTransaction(UINT message, LPARAM lparam,
                                          HWND game, bool popup_shield) {
  const DWORD thread_id = GetCurrentThreadId();
  if (game == nullptr || GetWindowThreadProcessId(game, nullptr) != thread_id)
    return false;
  if (message == WM_CANCELMODE || message == WM_CAPTURECHANGED ||
      message == WM_KILLFOCUS) {
    if (g_siglus_lookup_message_transaction.thread_id == thread_id)
      g_siglus_lookup_message_transaction.pending = false;
    return false; // Cancellation still reaches the engine; owned up stays shielded.
  }
  const bool down = message == WM_LBUTTONDOWN || message == WM_LBUTTONDBLCLK;
  if (!down && message != WM_LBUTTONUP) return false;
  const uint32_t epoch = g_siglus_lookup_click_epoch.load(std::memory_order_acquire);
  const bool latched = g_siglus_lookup_message_left_button_latched.load(
      std::memory_order_acquire);
  if (!down) {
    // Clear before validation/queueing so reentry or duplicate up cannot submit.
    const auto pending = g_siglus_lookup_message_transaction;
    g_siglus_lookup_message_transaction = {};
    g_siglus_lookup_message_left_button_latched.store(false, std::memory_order_release);
    if (latched && pending.pending && pending.thread_id == thread_id &&
        pending.epoch == epoch && !popup_shield &&
        g_siglus_lookup_click_runtime_enabled.load(std::memory_order_acquire) &&
        game != nullptr && GetForegroundWindow() == game &&
        pending.payload.game_window == reinterpret_cast<uintptr_t>(game) &&
        SiglusLookupViewAllowsInput(game) &&
        fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
            g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
            fushi_voice_hook::kLookupGeometryProviderIdSiglus) &&
        SiglusLookupPayloadMatchesPublishedTarget(pending.payload)) {
      QueueSiglusLookupClickSubmit(pending.payload);
    }
    return latched;
  }
  // A fresh down also retires a lost up; never reuse its payload or ownership.
  g_siglus_lookup_message_transaction = {};
  SiglusLookupPressDiagnostic diagnostic;
  diagnostic.tick = GetTickCount64();
  diagnostic.surface = SiglusLookupPressSurface::kEngineMessage;
  const bool runtime = g_siglus_lookup_click_runtime_enabled.load(std::memory_order_acquire);
  const bool view_allowed = runtime && SiglusLookupViewAllowsInput(game);
  const bool admitted = view_allowed && !popup_shield &&
      fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSiglus);
  diagnostic.flags = (runtime ? 1u : 0u) | (admitted ? 4u : 0u);
  diagnostic.reason = !runtime ? SiglusLookupPressReason::kRuntimeDisabled
      : !view_allowed ? SiglusLookupPressReason::kLiveViewRejected
      : SiglusLookupPressReason::kNativeAdmissionRejected;
  SiglusLookupClickTarget target;
  SiglusLookupPayload payload;
  uint16_t glyph_index = fushi_voice_hook::kSiglusLookupNoGlyph;
  POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  bool hit = false;
  if (admitted && game != nullptr && ClientToScreen(game, &point)) {
    diagnostic.screen_x = point.x;
    diagnostic.screen_y = point.y;
    hit = ReadSiglusLookupClickTarget(&target, &diagnostic) &&
        BuildSiglusLookupPayloadAtPress(target, game, point, &payload,
                                       &glyph_index, &diagnostic);
  }
  const auto decision = fushi_voice_hook::DecideSiglusLookupMouseMessage(
      admitted, message, popup_shield, hit, latched);
  if (hit && decision.consume && !popup_shield) {
    g_siglus_lookup_message_transaction = {payload, epoch, thread_id, true};
  }
  g_siglus_lookup_message_left_button_latched.store(decision.next_latched,
                                                  std::memory_order_release);
  g_siglus_lookup_left_button_filter_latched.store(decision.consume,
                                                  std::memory_order_release);
  diagnostic.flags |= decision.consume ? 8u : 0u;
  diagnostic.flags |= popup_shield ? 32u : 0u;
  if (decision.consume) diagnostic.reason = popup_shield
      ? SiglusLookupPressReason::kPopupOwned : SiglusLookupPressReason::kLookupOwned;
  RecordSiglusLookupPressDiagnostic(diagnostic);
  return decision.consume;
}
