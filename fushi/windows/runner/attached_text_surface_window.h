#ifndef RUNNER_ATTACHED_TEXT_SURFACE_WINDOW_H_
#define RUNNER_ATTACHED_TEXT_SURFACE_WINDOW_H_

#include <windows.h>

#include <dwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "attached_capture_token.h"
#include "attached_hover_tracker.h"
#include "attached_overlayability.h"

// Transparent, no-activate Win32 surface attached to a foreign game client.
//
// The game keeps drawing its original text. Fushi lays only invisible
// DirectWrite cluster catch boxes over the user-calibrated body rectangle, so
// a bare left click can address the source UTF-16 text without OCR. Exact glyph
// hits participate in the unified v19 input shield; an explicitly accepted
// risk mode remains available when the shield cannot be proven ready. Pixels
// outside the cluster union are removed from the Win32 region and continue to
// hit the game normally.
//
// Every mutation is fenced by (session_epoch, surface_epoch). All methods run
// on the Flutter platform thread; the owned HWND and its timer therefore share
// that thread and require no cross-thread locking.
class AttachedTextSurfaceWindow {
public:
  struct Epoch {
    uint64_t session = 0;
    uint64_t surface = 0;
  };

  struct NormalizedRect {
    double left = 0.0;
    double top = 0.0;
    double width = 0.0;
    double height = 0.0;
  };

  struct ReferenceClient {
    int width_px = 0;
    int height_px = 0;
    int dpi = 96;
  };

  struct Layout {
    std::wstring font_family = L"Yu Gothic";
    double font_size_per_client_height = 0.045;
    double letter_spacing_per_client_height = 0.0;
    double line_height = 1.0;
    std::string text_align = "left";
    std::string vertical_align = "top";
    double padding_per_client_height = 0.0;
  };

  struct TargetInfo {
    uint32_t pid = 0;
    HWND hwnd = nullptr;
    std::string exe_path;
    std::string exe_sha256;
    ReferenceClient reference_client;
  };

  struct ShieldStatus {
    uint32_t request_seq = 0;
    uint32_t applied_seq = 0;
    uint32_t required_mask = 0;
    uint32_t ready_mask = 0;
    uint32_t observed_mask = 0;
    uint32_t fault_mask = 0;
    uint32_t status_flags = 0;
    uint32_t owner_kind = 0;
    uint64_t target_hwnd = 0;
    uint64_t transaction_id = 0;
    uint32_t active_buttons = 0;
    bool allow_risk = false;
    bool available = false;
  };

  struct GeometryProviderStatus {
    uint32_t provider_kind = 0;
    uint32_t provider_id = 0;
    uint32_t provider_status = 0;
    uint32_t lookup_diag = 0;
    uint64_t generation = 0;
    uint64_t text_generation = 0;
    bool available = false;
  };

  struct Snapshot {
    Epoch epoch;
    TargetInfo target;
    NormalizedRect body_rect;
    Layout layout;
    std::string state = "detached";
    std::string status = "detached";
    std::string reason;
    bool surface_visible = false;
    bool risk_accepted = false;
    int64_t text_generation = 0;
    uint32_t calibration_probe_mask = 0;
    int64_t probe_start_observed_index = -1;
    int64_t probe_middle_observed_index = -1;
    int64_t probe_end_observed_index = -1;
    GeometryProviderStatus provider;
    ShieldStatus shield;
  };

  struct LookupEvent {
    Epoch epoch;
    uint32_t target_pid = 0;
    HWND target_hwnd = nullptr;
    int64_t text_generation = 0;
    std::string source_text;
    uint32_t char_index = 0;
    uint32_t source_length = 0;
    RECT screen_rect_px{};
    int dpi = 96;
    // True when emitted by the Shift+hover timer instead of a completed
    // shielded click transaction. Hover never consumes any input.
    bool hover = false;
  };

  struct ShieldTransaction {
    Epoch epoch;
    uint64_t transaction_id = 0;
    HWND surface_hwnd = nullptr;
    HWND target_hwnd = nullptr;
    bool left_active = false;
    bool allow_risk = false;
  };

  struct CalibrationProbes {
    int64_t start_index = -1;
    int64_t middle_index = -1;
    int64_t end_index = -1;
    uint32_t provided_mask = 0;
    uint32_t confirmed_mask = 0;
  };

  enum class RequestResult {
    kApplied,
    kStale,
    kRejected,
  };

