#ifndef FUSHI_LOOKUP_CARD_CARD_OVERLAY_H_
#define FUSHI_LOOKUP_CARD_CARD_OVERLAY_H_

// Linux (X11) app-external global lookup card: the Linux counterpart of
// windows/runner/global_lookup_window.cpp and macos/Runner/
// GlobalLookupOverlay.swift, with the same channel contract
// (lib/src/lookup/overlay_window_channel.dart).
//
// It runs in its own process (main.cc) because the app's in-process web views
// use WPE WebKit, which registers the same GObject type names as WebKitGTK; the
// two cannot be loaded into one process. The runner forwards every
// `app.fushi.reader/global_lookup` call here (linux/runner/
// global_lookup_channel.cc).
//
// Like macOS there is NO second Flutter engine: the main Dart engine looks the
// word up and pushes a complete render script; this file hosts a bare
// WebKitWebView rendering the same popup assets (assets/popup/
// global_lookup_host.html + popup.html) and answers the reverse calls (image://
// + dictmedia:// bytes, JS bridge messages, dismissal).
//
// Coordinates: Dart speaks PHYSICAL px with a top-left origin. GDK speaks
// logical root coordinates; the anchor monitor's scale factor converts between
// them and is reported back to Dart as `monitorDpr`.
//
// "Never disturb the foreground app" (design §5), mapped to X11:
//   WS_EX_NOACTIVATE / HWND_TOPMOST -> override-redirect popup window: never
//                                      focused, stacked above managed windows;
//   click-outside                   -> XInput2 raw button events on the root
//                                      window (observe-only, no grab);
//   foreground change               -> root _NET_ACTIVE_WINDOW changes.
// Both monitors are armed only while the card is on screen.
//
// WebKit throttles requestAnimationFrame in unmapped windows, and the host
// measures itself with rAF. So, like macOS, the card is measured ON screen at
// the anchor, fully transparent and click-through, and revealed in place.

#include <gtk/gtk.h>
#include <json-glib/json-glib.h>
#include <webkit2/webkit2.h>

#include <cstdint>
#include <functional>
#include <string>

namespace fushi::lookup_card {

// Route identity bound to one lookup render (GlobalLookupWindow::RouteContext).
// Stamped on every reverse call so a late callback from an older lookup can
// never take ownership away from a newer render.
struct RouteContext {
  std::string source = "desktop";
  int64_t route_epoch = 0;
  int64_t lookup_epoch = 0;
};

// Answer to one channel call. |value| is owned by whoever receives the Reply.
struct Reply {
  enum class Kind { kValue, kNotImplemented, kError };
  Kind kind = Kind::kValue;
  JsonNode* value = nullptr;
  std::string error_code;
  std::string error_message;
};

class CardOverlay {
 public:
  // Reverse call to Dart (jsMessage, overlayHidden, globalMouseTrigger,
  // nativeError). Takes ownership of |args| (may be null).
  using EventSink = std::function<void(const char* method, JsonNode* args)>;
  // |data| is null or empty when Dart has no bytes for the URL.
  using MediaReply = std::function<void(GBytes* data)>;
  using MediaRequester =
      std::function<void(const std::string& url, MediaReply reply)>;

  CardOverlay(EventSink emit, MediaRequester request_media);
  ~CardOverlay();

  CardOverlay(const CardOverlay&) = delete;
  CardOverlay& operator=(const CardOverlay&) = delete;

  Reply Handle(const std::string& method, JsonObject* args);

 private:
  struct Frame {
    double x = 0;
    double y = 0;
    double width = 1;
    double height = 1;
  };

  // GTK / WebKit / X11 trampolines.
  static gboolean OnWindowDraw(GtkWidget* widget, cairo_t* cr, gpointer data);
  static gboolean OnWindowMotion(GtkWidget* widget, GdkEventMotion* event,
                                 gpointer data);
  static gboolean OnWindowRelease(GtkWidget* widget, GdkEventButton* event,
                                  gpointer data);
  static gboolean OnWindowGrabBroken(GtkWidget* widget, GdkEvent* event,
                                     gpointer data);
  static void OnLoadChanged(WebKitWebView* view, WebKitLoadEvent event,
                            gpointer data);
  static gboolean OnLoadFailed(WebKitWebView* view, WebKitLoadEvent event,
                               gchar* uri, GError* error, gpointer data);
  static void OnWebProcessTerminated(WebKitWebView* view,
                                     WebKitWebProcessTerminationReason reason,
                                     gpointer data);
  static void OnScriptMessage(WebKitUserContentManager* manager,
                              WebKitJavascriptResult* result, gpointer data);
  static void OnAssetRequest(WebKitURISchemeRequest* request, gpointer data);
  static void OnMediaRequest(WebKitURISchemeRequest* request, gpointer data);
  static GdkFilterReturn OnXEvent(GdkXEvent* xevent, GdkEvent* event,
                                  gpointer data);

