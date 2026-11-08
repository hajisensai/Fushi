#include "card_overlay.h"

#include "../runner/gamescope_overlay.h"

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>
#include <gdk/gdkx.h>
#include <sys/random.h>

#include <algorithm>
#include <array>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <memory>
#include <set>
#include <utility>
#include <vector>

namespace fushi::lookup_card {
namespace {

constexpr char kPopupAssetScheme[] = "fushi-popup";
constexpr char kPopupAssetHost[] = "assets";
constexpr char kPopupHostDocument[] = "global_lookup_host.html";
constexpr char kScriptMessageName[] = "fushiOverlay";
// Fushi bridge lock contract (global_lookup_host.js / global_lookup_window.cpp).
constexpr char kBridgeLockHandler[] = "_fushiLockBridge";
constexpr char kBridgeTokenField[] = "__fushiBridgeToken";

// Installed at document start in every frame: the WebView2 API surface the
// popup adapter and the host post through, mapped onto the WebKit script
// message handler (identical to the macOS shim; WebKitGTK exposes the same
// window.webkit.messageHandlers API).
constexpr char kChromeWebViewShim[] = R"JS((function () {
  if (window.chrome && window.chrome.webview &&
      typeof window.chrome.webview.postMessage === 'function') {
    return;
  }
  window.chrome = window.chrome || {};
  window.chrome.webview = {
    postMessage: function (message) {
      try {
        window.webkit.messageHandlers.fushiOverlay.postMessage(
            JSON.stringify(message));
      } catch (e) {
        // No bridge in this realm: drop (matches the adapter's own guard).
      }
    }
  };
})();)JS";

// Bridge handlers whose Promise is settled by the main Dart engine
// (resolveBridge) instead of the immediate `null`: the list the Windows router
// keeps (global_lookup_window.cpp WebMessageReceived).
const std::set<std::string>& DeferredHandlers() {
  static const std::set<std::string> handlers = {
      "resolveWordAudio", "listWordAudioSources", "queryLocalAudio",
      "favoriteEntry",    "favoriteCheck",        "mineEntry",
      "duplicateCheck",   "overwriteTargetNoteId", "updateEntry",
      "findMinedMatches", "openMinedNote",        "openInAnki",
      "srsTermStatus",    "srsTermStatusBatch",   "srsOpenCard",
  };
  return handlers;
}

// Best-effort diagnostics, appended to the file the Dart side writes (glog ->
// <systemTemp>/hibiki_glookup.log) so both halves correlate.
void NativeLog(const std::string& message) {
  const std::string path =
      std::string(g_get_tmp_dir()) + "/hibiki_glookup.log";
  FILE* file = fopen(path.c_str(), "a");
  if (file == nullptr) {
    return;
  }
  GDateTime* now = g_date_time_new_now_utc();
  gchar* stamp = g_date_time_format_iso8601(now);
  fprintf(file, "%s  [native-linux] %s\n", stamp, message.c_str());
  g_free(stamp);
  g_date_time_unref(now);
  fclose(file);
}

// ---- JSON argument helpers ----

JsonNode* Member(JsonObject* args, const char* key) {
  return args != nullptr && json_object_has_member(args, key)
             ? json_object_get_member(args, key)
             : nullptr;
}

int64_t Int64Arg(JsonObject* args, const char* key, int64_t fallback) {
  JsonNode* node = Member(args, key);
  if (node == nullptr || !JSON_NODE_HOLDS_VALUE(node)) {
    return fallback;
  }
  const GType type = json_node_get_value_type(node);
  if (type == G_TYPE_INT64) {
    return json_node_get_int(node);
  }
  if (type == G_TYPE_DOUBLE) {
    return static_cast<int64_t>(json_node_get_double(node));
  }
  return fallback;
}

int IntArg(JsonObject* args, const char* key, int fallback) {
  const int64_t value = Int64Arg(args, key, fallback);
  return static_cast<int>(std::clamp<int64_t>(value, INT_MIN, INT_MAX));
}

double DoubleArg(JsonObject* args, const char* key, double fallback) {
  JsonNode* node = Member(args, key);
  if (node == nullptr || !JSON_NODE_HOLDS_VALUE(node)) {
    return fallback;
  }
  const GType type = json_node_get_value_type(node);
  if (type == G_TYPE_INT64 || type == G_TYPE_DOUBLE) {
    return json_node_get_double(node);
  }
  return fallback;
}

bool BoolArg(JsonObject* args, const char* key, bool fallback) {
  JsonNode* node = Member(args, key);
  if (node == nullptr || !JSON_NODE_HOLDS_VALUE(node) ||
      json_node_get_value_type(node) != G_TYPE_BOOLEAN) {
    return fallback;
  }
  return json_node_get_boolean(node);
}

std::string StringArg(JsonObject* args, const char* key,
                      const std::string& fallback) {
  JsonNode* node = Member(args, key);
  if (node == nullptr || !JSON_NODE_HOLDS_VALUE(node) ||
      json_node_get_value_type(node) != G_TYPE_STRING) {
    return fallback;
  }
  return json_node_get_string(node);
}

JsonNode* BoolNode(bool value) {
  JsonNode* node = json_node_new(JSON_NODE_VALUE);
  json_node_set_boolean(node, value);
  return node;
}

JsonNode* StringNode(const std::string& value) {
  JsonNode* node = json_node_new(JSON_NODE_VALUE);
  json_node_set_string(node, value.c_str());
  return node;
}

Reply ValueReply(JsonNode* value) {
  Reply reply;
  reply.value = value;
  return reply;
}

Reply NullReply() { return ValueReply(nullptr); }

// Parses |text| as a JSON object; null when it is anything else.
JsonObject* ParseObject(const std::string& text, JsonParser** parser_out) {
  JsonParser* parser = json_parser_new();
  if (!json_parser_load_from_data(parser, text.data(),
                                  static_cast<gssize>(text.size()), nullptr)) {
    g_object_unref(parser);
    return nullptr;
  }
  JsonNode* root = json_parser_get_root(parser);
  if (root == nullptr || !JSON_NODE_HOLDS_OBJECT(root)) {
    g_object_unref(parser);
    return nullptr;
  }
  *parser_out = parser;
  return json_node_get_object(root);
}

// ---- Bridge lock token ----

// >=128 bit random token: 32 bytes from the kernel CSPRNG, lower-case hex.
// Empty on failure.
std::string GenerateBridgeLockToken() {
  std::array<unsigned char, 32> bytes{};
  size_t filled = 0;
  while (filled < bytes.size()) {
    const ssize_t got =
        getrandom(bytes.data() + filled, bytes.size() - filled, 0);
    if (got <= 0) {
      return std::string();
    }
    filled += static_cast<size_t>(got);
  }
  static constexpr char kHex[] = "0123456789abcdef";
  std::string token;
  token.reserve(bytes.size() * 2);
  for (unsigned char byte : bytes) {
    token.push_back(kHex[byte >> 4]);
    token.push_back(kHex[byte & 0x0F]);
  }
  return token;
}

// Constant-time comparison (no early exit on the first differing byte).
bool BridgeTokensEqual(const std::string& a, const std::string& b) {
  if (a.size() != b.size()) {
    return false;
  }
  unsigned char diff = 0;
  for (size_t i = 0; i < a.size(); ++i) {
    diff |= static_cast<unsigned char>(a[i] ^ b[i]);
  }
  return diff == 0;
}

