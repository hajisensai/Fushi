#ifndef RUNNER_FLOATING_LYRIC_WINDOW_H_
#define RUNNER_FLOATING_LYRIC_WINDOW_H_

#include <windows.h>

#include <d2d1.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <functional>
#include <string>

// A standalone always-on-top "QQ Music style" desktop lyric strip.
//
// This is a self-owned Win32 layered top-level window — NOT a Flutter view and
// NOT a child of the main Hibiki window. It mirrors the Android
// FloatingLyricService: the Dart side feeds it text / style / playback state
// over the floating_lyric MethodChannel, and it reports control taps (previous
// / play-pause / next / close) and word-lookup taps back through callbacks.
//
// Rendering uses Direct2D + DirectWrite so a tap can be hit-tested to an exact
// character index (same contract as Android's getCharIndexAt), which is sent
// back as a `lookupText` event for the in-app dictionary popup to resolve.
//
// Click-through contract (the core of TODO-038): the strip must NOT block the
// apps underneath it, yet its words must stay tappable for lookup. A plain
// always-on-top window swallows every click in its rectangle, so by default the
// strip carries WS_EX_TRANSPARENT and all mouse input falls straight through to
// whatever is below. A low-frequency WM_TIMER polls the global cursor: while it
// is over the strip we drop WS_EX_TRANSPARENT so clicks (word lookup + control
// buttons + drag) land on us; once the cursor leaves we restore it so the
// desktop is fully usable again. (A transparent window receives no
// WM_MOUSEMOVE, hence the poll rather than hover messages.)
//
// All methods must be called on the thread that owns the message loop (the
// runner's main thread); the channel handler in flutter_window.cpp guarantees
// this because MethodChannel callbacks run on the platform thread.
class FloatingLyricWindow {
 public:
  // Reports a tap on a character at |char_index| within the full |text|.
  using LookupCallback =
      std::function<void(const std::string& text, int char_index)>;
  // Reports a tap on one of the control buttons. |action| is one of
  // "previousCue", "playPause", "nextCue", "close" (the "lock" button is
  // handled internally and surfaced through LockCallback instead).
  using ControlCallback = std::function<void(const std::string& action)>;
  // Reports the new locked state after the user toggles the lock button, so the
  // Dart side can persist it and refresh any in-app mirror of the strip state.
  using LockCallback = std::function<void(bool locked)>;

  struct Style {
    double font_size = 20.0;
    uint32_t text_color = 0xFFFFFFFF;
    uint32_t bg_color = 0xCC000000;
    uint32_t button_text_color = 0xFFFFFFFF;
    uint32_t button_bg_color = 0x33000000;
    uint32_t highlight_color = 0x80FFD54F;
    uint32_t active_color = 0xFFFFD54F;
  };

  struct Labels {
    std::wstring previous = L"Previous";
    std::wstring play_pause = L"Play";
    std::wstring next = L"Next";
    std::wstring lock = L"Lock";
    std::wstring unlock = L"Unlock";
    std::wstring close = L"Close";
  };

  FloatingLyricWindow();
  ~FloatingLyricWindow();

  FloatingLyricWindow(const FloatingLyricWindow&) = delete;
  FloatingLyricWindow& operator=(const FloatingLyricWindow&) = delete;

  void SetLookupCallback(LookupCallback callback) {
    on_lookup_ = std::move(callback);
  }
  void SetControlCallback(ControlCallback callback) {
    on_control_ = std::move(callback);
  }
  void SetLockCallback(LockCallback callback) {
    on_lock_ = std::move(callback);
  }

  // Creates (if needed) and shows the strip. Returns false if the OS window
  // could not be created. |owner| is the main window, used only for initial
  // positioning relative to the active monitor.
  bool Show(HWND owner);
  void Hide();
  bool IsShowing() const;

