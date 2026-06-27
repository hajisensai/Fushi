#ifndef RUNNER_GLOBAL_LOOKUP_WINDOW_H_
#define RUNNER_GLOBAL_LOOKUP_WINDOW_H_

// TODO-617 global lookup overlay (Windows MVP).
//
// A runner-owned bare Win32 top-level window that hosts a WebView2 control to
// render the existing dictionary popup (assets/popup/popup.html). It is the
// Windows counterpart of Android's native ":popup" process: no second Flutter
// engine — the main Dart engine performs the lookup, produces the self-contained
// popupJson, and pushes it here for rendering. The overlay never activates
// (WS_EX_NOACTIVATE) so the foreground app keeps keyboard focus; gaiji images
// (image://) and audio resolution route back to the main Dart engine.
//
// See docs/specs/2026-06-25-global-lookup-webview-overlay-design.md.

#include <windows.h>
#include <wrl.h>

// The WebView2 SDK headers trip /WX (warnings-as-errors) via C4458 ('value'
// hides class member) on the runner target. Suppress around the SDK includes
// only — the warning is in Microsoft's headers, not our code.
#pragma warning(push)
#pragma warning(disable : 4458)
#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>
#include <wil/com.h>
#pragma warning(pop)

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

class GlobalLookupWindow {
 public:
  // Resolves the bytes for a custom-scheme resource request (image://...).
  // Asynchronous on purpose: the bytes come from the main Dart engine over a
  // MethodChannel whose reply is delivered on the platform thread, so blocking
  // here would deadlock the message loop. The window hands the resolver a
  // |respond| continuation that completes the WebView2 deferral once Dart
  // replies (empty bytes -> 404).
  using MediaResolver = std::function<void(
      const std::string& url, std::function<void(std::vector<uint8_t>)> respond)>;
  // Receives raw JSON sent by popup JS via window.chrome.webview.postMessage.
  using MessageCallback = std::function<void(const std::string& json)>;

  GlobalLookupWindow();
  ~GlobalLookupWindow();

  GlobalLookupWindow(const GlobalLookupWindow&) = delete;
  GlobalLookupWindow& operator=(const GlobalLookupWindow&) = delete;

  // Absolute folder that holds popup.html / popup.js / popup.css and the
  // injected bridge adapter (flutter_assets/assets/popup at runtime). Must be
  // set (via the channel "prepare" call) before the first ShowAt.
  void SetPopupAssetsDir(const std::wstring& dir) { popup_assets_dir_ = dir; }

  // Shows the overlay at screen coordinates (physical pixels) without stealing
  // focus. Creates the window + WebView2 lazily on first call. Returns false if
  // window creation failed.
  bool ShowAt(int x, int y, int width, int height, HWND owner);
  // Resizes to fit the rendered card (physical px); clamps to the monitor work
  // area and nudges back on-screen if the bottom/right would overflow.
  void ResizeTo(int width, int height);
  // Moves the off-screen-rendered card to the pending cursor anchor at its final
  // size and makes it visible (arming the click-outside hooks). Called once per
  // lookup after the page has self-measured, so the user never sees the
  // measure->resize jitter. Pass <=0 to keep the current size.
  void Reveal(int width, int height);
  void Hide();
  bool IsShowing() const;

  // Injects |popup_json| and calls window.renderPopup(). Cached until the
  // WebView2 finishes initial navigation if called too early.
  void RenderJson(const std::string& popup_json);

  // Resolves a deferred JS bridge promise. |json_value| is a JSON literal
  // (e.g. "\"file:///a.mp3\"", "true", "null") passed straight to
  // window.__hibikiBridgeResolve(id, json_value). Used by the audio handlers,
  // whose real reply comes from the main Dart engine.
  void ResolveBridge(int64_t id, const std::string& json_value);

  void SetMediaResolver(MediaResolver resolver) {
    media_resolver_ = std::move(resolver);
  }
  void SetMessageCallback(MessageCallback cb) {
    message_cb_ = std::move(cb);
  }

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  // Closes the overlay when the user activates another window (alt-tab away).
  static void CALLBACK ForegroundHookProc(HWINEVENTHOOK hook, DWORD event,
                                          HWND hwnd, LONG id_object,
                                          LONG id_child, DWORD thread,
                                          DWORD time);
  // Closes the overlay when a click lands outside the card (incl. blank space in
  // the same app, which the foreground hook does not catch).
  static LRESULT CALLBACK MouseHookProc(int code, WPARAM wparam, LPARAM lparam);
  LRESULT HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  int OffscreenX() const;
  // TODO-867 P2: round the window corners to match popup.css's card radius.
  void ApplyRoundedRegion();
  void EnsureWindowClass();
  void EnsureWebView();
  void ConfigureWebView();
  std::wstring LoadAdapterScript() const;
  // TODO-867 P3c — reads global_lookup_host.js for top-level injection.
  std::wstring LoadHostScript() const;

  HWND hwnd_ = nullptr;
  HWINEVENTHOOK foreground_hook_ = nullptr;
  HHOOK mouse_hook_ = nullptr;
  static GlobalLookupWindow* s_hook_owner_;
  bool visible_ = false;
  bool revealed_ = false;
  int pending_x_ = 0;
  int pending_y_ = 0;
  bool class_registered_ = false;
  bool webview_ready_ = false;
  std::wstring popup_assets_dir_;
  std::string pending_json_;

  wil::com_ptr<ICoreWebView2Environment> env_;
  wil::com_ptr<ICoreWebView2Controller> controller_;
  wil::com_ptr<ICoreWebView2> webview_;

  MediaResolver media_resolver_;
  MessageCallback message_cb_;
};

#endif  // RUNNER_GLOBAL_LOOKUP_WINDOW_H_