// ---- URL scheme responses ----

std::string LowerExtension(const std::string& path) {
  const size_t slash = path.find_last_of('/');
  const size_t dot = path.find_last_of('.');
  if (dot == std::string::npos || (slash != std::string::npos && dot < slash)) {
    return std::string();
  }
  std::string ext = path.substr(dot + 1);
  std::transform(ext.begin(), ext.end(), ext.begin(),
                 [](unsigned char c) { return g_ascii_tolower(c); });
  return ext;
}

const char* AssetContentType(const std::string& ext) {
  static const std::pair<const char*, const char*> kTypes[] = {
      {"html", "text/html; charset=utf-8"},
      {"htm", "text/html; charset=utf-8"},
      {"js", "text/javascript; charset=utf-8"},
      {"mjs", "text/javascript; charset=utf-8"},
      {"css", "text/css; charset=utf-8"},
      {"json", "application/json; charset=utf-8"},
      {"png", "image/png"},
      {"jpg", "image/jpeg"},
      {"jpeg", "image/jpeg"},
      {"gif", "image/gif"},
      {"webp", "image/webp"},
      {"svg", "image/svg+xml"},
      {"woff", "font/woff"},
      {"woff2", "font/woff2"},
      {"ttf", "font/ttf"},
      {"otf", "font/otf"},
      {"mp3", "audio/mpeg"},
      {"ogg", "audio/ogg"},
      {"oga", "audio/ogg"},
      {"wav", "audio/wav"},
  };
  for (const auto& [key, type] : kTypes) {
    if (ext == key) {
      return type;
    }
  }
  return "application/octet-stream";
}

// Content-Type for image:// and dictmedia:// (global_lookup_window.cpp
// MediaContentTypeHeader): dictmedia carries dictionary stylesheets.
const char* MediaContentType(const std::string& scheme,
                             const std::string& path) {
  if (g_ascii_strcasecmp(scheme.c_str(), "dictmedia") == 0) {
    return "text/css";
  }
  const std::string ext = LowerExtension(path);
  if (ext == "png" || ext == "jpg" || ext == "jpeg" || ext == "gif" ||
      ext == "webp" || ext == "svg") {
    return AssetContentType(ext);
  }
  return "application/octet-stream";
}

void FinishRequest(WebKitURISchemeRequest* request, int status,
                   const char* content_type, GBytes* bytes) {
  GBytes* body = bytes != nullptr ? g_bytes_ref(bytes) : g_bytes_new(nullptr, 0);
  const gsize size = g_bytes_get_size(body);
  GInputStream* stream = g_memory_input_stream_new_from_bytes(body);
  WebKitURISchemeResponse* response =
      webkit_uri_scheme_response_new(stream, static_cast<gint64>(size));
  webkit_uri_scheme_response_set_status(response, status, nullptr);
  webkit_uri_scheme_response_set_content_type(response, content_type);
  SoupMessageHeaders* headers =
      soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
  soup_message_headers_append(headers, "Access-Control-Allow-Origin", "*");
  webkit_uri_scheme_response_set_http_headers(response, headers);
  webkit_uri_scheme_request_finish_with_response(request, response);
  g_object_unref(response);
  g_object_unref(stream);
  g_bytes_unref(body);
}

int Round(double value) { return static_cast<int>(std::lround(value)); }

GdkDevice* Pointer() {
  GdkSeat* seat = gdk_display_get_default_seat(gdk_display_get_default());
  return seat != nullptr ? gdk_seat_get_pointer(seat) : nullptr;
}

bool PointerPosition(double* x, double* y) {
  GdkDevice* pointer = Pointer();
  if (pointer == nullptr) {
    return false;
  }
  gdk_device_get_position_double(pointer, nullptr, x, y);
  return true;
}

}  // namespace

// ---- Construction ----

CardOverlay::CardOverlay(EventSink emit, MediaRequester request_media)
    : emit_(std::move(emit)), request_media_(std::move(request_media)) {
  InitX11();
}

CardOverlay::~CardOverlay() {
  DisarmDismissMonitors();
  mouse_trigger_x_button_ = 0;
  UpdateRawButtonSelection();
  if (x11_) {
    gdk_window_remove_filter(nullptr, OnXEvent, this);
  }
  if (window_ != nullptr) {
    gtk_widget_destroy(window_);
    window_ = nullptr;
    web_view_ = nullptr;
  }
}

// ---- Channel dispatch ----

Reply CardOverlay::Handle(const std::string& method, JsonObject* args) {
  // The in-game (galCard) card window is a Windows-only galgame surface
  // (native/galgame_hook is Windows-only by CLAUDE.md rule).
  if (StringArg(args, "target", "") == "galCard") {
    Reply reply;
    reply.kind = Reply::Kind::kError;
    reply.error_code = "gal_card_unavailable";
    reply.error_message = "in-game lookup card window is not available on Linux";
    return reply;
  }
  BindRouteContext(args);

  if (method == "prepare") {
    assets_dir_ = StringArg(args, "assetsDir", "");
    char* resolved = realpath(assets_dir_.c_str(), nullptr);
    assets_root_ = resolved != nullptr ? resolved : std::string();
    free(resolved);
    return NullReply();
  }
  if (method == "prewarmWebView") {
    Prewarm(IntArg(args, "width", 420), IntArg(args, "height", 600));
    return NullReply();
  }
  if (method == "isWebViewReady") {
    return ValueReply(BoolNode(web_view_ready_));
  }
  if (method == "showAt") {
    return ValueReply(ShowAt(args));
  }
  if (method == "render") {
    Render(StringArg(args, "json", ""));
    return NullReply();
  }
  if (method == "gamepadAction") {
    DispatchGamepadAction(StringArg(args, "action", ""),
                          DoubleArg(args, "dy", 0));
    return NullReply();
  }
  if (method == "resize") {
    ResizeTo(IntArg(args, "width", 0), IntArg(args, "height", 0));
    return NullReply();
  }
  if (method == "resolveBridge") {
    ResolveBridge(Int64Arg(args, "id", 0), StringArg(args, "value", "null"));
    return NullReply();
  }
  if (method == "reveal") {
    Reveal(IntArg(args, "width", 0), IntArg(args, "height", 0));
    return NullReply();
  }
  if (method == "revealStack") {
    RevealStack(IntArg(args, "dx", 0), IntArg(args, "dy", 0),
                IntArg(args, "width", 0), IntArg(args, "height", 0),
                DoubleArg(args, "left", 0), DoubleArg(args, "top", 0),
                Int64Arg(args, "geometryEpoch", 0));
    return NullReply();
  }
  if (method == "hide") {
    Hide(BoolArg(args, "notify", true));
    return NullReply();
  }
  if (method == "isShowing") {
    return ValueReply(BoolNode(IsShowing()));
  }
  if (method == "suspendForCapture") {
    return ValueReply(
        BoolNode(SuspendForCapture(Int64Arg(args, "captureGeneration", 0))));
  }
  if (method == "restoreAfterCapture") {
    return ValueReply(
        BoolNode(RestoreAfterCapture(Int64Arg(args, "captureGeneration", 0))));
  }
  if (method == "setBlockCapture" || method == "setOutsideClickOwner") {
    // X11 cannot exclude a window from screen capture; the outside-click owner
    // is the attached galgame surface (Windows). Accepted as no-ops.
    return NullReply();
  }
  if (method == "setGlobalMouseTrigger") {
    return ValueReply(
        BoolNode(SetGlobalMouseTrigger(IntArg(args, "button", 0))));
  }
  Reply reply;
  reply.kind = Reply::Kind::kNotImplemented;
  return reply;
}

