#undef NDEBUG

#include <cassert>
#include <fstream>
#include <iterator>
#include <iostream>
#include <string>

#ifndef FUSHI_RUNNER_SOURCE_DIR
#error FUSHI_RUNNER_SOURCE_DIR must identify the Windows runner source tree
#endif

namespace {

std::string FunctionSlice(const std::string &source, const char *start,
                          const char *next) {
  const size_t begin = source.find(start);
  assert(begin != std::string::npos);
  const size_t end = source.find(next, begin + 1);
  assert(end != std::string::npos);
  return source.substr(begin, end - begin);
}

} // namespace

int main() {
  std::ifstream input(std::string(FUSHI_RUNNER_SOURCE_DIR) +
                      "/low_level_mouse_hook.cpp");
  assert(input.good());
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());

  const std::string begin =
      FunctionSlice(source, "bool BeginAttachedGlyphTransaction(",
                    "bool AdvanceAttachedGlyphReleaseIfAcknowledged();");
  assert(begin.find("TryAcquireSRWLockExclusive(") != std::string::npos);
  assert(begin.find("\n  AcquireSRWLockExclusive(") == std::string::npos);
  assert(begin.find("RequestAttachedGlyphPhysicalReconciliation()") !=
         std::string::npos);

  const size_t revoked_begin =
      begin.find("if (request_seq == 0 || after_publish.get() != snapshot.get())");
  const size_t admitted_begin = begin.find(
      "if (!g_attached_active_transaction.latch.Begin", revoked_begin);
  assert(revoked_begin != std::string::npos &&
         admitted_begin != std::string::npos);
  const std::string revoked_after_publish =
      begin.substr(revoked_begin, admitted_begin - revoked_begin);
  assert(revoked_after_publish.find("latch.Cancel()") != std::string::npos);
  assert(revoked_after_publish.find("MarkPhysicalUp()") == std::string::npos);

  const size_t post_failure_begin = begin.find("if (!PostMessageW(");
  assert(post_failure_begin != std::string::npos);
  const std::string post_failure = begin.substr(post_failure_begin);
  assert(post_failure.find("latch.Cancel()") != std::string::npos);
  assert(post_failure.find("g_attached_pending_cancel_transaction_id.store") !=
         std::string::npos);
  assert(post_failure.find("MarkPhysicalUp()") == std::string::npos);
  assert(post_failure.find("g_attached_pending_up_transaction_id.store") ==
         std::string::npos);

  const std::string callback_up =
      FunctionSlice(source, "bool TryObserveAttachedGlyphPhysicalUp(",
                    "bool EndAttachedGlyphTransaction(");
  assert(callback_up.find("TryAcquireSRWLockExclusive(") != std::string::npos);
  assert(callback_up.find("\n  AcquireSRWLockExclusive(") == std::string::npos);
  assert(callback_up.find("latch.cancelled()") != std::string::npos);

  const std::string wake =
      FunctionSlice(source, "void RequestAttachedGlyphReleasePoll() {",
                    "bool ObserveAttachedGlyphPhysicalUp(");
  assert(wake.find("lock_guard") == std::string::npos);
  assert(wake.find("std::call_once(") == std::string::npos);

  const std::string hook = FunctionSlice(source, "LRESULT CALLBACK HookProc(",
                                         "void HookThreadMain()");
  assert(hook.find("HasActiveAttachedGlyphTransactionFast()") !=
         std::string::npos);
  assert(hook.find("RequestAttachedGlyphRearmIfNeutral()") !=
         std::string::npos);
  assert(hook.find("TryObserveAttachedGlyphPhysicalUp(info->pt, false)") ==
         std::string::npos);
  const size_t attached_branch =
      hook.find("const auto attached_snapshot = AttachedGlyphSnapshotForTarget(target);");
  const size_t attached_branch_end =
      hook.find("if (!IsWindow(target))", attached_branch);
  assert(attached_branch != std::string::npos &&
         attached_branch_end != std::string::npos);
  const std::string attached_fast_path =
      hook.substr(attached_branch, attached_branch_end - attached_branch);
  // The only synchronous HWND read permitted for a Magpie attached snapshot
  // is the already-bound presentation ex-style bit used to validate the
  // published coordinate space. No property lookup, enumeration or point
  // ownership query may re-enter the hook path.
  assert(attached_fast_path.find("GetPropW(") == std::string::npos);
  assert(attached_fast_path.find("EnumWindows(") == std::string::npos);
  assert(attached_fast_path.find("WindowFromPoint(") == std::string::npos);
  assert(attached_fast_path.find("ResolveAttachedGlyphPointHit(") !=
         std::string::npos);
  const std::string cursor_style = FunctionSlice(
      source, "bool PresentationWindowHasTransparentStyle(",
      "bool AttachedGlyphCursorCaptureStillActive(");
  assert(cursor_style.find("GetWindowLongPtrW(") != std::string::npos);
  assert(cursor_style.find("GetPropW(") == std::string::npos);
  assert(cursor_style.find("EnumWindows(") == std::string::npos);
  assert(cursor_style.find("WindowFromPoint(") == std::string::npos);

  const std::string release = FunctionSlice(
      source, "bool AdvanceAttachedGlyphReleaseIfAcknowledged() {",
      "LRESULT CALLBACK HookProc(");
  assert(release.find("if (!status.ok())") != std::string::npos);
  assert(release.find("FailOpenRetireAttachedGlyphTransaction") !=
         std::string::npos);
  assert(release.find("PublishLookupShieldTransaction") != std::string::npos);
  assert(release.find("status.fault_mask != 0") != std::string::npos);
  assert(release.find("kLookupShieldStatusFaulted") != std::string::npos);
  assert(release.find("kAttachedShieldAcknowledgeTimeoutMs") !=
         std::string::npos);
  assert(release.find("AttachedGlyphAcknowledgeTimedOut") !=
         std::string::npos);
  const std::string fail_open = FunctionSlice(
      source, "bool FailOpenRetireAttachedGlyphTransaction(",
      "// Device replacement or a removed hook");
  assert(fail_open.find("kLowLevelMouseAttachedGlyphAbortMessage") !=
         std::string::npos);
  const size_t revoke_snapshot =
      fail_open.find("std::atomic_compare_exchange_weak_explicit(");
  const size_t publish_inactive = fail_open.find(
      "g_attached_active_transaction_id.store(0");
  const size_t disarm_target =
      fail_open.find("g_target.compare_exchange_strong(");
  assert(revoke_snapshot != std::string::npos &&
         disarm_target != std::string::npos &&
         publish_inactive != std::string::npos &&
         revoke_snapshot < disarm_target &&
         disarm_target < publish_inactive);

  std::ifstream reader_input(std::string(FUSHI_RUNNER_SOURCE_DIR) +
                             "/voice_hook_reader.cpp");
  assert(reader_input.good());
  const std::string reader((std::istreambuf_iterator<char>(reader_input)),
                           std::istreambuf_iterator<char>());
  const std::string publish = FunctionSlice(
      reader, "uint32_t TryPublishLookupShieldRequestOnce(",
      "void ResetLookupCursorsLocked(");
  const size_t claim = publish.find("InterlockedCompareExchange(");
  const size_t ownership =
      publish.find("!AttachedGeometryProviderOwns(header)");
  const size_t payload =
      publish.find("lookup_shield_owner_kind", ownership);
  assert(claim != std::string::npos && ownership != std::string::npos &&
         payload != std::string::npos && claim < ownership &&
         ownership < payload);
  assert(publish.find("&header->lookup_shield_request_seq, current") !=
         std::string::npos);
  assert(publish.find("lock_guard") == std::string::npos);
  assert(publish.find("unique_lock") == std::string::npos);
  assert(publish.find("WaitFor") == std::string::npos);
  assert(publish.find("Sleep(") == std::string::npos);

  const std::string callback_publish = FunctionSlice(
      reader, "uint32_t VoiceHookReader::TryPublishLookupShieldTransaction(",
      "uint32_t VoiceHookReader::PublishLookupShieldTransaction(");
  assert(callback_publish.find("std::try_to_lock") != std::string::npos);
  assert(callback_publish.find("std::lock_guard") == std::string::npos);
  assert(callback_publish.find("IsWindow(") == std::string::npos);
  assert(callback_publish.find("GetWindowThreadProcessId(") ==
         std::string::npos);

  // BUG-2531: a visible calibration HWND alone cannot shield a game's input
  // polling. Probes must use the same admitted glyph down/up transaction.
  std::ifstream surface_input(std::string(FUSHI_RUNNER_SOURCE_DIR) +
                              "/attached_text_surface_window.cpp");
  assert(surface_input.good());
  const std::string surface((std::istreambuf_iterator<char>(surface_input)),
                            std::istreambuf_iterator<char>());
  const std::string sync = FunctionSlice(
      surface, "void AttachedTextSurfaceWindow::SyncToTarget()",
      "void AttachedTextSurfaceWindow::HideSurface()");
  const size_t handshake = sync.find("EnsureShieldHandshake()");
  const size_t permits = sync.find("!ShieldPermitsLookup()",
                                   sync.find("const bool calibration ="));
  const size_t snapshot_publish = sync.find("!PublishInteractiveSnapshot(");
  const size_t show = sync.find("!SetVisible(true)");
  const size_t ready = sync.find("SetState(calibration ? \"calibrating\"");
  assert(handshake != std::string::npos && permits != std::string::npos &&
         snapshot_publish != std::string::npos && show != std::string::npos &&
         ready != std::string::npos && handshake < permits &&
         permits < snapshot_publish && snapshot_publish < show && show < ready);
  assert(sync.find("if (mode_ != Mode::kCalibration)") == std::string::npos);
  assert(sync.find("SetRuntimeClickThrough(false)") == std::string::npos);
  const std::string visible = FunctionSlice(
      surface, "bool AttachedTextSurfaceWindow::SetVisible(",
      "void AttachedTextSurfaceWindow::SetRuntimeClickThrough(");
  assert(visible.find("mode_ == Mode::kConfigured || mode_ == Mode::kCalibration") !=
         std::string::npos);
  assert(visible.find("ArmLowLevelMouseHookForAttachedGlyph(") !=
         std::string::npos);
  const std::string surface_publish = FunctionSlice(
      surface, "bool AttachedTextSurfaceWindow::PublishInteractiveSnapshot(",
      "void AttachedTextSurfaceWindow::RenderLayerBitmap(");
  assert(surface_publish.find("mode_ != Mode::kConfigured && mode_ != Mode::kCalibration") !=
         std::string::npos);
  assert(surface_publish.find("for (const ClusterBox &cluster : clusters_)") !=
         std::string::npos);
  // Full-client calibration drawing must never become a full-client catch box.
  assert(surface_publish.find("screen_rects.push_back(surface_screen_rect_)") ==
         std::string::npos);

  // A calibration surface covers the full client, while the configured
  // surface is only the body rect.  Positioning the smaller HWND must retire
  // the old clusters before any bitmap render, and bitmap writes must remain
  // bounded if stale geometry ever reaches the defensive path.
  const std::string position = FunctionSlice(
      surface, "void AttachedTextSurfaceWindow::PositionSurface(",
      "// BUG-2138");
  const size_t clear_geometry = position.find("ClearInteractiveRegion();");
  const size_t mark_dirty = position.find("layout_dirty_ = true;");
  const size_t move_window = position.find("SetWindowPos(");
  assert(clear_geometry != std::string::npos && mark_dirty != std::string::npos &&
         move_window != std::string::npos && clear_geometry < move_window &&
         mark_dirty < move_window);
  assert(position.find("RenderLayerBitmap(") == std::string::npos);
  const std::string render = FunctionSlice(
      surface, "void AttachedTextSurfaceWindow::RenderLayerBitmap(bool",
      "int AttachedTextSurfaceWindow::ClusterAt(");
  const size_t surface_bounds = render.find("surface_bounds");
  const size_t clipped_rect =
      render.find(
          "fushi::attached_bitmap_bounds::FillRectClippedToSurface(");
  assert(surface_bounds == std::string::npos &&
         clipped_rect != std::string::npos);

  const std::string hover = FunctionSlice(
      surface, "void AttachedTextSurfaceWindow::TickHoverLookup()",
      "void AttachedTextSurfaceWindow::CancelPointerGesture()");
  assert(hover.find("const int visual_cluster = over_text ? cluster : -1;") !=
         std::string::npos);
  assert(hover.find("RenderLayerBitmap(mode_ == Mode::kCalibration);") !=
         std::string::npos);
  const size_t hover_paint = render.find(
      "Show the current text cluster under the global cursor");
  assert(hover_paint != std::string::npos);
  assert(hover_paint > render.find("if (calibration && IsNormalizedRectValid"));

  const std::string ordinary = FunctionSlice(
      surface, "case WM_LBUTTONDOWN:",
      "case fushi::kLowLevelMouseAttachedGlyphDownMessage:");
  assert(ordinary.find("RecordObservedCalibrationProbe(") == std::string::npos);
  assert(ordinary.find("BeginPointerGesture(") == std::string::npos);
  assert(ordinary.find("EndPointerGesture(") == std::string::npos);
  assert(surface.find("calibration_dragging_") == std::string::npos);
  const std::string down_message = FunctionSlice(
      surface, "case fushi::kLowLevelMouseAttachedGlyphDownMessage:",
      "case fushi::kLowLevelMouseAttachedGlyphUpMessage:");
  assert(down_message.find("mode_ != Mode::kConfigured && mode_ != Mode::kCalibration") !=
         std::string::npos);
  assert(down_message.find("snapshot_token != hit_snapshot_token_") !=
         std::string::npos);
  assert(down_message.find("BeginPointerGesture(point, transaction_id)") !=
         std::string::npos);
  const std::string up = FunctionSlice(
      surface, "void AttachedTextSurfaceWindow::EndPointerGesture(",
      "void AttachedTextSurfaceWindow::EmitLookupEvent(");
  assert(up.find("external_transaction_id == 0 || !shield_transaction_active_") !=
         std::string::npos);
  assert(up.find("shield_transaction_.transaction_id != external_transaction_id") !=
         std::string::npos);
  assert(up.find("pressed_cluster == released_cluster") != std::string::npos);
  assert(up.find("pointer_text_generation_ == text_generation_") !=
         std::string::npos);
  const size_t probe = up.find("valid && RecordObservedCalibrationProbe(");
  const size_t probe_return = up.find("return;", probe);
  const size_t lookup = up.find("EmitLookupEvent(");
  assert(probe != std::string::npos && probe_return != std::string::npos &&
         lookup != std::string::npos && probe < probe_return &&
         probe_return < lookup);
  const std::string release_mirror = FunctionSlice(
      surface, "void AttachedTextSurfaceWindow::ReleaseShieldTransaction()",
      "void AttachedTextSurfaceWindow::RefreshShieldStatus()");
  assert(release_mirror.find("PublishLookupShield") == std::string::npos);
  assert(release_mirror.find("MarkPhysicalUp") == std::string::npos);
  for (const char *method : {"CommitCalibration(", "CancelCalibration("}) {
    const size_t method_start = surface.find(method);
    const size_t hide = surface.find("HideSurface();", method_start);
    const size_t mode_change = surface.find("mode_ = pre_calibration_configured_", method_start);
    assert(method_start != std::string::npos && hide != std::string::npos &&
           mode_change != std::string::npos && hide < mode_change);
  }
  // Misses still fall through the existing LL route without a shield request.
  const size_t hit = hook.find("if (ResolveAttachedGlyphPointHit(");
  const size_t begin_hit = hook.find("BeginAttachedGlyphTransaction(", hit);
  const size_t miss = hook.find("return CallNextHookEx(", begin_hit);
  assert(hit != std::string::npos && begin_hit != std::string::npos &&
         miss != std::string::npos && hit < begin_hit && begin_hit < miss);

  // Popup close has a direct notification path. It must be gated by the full
  // neutral transaction state and must not rely on the 500 ms follow timer.
  const std::string rearm = FunctionSlice(
      source, "void RequestAttachedGlyphRearmIfNeutral() {",
      "bool FailOpenRetireAttachedGlyphTransaction(");
  assert(rearm.find("g_attached_rearm_candidate.load") != std::string::npos);
  assert(rearm.find("g_target.load") != std::string::npos);
  assert(rearm.find("g_swallowed_buttons.load") != std::string::npos);
  assert(rearm.find("g_direct_input_shield_tail_token.load") !=
         std::string::npos);
  assert(rearm.find("HasActiveAttachedGlyphTransactionFast()") !=
         std::string::npos);
  assert(rearm.find("g_attached_rearm_pending") != std::string::npos);
  assert(rearm.find("compare_exchange_strong") != std::string::npos);
  assert(rearm.find("PostMessageW(state.candidate_surface,") !=
         std::string::npos);
  const std::string revoke = FunctionSlice(
      source, "void RevokeDirectInputShieldIfIdle(HWND expected_popup) {",
      "bool PointInWindowClient(");
  const size_t direct_tail_clear = revoke.rfind(
      "g_direct_input_shield_tail_token.store(0", revoke.size());
  const size_t tail_rearm = revoke.rfind("RequestAttachedGlyphRearmIfNeutral()",
                                        revoke.size());
  assert(direct_tail_clear != std::string::npos &&
         tail_rearm != std::string::npos && direct_tail_clear < tail_rearm);
  const std::string disarm = FunctionSlice(source,
                                            "void DisarmLowLevelMouseHook(",
                                            "}  // namespace fushi");
  assert(disarm.find("RequestAttachedGlyphRearmIfNeutral()") !=
         std::string::npos);
  assert(disarm.find("released_transient_popup") != std::string::npos);
  assert(hook.find("RequestAttachedGlyphRearmIfNeutral();\n      return 1;") !=
         std::string::npos);
  assert(hook.find("g_attached_rearm_suppressed_buttons") !=
         std::string::npos);
  assert(surface.find("case fushi::kLowLevelMouseAttachedGlyphRearmMessage:") !=
         std::string::npos);
  assert(surface.find(
             "RetireLowLevelAttachedGlyphRearmCandidate(old)") !=
         std::string::npos);
  assert(surface.find("RetireLowLevelAttachedGlyphRearmCandidate(hwnd_)") !=
         std::string::npos);
  std::cout << "attached mouse hook and calibration source guards passed\n";
  return 0;
}