  void BindRouteContext(JsonObject* args);
  JsonNode* Envelope(const RouteContext& route) const;
  JsonNode* RoutedPayload(const std::string& json,
                          const RouteContext& route) const;

  // Window + web view lifecycle.
  bool EnsureWindow(int width, int height);
  void LoadHostDocument();
  void Prewarm(int width, int height);

  // showAt / reveal / resize / hide.
  JsonNode* ShowAt(JsonObject* args);
  void Present();
  void Reveal(int width, int height);
  bool BeginGeometryRequest(int64_t epoch);
  void RevealStack(int dx, int dy, int width, int height, double bbox_left,
                   double bbox_top, int64_t geometry_epoch);
  void ResizeTo(int width, int height);
  bool IsShowing() const;
  void Hide(bool notify);
  bool SuspendForCapture(int64_t generation);
  bool RestoreAfterCapture(int64_t generation);

  // Geometry (logical px unless named otherwise).
  GdkMonitor* MonitorAtPhysical(double x, double y) const;
  Frame ClampToWorkArea(Frame frame) const;
  void MoveResize(const Frame& frame);
  void SetMeasuring();

  // Dismissal monitors + side-button trigger (X11 only).
  void InitX11();
  void ArmDismissMonitors();
  void DisarmDismissMonitors();
  void UpdateRawButtonSelection();
  void OnRawButtonPress(int x_button);
  void OnActiveWindowChanged();
  unsigned long ReadActiveWindow() const;
  bool SetGlobalMouseTrigger(int dom_button);

  // Host-chrome resize grip.
  void BeginWindowResize();
  void EndResizeTracking(bool report);

  // JS.
  void Evaluate(const std::string& script);
  void Render(const std::string& script);
  void DispatchGamepadAction(const std::string& action, double dy);
  void ResolveBridge(int64_t id, const std::string& js_value);
  void RecoverDeadWebView();
  void ReportError(const std::string& message);
  void HandleScriptMessage(std::string body);
  void HandleBridgeLockRequest();
  bool AuthorizeLockedBridgeMessage(JsonObject* message, std::string* body);
  RouteContext RouteForMessage(JsonObject* message) const;

  // URL schemes.
  void ServeAsset(WebKitURISchemeRequest* request);
  void ServeMedia(WebKitURISchemeRequest* request);

  EventSink emit_;
  MediaRequester request_media_;

  GtkWidget* window_ = nullptr;
  GtkWidget* web_view_ = nullptr;
  std::string assets_dir_;
  std::string assets_root_;  // realpath of assets_dir_
  bool web_view_ready_ = false;
  bool recovering_ = false;
  bool has_pending_script_ = false;
  std::string pending_script_;
  std::string last_script_;

  // Fushi bridge lock (docs/specs/2026-10-23-dictionary-script-sandbox.md).
  // Empty = unlocked. Set by `_fushiLockBridge`, cleared on every top-level
  // document commit / host reload.
  std::string bridge_lock_token_;

  RouteContext route_;
  bool route_bound_ = false;

  // Anchor for the next reveal: PHYSICAL px, top-left origin, in the anchor
  // monitor's scale.
  double pending_x_ = 0;
  double pending_y_ = 0;
  double anchor_scale_ = 1;
  GdkMonitor* anchor_monitor_ = nullptr;
  Frame frame_;

  bool visible_ = false;
  bool revealed_ = false;
  bool measuring_ = false;
  int64_t latest_geometry_epoch_ = 0;
  bool capture_suppressed_ = false;
  int64_t capture_generation_ = 0;

  // X11 monitors.
  bool x11_ = false;
  int xi_opcode_ = -1;
  bool raw_buttons_selected_ = false;
  bool dismiss_armed_ = false;
  unsigned long armed_active_window_ = 0;
  int mouse_trigger_x_button_ = 0;

  bool resizing_ = false;
  Frame resize_start_frame_;
  double resize_start_x_ = 0;
  double resize_start_y_ = 0;
};

}  // namespace fushi::lookup_card

#endif  // FUSHI_LOOKUP_CARD_CARD_OVERLAY_H_
