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
// All methods must be called on the thread that owns the message loop (the
// runner's main thread); the channel handler in flutter_window.cpp guarantees
// this because MethodChannel callbacks run on the platform thread.
class FloatingLyricWindow {
 public:
  // Reports a tap on a character at |char_index| within the full |text|.
  using LookupCallback =
      std::function<void(const std::string& text, int char_index)>;
  // Reports a tap on one of the control buttons. |action| is one of
  // "previousCue", "playPause", "nextCue", "close".
  using ControlCallback = std::function<void(const std::string& action)>;

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

  float ScaleForDpi(float value) const;

  HWND hwnd_ = nullptr;
  bool class_registered_ = false;
  bool visible_ = false;
  bool playing_ = false;
  bool click_lookup_enabled_ = true;
  bool hovered_ = false;
  UINT dpi_ = 96;

  std::wstring text_;
  int highlight_start_ = -1;
  int highlight_length_ = 0;
  Style style_;
  Labels labels_;

  TextLayoutRect text_rect_;

  // Drag state for moving the strip.
  bool dragging_ = false;
  POINT drag_anchor_ = {0, 0};

  // Direct2D / DirectWrite.
  Microsoft::WRL::ComPtr<ID2D1Factory> d2d_factory_;
  Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_factory_;
  Microsoft::WRL::ComPtr<ID2D1DCRenderTarget> render_target_;
  Microsoft::WRL::ComPtr<IDWriteTextFormat> text_format_;
  Microsoft::WRL::ComPtr<IDWriteTextLayout> text_layout_;

  LookupCallback on_lookup_;
  ControlCallback on_control_;
};

#endif  // RUNNER_FLOATING_LYRIC_WINDOW_H_