  using StateCallback = std::function<void(const Snapshot &snapshot)>;
  using CalibrationCommittedCallback =
      std::function<void(const Snapshot &snapshot)>;
  using CalibrationCancelledCallback =
      std::function<void(const Snapshot &snapshot)>;
  using LookupCallback = std::function<void(const LookupEvent &event)>;
  using ShieldStatusCallback = std::function<ShieldStatus()>;
  using ShieldProbeCallback = std::function<uint32_t(
      HWND target, uint64_t transaction_id, bool allow_risk)>;
  using GeometryProviderStatusCallback =
      std::function<GeometryProviderStatus()>;

  AttachedTextSurfaceWindow();
  ~AttachedTextSurfaceWindow();

  AttachedTextSurfaceWindow(const AttachedTextSurfaceWindow &) = delete;
  AttachedTextSurfaceWindow &
  operator=(const AttachedTextSurfaceWindow &) = delete;

  void SetStateCallback(StateCallback callback) {
    on_state_ = std::move(callback);
  }
  void SetCalibrationCommittedCallback(CalibrationCommittedCallback callback) {
    on_calibration_committed_ = std::move(callback);
  }
  void SetCalibrationCancelledCallback(CalibrationCancelledCallback callback) {
    on_calibration_cancelled_ = std::move(callback);
  }
  void SetLookupCallback(LookupCallback callback) {
    on_lookup_ = std::move(callback);
  }
  void SetShieldStatusCallback(ShieldStatusCallback callback) {
    read_shield_status_ = std::move(callback);
  }
  void SetShieldProbeCallback(ShieldProbeCallback callback) {
    publish_shield_probe_ = std::move(callback);
  }
  void
  SetGeometryProviderStatusCallback(GeometryProviderStatusCallback callback) {
    read_geometry_provider_status_ = std::move(callback);
  }
  void OnGeometryProviderStatusChanged();

  // Resolves and fingerprints the target. |requested_hwnd| may be null; in that
  // case the largest visible top-level window for |target_pid| is selected.
  RequestResult InspectTarget(const Epoch &epoch, uint32_t target_pid,
                              HWND requested_hwnd,
                              const std::wstring &launch_exe_path,
                              std::string *error);

  RequestResult StartCalibration(const Epoch &epoch, uint32_t target_pid,
                                 HWND target_hwnd,
                                 const NormalizedRect *initial_rect,
                                 const ReferenceClient &reference_client,
                                 const Layout &layout, bool risk_accepted,
                                 const std::string &input_mode,
                                 std::string *error);
  RequestResult UpdateCalibration(const Epoch &epoch, uint32_t target_pid,
                                  HWND target_hwnd,
                                  const NormalizedRect &body_rect,
                                  const CalibrationProbes &probes,
                                  std::string *error);
  RequestResult CommitCalibration(const Epoch &epoch, uint32_t target_pid,
                                  HWND target_hwnd,
                                  const CalibrationProbes &probes,
                                  std::string *error);
  RequestResult CancelCalibration(const Epoch &epoch, uint32_t target_pid,
                                  HWND target_hwnd, const std::string &reason,
                                  std::string *error);

  RequestResult Configure(const Epoch &epoch, uint32_t target_pid,
                          HWND target_hwnd, const NormalizedRect &body_rect,
                          const ReferenceClient &reference_client,
                          const Layout &layout, bool risk_accepted,
                          const std::string &input_mode,
                          const std::string &surface_mode, std::string *error);
  RequestResult UpdateText(const Epoch &epoch, uint32_t target_pid,
                           HWND target_hwnd, const std::wstring &source_text,
                           int64_t text_generation,
                           const std::string &writing_mode, std::string *error);
  RequestResult UpdateStyle(const Epoch &epoch, uint32_t target_pid,
                            HWND target_hwnd, const Layout &layout,
                            std::string *error);
  RequestResult Detach(const Epoch &epoch, uint32_t target_pid,
                       HWND target_hwnd, std::string *error);

  // Screenshot/card capture barrier. Acquisition is bound to the exact
  // logical surface, text generation and token. Release authority is the
  // exact epoch/token alone: a newer sentence can be staged while hidden and
  // release then synchronizes that internally current generation. Both
  // transitions include a compositor flush before success.
  RequestResult SuspendForCapture(const Epoch &epoch, uint32_t target_pid,
                                  HWND target_hwnd, int64_t text_generation,
                                  uint64_t capture_generation,
                                  std::string *error);
  RequestResult RestoreAfterCapture(const Epoch &epoch, uint32_t target_pid,
                                    HWND target_hwnd, int64_t text_generation,
                                    uint64_t capture_generation,
                                    std::string *error);

