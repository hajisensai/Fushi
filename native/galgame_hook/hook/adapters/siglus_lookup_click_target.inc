bool ReadSiglusLookupClickTarget(SiglusLookupClickTarget *copy,
    SiglusLookupPressDiagnostic* diagnostic = nullptr) {
  using Reason = SiglusLookupPressReason;
  if (copy == nullptr)
    return false;
  const uint64_t before = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_click_target.seq, 0, 0));
  if (before == 0)
    return RejectSiglusLookupPress(diagnostic, Reason::kTargetUnpublished);
  memcpy(copy, &g_siglus_lookup_click_target, sizeof(*copy));
  const uint64_t after = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_click_target.seq, 0, 0));
  const ULONGLONG now = GetTickCount64();
  if (after != before || after == 0)
    return RejectSiglusLookupPress(diagnostic, Reason::kTargetChanged);
  SetSiglusLookupPressTarget(diagnostic, *copy);
  if (copy->valid != 1)
    return RejectSiglusLookupPress(diagnostic, Reason::kTargetInvalid);
  if (copy->text_identity.event_id == 0 || copy->text_identity.thread_id == 0)
    return RejectSiglusLookupPress(diagnostic, Reason::kTargetIdentity);
  if (copy->text_units == 0 || copy->text_units > kSiglusLookupMaxTextUnits)
    return RejectSiglusLookupPress(diagnostic, Reason::kTargetTextUnits);
  if (copy->geometry.glyph_count == 0 ||
      copy->geometry.glyph_count > fushi_voice_hook::kSiglusLookupMaxGlyphs)
    return RejectSiglusLookupPress(diagnostic, Reason::kTargetGlyphCount);
  if (copy->geometry_generation == 0)
    return RejectSiglusLookupPress(diagnostic, Reason::kTargetGeneration);
  if (copy->snapshot_epoch == 0)
    return RejectSiglusLookupPress(diagnostic, Reason::kTargetEpoch);
  if (copy->published_tick == 0 || now < copy->published_tick)
    return RejectSiglusLookupPress(diagnostic, Reason::kTargetTimestamp);
  if (now - copy->published_tick > kSiglusLookupClickTargetMaxAgeMs)
    return RejectSiglusLookupPress(diagnostic, Reason::kTargetExpired);
  return true;
}

bool BuildSiglusLookupPayloadAtPress(const SiglusLookupClickTarget &target,
                                     HWND game, const POINT &screen_point,
                                     SiglusLookupPayload *payload,
                                     uint16_t *glyph_index,
                                     SiglusLookupPressDiagnostic* diagnostic = nullptr) {
  using Reason = SiglusLookupPressReason;
  const auto *profile = ActiveSiglusLookupProfile();
  if (payload == nullptr || glyph_index == nullptr || target.valid != 1)
    return RejectSiglusLookupPress(diagnostic, Reason::kTargetInvalid);
  if (profile == nullptr)
    return RejectSiglusLookupPress(diagnostic, Reason::kProfileUnavailable);
  if (game == nullptr || reinterpret_cast<HWND>(target.game_window) != game)
    return RejectSiglusLookupPress(diagnostic, Reason::kWindowMismatch);
  if (!IsWindow(game))
    return RejectSiglusLookupPress(diagnostic, Reason::kWindowUnavailable);
  if (GetForegroundWindow() != game)
    return RejectSiglusLookupPress(diagnostic, Reason::kForegroundMismatch);
  const HWND point_window = WindowFromPoint(screen_point);
  if (point_window == nullptr ||
      (point_window != game && !IsChild(game, point_window))) {
    return RejectSiglusLookupPress(diagnostic, Reason::kPointWindowMismatch);
  }
  RECT client = {};
  POINT origin = {0, 0};
  if (!GetClientRect(game, &client) || !ClientToScreen(game, &origin)) {
    return RejectSiglusLookupPress(diagnostic, Reason::kClientUnavailable);
  }
  const int32_t client_width = client.right - client.left;
  const int32_t client_height = client.bottom - client.top;
  if (client_width != target.client_width ||
      client_height != target.client_height ||
      origin.x != target.client_screen_x ||
      origin.y != target.client_screen_y) {
    return RejectSiglusLookupPress(diagnostic, Reason::kClientChanged);
  }
  fushi_voice_hook::SiglusLookupEngineView engine_view;
  if (!ReadSiglusLookupEngineView(game, &engine_view))
    return RejectSiglusLookupPress(diagnostic, Reason::kLiveViewRejected);
  if (!fushi_voice_hook::SameSiglusLookupEngineView(engine_view, target.engine_view))
    return RejectSiglusLookupPress(diagnostic, Reason::kEngineViewChanged);
  const int32_t cursor_x = screen_point.x - origin.x;
  const int32_t cursor_y = screen_point.y - origin.y;
  bool any_projected = false;
  for (size_t index = 0; index < target.geometry.glyph_count; ++index) {
    fushi_voice_hook::SiglusLookupRect client_rect;
    if (!fushi_voice_hook::ProjectSiglusLookupRect(
            *profile, engine_view, target.geometry.glyphs[index].rect, client_width,
            client_height, &client_rect)) {
      continue;
    }
    any_projected = true;
    if (cursor_x < client_rect.x || cursor_y < client_rect.y ||
        cursor_x >= client_rect.x + client_rect.width ||
        cursor_y >= client_rect.y + client_rect.height) {
      continue;
    }
    *payload = {};
    payload->engine_view = engine_view;
    payload->text_identity = target.text_identity;
    payload->geometry_generation = target.geometry_generation;
    payload->snapshot_epoch = target.snapshot_epoch;
    payload->text_units = target.text_units;
    payload->char_index = target.geometry.glyphs[index].char_index;
    payload->rect = client_rect;
    payload->game_window = reinterpret_cast<uintptr_t>(game);
    payload->client_screen_x = origin.x;
    payload->client_screen_y = origin.y;
    payload->client_width = client_width;
    payload->client_height = client_height;
    memcpy(payload->text, target.text,
           static_cast<size_t>(target.text_units) * sizeof(wchar_t));
    *glyph_index = static_cast<uint16_t>(index);
    return payload->char_index < payload->text_units ||
        RejectSiglusLookupPress(diagnostic, Reason::kCharacterIndex);
  }
  return RejectSiglusLookupPress(diagnostic,
      any_projected ? Reason::kPointMiss : Reason::kNoProjectedGlyph);
}

