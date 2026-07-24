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
// Click-through contract (the core of TODO-038): the strip must NOT block apps
// when the mouse is outside its bounds, yet its words must be tappable on the
// very first click after the cursor enters the bar. The window is therefore
// mouse-interactive from creation and uses WS_EX_NOACTIVATE to avoid stealing
// keyboard focus; outside the strip rectangle Windows naturally hit-tests the
// app underneath.
//
// All methods must be called on the thread that owns the message loop (the
// runner's main thread); the channel handler in flutter_window.cpp guarantees
// this because MethodChannel callbacks run on the platform thread.
class FloatingLyricWindow {
 public:
  // Reports a tap on a character at |char_index| within the full |text|.
  using LookupCallback =
      std::function<void(const std::string& text, int char_index)>;
  using ContextLookupCallback = std::function<void(
      const std::string& context_id, const std::string& text, int char_index)>;
  // Reports a tap on one of the control buttons. |action| is one of
  // "previousCue", "playPause", "nextCue", "close" (the "lock" button is
  // handled internally and surfaced through LockCallback instead).
  using ControlCallback = std::function<void(const std::string& action)>;
  // Reports the new locked state after the user toggles the lock button, so the
  // Dart side can persist it and refresh any in-app mirror of the strip state.
  using LockCallback = std::function<void(bool locked)>;
  using BoundsCallback =
      std::function<void(int left, int top, int width, int height)>;

  struct Style {
    double font_size = 20.0;
    uint32_t text_color = 0xFFFFFFFF;
    uint32_t bg_color = 0xCC000000;
    uint32_t button_text_color = 0xFFFFFFFF;
    uint32_t button_bg_color = 0x33000000;
    uint32_t highlight_color = 0x80FFD54F;
    uint32_t active_color = 0xFFFFD54F;
    // TODO-708 P2: 圆角半径 / 窗宽（逻辑 dp）。0 = 平台原生默认（14dp 圆角 / 720dip 起始
    // 宽 + 可拖拽），>0 时按该 dp 覆盖，保证默认零观感变化。
    double corner_radius = 0.0;
    double window_width = 0.0;
    double window_height = 0.0;
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
  void SetContextLookupCallback(ContextLookupCallback callback) {
    on_context_lookup_ = std::move(callback);
  }
  void SetControlCallback(ControlCallback callback) {
    on_control_ = std::move(callback);
  }
  void SetLockCallback(LockCallback callback) {
    on_lock_ = std::move(callback);
  }
  void SetBoundsCallback(BoundsCallback callback) {
    on_bounds_ = std::move(callback);
  }

  // Creates (if needed) and shows the strip. Returns false if the OS window
  // could not be created. |owner| is the main window, used only for initial
  // positioning relative to the active monitor.
  bool Show(HWND owner);
  void Hide();
  bool IsShowing() const;

  // TODO-708 P4: 多行上下文文本 + 块内当前行区间。current_line_start<0 = 无行
  // 标记（N=0 单行/旧 payload），整块满色 = 今天观感（never-break userspace）。
  void UpdateText(const std::wstring& text, int current_line_start = -1,
                  int current_line_length = 0,
                  const std::string& context_id = std::string());
  // Highlights [start, start + length) UTF-16 code units of the current text.
  void Highlight(int start, int length);
  void UpdateStyle(const Style& style);
  void UpdateLabels(const Labels& labels);
  void SetPlaybackState(bool playing);
  // Hook-text voice controls: whether the line's captured audio is currently
  // being replayed, and whether a recapture window is open. Drives the two
  // leading toolbar glyphs' active highlight — the overlay is a separate
  // window, so this is the only place the user can see either state.
  void SetVoiceState(bool replaying, bool recapturing);
  void SetClickLookupEnabled(bool enabled);
  // Text-only mode (the transparent clipboard text window): the strip draws
  // ONLY the draggable, tappable text — no playback / lock / close control
  // buttons and no resize grip. Drag + single-tap word lookup still work exactly
  // as in the audiobook lyric strip. Set once right after construction (before
  // Show) by the clipboard_text channel; the audiobook lyric instance leaves it
  // false so its rendering + hit-testing stay byte-for-byte unchanged.
  void SetTextOnly(bool text_only) { text_only_ = text_only; }
  // Rich text-only mode used by the galgame Hook window. It keeps the text-only
  // rendering surface but enables wrapping, resizing, the six-button core
  // toolbar, line-context lookup and body pass-through.
  void SetHookTextMode(bool enabled) {
    hook_text_mode_ = enabled;
    if (enabled) text_only_ = true;
  }
  // Window title = the taskbar / Alt+Tab label. The text-only clipboard window
  // shows in the taskbar (WS_EX_APPWINDOW) so the fully transparent overlay is
  // always a selectable window the user can find / raise; this sets its label
  // (localised, pushed from Dart). No-op visual for the lyric strip, which keeps
  // WS_EX_TOOLWINDOW and never appears in the taskbar. Call before Show to seed
  // the CreateWindowExW title; later calls retitle the live window.
  void SetWindowTitle(const std::wstring& title);
  // Position lock: when locked the strip can no longer be dragged, but word
  // lookup taps and the playback-control buttons keep working (mirrors the
  // Android FloatingLyricService position lock — drag-only restriction).
  void SetLocked(bool locked);
  bool IsLocked() const { return locked_; }
  void SetPassThrough(bool enabled);
  bool IsPassThrough() const { return pass_through_; }
  // Restores a physical-pixel window rectangle before the next Show. Invalid
  // rectangles are ignored and Show uses its DPI-aware default.
  void SetInitialBounds(int left, int top, int width, int height);

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
  void NotifyBoundsChanged();