void CardOverlay::BindRouteContext(JsonObject* args) {
  RouteContext next;
  next.source =
      StringArg(args, "source", "desktop") == "galCard" ? "galCard" : "desktop";
  next.route_epoch = Int64Arg(args, "routeEpoch", 0);
  next.lookup_epoch = Int64Arg(args, "lookupEpoch", 0);
  route_ = next;
  route_bound_ = true;
}

JsonNode* CardOverlay::Envelope(const RouteContext& route) const {
  JsonObject* object = json_object_new();
  json_object_set_string_member(object, "source", route.source.c_str());
  json_object_set_int_member(object, "routeEpoch", route.route_epoch);
  json_object_set_int_member(object, "lookupEpoch", route.lookup_epoch);
  JsonNode* node = json_node_new(JSON_NODE_OBJECT);
  json_node_take_object(node, object);
  return node;
}

JsonNode* CardOverlay::RoutedPayload(const std::string& json,
                                     const RouteContext& route) const {
  JsonNode* node = Envelope(route);
  json_object_set_string_member(json_node_get_object(node), "payload",
                                json.c_str());
  return node;
}

// ---- Window + web view lifecycle ----

bool CardOverlay::EnsureWindow(int width, int height) {
  if (window_ != nullptr) {
    return true;
  }
  const double scale = anchor_scale_ > 0 ? anchor_scale_ : 1;

  window_ = gtk_window_new(GTK_WINDOW_POPUP);
  GtkWindow* window = GTK_WINDOW(window_);
  gtk_window_set_title(window, "Fushi Lookup");
  gtk_window_set_accept_focus(window, FALSE);
  gtk_widget_set_app_paintable(window_, TRUE);
  GdkScreen* screen = gtk_widget_get_screen(window_);
  GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
  const bool game_mode = fushi::gamescope::InGameMode();
  // Game Mode: Gamescope composites the window's alpha; the screen OCR layer
  // must show around the card.
  if (visual != nullptr && (game_mode || gdk_screen_is_composited(screen))) {
    gtk_widget_set_visual(window_, visual);
  }
  gtk_widget_add_events(window_,
                        GDK_POINTER_MOTION_MASK | GDK_BUTTON_RELEASE_MASK);
  g_signal_connect(window_, "draw", G_CALLBACK(OnWindowDraw), this);
  g_signal_connect(window_, "motion-notify-event", G_CALLBACK(OnWindowMotion),
                   this);
  g_signal_connect(window_, "button-release-event",
                   G_CALLBACK(OnWindowRelease), this);
  g_signal_connect(window_, "grab-broken-event",
                   G_CALLBACK(OnWindowGrabBroken), this);

  WebKitWebContext* context = webkit_web_context_new_ephemeral();
  webkit_web_context_register_uri_scheme(context, kPopupAssetScheme,
                                         OnAssetRequest, this, nullptr);
  webkit_web_context_register_uri_scheme(context, "image", OnMediaRequest,
                                         this, nullptr);
  webkit_web_context_register_uri_scheme(context, "dictmedia", OnMediaRequest,
                                         this, nullptr);
  WebKitSecurityManager* security =
      webkit_web_context_get_security_manager(context);
  for (const char* scheme : {kPopupAssetScheme, "image", "dictmedia"}) {
    webkit_security_manager_register_uri_scheme_as_secure(security, scheme);
    webkit_security_manager_register_uri_scheme_as_cors_enabled(security,
                                                                scheme);
  }

  WebKitUserContentManager* content = webkit_user_content_manager_new();
  webkit_user_content_manager_register_script_message_handler(
      content, kScriptMessageName);
  g_signal_connect(content, "script-message-received::fushiOverlay",
                   G_CALLBACK(OnScriptMessage), this);
  // 1) chrome.webview shim, 2) bridge adapter, 3) nested-stack host: the same
  // order and all-frames injection as the Windows / macOS runners (host.js
  // bails on sub-frames itself via window.top !== window.self).
  std::vector<std::string> sources = {kChromeWebViewShim};
  for (const char* name : {"popup_bridge_adapter.js", "global_lookup_host.js"}) {
    const std::string path = assets_dir_ + "/" + name;
    gchar* text = nullptr;
    if (g_file_get_contents(path.c_str(), &text, nullptr, nullptr) &&
        text != nullptr && text[0] != '\0') {
      sources.emplace_back(text);
    } else {
      ReportError("overlay script missing: " + path);
    }
    g_free(text);
  }
  for (const std::string& source : sources) {
    WebKitUserScript* script = webkit_user_script_new(
        source.c_str(), WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, nullptr, nullptr);
    webkit_user_content_manager_add_script(content, script);
    webkit_user_script_unref(script);
  }

  web_view_ = GTK_WIDGET(g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context",
                                      context, "user-content-manager",
                                      content, nullptr));
  g_object_unref(content);
  g_object_unref(context);
  WebKitWebView* view = WEBKIT_WEB_VIEW(web_view_);
  WebKitSettings* settings = webkit_web_view_get_settings(view);
  // BUG-1091 parity: the card auto-plays word audio from its own <audio>.
  webkit_settings_set_media_playback_requires_user_gesture(settings, FALSE);
  webkit_settings_set_enable_developer_extras(settings, FALSE);
  // Transparent page background: the card's rounded shell and the gaps between
  // cascade cards show the desktop.
  const GdkRGBA transparent = {0, 0, 0, 0};
  webkit_web_view_set_background_color(view, &transparent);
  g_signal_connect(view, "load-changed", G_CALLBACK(OnLoadChanged), this);
  g_signal_connect(view, "load-failed", G_CALLBACK(OnLoadFailed), this);
  g_signal_connect(view, "web-process-terminated",
                   G_CALLBACK(OnWebProcessTerminated), this);
  if (game_mode) {
    stage_ = gtk_fixed_new();
    gtk_container_add(GTK_CONTAINER(stage_), web_view_);
    gtk_container_add(GTK_CONTAINER(window_), stage_);
    gtk_widget_show(stage_);
    // The window takes every touch while it holds Steam's overlay slot: a tap
    // beside the card closes it (the desktop's click-outside).
    gtk_widget_add_events(window_, GDK_BUTTON_PRESS_MASK);
    g_signal_connect(window_, "button-press-event", G_CALLBACK(OnStagePress),
                     this);
  } else {
    gtk_container_add(GTK_CONTAINER(window_), web_view_);
  }
  gtk_widget_show(web_view_);
  gtk_widget_set_opacity(web_view_, 0);

  frame_ = Frame{-32000, -32000, std::max(width / scale, 1.0),
                 std::max(height / scale, 1.0)};
  MoveResize(frame_);
  gtk_widget_realize(window_);
  LoadHostDocument();
  return true;
}

void CardOverlay::LoadHostDocument() {
  if (web_view_ == nullptr) {
    return;
  }
  web_view_ready_ = false;
  bridge_lock_token_.clear();
  const std::string uri = std::string(kPopupAssetScheme) + "://" +
                          kPopupAssetHost + "/" + kPopupHostDocument;
  webkit_web_view_load_uri(WEBKIT_WEB_VIEW(web_view_), uri.c_str());
}