fushi_voice_hook::SiglusLookupClientSnapshot SiglusLookupPayloadClientSnapshot(
    const SiglusLookupPayload &payload) {
  return {payload.game_window, payload.client_screen_x,
          payload.client_screen_y, payload.client_width,
          payload.client_height};
}

fushi_voice_hook::SiglusLookupClientSnapshot SiglusLookupTargetClientSnapshot(
    const SiglusLookupClickTarget &target) {
  return {target.game_window, target.client_screen_x,
          target.client_screen_y, target.client_width,
          target.client_height};
}

bool SiglusLookupPayloadMatchesPublishedTarget(
    const SiglusLookupPayload &payload,
    SiglusLookupPressDiagnostic* diagnostic = nullptr) {
  using Reason = SiglusLookupPressReason;
  SiglusLookupClickTarget target;
  fushi_voice_hook::SiglusLookupEngineView engine_view;
  if (!ReadSiglusLookupClickTarget(&target, diagnostic)) return false;
  if (!ReadSiglusLookupEngineView(reinterpret_cast<HWND>(payload.game_window), &engine_view))
    return RejectSiglusLookupPress(diagnostic, Reason::kLiveViewRejected);
  if (!fushi_voice_hook::SameSiglusLookupEngineView(engine_view, payload.engine_view) ||
      !fushi_voice_hook::SameSiglusLookupEngineView(target.engine_view, payload.engine_view))
    return RejectSiglusLookupPress(diagnostic, Reason::kEngineViewChanged);
  if (!fushi_voice_hook::IsSiglusLookupTextIdentityCurrent(payload.text_identity, target.text_identity))
    return RejectSiglusLookupPress(diagnostic, Reason::kPendingTextIdentity);
  if (payload.snapshot_epoch == 0 || payload.snapshot_epoch != target.snapshot_epoch)
    return RejectSiglusLookupPress(diagnostic, Reason::kPendingEpoch);
  if (!fushi_voice_hook::MatchesSiglusLookupGenerationAndClient(
          payload.geometry_generation, SiglusLookupPayloadClientSnapshot(payload),
          target.geometry_generation, SiglusLookupTargetClientSnapshot(target)))
    return RejectSiglusLookupPress(diagnostic,
        payload.geometry_generation != target.geometry_generation
            ? Reason::kPendingGeneration : Reason::kPendingClient);
  return true;
}