  // TODO-708 P2: applies style_.window_width (logical dp, >0) to the live window
  // by resizing it (clamped to the drag min/max), keeping the top-left origin
  // and re-clamping to the monitor. No-op when the width is 0 (platform default)
  // or the window does not exist yet.
  void ApplyStyleWidth();

  float ScaleForDpi(float value) const;

  // Minimum visible margin (in 96-DPI logical px) that must always stay inside
  // the target monitor's work area, so the strip can never be dragged or
  // restored entirely off-screen (TODO-832). Run through ScaleForDpi before use
  // — drag math is in screen physical px. Mirrors Android MIN_VISIBLE_DP=48.
  static constexpr float kMinVisibleMarginDip = 48.0f;

  // Clamps a proposed top-left window origin (screen physical px) so at least
  // ScaleForDpi(kMinVisibleMarginDip) of the window stays inside |work| on
  // every edge. |work| is the target monitor's rcWork (chosen by the caller:
  // MonitorFromPoint(cursor) on drag, MonitorFromWindow(hwnd_) on display/DPI
  // change). Returns the clamped origin as {x, y}. Single source of truth for
  // the same formula as Dart clampFloatingWindowOrigin.
  POINT ClampOriginToWorkArea(int x, int y, int width, int height,
                              const RECT& work) const;

  // Pulls the current window back inside the work area of the monitor it sits
  // on (MonitorFromWindow), used by WM_DISPLAYCHANGE / WM_DPICHANGED where the
  // cursor is not necessarily over the strip. No-op when already inside.
  void ClampCurrentPositionToWindowMonitor();

  // Narrowest width the strip may be resized / restored to. Hook mode floors at
  // its own 8-slot toolbar width so the voice buttons can never be clipped.
  float MinStripWidthDip() const;

  HWND hwnd_ = nullptr;
  bool class_registered_ = false;
  bool visible_ = false;
  bool playing_ = false;
  // Hook-text voice control state (see SetVoiceState).
  bool replaying_ = false;
  bool recapturing_ = false;
  bool click_lookup_enabled_ = true;
  // Text-only clipboard window: suppress control buttons + resize grip, use the
  // full window height for text. Never true for the audiobook lyric strip.
  bool text_only_ = false;
  bool hook_text_mode_ = false;
  bool pass_through_ = false;
  bool hovered_ = false;
  bool tracking_mouse_leave_ = false;
  // Position lock: drag disabled, everything else (lookup + controls) still
  // works. Toggled by the lock button or SetLocked() over the channel.
  bool locked_ = false;
  // Always-on-top state. The window is created WS_EX_TOPMOST, so it starts true;
  // the text-only Luna toolbar's pin button toggles it (mirrors LunaTranslator's
  // window-always-on-top button). Every window-Z SetWindowPos derives its
  // insert-after handle from this so drag / resize / re-show never silently
  // re-assert topmost after the user pinned it off. The audiobook lyric strip
  // never toggles it, so its behaviour is unchanged.
  bool topmost_ = true;
  UINT dpi_ = 96;

  // Logical (96-DPI) strip size. Mutable so the bottom-right resize grip can
  // grow / shrink the bar; the font + control layout follow this size.
  float strip_width_dip_ = 720.0f;
  float strip_height_dip_ = 96.0f;

  bool has_initial_bounds_ = false;
  RECT initial_bounds_ = {0, 0, 0, 0};

  std::wstring text_;
  std::string context_id_;
  // Taskbar / Alt+Tab label; seeds CreateWindowExW and retitles the live window.
  std::wstring window_title_ = L"Hibiki Lyric";
  int highlight_start_ = -1;
  int highlight_length_ = 0;
  // TODO-708 P4: 块内当前行区间（UTF-16）。-1/0 = 无行标记（不 dim）。
  int current_line_start_ = -1;
  int current_line_length_ = 0;
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
  ContextLookupCallback on_context_lookup_;
  ControlCallback on_control_;
  LockCallback on_lock_;
  BoundsCallback on_bounds_;
};

#endif  // RUNNER_FLOATING_LYRIC_WINDOW_H_
