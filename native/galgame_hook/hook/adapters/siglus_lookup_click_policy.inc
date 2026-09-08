SHORT FilterSiglusLookupLeftButtonSample(SHORT raw, uintptr_t return_address,
                                         bool keyboard_table) {
  if (!g_capture_enabled) {
    // Diagnostic history only: no ownership reset and no module/game reads.
    ResetSiglusLookupDiagnosticHistory();
    return raw;
  }
  // 早退之后才解析模块基址：这条 detour 装在全进程的 user32!GetKeyState 上，
  // 游戏每帧会为一堆与查词无关的虚拟键调它，把 syscall 排在早退之前等于给每一次
  // 调用白付一笔。
  const uintptr_t module =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  const bool runtime_enabled =
      g_siglus_lookup_click_runtime_enabled.load(std::memory_order_acquire);
  const HWND published_game =
      g_siglus_sampled_input_game_window.load(std::memory_order_acquire);
  const HWND direct_popup =
      GetValidPublishedSiglusSampledInputShieldPopup(published_game);
  const bool direct_shield =
      direct_popup != nullptr &&
      IsSiglusSampledInputShieldReadyPublished(published_game);
  const bool bitmap_popup_visible = IsLookupOverlayInputShieldVisible();
  const bool popup_shield = direct_shield || bitmap_popup_visible;
  const bool lookup_press_latched =
      g_siglus_lookup_left_button_filter_latched.load(
          std::memory_order_acquire);
  const auto *profile = ActiveSiglusLookupProfile();
  const bool admitted_lookup_poller =
      profile != nullptr && return_address >= module &&
      return_address - module == (keyboard_table
          ? profile->get_keyboard_state_return_rva
          : profile->get_key_state_return_rva);
  if (!admitted_lookup_poller) {
    // The WebView HWND consumes queued mouse messages in its real region and
    // the host HHOOK consumes game-client clicks outside it.  Siglus also polls
    // physical state at several other callsites, so those callers must be
    // filtered before the exact lookup-poller gate.  Otherwise a click can be
    // handled by WebView and still advance the game in the same frame.
    return fushi_voice_hook::FilterSiglusLookupGetKeyState(
        raw, popup_shield || lookup_press_latched);
  }
  SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagSiglusGetKeyStateObserved);
  const bool button_down = (static_cast<uint16_t>(raw) & 0x8000u) != 0;
  const uint32_t epoch =
      g_siglus_lookup_click_epoch.load(std::memory_order_acquire);
  const bool diagnostic_down =
      ObserveSiglusLookupDiagnosticDown(button_down, keyboard_table, epoch);
  SiglusLookupPressDiagnostic diagnostic;
  auto* observed = diagnostic_down ? &diagnostic : nullptr;
  if (observed != nullptr) {
    diagnostic.tick = GetTickCount64();
    diagnostic.surface = keyboard_table ? SiglusLookupPressSurface::kKeyboardState
                                       : SiglusLookupPressSurface::kKeyState;
    diagnostic.flags = runtime_enabled ? 1u : 0u;
  }
  if (observed != nullptr) {
    diagnostic.sample_epoch = epoch;
    diagnostic.previous_sample_epoch = g_siglus_lookup_click_observed_epoch;
  }
  // Freeze only scalar pending metadata before the existing lifecycle reset.
  // A completion record is emitted only if this owned up never reaches Queue.
  const bool owned_up = !button_down && g_siglus_lookup_click_sample_state.owner ==
      fushi_voice_hook::SiglusLookupClickOwner::kLookup;
  SiglusLookupPressDiagnostic completion;
  if (owned_up) {
    completion.tick = GetTickCount64();
    completion.surface = keyboard_table ? SiglusLookupPressSurface::kKeyboardStateCompletion
                                       : SiglusLookupPressSurface::kKeyStateCompletion;
    completion.sample_epoch = epoch;
    completion.previous_sample_epoch = g_siglus_lookup_click_observed_epoch;
    completion.flags = runtime_enabled ? 1u : 0u;
    completion.sample_owner = static_cast<uint32_t>(g_siglus_lookup_click_sample_state.owner);
    if (g_siglus_lookup_pending_click_valid) {
      completion.pending_event_id = g_siglus_lookup_pending_click.text_identity.event_id;
      completion.pending_thread_id = g_siglus_lookup_pending_click.text_identity.thread_id;
      completion.pending_geometry_generation = g_siglus_lookup_pending_click.geometry_generation;
      completion.pending_snapshot_epoch = g_siglus_lookup_pending_click.snapshot_epoch;
    }
    if (epoch != g_siglus_lookup_click_observed_epoch)
      completion.reason = SiglusLookupPressReason::kSampleEpochReset;
  }
  if (epoch != g_siglus_lookup_click_observed_epoch) {
    g_siglus_lookup_click_observed_epoch = epoch;
    g_siglus_lookup_click_sample_state = {};
    g_siglus_lookup_pending_click = {};
    g_siglus_lookup_pending_click_valid = false;
    g_siglus_lookup_left_button_filter_latched.store(false,
                                                     std::memory_order_release);
  }
  if (!runtime_enabled && !popup_shield && !lookup_press_latched &&
      g_siglus_lookup_click_sample_state.owner ==
          fushi_voice_hook::SiglusLookupClickOwner::kIdle) {
    if (observed != nullptr) {
      diagnostic.reason = SiglusLookupPressReason::kRuntimeDisabled;
      RecordSiglusLookupPressDiagnostic(diagnostic);
    }
    if (owned_up) {
      if (completion.reason == SiglusLookupPressReason::kNotEvaluated)
        completion.reason = SiglusLookupPressReason::kRuntimeDisabled;
      RecordSiglusLookupPressDiagnostic(completion);
    }
    return raw;
  }
  const bool fresh_down = button_down &&
                          g_siglus_lookup_click_sample_state.synchronized &&
                          g_siglus_lookup_click_sample_state.owner ==
                              fushi_voice_hook::SiglusLookupClickOwner::kIdle;
  HWND game = published_game;
  if (game == nullptr || !IsWindow(game))
    game = FindGameMainWindow();
  POINT pointer = {};
  const bool pointer_valid = !fresh_down || GetCursorPos(&pointer) != FALSE;
  SiglusLookupPayload pressed_payload;
  uint16_t hit_index = fushi_voice_hook::kSiglusLookupNoGlyph;
  bool hit = false;
  if (observed != nullptr) {
    diagnostic.sample_owner = static_cast<uint32_t>(g_siglus_lookup_click_sample_state.owner);
    diagnostic.flags |= g_siglus_lookup_click_sample_state.synchronized ? 2u : 0u;
    diagnostic.flags |= fresh_down ? 128u : 0u;
    diagnostic.screen_x = pointer.x;
    diagnostic.screen_y = pointer.y;
    diagnostic.reason = !g_siglus_lookup_click_sample_state.synchronized
        ? SiglusLookupPressReason::kUnsynchronized
        : SiglusLookupPressReason::kExistingTransaction;
  }
  // A live text/geometry sensor is not permission to consume game input.
  // Query the registry at the down edge (and recheck before submitting up),
  // without waiting on its worker lock. Existing owners retain their tail.
  const bool view_allowed = runtime_enabled && SiglusLookupViewAllowsInput(game);
  const bool native_input_allowed = view_allowed &&
      (fresh_down || (!button_down &&
          g_siglus_lookup_click_sample_state.owner ==
              fushi_voice_hook::SiglusLookupClickOwner::kLookup)) &&
      fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSiglus);
  if (observed != nullptr && fresh_down) {
    diagnostic.reason = !runtime_enabled ? SiglusLookupPressReason::kRuntimeDisabled
        : !view_allowed ? SiglusLookupPressReason::kLiveViewRejected
        : !native_input_allowed ? SiglusLookupPressReason::kNativeAdmissionRejected
        : !pointer_valid ? SiglusLookupPressReason::kCursorUnavailable
        : SiglusLookupPressReason::kNotEvaluated;
    diagnostic.flags |= native_input_allowed ? 4u : 0u;
  }
  if (fresh_down && native_input_allowed && !popup_shield && pointer_valid &&
      ReadSiglusLookupClickTarget(&g_siglus_lookup_click_read_target, observed)) {
    hit =
        BuildSiglusLookupPayloadAtPress(g_siglus_lookup_click_read_target, game,
                                        pointer, &pressed_payload, &hit_index, observed);
  }
  const auto decision = fushi_voice_hook::AdvanceSiglusLookupClickSample(
      native_input_allowed, button_down, popup_shield,
      hit ? hit_index : fushi_voice_hook::kSiglusLookupNoGlyph,
      &g_siglus_lookup_click_sample_state);
  if (observed != nullptr) {
    diagnostic.flags |= decision.consume ? 8u : 0u;
    diagnostic.flags |= decision.begin ? 16u : 0u;
    diagnostic.flags |= decision.popup_transaction ? 32u : 0u;
    if (decision.consume && decision.begin)
      diagnostic.reason = decision.popup_transaction
          ? SiglusLookupPressReason::kPopupOwned : SiglusLookupPressReason::kLookupOwned;
    RecordSiglusLookupPressDiagnostic(diagnostic);
  }
  if (decision.begin && decision.popup_transaction && pointer_valid &&
      !direct_shield && bitmap_popup_visible && game != nullptr &&
      GetForegroundWindow() == game) {
    const HWND point_window = WindowFromPoint(pointer);
    if (point_window != nullptr &&
        (point_window == game || IsChild(game, point_window))) {
      RequestLookupOverlayOutsideDismiss();
    }
  }
  if (decision.begin && hit && !decision.popup_transaction) {
    g_siglus_lookup_pending_click = pressed_payload;
    g_siglus_lookup_pending_click_valid = true;
  }
  bool queued = false;
  if (decision.submit) {
    // Freeze the glyph at down, then require the worker-published logical
    // sentence, geometry, HWND and client transform to still match on up.
    if (g_siglus_lookup_pending_click_valid && runtime_enabled &&
        SiglusLookupPayloadMatchesPublishedTarget(
            g_siglus_lookup_pending_click, owned_up ? &completion : nullptr)) {
      QueueSiglusLookupClickSubmit(g_siglus_lookup_pending_click);
      queued = true;
    }
    if (owned_up && !g_siglus_lookup_pending_click_valid)
      completion.reason = SiglusLookupPressReason::kPendingUnavailable;
    g_siglus_lookup_pending_click_valid = false;
  } else if (!button_down && !decision.consume) {
    g_siglus_lookup_pending_click_valid = false;
  }
  if (owned_up && !queued) {
    completion.flags |= decision.consume ? 8u : 0u;
    completion.flags |= native_input_allowed ? 4u : 0u;
    if (completion.reason == SiglusLookupPressReason::kNotEvaluated)
      completion.reason = !runtime_enabled ? SiglusLookupPressReason::kRuntimeDisabled
          : !view_allowed ? SiglusLookupPressReason::kLiveViewRejected
          : SiglusLookupPressReason::kNativeAdmissionRejected;
    RecordSiglusLookupPressDiagnostic(completion);
  }
  if (decision.consume) {
    g_siglus_lookup_left_button_filter_latched.store(true,
                                                     std::memory_order_release);
  }
  const SHORT filtered = fushi_voice_hook::FilterSiglusLookupGetKeyState(
      raw, decision.consume || popup_shield || lookup_press_latched);
  if (!button_down) {
    // Keep the latch through the exact poller's up sample itself, then release
    // it for the next physical transaction. Other GetKeyState callers are not
    // allowed to clear it because GetKeyState state is thread-queue-relative.
    g_siglus_lookup_left_button_filter_latched.store(false,
                                                     std::memory_order_release);
  }
  return filtered;
}