void CardOverlay::Prewarm(int width, int height) {
  // TODO-1079 parity: build the window + web view now so the first lookup hits
  // a warm surface. Not mapped until showAt places it at the anchor.
  if (window_ != nullptr) {
    return;
  }
  EnsureWindow(width, height);
  NativeLog("prewarm: window created " + std::to_string(width) + "x" +
            std::to_string(height));
}

// ---- Geometry ----

GdkMonitor* CardOverlay::MonitorAtPhysical(double x, double y) const {
  GdkDisplay* display = gdk_display_get_default();
  const int count = gdk_display_get_n_monitors(display);
  for (int i = 0; i < count; ++i) {
    GdkMonitor* monitor = gdk_display_get_monitor(display, i);
    GdkRectangle g;
    gdk_monitor_get_geometry(monitor, &g);
    const double s = gdk_monitor_get_scale_factor(monitor);
    if (x >= g.x * s && x < (g.x + g.width) * s && y >= g.y * s &&
        y < (g.y + g.height) * s) {
      return monitor;
    }
  }
  GdkMonitor* primary = gdk_display_get_primary_monitor(display);
  return primary != nullptr ? primary : gdk_display_get_monitor(display, 0);
}

// Shrink to fit the anchor monitor's work area, then nudge back on-screen if
// the bottom / right would overflow (Reveal / RevealStack / ResizeTo on
// Windows).
CardOverlay::Frame CardOverlay::ClampToWorkArea(Frame frame) const {
  if (anchor_monitor_ == nullptr) {
    return frame;
  }
  GdkRectangle work;
  gdk_monitor_get_workarea(anchor_monitor_, &work);
  frame.width = std::min<double>(frame.width, work.width);
  frame.height = std::min<double>(frame.height, work.height);
  if (frame.x + frame.width > work.x + work.width) {
    frame.x = work.x + work.width - frame.width;
  }
  if (frame.y + frame.height > work.y + work.height) {
    frame.y = work.y + work.height - frame.height;
  }
  frame.x = std::max<double>(frame.x, work.x);
  frame.y = std::max<double>(frame.y, work.y);
  frame.width = std::max(frame.width, 1.0);
  frame.height = std::max(frame.height, 1.0);
  return frame;
}

void CardOverlay::MoveResize(const Frame& frame) {
  frame_ = frame;
  if (window_ == nullptr) {
    return;
  }
  const int width = std::max(Round(frame.width), 1);
  const int height = std::max(Round(frame.height), 1);
  gtk_widget_set_size_request(web_view_, width, height);
  if (stage_ != nullptr) {
    // Game Mode: the window stays on the whole output; the card moves inside.
    const GdkRectangle area = StageArea();
    gtk_widget_set_size_request(window_, area.width, area.height);
    gtk_window_resize(GTK_WINDOW(window_), area.width, area.height);
    gtk_window_move(GTK_WINDOW(window_), area.x, area.y);
    gtk_fixed_move(GTK_FIXED(stage_), web_view_, Round(frame.x) - area.x,
                   Round(frame.y) - area.y);
    return;
  }
  gtk_window_resize(GTK_WINDOW(window_), width, height);
  gtk_window_move(GTK_WINDOW(window_), Round(frame.x), Round(frame.y));
}

GdkRectangle CardOverlay::StageArea() const {
  GdkMonitor* monitor = anchor_monitor_;
  if (monitor == nullptr) {
    GdkDisplay* display = gdk_display_get_default();
    monitor = gdk_display_get_primary_monitor(display);
    if (monitor == nullptr) monitor = gdk_display_get_monitor(display, 0);
  }
  GdkRectangle area{0, 0, 1, 1};
  if (monitor != nullptr) gdk_monitor_get_geometry(monitor, &area);
  return area;
}

// On-screen, invisible, click-through measurement parking.
void CardOverlay::SetMeasuring() {
  gtk_widget_set_opacity(web_view_, 0);
  cairo_region_t* empty = cairo_region_create();
  gtk_widget_input_shape_combine_region(window_, empty);
  cairo_region_destroy(empty);
  gtk_widget_show(window_);
  measuring_ = true;
  visible_ = false;
}

// ---- showAt / reveal / resize / hide ----

JsonNode* CardOverlay::ShowAt(JsonObject* args) {
  const int width_px = IntArg(args, "width", 420);
  const int height_px = IntArg(args, "height", 600);
  const bool at_cursor = BoolArg(args, "atCursor", false);

  GdkDisplay* display = gdk_display_get_default();
  double anchor_x = 0;
  double anchor_y = 0;
  GdkMonitor* monitor = nullptr;
  if (at_cursor && PointerPosition(&anchor_x, &anchor_y)) {
    monitor = gdk_display_get_monitor_at_point(display, Round(anchor_x),
                                               Round(anchor_y));
    // Same +8 physical px cursor offset as the Windows GetCursorPos path.
    const double scale = gdk_monitor_get_scale_factor(monitor);
    anchor_x += 8 / scale;
    anchor_y += 8 / scale;
  } else {
    const double x = IntArg(args, "x", 0);
    const double y = IntArg(args, "y", 0);
    monitor = MonitorAtPhysical(x, y);
    const double scale = gdk_monitor_get_scale_factor(monitor);
    anchor_x = x / scale;
    anchor_y = y / scale;
  }
  anchor_monitor_ = monitor;
  anchor_scale_ = std::max(gdk_monitor_get_scale_factor(monitor), 1);
  pending_x_ = anchor_x * anchor_scale_;
  pending_y_ = anchor_y * anchor_scale_;
  revealed_ = false;

  // Anchor-monitor work area in PHYSICAL px + the window-local origin's offset
  // inside it (TODO-893 / BUG-859 reply contract).
  GdkRectangle work;
  gdk_monitor_get_workarea(monitor, &work);
  double work_w = work.width * anchor_scale_;
  double work_h = work.height * anchor_scale_;
  double cursor_work_x = (anchor_x - work.x) * anchor_scale_;
  double cursor_work_y = (anchor_y - work.y) * anchor_scale_;
  const int cap_w = IntArg(args, "capW", 0);
  const int cap_h = IntArg(args, "capH", 0);
  if (cap_w > 0 && cap_h > 0) {
    work_w = cap_w;
    work_h = cap_h;
    cursor_work_x = IntArg(args, "capX", 0);
    cursor_work_y = IntArg(args, "capY", 0);
  }

  const bool ok = EnsureWindow(width_px, height_px);
  if (ok) {
    MoveResize(Frame{anchor_x, anchor_y, width_px / anchor_scale_,
                     height_px / anchor_scale_});
    SetMeasuring();
  }
  NativeLog("showAt: ok=" + std::to_string(ok) +
            " atCursor=" + std::to_string(at_cursor) + " pending=(" +
            std::to_string(Round(pending_x_)) + "," +
            std::to_string(Round(pending_y_)) +
            ") scale=" + std::to_string(anchor_scale_) +
            " work=" + std::to_string(Round(work_w)) + "x" +
            std::to_string(Round(work_h)));

  JsonObject* result = json_object_new();
  json_object_set_boolean_member(result, "ok", ok);
  json_object_set_double_member(result, "workW", work_w);
  json_object_set_double_member(result, "workH", work_h);
  json_object_set_double_member(result, "cursorWorkX", cursor_work_x);
  json_object_set_double_member(result, "cursorWorkY", cursor_work_y);
  json_object_set_double_member(result, "monitorDpr", anchor_scale_);
  JsonNode* node = json_node_new(JSON_NODE_OBJECT);
  json_node_take_object(node, result);
  return node;
}

