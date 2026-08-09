#ifndef RUNNER_HOOK_TOOLBAR_WINDOW_H_
#define RUNNER_HOOK_TOOLBAR_WINDOW_H_

#include <windows.h>

#include <d2d1.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <functional>
#include <string>

// BUG-951 — the galgame hook overlay's pass-through escape hatch.
//
// Why this window exists at all
// -----------------------------
// The overlay body must become *genuinely* click-through in pass-through mode:
// the user is reading captions on top of a galgame that lives in ANOTHER
// PROCESS, and clicks have to advance that game's dialogue. The only Win32
// mechanism that does this across processes is WS_EX_TRANSPARENT (returning
// HTTRANSPARENT from WM_NCHITTEST only walks same-thread windows, which is the
// original bug). WS_EX_TRANSPARENT is a WHOLE-WINDOW property — it cannot spare
// a toolbar band — so a single-window overlay has exactly two options: keep the
// user locked out of the toolbar, or flip the bit by cursor position on a timer.
// The timer variant was implemented, reviewed and reverted: a starved timer
// leaves the bit set while the user is already over the toolbar, so the click
// falls through into the game and advances dialogue / picks a branch.
//
// The structural fix is to stop asking one window to be two things. The body
// window becomes purely visual while pass-through is on, and this window — a
// separate, small, never-transparent top-level window — carries the toolbar.
// It is always clickable because it is never transparent; there is no state to
// flip, therefore no race to lose.
//
// Contract with FloatingLyricWindow
// ---------------------------------
//  * geometry is pushed in (HookToolbarLayout), never recomputed here, so the
//    two windows cannot drift apart about where the buttons are;
//  * slot -> action mapping lives in kSlotActions below and is shared with the
//    body window's ControlActionAt(), so button 3 means the same thing in both;
//  * dragging the toolbar background drags the OWNER window (the body), which
//    is the only way to move the overlay while the body takes no mouse input.
//
// All methods must be called on the thread owning the message loop.

namespace hook_toolbar {

// Draw / hit-test order of the galgame hook toolbar. Single source of truth:
// FloatingLyricWindow::ControlActionAt() indexes the same table, so the body
// window and the standalone toolbar can never disagree about what a slot does.
constexpr int kSlotCount = 9;
constexpr const char* kSlotActions[kSlotCount] = {
    "replayVoice",         // 0 replay the line's captured audio
    "recaptureVoice",      // 1 open a recapture window
    "toggleFollow",        // 2 follow / pause caption updates
    "togglePassThrough",   // 3 mouse pass-through  <- the escape hatch
    "toggleTransparency",  // 4 one-click background transparency
    "lock",                // 5 position lock
    "openWorkbench",       // 6 capture workbench
    // 7 always-on-top pin. Handled natively in DispatchControlAction (no Dart
    // round-trip), exactly like the clipboard window's 📌 — the overlay is born
    // topmost, and this is the only way to drop it behind another window
    // without closing it. Inserted ahead of the close slot so the rightmost
    // button is still 关闭 (muscle memory) and slots 0..6 keep their index.
    "topmost",
    "close",  // 8 close the overlay
};

// Button states that change a slot's glyph or its active tint.
struct States {
  bool replaying = false;
  bool recapturing = false;
  bool playing = false;
  bool pass_through = false;
  bool locked = false;
  // Mirrors FloatingLyricWindow::topmost_ so the pin renders lit while the
  // overlay really is HWND_TOPMOST. Default true = the overlay's own default.
  bool topmost = true;
};

// Colours, mirrored from the body window's Style so both toolbars look alike.
struct Style {
  uint32_t button_text_color = 0xFFFFFFFF;
  uint32_t button_bg_color = 0x33000000;
  uint32_t active_color = 0xFFFFD54F;
  uint32_t bg_color = 0xCC000000;
};

// Where to put the toolbar, in screen / client PHYSICAL px. Computed by the
// owner from its own layout constants (see
// FloatingLyricWindow::ComputePassThroughToolbarLayout) so the floating buttons
// land exactly where the in-body toolbar used to draw them.
struct Layout {
  RECT rect = {0, 0, 0, 0};  // toolbar window rect, screen px
  // Top-left of the OWNER (body) window, screen px. The toolbar rect is offset
  // from it (the row is centred in the body and sits kControlsTopDip down), so
  // an owner drag MUST anchor on this, not on |rect| — anchoring on the toolbar
  // rect teleports the body by that offset the moment the drag starts.
  POINT owner_origin = {0, 0};
  float button_px = 0.0f;  // button edge length
  float gap_px = 0.0f;     // gap between two buttons
  float margin_px = 0.0f;  // padding between the window edge and the row
};

// Glyph drawn for |slot| under |states| (never null).
const wchar_t* SlotGlyph(int slot, const States& states);
// Whether |slot| draws with the active (highlight) colour under |states|.
bool SlotActive(int slot, const States& states);

}  // namespace hook_toolbar