bool ConsumeSiglusLookupInputMessage(UINT message, LPARAM lparam,
                                    uintptr_t return_address) {
  const uintptr_t module =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  const auto *profile = ActiveSiglusLookupProfile();
  if (profile == nullptr || return_address < module ||
      return_address - module != profile->main_input_message_return_rva) {
    return false;
  }

  const bool is_down =
      message == fushi_voice_hook::kSiglusLookupWmLeftButtonDown ||
      message == fushi_voice_hook::kSiglusLookupWmLeftButtonDoubleClick;
  const bool is_up = message == fushi_voice_hook::kSiglusLookupWmLeftButtonUp;
  if (!is_down && !is_up) {
    return false;
  }

  HWND game =
      g_siglus_sampled_input_game_window.load(std::memory_order_acquire);
  if (game == nullptr || !IsWindow(game))
    game = FindGameMainWindow();
  const HWND direct_popup =
      GetValidPublishedSiglusSampledInputShieldPopup(game);
  const bool direct_shield =
      direct_popup != nullptr && IsSiglusSampledInputShieldReadyPublished(game);
  const bool popup_shield =
      direct_shield || IsLookupOverlayInputShieldVisible();

  bool glyph_hit = false;
  SiglusLookupPressDiagnostic diagnostic;
  auto* observed = is_down ? &diagnostic : nullptr;
  if (observed != nullptr) {
    diagnostic.tick = GetTickCount64();
    diagnostic.surface = SiglusLookupPressSurface::kEngineMessage;
  }
  bool view_allowed = false;
  bool runtime_enabled = false;
  const bool native_input_allowed = is_down && !popup_shield &&
      (runtime_enabled = g_siglus_lookup_click_runtime_enabled.load(std::memory_order_acquire)) &&
      (view_allowed = SiglusLookupViewAllowsInput(game)) &&
      fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSiglus);
  if (observed != nullptr) {
    diagnostic.flags = (runtime_enabled ? 1u : 0u) | (native_input_allowed ? 4u : 0u);
    diagnostic.reason = !runtime_enabled ? SiglusLookupPressReason::kRuntimeDisabled
        : !view_allowed ? SiglusLookupPressReason::kLiveViewRejected
        : SiglusLookupPressReason::kNativeAdmissionRejected;
  }
  if (native_input_allowed && game != nullptr) {
    POINT screen_point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    SiglusLookupClickTarget target;
    SiglusLookupPayload payload;
    uint16_t glyph_index = fushi_voice_hook::kSiglusLookupNoGlyph;
    const bool screen_valid = ClientToScreen(game, &screen_point) != FALSE;
    if (observed != nullptr) {
      diagnostic.screen_x = screen_point.x;
      diagnostic.screen_y = screen_point.y;
      if (!screen_valid) diagnostic.reason = SiglusLookupPressReason::kClientUnavailable;
    }
    if (screen_valid && ReadSiglusLookupClickTarget(&target, observed)) {
      glyph_hit = BuildSiglusLookupPayloadAtPress(target, game, screen_point,
                                                  &payload, &glyph_index, observed);
    }
  }

  const bool latched = g_siglus_lookup_message_left_button_latched.load(
      std::memory_order_acquire);
  const auto decision = fushi_voice_hook::DecideSiglusLookupMouseMessage(
      native_input_allowed, static_cast<uint32_t>(message), popup_shield,
      glyph_hit, latched);
  if (observed != nullptr) {
    diagnostic.flags |= decision.consume ? 8u : 0u;
    diagnostic.flags |= popup_shield ? 32u : 0u;
    if (decision.consume)
      diagnostic.reason = popup_shield ? SiglusLookupPressReason::kPopupOwned
                                       : SiglusLookupPressReason::kLookupOwned;
    RecordSiglusLookupPressDiagnostic(diagnostic);
  }
  g_siglus_lookup_message_left_button_latched.store(decision.next_latched,
                                                    std::memory_order_release);
  if (decision.consume) {
    // The exact GetKeyState poller still observes physical state and owns the
    // one lookup submission. This latch only makes every other state consumer
    // agree while the engine's independent WM edge writer is bypassed.
    g_siglus_lookup_left_button_filter_latched.store(true,
                                                     std::memory_order_release);
    return true;
  }
  return false;
}