// Makes the parked window visible + interactive and arms the dismissal
// monitors (the Windows Reveal / RevealStack tail).
void CardOverlay::Present() {
  if (window_ == nullptr) {
    return;
  }
  gtk_widget_set_opacity(web_view_, 1);
  gtk_widget_input_shape_combine_region(window_, nullptr);
  gtk_widget_show(window_);
  GdkWindow* gdk_window = gtk_widget_get_window(window_);
  if (gdk_window != nullptr) {
    gdk_window_raise(gdk_window);
  }
  measuring_ = false;
  visible_ = true;
  revealed_ = true;
  // Game Mode: drawn over the game and given the touches, above the screen OCR
  // layer (kCardRank > kFreezeLayerRank) and below Steam's own overlay.
  fushi::gamescope::SetRole(window_, fushi::gamescope::kInput,
                            fushi::gamescope::kCardRank);
  ArmDismissMonitors();
}

void CardOverlay::Reveal(int width, int height) {
  if (capture_suppressed_ || window_ == nullptr) {
    return;
  }
  Frame frame = frame_;
  if (width > 0) {
    frame.width = width / anchor_scale_;
  }
  if (height > 0) {
    frame.height = height / anchor_scale_;
  }
  frame.x = pending_x_ / anchor_scale_;
  frame.y = pending_y_ / anchor_scale_;
  MoveResize(ClampToWorkArea(frame));
  Present();
  // BUG-2123 parity: this legacy path places the window at the cursor at the
  // single-card size; undo the host's pre-shift so the root card is not pushed
  // outside the window.
  Evaluate(
      "(function(){var h=window.__globalLookupHost;"
      "if(h&&typeof h.resetLayerOffsetForLegacyReveal==='function'){"
      "h.resetLayerOffsetForLegacyReveal();}})();");
}

bool CardOverlay::BeginGeometryRequest(int64_t epoch) {
  if (epoch < 0) {
    return false;
  }
  if (epoch == 0) {
    return latest_geometry_epoch_ == 0;
  }
  if (epoch < latest_geometry_epoch_) {
    return false;
  }
  latest_geometry_epoch_ = epoch;
  return true;
}

void CardOverlay::RevealStack(int dx, int dy, int width, int height,
                              double bbox_left, double bbox_top,
                              int64_t geometry_epoch) {
  if (capture_suppressed_ || !BeginGeometryRequest(geometry_epoch) ||
      window_ == nullptr || width <= 0 || height <= 0) {
    return;
  }
  const Frame intended{(pending_x_ + dx) / anchor_scale_,
                       (pending_y_ + dy) / anchor_scale_,
                       width / anchor_scale_, height / anchor_scale_};
  const Frame clamped = ClampToWorkArea(intended);
  MoveResize(clamped);
  Present();
  // TODO-1231 P2 / BUG-859 parity: content shift AFTER the window move, with
  // any work-area clamp delta folded in. Logical px == CSS px here.
  const double clamp_dx = clamped.x - intended.x;
  const double clamp_dy = clamped.y - intended.y;
  gchar* script = g_strdup_printf(
      "window.__globalLookupHost && window.__globalLookupHost.commitLayerShift("
      "%.3f, %.3f, %" G_GINT64_FORMAT ");",
      bbox_left + clamp_dx, bbox_top + clamp_dy, geometry_epoch);
  Evaluate(script);
  g_free(script);
}

void CardOverlay::ResizeTo(int width, int height) {
  if (window_ == nullptr || width <= 0 || height <= 0) {
    return;
  }
  Frame frame = frame_;
  frame.width = width / anchor_scale_;
  frame.height = height / anchor_scale_;
  MoveResize(ClampToWorkArea(frame));
}

bool CardOverlay::IsShowing() const {
  return visible_ && window_ != nullptr && gtk_widget_get_visible(window_);
}

// The single dismissal funnel (TODO-1233): every genuine dismissal
// (click-outside / foreground change / JS dismiss) and the programmatic
// between-lookups reset (notify=false) go through here.
void CardOverlay::Hide(bool notify) {
  const bool was_showing = visible_;
  const RouteContext hidden_route = route_;
  capture_suppressed_ = false;
  capture_generation_ = 0;
  visible_ = false;
  revealed_ = false;
  measuring_ = false;
  DisarmDismissMonitors();
  EndResizeTracking(false);
  if (window_ != nullptr) {
    // Gamescope picks overlays without checking whether they are mapped.
    fushi::gamescope::SetRole(window_, fushi::gamescope::kNone, 0);
    gtk_widget_hide(window_);
    gtk_widget_set_opacity(web_view_, 0);
  }
  if (notify && was_showing) {
    emit_("overlayHidden", Envelope(hidden_route));
  }
}

bool CardOverlay::SuspendForCapture(int64_t generation) {
  if (generation <= 0 || !route_bound_ || capture_suppressed_ || !visible_) {
    return false;
  }
  capture_suppressed_ = true;
  capture_generation_ = generation;
  if (window_ != nullptr) {
    fushi::gamescope::SetRole(window_, fushi::gamescope::kNone, 0);
    gtk_widget_hide(window_);
  }
  return true;
}

bool CardOverlay::RestoreAfterCapture(int64_t generation) {
  if (generation <= 0 || !capture_suppressed_ ||
      capture_generation_ != generation) {
    return false;
  }
  capture_suppressed_ = false;
  capture_generation_ = 0;
  if (visible_ && window_ != nullptr) {
    fushi::gamescope::SetRole(window_, fushi::gamescope::kInput,
                              fushi::gamescope::kCardRank);
    gtk_widget_show(window_);
    gdk_window_raise(gtk_widget_get_window(window_));
  }
  return true;
}

gboolean CardOverlay::OnWindowDraw(GtkWidget*, cairo_t* cr, gpointer) {
  // Clear to fully transparent; the web view paints the card on top.
  cairo_save(cr);
  cairo_set_source_rgba(cr, 0, 0, 0, 0);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_paint(cr);
  cairo_restore(cr);
  return FALSE;
}

// ---- X11 dismissal monitors + side-button trigger ----

void CardOverlay::InitX11() {
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr || !GDK_IS_X11_DISPLAY(display)) {
    NativeLog("init: not an X11 display; no click-outside dismissal");
    return;
  }
  x11_ = true;
  Display* xdisplay = GDK_DISPLAY_XDISPLAY(display);
  int event_base = 0;
  int error_base = 0;
  // GDK already negotiated XInput 2.x for this connection, and the server
  // refuses a later request for a LOWER version (BadValue), so ask for the
  // highest GTK 3 knows; the server answers with the agreed one.
  int major = 2;
  int minor = 4;
  if (XQueryExtension(xdisplay, "XInputExtension", &xi_opcode_, &event_base,
                      &error_base) &&
      XIQueryVersion(xdisplay, &major, &minor) == Success) {
    NativeLog("init: XInput " + std::to_string(major) + "." +
              std::to_string(minor));
  } else {
    xi_opcode_ = -1;
    NativeLog("init: no XInput2; no click-outside dismissal");
  }
  // _NET_ACTIVE_WINDOW changes arrive as PropertyNotify on the root window.
  GdkWindow* root = gdk_get_default_root_window();
  gdk_window_set_events(root,
                        static_cast<GdkEventMask>(gdk_window_get_events(root) |
                                                  GDK_PROPERTY_CHANGE_MASK));
  gdk_window_add_filter(nullptr, OnXEvent, this);
}

