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
  // TODO-1153 -- receives a native bring-up error message (WebView2 environment
  // /controller create failure) so Dart can surface it via ErrorLogService.
  using ErrorCallback = std::function<void(const std::string& message)>;
  // TODO-1233 -- fired when the overlay transitions from on-screen to hidden via
  // a GENUINE dismissal (foreground hook / click-outside / JS dismiss), so Dart
  // can hang a resume-on-dismiss (video subtitle lookup BUG-072 pause/resume) or
  // reset its own reveal state. NOT fired for the programmatic reset Hide() that
  // precedes a fresh lookup (see Hide(bool)).
  using HiddenCallback = std::function<void()>;

  GlobalLookupWindow();
  ~GlobalLookupWindow();

  GlobalLookupWindow(const GlobalLookupWindow&) = delete;
  GlobalLookupWindow& operator=(const GlobalLookupWindow&) = delete;

  // Absolute folder that holds popup.html / popup.js / popup.css and the
  // injected bridge adapter (flutter_assets/assets/popup at runtime). Must be
  // set (via the channel "prepare" call) before the first ShowAt.
  void SetPopupAssetsDir(const std::wstring& dir) { popup_assets_dir_ = dir; }

  // TODO-1079 — creates the overlay window + WebView2 OFF-SCREEN and navigates
  // to host.html WITHOUT revealing it, so the first hotkey lookup hits a WARM
  // WebView2 (webview_ready_ already set) instead of racing a cold create chain
  // (environment + controller + navigation + host/popup double-iframe, commonly
  // >450ms). Idempotent: a no-op once the window exists. Mirrors the in-app
  // keepWebViewWarm hot-slot ownership for this app-external overlay window.
  // |width|/|height| size the off-screen host so its first self-measure is at a
  // sane size; the real card size is applied on the first ShowAt/Reveal.
  void PrewarmWebView(int width, int height, HWND owner);
  // TODO-1079 — whether the WebView2 has finished its initial navigation (the
  // host document + popup iframes are loaded). The ready-driven reveal fallback
  // must confirm this before revealing so a not-yet-loaded overlay never shows
  // as a blank window.
  bool IsWebViewReady() const { return webview_ready_; }

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
  // TODO-867 P3c E1 — reveals/resizes to the nested-stack union bounding box.
  // |dx|/|dy| offset the window from the pending cursor anchor (physical px; the
  // host bbox origin × dpr) so a left/up cascade shifts the window while the root
  // card stays pinned at the cursor; |width|/|height| are the bbox size (physical
  // px). Clamps to the monitor work area like Reveal/ResizeTo.
  void RevealStack(int dx, int dy, int width, int height,
                   double bbox_left, double bbox_top);
  // TODO-1233 -- [notify]=true (default) fires the HiddenCallback on a genuine
  // dismissal; the programmatic reset before a fresh lookup passes false so the
  // between-lookups reset does not look like a user dismissal.
  void Hide(bool notify = true);
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
  // TODO-1153 -- wires the native overlay-error reporter (see ReportOverlayError).
  void SetErrorCallback(ErrorCallback cb) {
    error_cb_ = std::move(cb);
  }
  // TODO-1233 -- wires the overlay-dismissed reporter (see HiddenCallback).
  void SetHiddenCallback(HiddenCallback cb) {
    hidden_cb_ = std::move(cb);
  }

  // spec 2026-07-10 clipboard panel — the persistent clipboard-panel window is
  // a SECOND GlobalLookupWindow instance. Panel differences are data, not
  // modes: it never arms the dismiss hooks (persistent semantics: click-outside
  // / foreground-switch must NOT close it), and it gets its own WebView2
  // user-data leaf so its environment options never have to match the lookup
  // overlay's (same-folder different-options fails with 0x8007139F).
  void SetArmDismissHooks(bool arm) { arm_dismiss_hooks_ = arm; }
  void SetUserDataLeaf(std::wstring leaf) { user_data_leaf_ = std::move(leaf); }
  // 真机第 4 轮 — 面板窗可被激活：不带 WS_EX_NOACTIVATE 创建，点击面板时焦点
  // 落在面板上（游戏失焦，滚轮不再穿到底下的游戏）。程序化 show/update 仍全
  // 走 SW_SHOWNOACTIVATE / SWP_NOACTIVATE，文本流更新绝不抢游戏焦点。瞬态
  // 覆盖窗保持默认 false（查词卡出现时前台键盘焦点原地不动，design §5 保证 3）。
  // 必须在首次 ShowAt/PrewarmWebView（窗口创建）前设置。
  void SetActivatable(bool activatable) { activatable_ = activatable; }
  // 面板任务栏图标 — 常驻剪贴板面板要有独立任务栏按钮（WS_EX_APPWINDOW 而非
  // WS_EX_TOOLWINDOW）：面板未置顶（图钉关）被游戏/浏览器压到底下时，点任务栏
  // 图标即可激活+拉回前台（任务栏激活自带 raise），面板永远找得回来。瞬态查词
  // 覆盖窗保持默认 false（工具窗，无任务栏项/Alt-Tab 项）。必须在窗口创建前设置。
  void SetTaskbarPresence(bool present) { taskbar_presence_ = present; }
  // 任务栏按钮 / Alt-Tab 项显示的窗口标题（Dart 侧传本地化文案）。创建前设置
  // 则用于 CreateWindowExW；窗口已存在时经 SetWindowTextW 即时生效。
  void SetWindowTitle(const std::wstring& title);

  // spec §6 semi-transparency gate — asks DWM for a Win11 acrylic backdrop
  // behind the window's transparent WebView2 pixels. Returns whether the OS
  // accepted it (Win10 / pre-22H2 -> false; the panel then stays opaque and
  // Dart hides the opacity slider). Requires the window to exist (call after
  // ShowAt/PrewarmWebView). Never touches WS_EX_LAYERED (incompatible with the
  // WebView2 composition surface, see the CreateWindowExW comment).
  bool ApplySystemBackdrop();

  // spec 2026-07-10 panel pin — toggles HWND_TOPMOST without moving/resizing
  // or activating. No-op before the window exists.
  void SetTopmost(bool topmost);

  // spec §6 真机修正 — WHOLE-WINDOW opacity via WS_EX_LAYERED +
  // SetLayeredWindowAttributes(LWA_ALPHA). Real-device finding: the acrylic
  // backdrop chain renders user-visibly OPAQUE through the windowed WebView2
  // child — and frosted glass was never the ask anyway; the user wants to SEE
  // the game/page beneath. LWA_ALPHA is the verified working path for WebView2
  // hosts (whole window fades, incl. text; LWA_COLORKEY is NOT supported by
  // WebView2) and works on Win10 too. [percent] clamped to 30..100; the
  // layered bit sticks once set (a layered window does not render until
  // SetLayeredWindowAttributes is called, so the call always follows).
  void SetWindowAlpha(int percent);

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
  // TODO-867 P3c E2: forward a global click (screen physical px) into the web
  // host as host CSS px relative to the window, so the host hit-tests its shells
  // and dismisses the appropriate layer (the host owns the shell geometry truth).
  void ForwardGlobalClickToHost(int screen_x, int screen_y);
  void EnsureWindowClass();
  // Root fix: hwnd_ must be non-null IFF a LIVE window that is OURS exists.
  // External teardown (WebView2 runtime crash/update, owner destroy, any
  // DestroyWindow) left hwnd_ dangling-non-null, so ShowAt kept SetWindowPos-ing
  // a corpse instead of rebuilding -> the app-external lookup/panel window
  // "never came back without an app restart". OwnsLiveWindow() rejects a
  // destroyed handle (IsWindow) AND a handle recycled to another window
  // (GWLP_USERDATA != this); ForgetDeadWindow() drops such a handle + its dead
  // WebView2 proxies so the next ShowAt/PrewarmWebView rebuilds from scratch.
  bool OwnsLiveWindow() const;
  void ForgetDeadWindow();
  void EnsureWebView();
  void RecoverDeadWebView(const std::string& replay_script);
  // TODO-1153 -- logs + reports an overlay WebView2 bring-up failure (never
  // swallows it) so the "app-external lookup shows no popup" cause is visible.
  void ReportOverlayError(const std::string& message, HRESULT hr);
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
  bool webview_ready_ = false;
  // TODO-1268 (BUG-693): a dead-surface rebuild is in flight; renders
  // cache into pending_json_ until NavigationCompleted re-arms
  // webview_ready_.
  bool recovering_ = false;
  // spec 2026-07-10 — panel-instance data knobs (defaults == the historical
  // lookup-overlay behaviour, so the first instance is byte-for-byte unchanged).
  bool arm_dismiss_hooks_ = true;
  bool activatable_ = false;
  bool taskbar_presence_ = false;
  std::wstring window_title_ = L"Hibiki Lookup";
  std::wstring user_data_leaf_ = L"GlobalLookupWebView2";
  std::wstring popup_assets_dir_;
  std::string pending_json_;

  wil::com_ptr<ICoreWebView2Environment> env_;
  wil::com_ptr<ICoreWebView2Controller> controller_;
  wil::com_ptr<ICoreWebView2> webview_;

  MediaResolver media_resolver_;
  MessageCallback message_cb_;
  ErrorCallback error_cb_;
  HiddenCallback hidden_cb_;
};

#endif  // RUNNER_GLOBAL_LOOKUP_WINDOW_H_