class HookToolbarWindow {
 public:
  // Reports a toolbar button press. The string is one of
  // hook_toolbar::kSlotActions and is dispatched through exactly the same
  // owner-side handler as a press on the in-body toolbar.
  using ActionCallback = std::function<void(const std::string& action)>;
  // Requested new top-left for the OWNER window (screen physical px) while the
  // user drags the toolbar background. The owner clamps it to the work area and
  // moves both windows; this window never moves itself.
  using DragCallback = std::function<void(int owner_x, int owner_y)>;
  // The drag finished — the owner persists the new bounds.
  using DragEndCallback = std::function<void()>;

  HookToolbarWindow();
  ~HookToolbarWindow();

  HookToolbarWindow(const HookToolbarWindow&) = delete;
  HookToolbarWindow& operator=(const HookToolbarWindow&) = delete;

  void SetActionCallback(ActionCallback callback) {
    on_action_ = std::move(callback);
  }
  void SetDragCallback(DragCallback callback) { on_drag_ = std::move(callback); }
  void SetDragEndCallback(DragEndCallback callback) {
    on_drag_end_ = std::move(callback);
  }

  // Creates (if needed), positions and shows the toolbar. Returns false when
  // the OS window could not be created — the caller MUST then refuse to make
  // the body click-through, otherwise the user is locked out with no way back.
  bool Show(const hook_toolbar::Layout& layout,
            const hook_toolbar::Style& style,
            const hook_toolbar::States& states);
  void Hide();
  bool IsShowing() const;

  // Idempotent re-sync of geometry / colours / states. No-op (not even a
  // repaint) when nothing changed, so the owner can call it from every render
  // without turning caption updates into toolbar redraws.
  void Sync(const hook_toolbar::Layout& layout,
            const hook_toolbar::Style& style,
            const hook_toolbar::States& states);

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  LRESULT HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) noexcept;

  void EnsureWindowClass();
  bool EnsureDeviceResources();
  void Render();
  // Slot under the client point, or -1.
  int SlotAt(float x, float y) const;

  HWND hwnd_ = nullptr;
  bool class_registered_ = false;
  bool visible_ = false;
  bool hovered_ = false;
  bool tracking_mouse_leave_ = false;

  // Owner-drag state. |dragging_| only becomes true once the press travelled
  // past the threshold, so a still press on the background is not a 1px drag.
  bool pressed_ = false;
  bool dragging_ = false;

  // BUG-1471: same one-transaction rule as FloatingLyricWindow -- WM_LBUTTONUP
  // is not the only terminator, the system revokes capture whenever the
  // foreground window changes underneath this WS_EX_NOACTIVATE window.
  void CancelPointerGesture();
  POINT press_origin_ = {0, 0};   // screen point where the press began
  POINT owner_drag_anchor_ = {0, 0};  // cursor offset inside the OWNER rect

  hook_toolbar::Layout layout_;
  hook_toolbar::Style style_;
  hook_toolbar::States states_;
  bool has_layout_ = false;

  Microsoft::WRL::ComPtr<ID2D1Factory> d2d_factory_;
  Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_factory_;
  Microsoft::WRL::ComPtr<ID2D1DCRenderTarget> render_target_;

  ActionCallback on_action_;
  DragCallback on_drag_;
  DragEndCallback on_drag_end_;
};

#endif  // RUNNER_HOOK_TOOLBAR_WINDOW_H_