// Raw button presses are observed (never grabbed) only while something needs
// them: the card is on screen, or a side button is bound as a trigger
// (BUG-1077 spirit: no system-wide listener for users who never use it).
void CardOverlay::UpdateRawButtonSelection() {
  if (!x11_ || xi_opcode_ < 0) {
    return;
  }
  const bool want = dismiss_armed_ || mouse_trigger_x_button_ != 0;
  if (want == raw_buttons_selected_) {
    return;
  }
  GdkDisplay* display = gdk_display_get_default();
  Display* xdisplay = GDK_DISPLAY_XDISPLAY(display);
  std::array<unsigned char, XIMaskLen(XI_LASTEVENT)> mask{};
  if (want) {
    XISetMask(mask.data(), XI_RawButtonPress);
  }
  XIEventMask event_mask;
  event_mask.deviceid = XIAllMasterDevices;
  event_mask.mask_len = static_cast<int>(mask.size());
  event_mask.mask = mask.data();
  XISelectEvents(xdisplay, DefaultRootWindow(xdisplay), &event_mask, 1);
  XFlush(xdisplay);
  raw_buttons_selected_ = want;
}

unsigned long CardOverlay::ReadActiveWindow() const {
  if (!x11_) {
    return 0;
  }
  Display* xdisplay = GDK_DISPLAY_XDISPLAY(gdk_display_get_default());
  const Atom atom = XInternAtom(xdisplay, "_NET_ACTIVE_WINDOW", False);
  Atom type = None;
  int format = 0;
  unsigned long count = 0;
  unsigned long after = 0;
  unsigned char* data = nullptr;
  unsigned long active = 0;
  if (XGetWindowProperty(xdisplay, DefaultRootWindow(xdisplay), atom, 0, 1,
                         False, XA_WINDOW, &type, &format, &count, &after,
                         &data) == Success &&
      data != nullptr && count == 1 && format == 32) {
    active = *reinterpret_cast<unsigned long*>(data);
  }
  if (data != nullptr) {
    XFree(data);
  }
  return active;
}

void CardOverlay::ArmDismissMonitors() {
  if (dismiss_armed_) {
    return;
  }
  dismiss_armed_ = true;
  armed_active_window_ = ReadActiveWindow();
  UpdateRawButtonSelection();
}

void CardOverlay::DisarmDismissMonitors() {
  if (!dismiss_armed_) {
    return;
  }
  dismiss_armed_ = false;
  UpdateRawButtonSelection();
}

GdkFilterReturn CardOverlay::OnXEvent(GdkXEvent* gdk_xevent, GdkEvent*,
                                      gpointer data) {
  auto* self = static_cast<CardOverlay*>(data);
  auto* xevent = static_cast<XEvent*>(gdk_xevent);
  if (xevent->type == GenericEvent &&
      xevent->xcookie.extension == self->xi_opcode_ &&
      xevent->xcookie.evtype == XI_RawButtonPress &&
      xevent->xcookie.data != nullptr) {
    const auto* raw = static_cast<const XIRawEvent*>(xevent->xcookie.data);
    self->OnRawButtonPress(raw->detail);
  } else if (xevent->type == PropertyNotify && self->dismiss_armed_) {
    Display* xdisplay = xevent->xproperty.display;
    if (xevent->xproperty.window == DefaultRootWindow(xdisplay) &&
        xevent->xproperty.atom ==
            XInternAtom(xdisplay, "_NET_ACTIVE_WINDOW", False)) {
      self->OnActiveWindowChanged();
    }
  }
  return GDK_FILTER_CONTINUE;
}

void CardOverlay::OnRawButtonPress(int x_button) {
  if (mouse_trigger_x_button_ != 0 && x_button == mouse_trigger_x_button_) {
    // Observe-only, like the Windows RawInput listener: the click still
    // reaches the app under the cursor.
    emit_("globalMouseTrigger", nullptr);
    return;
  }
  // 1-3 = left / middle / right, 8 / 9 = back / forward. 4-7 are the wheel.
  if (!dismiss_armed_ || !visible_ || (x_button >= 4 && x_button <= 7)) {
    return;
  }
  double x = 0;
  double y = 0;
  if (!PointerPosition(&x, &y)) {
    return;
  }
  const bool inside = x >= frame_.x && x < frame_.x + frame_.width &&
                      y >= frame_.y && y < frame_.y + frame_.height;
  if (!inside) {
    Hide(true);
    return;
  }
  // Inside the window: the host owns the per-shell geometry and decides
  // card-vs-gap (TODO-867 C4/E2).
  gchar* script = g_strdup_printf(
      "window.__globalLookupHost && window.__globalLookupHost.handleGlobalClick("
      "%.3f, %.3f);",
      x - frame_.x, y - frame_.y);
  Evaluate(script);
  g_free(script);
}

void CardOverlay::OnActiveWindowChanged() {
  // Game Mode: Gamescope rewrites _NET_ACTIVE_WINDOW whenever it moves input
  // focus, including to this card when it takes Steam's overlay slot. Leaving
  // the game goes through Steam's menu there, which takes the slot instead.
  if (fushi::gamescope::InGameMode()) {
    return;
  }
  // The user switched to another window (the Windows EVENT_SYSTEM_FOREGROUND
  // hook). The card itself is never activated (override-redirect).
  if (ReadActiveWindow() != armed_active_window_) {
    Hide(true);
  }
}

// button = DOM MouseEvent.button (3 = back, 4 = forward) -> X buttons 8 / 9;
// 0 = unregister.
bool CardOverlay::SetGlobalMouseTrigger(int dom_button) {
  mouse_trigger_x_button_ = 0;
  if (dom_button == 3 || dom_button == 4) {
    mouse_trigger_x_button_ = dom_button == 3 ? 8 : 9;
  }
  UpdateRawButtonSelection();
  if (mouse_trigger_x_button_ == 0) {
    return dom_button == 0;
  }
  return raw_buttons_selected_;
}

// ---- Host-chrome resize grip ----

void CardOverlay::BeginWindowResize() {
  if (window_ == nullptr || !visible_) {
    return;
  }
  EndResizeTracking(false);
  GdkWindow* gdk_window = gtk_widget_get_window(window_);
  GdkDevice* pointer = Pointer();
  if (gdk_window == nullptr || pointer == nullptr) {
    return;
  }
  // The message is posted on mousedown; a click that is already released
  // would leave the grab waiting for a release that never comes.
  GdkModifierType state = static_cast<GdkModifierType>(0);
  gdk_device_get_state(pointer, gdk_window, nullptr, &state);
  if ((state & GDK_BUTTON1_MASK) == 0) {
    return;
  }
  GdkSeat* seat = gdk_device_get_seat(pointer);
  if (gdk_seat_grab(seat, gdk_window, GDK_SEAT_CAPABILITY_POINTER, FALSE,
                    nullptr, nullptr, nullptr,
                    nullptr) != GDK_GRAB_SUCCESS) {
    return;
  }
  PointerPosition(&resize_start_x_, &resize_start_y_);
  resize_start_frame_ = frame_;
  resizing_ = true;
}