  void UpdateText(const std::wstring& text);
  // Highlights [start, start + length) UTF-16 code units of the current text.
  void Highlight(int start, int length);
  void UpdateStyle(const Style& style);
  void UpdateLabels(const Labels& labels);
  void SetPlaybackState(bool playing);
  void SetClickLookupEnabled(bool enabled);
  // Position lock: when locked the strip can no longer be dragged, but word
  // lookup taps and the playback-control buttons keep working (mirrors the
  // Android FloatingLyricService position lock — drag-only restriction).
  void SetLocked(bool locked);
  bool IsLocked() const { return locked_; }

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  LRESULT HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) noexcept;

  void EnsureWindowClass();
  bool EnsureDeviceResources();
  void DiscardDeviceResources();
  bool EnsureTextResources();
  void Render();
  void RequestRender();

  // Click-through management. The strip is created mouse-transparent so the
  // desktop stays usable; ApplyInteractive() toggles WS_EX_TRANSPARENT and
  // PollCursorInteractivity() (driven by a WM_TIMER) flips it as the global
  // cursor enters / leaves the strip rectangle.
  void ApplyInteractive(bool interactive);
  void PollCursorInteractivity();
  bool CursorOverStrip() const;
  void StartCursorPoll();
  void StopCursorPoll();

  // Geometry of the lyric text area in client (DIP-equivalent physical px),
  // computed during the last Render. Used for tap hit-testing.
  struct TextLayoutRect {
    float left = 0;
    float top = 0;
    float width = 0;
    float height = 0;
  };

  // Returns the UTF-16 code-unit index nearest the client point, or -1 when
  // the point is outside the text area or no text is present.
  int CharIndexAt(float x, float y);

  // Returns the control action at the client point, or empty when none.
  std::string ControlActionAt(float x, float y);

  // True when the client point falls inside the bottom-right resize grip — used
  // by WM_NCHITTEST to hand the corner to the system resize loop.
  bool ResizeGripContains(float x, float y) const;
  // Recomputes the logical strip size from the current window size (after a
  // system resize) so the font + control layout track the new dimensions.
  void SyncStripSizeFromWindow();

  float ScaleForDpi(float value) const;

  HWND hwnd_ = nullptr;
  bool class_registered_ = false;
  bool visible_ = false;
  bool playing_ = false;
  bool click_lookup_enabled_ = true;
  bool hovered_ = false;
  // Position lock: drag disabled, everything else (lookup + controls) still
  // works. Toggled by the lock button or SetLocked() over the channel.
  bool locked_ = false;
  // True while the strip is currently accepting mouse input (WS_EX_TRANSPARENT
  // cleared). Starts false so a freshly shown strip lets clicks fall through.
  bool interactive_ = false;
  UINT dpi_ = 96;

  // Logical (96-DPI) strip size. Mutable so the bottom-right resize grip can
  // grow / shrink the bar; the font + control layout follow this size.
  float strip_width_dip_ = 720.0f;
  float strip_height_dip_ = 96.0f;

  // Timer id for the global-cursor poll that drives click-through toggling.
  static constexpr UINT_PTR kCursorPollTimerId = 1;
  static constexpr UINT kCursorPollIntervalMs = 120;

  std::wstring text_;
  int highlight_start_ = -1;
  int highlight_length_ = 0;
  Style style_;
  Labels labels_;

  TextLayoutRect text_rect_;

  // Press / drag / resize state for moving and sizing the strip.
  //
  // A left-press over the lyric text starts in the "pressed, not yet decided"
  // state: if the cursor moves past a small threshold it becomes a drag,
  // otherwise the button-up fires a word-lookup at the original press point.
  // This is what makes the bar draggable from anywhere on the text instead of
  // only the tiny blank margins (BUG-203), while preserving single-tap lookup.
  bool pressed_ = false;        // left button held, decision pending
  bool press_was_text_ = false; // press landed on the lyric text (lookup case)
  bool dragging_ = false;       // promoted to a move-the-strip drag
  POINT drag_anchor_ = {0, 0};  // cursor offset inside the window at press
  POINT press_origin_ = {0, 0}; // screen point where the press began
  POINT press_client_ = {0, 0}; // client point where the press began (lookup)

  // Direct2D / DirectWrite.
  Microsoft::WRL::ComPtr<ID2D1Factory> d2d_factory_;
  Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_factory_;
  Microsoft::WRL::ComPtr<ID2D1DCRenderTarget> render_target_;
  Microsoft::WRL::ComPtr<IDWriteTextFormat> text_format_;
  Microsoft::WRL::ComPtr<IDWriteTextLayout> text_layout_;

  LookupCallback on_lookup_;
  ControlCallback on_control_;
  LockCallback on_lock_;
};

#endif  // RUNNER_FLOATING_LYRIC_WINDOW_H_