  // Re-resolves the source/presentation HWND pair and proves that a host-side
  // layered/composition popup can currently cover it.  False intentionally
  // selects the shared-bitmap route; only an injected provider with an
  // in-process render-tree presenter may remain active in exclusive mode.
  bool DesktopOverlayAvailableForTarget(uint32_t target_pid);

  Snapshot GetSnapshot() const;

private:
  struct ClusterBox {
    uint32_t text_position = 0;
    uint32_t text_length = 0;
    RECT client_rect{};
  };

  enum class Mode {
    kDetached,
    kTargetReady,
    kCalibration,
    kConfigured,
  };

  enum class ShieldHandshakeState {
    kReady,
    kPending,
    kUnavailable,
  };

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  static void CALLBACK WinEventProc(HWINEVENTHOOK hook, DWORD event,
                                    HWND event_hwnd, LONG object_id,
                                    LONG child_id, DWORD event_thread,
                                    DWORD event_time) noexcept;
  LRESULT HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) noexcept;

  RequestResult AcceptRequest(const Epoch &epoch, uint32_t target_pid,
                              HWND target_hwnd, bool resolve_if_needed,
                              std::string *error);
  void AdoptNewEpoch(const Epoch &epoch, bool session_changed);
  bool ResolveTarget(uint32_t target_pid, HWND requested_hwnd,
                     TargetInfo *target, std::string *error) const;
  bool RefreshTargetClient(RECT *client_screen, ReferenceClient *reference,
                           std::string *error);
  bool TargetIsForeground() const;
  bool TryRebindTarget(std::string *error);
  void RefreshPresentationWindow();
  void InstallWinEventHooks();
  void RemoveWinEventHooks();
  bool ApplyCalibrationProbes(const CalibrationProbes &probes,
                              std::string *error);
  bool CalibrationProbesComplete(std::string *error) const;
  void ResetObservedCalibrationProbes();
  bool RecordObservedCalibrationProbe(POINT client_point, std::string *error);

  bool EnsureWindow(std::string *error);
  void DestroySurfaceWindow();
  void SyncToTarget();
  void HideSurface();
  bool SetVisible(bool visible);
  void SetRuntimeClickThrough(bool enabled);
  void PositionSurface(const RECT &screen_rect, bool calibration);

  bool RebuildClusters();
  // BUG-2095：记下 RebuildClusters 具体败在哪一点，随 noGlyphClusters 一起上报。
  bool ClusterFailure(const char *reason);
  std::string last_cluster_failure_;
  void ClearInteractiveRegion();
  void ApplyInteractiveRegion();
  bool PublishInteractiveSnapshot(std::string *publication_error = nullptr);
  void RenderLayerBitmap(bool calibration);
  int ClusterAt(POINT client_point) const;

  void BeginPointerGesture(POINT client_point,
                           uint64_t external_transaction_id);
  void UpdatePointerGesture(POINT client_point);
  void EndPointerGesture(POINT client_point,
                         uint64_t external_transaction_id = 0);
  void CancelPointerGesture();
  // Builds the LookupEvent for |cluster_index| (index into clusters_) and
  // invokes on_lookup_. Shared by the click transaction and the Shift+hover
  // timer.
  void EmitLookupEvent(int cluster_index, bool hover);
  // Shift+hover lookup (kHoverTimerId tick). Reads physical Shift state via
  // GetAsyncKeyState (the surface is WS_EX_NOACTIVATE and never owns keyboard
  // focus), maps the cursor into the calibrated body and fires once per
  // distinct cluster through AttachedHoverTracker. Never touches the shield.
  void TickHoverLookup();
  bool HoverLookupGeometryAvailable() const;
  bool AdoptShieldTransaction(uint64_t external_transaction_id);
  void ReleaseShieldTransaction();
  void RefreshShieldStatus();
  ShieldHandshakeState EnsureShieldHandshake();
  void ResetShieldHandshake();
  bool ShieldStatusBelongsToCurrentHandshake() const;
  ShieldStatus ShieldStatusForSnapshot() const;
  bool EffectiveAllowRisk() const;
  void RefreshGeometryProviderStatus();
  fushi::attached_overlayability::Evaluation CurrentOverlayability() const;
  bool NativeProviderCanPresentWithoutDesktopOverlay() const;
  bool NativeProviderPreferred() const;
  bool AttachedProviderOwned() const;
  bool ShieldNeutralForProviderSwitch() const;
  bool ShieldFaulted() const;
  bool ShieldVerified() const;
  bool ShieldPermitsLookup() const;

  void SetState(std::string state, std::string status,
                std::string reason = std::string());
  void EmitStateIfChanged(bool force = false);
  void NotifyCalibrationCommitted();
  void NotifyCalibrationCancelled(const std::string &reason);

  static bool IsEpochValid(const Epoch &epoch);
  static int CompareEpoch(const Epoch &left, const Epoch &right);
  static bool IsNormalizedRectValid(const NormalizedRect &rect);
  static NormalizedRect ClampNormalizedRect(const NormalizedRect &rect);

  HWND hwnd_ = nullptr;
  TargetInfo target_;
  // Non-empty only for a launch session.  Attach sessions deliberately leave
  // this empty and derive their persisted identity from target_.pid.
  std::wstring launch_exe_path_;
  HWND presentation_hwnd_ = nullptr;
  Epoch epoch_;
  Mode mode_ = Mode::kDetached;

  NormalizedRect body_rect_;
  NormalizedRect calibration_rect_;
  NormalizedRect pre_calibration_rect_;
  bool pre_calibration_configured_ = false;
  ReferenceClient configured_reference_client_;
  ReferenceClient live_reference_client_;
  Layout layout_;
  bool risk_accepted_ = false;
  std::string input_mode_;
  std::string surface_mode_ = "attachedOnly";

  std::wstring source_text_;
  std::string source_text_utf8_;
  int64_t text_generation_ = 0;
  std::string writing_mode_ = "horizontal";

  Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_factory_;
  Microsoft::WRL::ComPtr<IDWriteTextLayout> text_layout_;
  std::vector<ClusterBox> clusters_;

  RECT surface_screen_rect_{};
  bool surface_visible_ = false;
  bool mouse_hook_ready_ = false;
  bool layout_dirty_ = true;
  uint32_t hit_snapshot_token_ = 0;
  HWND published_snapshot_game_ = nullptr;
  bool published_snapshot_allow_risk_ = false;
  std::vector<RECT> published_screen_rects_;

  bool pointer_down_ = false;
  bool pointer_dragged_ = false;
  int pressed_cluster_ = -1;
  POINT pointer_down_point_{};
  Epoch pointer_epoch_;
  int64_t pointer_text_generation_ = 0;
  ShieldTransaction shield_transaction_;
  bool shield_transaction_active_ = false;
  fushi::AttachedHoverTracker hover_tracker_;
  ShieldStatus shield_status_;
  Epoch shield_handshake_epoch_;
  HWND shield_handshake_target_ = nullptr;
  uint64_t shield_handshake_transaction_id_ = 0;
  uint32_t shield_handshake_request_seq_ = 0;
  bool shield_handshake_established_ = false;
  GeometryProviderStatus provider_status_;
  bool native_provider_retire_pending_ = false;

  bool calibration_dragging_ = false;
  bool calibration_drag_moved_ = false;
  POINT calibration_drag_start_{};
  int64_t probe_start_index_ = -1;
  int64_t probe_middle_index_ = -1;
  int64_t probe_end_index_ = -1;
  uint32_t calibration_probe_mask_ = 0;
  int64_t probe_start_observed_index_ = -1;
  int64_t probe_middle_observed_index_ = -1;
  int64_t probe_end_observed_index_ = -1;
  std::wstring calibration_probe_source_;
  int64_t calibration_probe_text_generation_ = 0;

  HWINEVENTHOOK foreground_event_hook_ = nullptr;
  HWINEVENTHOOK location_event_hook_ = nullptr;
  HWINEVENTHOOK minimize_event_hook_ = nullptr;

  fushi::attached_capture_token::State capture_token_;

  std::string state_ = "detached";
  std::string status_ = "detached";
  std::string reason_;
  std::string last_emitted_signature_;

  StateCallback on_state_;
  CalibrationCommittedCallback on_calibration_committed_;
  CalibrationCancelledCallback on_calibration_cancelled_;
  LookupCallback on_lookup_;
  ShieldStatusCallback read_shield_status_;
  ShieldProbeCallback publish_shield_probe_;
  GeometryProviderStatusCallback read_geometry_provider_status_;

  static AttachedTextSurfaceWindow *active_instance_;
};

#endif // RUNNER_ATTACHED_TEXT_SURFACE_WINDOW_H_