gboolean CardOverlay::OnWindowMotion(GtkWidget*, GdkEventMotion* event,
                                     gpointer data) {
  auto* self = static_cast<CardOverlay*>(data);
  if (!self->resizing_) {
    return FALSE;
  }
  Frame frame = self->resize_start_frame_;
  frame.width = std::max(120.0, frame.width + event->x_root -
                                    self->resize_start_x_);
  frame.height = std::max(80.0, frame.height + event->y_root -
                                    self->resize_start_y_);
  self->MoveResize(frame);
  return TRUE;
}

gboolean CardOverlay::OnWindowRelease(GtkWidget*, GdkEventButton*,
                                      gpointer data) {
  auto* self = static_cast<CardOverlay*>(data);
  if (!self->resizing_) {
    return FALSE;
  }
  self->EndResizeTracking(true);
  return TRUE;
}

gboolean CardOverlay::OnStagePress(GtkWidget*, GdkEventButton* event,
                                   gpointer data) {
  auto* self = static_cast<CardOverlay*>(data);
  if (!self->visible_ || self->resizing_) {
    return FALSE;
  }
  const Frame& f = self->frame_;
  const bool inside = event->x_root >= f.x && event->x_root < f.x + f.width &&
                      event->y_root >= f.y && event->y_root < f.y + f.height;
  if (inside) {
    return FALSE;
  }
  self->Hide(true);
  return TRUE;
}

gboolean CardOverlay::OnWindowGrabBroken(GtkWidget*, GdkEvent*,
                                         gpointer data) {
  auto* self = static_cast<CardOverlay*>(data);
  if (self->resizing_) {
    self->EndResizeTracking(true);
  }
  return FALSE;
}

// Ends the drag; |report| mirrors WM_EXITSIZEMOVE: endLiveResize first, then
// windowMoved [left, top, w, h, startW, startH] in physical px for Dart to
// persist the card size.
void CardOverlay::EndResizeTracking(bool report) {
  if (!resizing_) {
    return;
  }
  resizing_ = false;
  GdkDevice* pointer = Pointer();
  if (pointer != nullptr) {
    gdk_seat_ungrab(gdk_device_get_seat(pointer));
  }
  if (!report) {
    return;
  }
  Evaluate("window.__globalLookupHost && window.__globalLookupHost.endLiveResize();");
  const double s = anchor_scale_;
  gchar* body = g_strdup_printf(
      "{\"handler\":\"windowMoved\",\"args\":[%d,%d,%d,%d,%d,%d]}",
      Round(frame_.x * s), Round(frame_.y * s), Round(frame_.width * s),
      Round(frame_.height * s), Round(resize_start_frame_.width * s),
      Round(resize_start_frame_.height * s));
  emit_("jsMessage", RoutedPayload(body, route_));
  g_free(body);
}

// ---- JS execution ----

void CardOverlay::Evaluate(const std::string& script) {
  if (web_view_ == nullptr) {
    return;
  }
  webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(web_view_),
                                      script.c_str(),
                                      static_cast<gssize>(script.size()),
                                      nullptr, nullptr, nullptr, nullptr,
                                      nullptr);
}

// |script| is the COMPLETE render script built in Dart (settings +
// lookupEntries + renderPopup). Held until the host document finished loading
// (renderPopup must exist): last wins, like pending_json_.
void CardOverlay::Render(const std::string& script) {
  last_script_ = script;
  if (recovering_ || !web_view_ready_ || web_view_ == nullptr) {
    pending_script_ = script;
    has_pending_script_ = true;
    return;
  }
  Evaluate(script);
}

void CardOverlay::DispatchGamepadAction(const std::string& action, double dy) {
  static const std::set<std::string> allowed = {"next", "prev", "mine",
                                                "audio", "scroll"};
  if (!web_view_ready_ || recovering_ || allowed.count(action) == 0) {
    return;
  }
  gchar* script = g_strdup_printf(
      "window.__globalLookupHost && "
      "window.__globalLookupHost.gamepadAction('%s', %.3f);",
      action.c_str(), dy);
  Evaluate(script);
  g_free(script);
}

// |js_value| is a ready JS string literal (Dart double-encodes it); the adapter
// JSON.parses it. Spliced verbatim like the Windows runner.
void CardOverlay::ResolveBridge(int64_t id, const std::string& js_value) {
  Evaluate("window.__fushiBridgeResolve && window.__fushiBridgeResolve(" +
           std::to_string(id) + ", " + js_value + ");");
}

// TODO-1268 parity: rebuild a dead content process in place, replaying the
// last render once the host document has reloaded.
void CardOverlay::RecoverDeadWebView() {
  if (!has_pending_script_ && (visible_ || measuring_) &&
      !last_script_.empty()) {
    pending_script_ = last_script_;
    has_pending_script_ = true;
  }
  web_view_ready_ = false;
  latest_geometry_epoch_ = 0;
  if (recovering_) {
    return;
  }
  recovering_ = true;
  ReportError("overlay web content process died; reloading host document");
  LoadHostDocument();
}

void CardOverlay::ReportError(const std::string& message) {
  NativeLog("ERROR: " + message);
  emit_("nativeError", StringNode(message));
}

void CardOverlay::OnLoadChanged(WebKitWebView*, WebKitLoadEvent event,
                                gpointer data) {
  auto* self = static_cast<CardOverlay*>(data);
  if (event == WEBKIT_LOAD_COMMITTED) {
    // A new top-level document starts unlocked; a merely started navigation
    // does not unlock (it can still be cancelled while the locked page lives).
    self->bridge_lock_token_.clear();
  } else if (event == WEBKIT_LOAD_FINISHED) {
    self->web_view_ready_ = true;
    self->recovering_ = false;
    if (self->has_pending_script_) {
      self->has_pending_script_ = false;
      std::string script = std::move(self->pending_script_);
      self->pending_script_.clear();
      self->Render(script);
    }
  }
}

gboolean CardOverlay::OnLoadFailed(WebKitWebView*, WebKitLoadEvent, gchar* uri,
                                   GError* error, gpointer data) {
  auto* self = static_cast<CardOverlay*>(data);
  self->ReportError(std::string("overlay host navigation failed: ") +
                    (uri != nullptr ? uri : "?") + ": " +
                    (error != nullptr ? error->message : "?"));
  return FALSE;
}

void CardOverlay::OnWebProcessTerminated(WebKitWebView*,
                                         WebKitWebProcessTerminationReason,
                                         gpointer data) {
  static_cast<CardOverlay*>(data)->RecoverDeadWebView();
}

// ---- Script messages (chrome.webview.postMessage stand-in) ----

void CardOverlay::OnScriptMessage(WebKitUserContentManager*,
                                  WebKitJavascriptResult* result,
                                  gpointer data) {
  JSCValue* value = webkit_javascript_result_get_js_value(result);
  if (value == nullptr || !jsc_value_is_string(value)) {
    return;
  }
  gchar* text = jsc_value_to_string(value);
  std::string body = text != nullptr ? text : "";
  g_free(text);
  static_cast<CardOverlay*>(data)->HandleScriptMessage(std::move(body));
}

void CardOverlay::HandleScriptMessage(std::string body) {
  JsonParser* parser = nullptr;
  JsonObject* message = ParseObject(body, &parser);
  if (message == nullptr) {
    return;
  }
  std::unique_ptr<JsonParser, decltype(&g_object_unref)> parser_holder(
      parser, g_object_unref);
  const std::string handler = StringArg(message, "handler", "");
  // Fushi bridge lock: handled natively, never forwarded to Dart.
  if (handler == kBridgeLockHandler) {
    HandleBridgeLockRequest();
    return;
  }
  if (!AuthorizeLockedBridgeMessage(message, &body)) {
    return;
  }
  const RouteContext message_route = RouteForMessage(message);
  if (handler == "shellRects") {
    // Window-region truth for the Win32 HRGN clip. The web view is per-pixel
    // transparent already, so there is nothing to apply (and Windows does not
    // forward it either).
    return;
  }
  if (handler == "beginWindowResize") {
    BeginWindowResize();
    return;
  }
  const bool has_bridge_id = json_object_has_member(message, "__bridgeId");
  const int64_t bridge_id = Int64Arg(message, "__bridgeId", 0);
  emit_("jsMessage", RoutedPayload(body, message_route));
  // Resolve the callHandler promise so popup.js await points never hang;
  // deferred handlers get their real reply via resolveBridge from Dart.
  if (DeferredHandlers().count(handler) == 0 && has_bridge_id) {
    Evaluate("window.__fushiBridgeResolve && window.__fushiBridgeResolve(" +
             std::to_string(bridge_id) + ", null);");
  }
}

// Same contract as global_lookup_window.cpp HandleBridgeLockRequest /
// AuthorizeLockedBridgeMessage. global_lookup_host.js (the top-level host
// document) forwards a popup document's callHandler('_fushiLockBridge'); the
// token goes back ONLY to the host closure via window.__fushiBridgeLockResult,
// and from then on the host stamps it first on every message it posts.
//
// WebKitGTK 4.1 does not say which frame posted a script message, so the
// second gate of Windows / macOS (only the host document's main frame is heard
// once locked) cannot be applied. The token alone still holds: a dictionary's
// sandboxed srcdoc iframe has an opaque origin and can read neither the host
// closure nor the token, and the host locks at document start, before any
// dictionary content is rendered.
void CardOverlay::HandleBridgeLockRequest() {
  std::string token;
  if (!bridge_lock_token_.empty()) {
    NativeLog("[bridge-lock][warn] refused _fushiLockBridge: already locked");
  } else {
    token = GenerateBridgeLockToken();
    if (token.empty()) {
      NativeLog("[bridge-lock][warn] refused _fushiLockBridge: getrandom failed");
    }
    bridge_lock_token_ = token;
  }
  // The token is lower-case hex, safe to splice as a JS string literal.
  const std::string arg = token.empty() ? "false" : "'" + token + "'";
  Evaluate("window.__fushiBridgeLockResult && window.__fushiBridgeLockResult(" +
           arg + ");");
}

// Unlocked: legacy behaviour, byte for byte. Locked: the message must carry
// the token, which the host puts FIRST; it is stripped so Dart never sees it.
bool CardOverlay::AuthorizeLockedBridgeMessage(JsonObject* message,
                                               std::string* body) {
  if (bridge_lock_token_.empty()) {
    return true;
  }
  const std::string token = StringArg(message, kBridgeTokenField, "");
  if (token.empty() || !BridgeTokensEqual(token, bridge_lock_token_)) {
    NativeLog(
        "[bridge-lock][warn] dropped message on locked bridge "
        "(missing/invalid token)");
    return false;
  }
  const std::string prefix =
      std::string("{\"") + kBridgeTokenField + "\":\"" + token + "\"";
  if (body->compare(0, prefix.size(), prefix) == 0 &&
      body->size() > prefix.size()) {
    const char next = (*body)[prefix.size()];
    if (next == ',') {
      *body = "{" + body->substr(prefix.size() + 1);
    } else if (next == '}') {
      *body = "{" + body->substr(prefix.size());
    }
  }
  return true;
}

RouteContext CardOverlay::RouteForMessage(JsonObject* message) const {
  RouteContext route = route_;
  const std::string source = StringArg(message, "__source", "");
  if (source == "desktop" || source == "galCard") {
    route.source = source;
  }
  const int64_t route_epoch = Int64Arg(message, "__routeEpoch", -1);
  if (route_epoch >= 0) {
    route.route_epoch = route_epoch;
  }
  const int64_t lookup_epoch = Int64Arg(message, "__lookupEpoch", -1);
  if (lookup_epoch >= 0) {
    route.lookup_epoch = lookup_epoch;
  }
  return route;
}

// ---- URL schemes ----

void CardOverlay::OnAssetRequest(WebKitURISchemeRequest* request,
                                 gpointer data) {
  static_cast<CardOverlay*>(data)->ServeAsset(request);
}

void CardOverlay::OnMediaRequest(WebKitURISchemeRequest* request,
                                 gpointer data) {
  static_cast<CardOverlay*>(data)->ServeMedia(request);
}

// Serves the popup assets folder at fushi-popup://assets/<file>: the WebKit
// stand-in for WebView2's SetVirtualHostNameToFolderMapping. A custom scheme
// (not file://) so the host document and its popup.html iframes share ONE
// origin.
void CardOverlay::ServeAsset(WebKitURISchemeRequest* request) {
  const char* raw_path = webkit_uri_scheme_request_get_path(request);
  gchar* unescaped =
      raw_path != nullptr ? g_uri_unescape_string(raw_path, nullptr) : nullptr;
  std::string relative = unescaped != nullptr ? unescaped : "";
  g_free(unescaped);
  while (!relative.empty() && relative.front() == '/') {
    relative.erase(0, 1);
  }
  std::string file;
  if (!assets_root_.empty() && !relative.empty()) {
    char* resolved = realpath((assets_root_ + "/" + relative).c_str(), nullptr);
    if (resolved != nullptr) {
      file = resolved;
      free(resolved);
    }
  }
  // Never serve outside the assets folder (the URL is page-controlled).
  gchar* contents = nullptr;
  gsize length = 0;
  if (file.compare(0, assets_root_.size() + 1, assets_root_ + "/") != 0 ||
      !g_file_get_contents(file.c_str(), &contents, &length, nullptr)) {
    FinishRequest(request, 404, "text/plain", nullptr);
    return;
  }
  GBytes* bytes = g_bytes_new_take(contents, length);
  FinishRequest(request, 200, AssetContentType(LowerExtension(file)), bytes);
  g_bytes_unref(bytes);
}

// image:// (gaiji / <img>) and dictmedia:// (dictionary <link> stylesheets and
// their fonts): routed to the main Dart engine over the channel's reverse
// `getMedia` call, like the Windows WebResourceRequested handler.
void CardOverlay::ServeMedia(WebKitURISchemeRequest* request) {
  const char* uri = webkit_uri_scheme_request_get_uri(request);
  const char* scheme = webkit_uri_scheme_request_get_scheme(request);
  const char* path = webkit_uri_scheme_request_get_path(request);
  const char* content_type = MediaContentType(scheme != nullptr ? scheme : "",
                                              path != nullptr ? path : "");
  g_object_ref(request);
  request_media_(uri != nullptr ? uri : "",
                 [request, content_type](GBytes* data) {
                   const bool found =
                       data != nullptr && g_bytes_get_size(data) > 0;
                   FinishRequest(request, found ? 200 : 404, content_type,
                                 found ? data : nullptr);
                   g_object_unref(request);
                 });
}

}  // namespace fushi::lookup_card
