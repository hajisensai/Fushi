#include "floating_lyric_window.h"

#include <dlfcn.h>
#include <fontconfig/fontconfig.h>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <algorithm>
#include <cmath>

namespace {

// Geometry (logical px; same values as macOS FushiFloatingLyric.swift, which
// mirrors the Windows dip constants).
constexpr double kStripWidth = 720;
constexpr double kStripHeight = 130;
// Narrowest window the six-slot toolbar fits in (Windows
// kHookTextMinStripWidthDip).
constexpr double kMinWidth = 376;
constexpr double kMinHeight = 64;
constexpr double kMaxWidth = 2400;
constexpr double kMaxHeight = 480;
constexpr double kBottomGap = 48;
// Dragging / restoring keeps at least this much of the window in the work area
// (Windows kMinVisibleMarginDip).
constexpr double kMinVisibleMargin = 48;
constexpr double kButtonSize = 32;
constexpr double kButtonGap = 4;
constexpr double kControlsTop = 8;
constexpr double kToolbarMargin = 5;
constexpr double kResizeGrip = 18;
constexpr double kDragThreshold = 6;
constexpr double kHighlightRadius = 4;
// Background alpha floor (~2%): a fully transparent background still catches
// clicks (Windows kHookTextMinCatchAlpha).
constexpr uint32_t kMinCatchAlpha = 5;
constexpr double kScrollStep = 40;
constexpr guint kHoverPollMs = 60;
// Families appended after the user's font so Japanese always has glyphs
// (fontconfig falls back further on its own).
constexpr const char* kFallbackFamilies = "Noto Sans CJK JP, Noto Sans JP, Sans";

// ── wlr-layer-shell through libgtk-layer-shell, loaded at runtime ───────────

// Enum values from gtk-layer-shell.h (stable ABI since 0.1).
constexpr int kLayerBottom = 1;
constexpr int kLayerOverlay = 3;
constexpr int kEdgeLeft = 0;
constexpr int kEdgeTop = 2;
constexpr int kKeyboardModeNone = 0;

struct LayerShellApi {
  gboolean (*is_supported)() = nullptr;
  void (*init_for_window)(GtkWindow*) = nullptr;
  void (*set_namespace)(GtkWindow*, const char*) = nullptr;
  void (*set_layer)(GtkWindow*, int) = nullptr;
  void (*set_anchor)(GtkWindow*, int, gboolean) = nullptr;
  void (*set_margin)(GtkWindow*, int, int) = nullptr;
  void (*set_monitor)(GtkWindow*, GdkMonitor*) = nullptr;
  // 0.6+; older releases only have set_keyboard_interactivity.
  void (*set_keyboard_mode)(GtkWindow*, int) = nullptr;
  void (*set_keyboard_interactivity)(GtkWindow*, gboolean) = nullptr;
};

template <typename T>
bool LoadSymbol(void* lib, const char* name, T* out) {
  *out = reinterpret_cast<T>(dlsym(lib, name));
  return *out != nullptr;
}

// nullptr when the library is missing or too old (no gtk_layer_is_supported).
const LayerShellApi* LayerShell() {
  static LayerShellApi api;
  static int state = 0;  // 0 untried, 1 loaded, -1 unavailable
  if (state != 0) return state == 1 ? &api : nullptr;
  state = -1;
  void* lib = dlopen("libgtk-layer-shell.so.0", RTLD_NOW | RTLD_LOCAL);
  if (lib == nullptr) return nullptr;
  bool ok = LoadSymbol(lib, "gtk_layer_is_supported", &api.is_supported) &&
            LoadSymbol(lib, "gtk_layer_init_for_window", &api.init_for_window) &&
            LoadSymbol(lib, "gtk_layer_set_namespace", &api.set_namespace) &&
            LoadSymbol(lib, "gtk_layer_set_layer", &api.set_layer) &&
            LoadSymbol(lib, "gtk_layer_set_anchor", &api.set_anchor) &&
            LoadSymbol(lib, "gtk_layer_set_margin", &api.set_margin) &&
            LoadSymbol(lib, "gtk_layer_set_monitor", &api.set_monitor);
  LoadSymbol(lib, "gtk_layer_set_keyboard_mode", &api.set_keyboard_mode);
  LoadSymbol(lib, "gtk_layer_set_keyboard_interactivity",
             &api.set_keyboard_interactivity);
  if (!ok) return nullptr;
  state = 1;
  return &api;
}

FloatingLyricWindow::Backend DetectBackend() {
  GdkDisplay* display = gdk_display_get_default();
#ifdef GDK_WINDOWING_X11
  if (display != nullptr && GDK_IS_X11_DISPLAY(display)) {
    return FloatingLyricWindow::Backend::kX11;
  }
#endif
  (void)display;
  const LayerShellApi* api = LayerShell();
  if (api != nullptr && api->is_supported()) {
    return FloatingLyricWindow::Backend::kLayerShell;
  }
  return FloatingLyricWindow::Backend::kWaylandToplevel;
}

// ── colours / paths ──────────────────────────────────────────────────────────

void SetSource(cairo_t* cr, uint32_t argb) {
  cairo_set_source_rgba(cr, ((argb >> 16) & 0xFF) / 255.0,
                        ((argb >> 8) & 0xFF) / 255.0, (argb & 0xFF) / 255.0,
                        ((argb >> 24) & 0xFF) / 255.0);
}

uint32_t ScaleAlpha(uint32_t argb, double factor) {
  const double f = std::clamp(factor, 0.0, 1.0);
  const auto alpha =
      static_cast<uint32_t>(std::lround(((argb >> 24) & 0xFF) * f));
  return (alpha << 24) | (argb & 0x00FFFFFF);
}

void RoundedRect(cairo_t* cr, double x, double y, double w, double h,
                 double r) {
  r = std::max(0.0, std::min(r, std::min(w, h) / 2));
  if (r <= 0) {
    cairo_rectangle(cr, x, y, w, h);
    return;
  }
  cairo_new_sub_path(cr);
  cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
  cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
  cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
  cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
  cairo_close_path(cr);
}

void AddColor(PangoAttrList* list, uint32_t argb, guint start, guint end) {
  if (end <= start) return;
  PangoAttribute* fg = pango_attr_foreground_new(
      static_cast<guint16>(((argb >> 16) & 0xFF) * 257),
      static_cast<guint16>(((argb >> 8) & 0xFF) * 257),
      static_cast<guint16>((argb & 0xFF) * 257));
  fg->start_index = start;
  fg->end_index = end;
  pango_attr_list_insert(list, fg);
  // Pango reads alpha 0 as "unset": the faintest real value instead.
  const auto alpha = static_cast<guint16>(
      std::max<uint32_t>(1, ((argb >> 24) & 0xFF) * 257));
  PangoAttribute* a = pango_attr_foreground_alpha_new(alpha);
  a->start_index = start;
  a->end_index = end;
  pango_attr_list_insert(list, a);
}

struct ToolbarColors {
  uint32_t surface;
  uint32_t icon;
  uint32_t hover;
  uint32_t active_bg;
  uint32_t active_icon;
};

// M3E toolbar colours (Dart galHookToolbarThemeArgs); not sent (toolbar_bg_color
// alpha 0) = the old four colours (Windows ToolbarStyle, macOS toolbarColors).
ToolbarColors ColorsFor(const FloatingLyricWindow::Style& s) {
  if ((s.toolbar_bg_color >> 24) != 0) {
    return {s.toolbar_bg_color, s.toolbar_icon_color, s.toolbar_hover_color,
            s.toolbar_active_bg_color, s.toolbar_active_icon_color};
  }
  uint32_t surface = s.bg_color;
  if ((surface >> 24) < 0xB0) surface = (0xB0u << 24) | (surface & 0x00FFFFFF);
  return {surface, s.button_text_color, s.button_bg_color, s.button_bg_color,
          s.active_color};
}

}  // namespace

// ── statics ──────────────────────────────────────────────────────────────────

const std::vector<std::string>& FloatingLyricWindow::SlotActions() {
  static const std::vector<std::string> actions = {
      "previousCue", "playPause", "nextCue", "lock", "topmost", "close"};
  return actions;
}

const char* FloatingLyricWindow::BackendName(Backend backend) {
  switch (backend) {
    case Backend::kX11:
      return "x11";
    case Backend::kLayerShell:
      return "layer-shell";
    case Backend::kWaylandToplevel:
      return "wayland-toplevel";
  }
  return "unknown";
}

FloatingLyricWindow::FloatingLyricWindow(GtkWindow* main_window)
    : main_window_(main_window), backend_(DetectBackend()) {
  if (main_window_ != nullptr) {
    g_object_add_weak_pointer(G_OBJECT(main_window_),
                              reinterpret_cast<gpointer*>(&main_window_));
  }
}

FloatingLyricWindow::~FloatingLyricWindow() {
  if (hover_timer_ != 0) g_source_remove(hover_timer_);
  if (recreate_idle_ != 0) g_source_remove(recreate_idle_);
  if (monitors_changed_handler_ != 0) {
    g_signal_handler_disconnect(gdk_screen_get_default(),
                                monitors_changed_handler_);
  }
  DestroyWindow();
  g_clear_object(&layout_);
  g_clear_object(&pango_context_);
  g_clear_object(&font_map_);
  if (main_window_ != nullptr) {
    g_object_remove_weak_pointer(G_OBJECT(main_window_),
                                 reinterpret_cast<gpointer*>(&main_window_));
  }
}

// ── window lifetime ──────────────────────────────────────────────────────────

bool FloatingLyricWindow::CreateWindow() {
  const bool popup = backend_ == Backend::kX11 && topmost_;
  GtkWidget* widget =
      gtk_window_new(popup ? GTK_WINDOW_POPUP : GTK_WINDOW_TOPLEVEL);
  if (widget == nullptr) return false;
  GtkWindow* window = GTK_WINDOW(widget);
  gtk_window_set_title(window, "Fushi Floating Lyric");
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_resizable(window, TRUE);
  gtk_window_set_skip_taskbar_hint(window, TRUE);
  gtk_window_set_skip_pager_hint(window, TRUE);
  // Clicking a word must not take focus from the app the user is in.
  gtk_window_set_accept_focus(window, FALSE);
  gtk_window_set_focus_on_map(window, FALSE);
  if (!popup) {
    gtk_window_set_type_hint(window, GDK_WINDOW_TYPE_HINT_UTILITY);
    gtk_window_set_keep_above(window, topmost_);
  }
  if (backend_ == Backend::kLayerShell) {
    const LayerShellApi* api = LayerShell();
    api->init_for_window(window);
    api->set_namespace(window, "fushi-floating-lyric");
    api->set_anchor(window, kEdgeLeft, TRUE);
    api->set_anchor(window, kEdgeTop, TRUE);
    if (api->set_keyboard_mode != nullptr) {
      api->set_keyboard_mode(window, kKeyboardModeNone);
    } else if (api->set_keyboard_interactivity != nullptr) {
      api->set_keyboard_interactivity(window, FALSE);
    }
  }
  gtk_widget_set_app_paintable(widget, TRUE);
  GdkScreen* screen = gtk_widget_get_screen(widget);
  GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
  if (visual != nullptr && gdk_screen_is_composited(screen)) {
    gtk_widget_set_visual(widget, visual);
  }
  gtk_widget_add_events(
      widget, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK |
                  GDK_POINTER_MOTION_MASK | GDK_ENTER_NOTIFY_MASK |
                  GDK_LEAVE_NOTIFY_MASK | GDK_SCROLL_MASK |
                  GDK_SMOOTH_SCROLL_MASK | GDK_STRUCTURE_MASK);
  g_signal_connect(widget, "draw", G_CALLBACK(OnDraw), this);
  g_signal_connect(widget, "button-press-event", G_CALLBACK(OnPress), this);
  g_signal_connect(widget, "button-release-event", G_CALLBACK(OnRelease),
                   this);
  g_signal_connect(widget, "motion-notify-event", G_CALLBACK(OnMotion), this);
  g_signal_connect(widget, "enter-notify-event", G_CALLBACK(OnEnter), this);
  g_signal_connect(widget, "leave-notify-event", G_CALLBACK(OnLeave), this);
  g_signal_connect(widget, "scroll-event", G_CALLBACK(OnScroll), this);
  g_signal_connect(widget, "configure-event", G_CALLBACK(OnConfigure), this);
  gtk_widget_set_has_tooltip(widget, TRUE);
  g_signal_connect(widget, "query-tooltip", G_CALLBACK(OnQueryTooltip), this);
  window_ = widget;
  ApplyLayer();
  ApplySize();
  ApplyPosition();
  UpdateInputShape();
  return true;
}

void FloatingLyricWindow::DestroyWindow() noexcept {
  if (window_ == nullptr) return;
  GtkWidget* widget = window_;
  window_ = nullptr;
  g_signal_handlers_disconnect_by_data(widget, this);
  gtk_widget_destroy(widget);
}

void FloatingLyricWindow::ApplySize() {
  if (window_ == nullptr) return;
  const int w = static_cast<int>(std::lround(width_));
  const int h = static_cast<int>(std::lround(height_));
  // A size request pins popups and layer surfaces to exactly this size (they
  // have no child to size them). Not on a Wayland toplevel: the compositor's
  // interactive resize must be able to shrink it.
  if (backend_ != Backend::kWaylandToplevel) {
    gtk_widget_set_size_request(window_, w, h);
  }
  gtk_window_set_default_size(GTK_WINDOW(window_), w, h);
  gtk_window_resize(GTK_WINDOW(window_), w, h);
}

void FloatingLyricWindow::ApplyPosition() {
  if (window_ == nullptr) return;
  switch (backend_) {
    case Backend::kX11:
      gtk_window_move(GTK_WINDOW(window_), static_cast<int>(std::lround(x_)),
                      static_cast<int>(std::lround(y_)));
      break;
    case Backend::kLayerShell: {
      const LayerShellApi* api = LayerShell();
      Monitor m = MonitorAt(x_ + width_ / 2, y_ + height_ / 2)
                      .value_or(DefaultMonitor());
      if (m.monitor != nullptr) api->set_monitor(GTK_WINDOW(window_), m.monitor);
      api->set_margin(GTK_WINDOW(window_), kEdgeLeft,
                      static_cast<int>(std::lround(x_ - m.geometry.x)));
      api->set_margin(GTK_WINDOW(window_), kEdgeTop,
                      static_cast<int>(std::lround(y_ - m.geometry.y)));
      break;
    }
    case Backend::kWaylandToplevel:
      // The compositor places it.
      break;
  }
}

void FloatingLyricWindow::ApplyLayer() {
  if (window_ == nullptr || backend_ != Backend::kLayerShell) return;
  LayerShell()->set_layer(GTK_WINDOW(window_),
                          topmost_ ? kLayerOverlay : kLayerBottom);
}

void FloatingLyricWindow::UpdateInputShape() {
  if (window_ == nullptr) return;
  if (!pass_through_) {
    gtk_widget_input_shape_combine_region(window_, nullptr);
    return;
  }
  // Pass-through: only the toolbar pill takes the pointer; the text lets
  // clicks through to the window below.
  const Rect tb = ToolbarRect();
  const cairo_rectangle_int_t rect = {
      static_cast<int>(std::floor(tb.x)), static_cast<int>(std::floor(tb.y)),
      static_cast<int>(std::ceil(tb.w)) + 1,
      static_cast<int>(std::ceil(tb.h)) + 1};
  cairo_region_t* region = cairo_region_create_rectangle(&rect);
  gtk_widget_input_shape_combine_region(window_, region);
  cairo_region_destroy(region);
}

// ── geometry ─────────────────────────────────────────────────────────────────

std::vector<FloatingLyricWindow::Monitor> FloatingLyricWindow::Monitors()
    const {
  std::vector<Monitor> out;
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) return out;
  const int n = gdk_display_get_n_monitors(display);
  for (int i = 0; i < n; ++i) {
    GdkMonitor* monitor = gdk_display_get_monitor(display, i);
    if (monitor == nullptr) continue;
    Monitor m;
    m.monitor = monitor;
    gdk_monitor_get_geometry(monitor, &m.geometry);
    gdk_monitor_get_workarea(monitor, &m.workarea);
    m.scale = std::max(1, gdk_monitor_get_scale_factor(monitor));
    out.push_back(m);
  }
  return out;
}

std::optional<FloatingLyricWindow::Monitor> FloatingLyricWindow::MonitorAt(
    double x, double y) const {
  for (const Monitor& m : Monitors()) {
    if (x >= m.geometry.x && y >= m.geometry.y &&
        x < m.geometry.x + m.geometry.width &&
        y < m.geometry.y + m.geometry.height) {
      return m;
    }
  }
  return std::nullopt;
}

FloatingLyricWindow::Monitor FloatingLyricWindow::DefaultMonitor() const {
  GdkDisplay* display = gdk_display_get_default();
  GdkMonitor* wanted = nullptr;
  if (display != nullptr && main_window_ != nullptr) {
    GdkWindow* main = gtk_widget_get_window(GTK_WIDGET(main_window_));
    if (main != nullptr) wanted = gdk_display_get_monitor_at_window(display, main);
  }
  if (wanted == nullptr && display != nullptr) {
    wanted = gdk_display_get_primary_monitor(display);
  }
  const std::vector<Monitor> monitors = Monitors();
  for (const Monitor& m : monitors) {
    if (m.monitor == wanted) return m;
  }
  if (!monitors.empty()) return monitors.front();
  Monitor fallback;
  fallback.geometry = {0, 0, 1280, 800};
  fallback.workarea = fallback.geometry;
  return fallback;
}

void FloatingLyricWindow::ClampSize(double* w, double* h) const {
  *w = std::round(std::clamp(*w, kMinWidth, kMaxWidth));
  *h = std::round(std::clamp(*h, kMinHeight, kMaxHeight));
}

// Every edge keeps at least kMinVisibleMargin (the whole window when it is
// smaller) inside the work area: Windows ClampOriginToWorkArea.
void FloatingLyricWindow::ClampOriginInto(const GdkRectangle& work, double* x,
                                          double* y) const {
  const double mx = std::min(kMinVisibleMargin, width_);
  const double my = std::min(kMinVisibleMargin, height_);
  const double min_x = work.x - (width_ - mx);
  const double max_x = work.x + work.width - mx;
  const double min_y = work.y - (height_ - my);
  const double max_y = work.y + work.height - my;
  *x = min_x > max_x ? min_x : std::clamp(*x, min_x, max_x);
  *y = min_y > max_y ? min_y : std::clamp(*y, min_y, max_y);
}

void FloatingLyricWindow::ClampOriginOnScreen() {
  std::optional<Monitor> m = MonitorAt(x_ + width_ / 2, y_ + height_ / 2);
  if (!m) {
    // Off every monitor (unplugged): bottom centre of the default one.
    const Monitor d = DefaultMonitor();
    x_ = std::round(d.workarea.x + (d.workarea.width - width_) / 2);
    y_ = d.workarea.y + d.workarea.height - height_ - kBottomGap;
    return;
  }
  ClampOriginInto(m->workarea, &x_, &y_);
}

// Physical px encoding (same idea as macOS FloatingLyricScreenSpace): size =
// logical x the monitor's scale; origin = monitor origin x k + offset inside the
// monitor x its scale, k = the largest scale. With one scale (always on X11,
// where GDK scales every monitor alike) that is plain logical x scale; with
// mixed scales (Wayland) it keeps the monitors' physical ranges disjoint so a
// stored rect decodes back to the right monitor.
FloatingLyricWindow::PhysicalRect FloatingLyricWindow::ToPhysical() const {
  const std::vector<Monitor> monitors = Monitors();
  int k = 1;
  for (const Monitor& m : monitors) k = std::max(k, m.scale);
  const Monitor m =
      MonitorAt(x_ + width_ / 2, y_ + height_ / 2).value_or(DefaultMonitor());
  const double s = m.scale;
  return PhysicalRect{
      static_cast<int>(
          std::lround(m.geometry.x * k + (x_ - m.geometry.x) * s)),
      static_cast<int>(
          std::lround(m.geometry.y * k + (y_ - m.geometry.y) * s)),
      static_cast<int>(std::lround(width_ * s)),
      static_cast<int>(std::lround(height_ * s))};
}

bool FloatingLyricWindow::FromPhysical(const PhysicalRect& p, double* x,
                                       double* y, double* w,
                                       double* h) const {
  if (p.width <= 0 || p.height <= 0) return false;
  const std::vector<Monitor> monitors = Monitors();
  int k = 1;
  for (const Monitor& m : monitors) k = std::max(k, m.scale);
  const double cx = p.left + p.width / 2.0;
  const double cy = p.top + p.height / 2.0;
  for (const Monitor& m : monitors) {
    const double s = m.scale;
    const double rx = m.geometry.x * static_cast<double>(k);
    const double ry = m.geometry.y * static_cast<double>(k);
    if (cx >= rx && cy >= ry && cx < rx + m.geometry.width * s &&
        cy < ry + m.geometry.height * s) {
      *x = m.geometry.x + (p.left - rx) / s;
      *y = m.geometry.y + (p.top - ry) / s;
      *w = p.width / s;
      *h = p.height / s;
      return true;
    }
  }
  return false;
}

void FloatingLyricWindow::NotifyBounds() {
  if (!KnowsPosition() || !on_bounds_) return;
  on_bounds_(ToPhysical());
}

void FloatingLyricWindow::RelayoutForScreenChange() {
  if (!visible_ || window_ == nullptr) return;
  CancelPress();
  const double old_x = x_;
  const double old_y = y_;
  if (KnowsPosition()) {
    ClampOriginOnScreen();
    if (old_x != x_ || old_y != y_) {
      ApplyPosition();
      NotifyBounds();
    }
  }
  layout_dirty_ = true;
  Redraw();
}

// A width from the settings (> 0) resizes the window, keeping its top-left
// corner, then clamps it back on screen (Windows ApplyStyleWidth).
void FloatingLyricWindow::ApplyStyleWidth() {
  if (window_ == nullptr || !placed_ || style_.window_width <= 0) return;
  const double target = std::clamp(style_.window_width, kMinWidth, kMaxWidth);
  if (std::fabs(width_ - target) < 0.5) return;
  width_ = target;
  if (KnowsPosition()) ClampOriginOnScreen();
  ApplySize();
  ApplyPosition();
  UpdateInputShape();
}

// ── lifecycle ────────────────────────────────────────────────────────────────

bool FloatingLyricWindow::Show(const ShowOptions& options) {
  if (options.slot_tooltips) slot_tooltips_ = *options.slot_tooltips;
  style_ = options.style;
  layout_dirty_ = true;
  click_lookup_enabled_ = options.click_lookup_enabled;
  hover_auto_lookup_ = options.hover_auto_lookup;
  if (options.locked) SetLocked(*options.locked);
  // Topmost and pass-through reset per session (as on Windows / macOS).
  const bool was_topmost = topmost_;
  topmost_ = options.topmost;
  if (window_ != nullptr && backend_ == Backend::kX11 &&
      was_topmost != topmost_) {
    DestroyWindow();
  } else if (window_ != nullptr) {
    ApplyLayer();
    if (backend_ != Backend::kX11) {
      gtk_window_set_keep_above(GTK_WINDOW(window_), topmost_);
    }
  }

  double x = 0, y = 0, w = 0, h = 0;
  if (options.rect && KnowsPosition() &&
      FromPhysical(*options.rect, &x, &y, &w, &h)) {
    // A stored width narrower than today's toolbar is raised to the minimum.
    ClampSize(&w, &h);
    width_ = w;
    height_ = h;
    x_ = x;
    y_ = y;
    ClampOriginOnScreen();
  } else if (placed_) {
    // Shown before: in place, only clamped back on screen.
    if (KnowsPosition()) ClampOriginOnScreen();
  } else {
    // First time, or the remembered monitor is gone: bottom centre of the
    // main window's monitor.
    const Monitor m = DefaultMonitor();
    w = style_.window_width > 0 ? style_.window_width : kStripWidth;
    h = style_.window_height > 0 ? style_.window_height : kStripHeight;
    if (options.rect && options.rect->width > 0 && options.rect->height > 0) {
      w = options.rect->width / static_cast<double>(m.scale);
      h = options.rect->height / static_cast<double>(m.scale);
    }
    ClampSize(&w, &h);
    width_ = w;
    height_ = h;
    x_ = std::round(m.workarea.x + (m.workarea.width - w) / 2);
    y_ = m.workarea.y + m.workarea.height - h - kBottomGap;
  }
  placed_ = true;

  if (window_ == nullptr && !CreateWindow()) return false;
  ApplySize();
  ApplyPosition();
  gtk_widget_show(window_);
  visible_ = true;
  hovered_ = false;
  hovered_slot_ = -1;
  hover_lookup_index_ = -1;
  layout_dirty_ = true;

  // Pass-through is applied silently (Dart asked for it); only a refusal is
  // reported.
  if (options.pass_through && backend_ == Backend::kWaylandToplevel) {
    pass_through_ = false;
    if (on_pass_through_) on_pass_through_(false);
  } else {
    pass_through_ = options.pass_through;
  }
  CancelPress();
  UpdateInputShape();
  UpdateHoverTimer();

  if (monitors_changed_handler_ == 0) {
    monitors_changed_handler_ =
        g_signal_connect(gdk_screen_get_default(), "monitors-changed",
                         G_CALLBACK(OnMonitorsChanged), this);
  }
  Redraw();
  return gtk_widget_get_visible(window_);
}

void FloatingLyricWindow::Hide() {
  visible_ = false;
  CancelPress();
  hovered_ = false;
  hovered_slot_ = -1;
  hover_lookup_index_ = -1;
  UpdateHoverTimer();
  if (window_ != nullptr) gtk_widget_hide(window_);
}

bool FloatingLyricWindow::IsShowing() const {
  return visible_ && window_ != nullptr && gtk_widget_get_visible(window_);
}

// ── state ────────────────────────────────────────────────────────────────────

void FloatingLyricWindow::UpdateText(const std::string& text,
                                     int current_line_start,
                                     int current_line_length,
                                     const std::string& line_id) {
  if (g_utf8_validate(text.data(), static_cast<gssize>(text.size()),
                      nullptr)) {
    text_ = text;
  } else {
    gchar* valid =
        g_utf8_make_valid(text.data(), static_cast<gssize>(text.size()));
    text_ = valid;
    g_free(valid);
  }
  // UTF-16 (Dart's indices) <-> UTF-8 bytes (Pango's).
  u16_to_byte_.clear();
  byte_to_u16_.assign(text_.size() + 1, 0);
  int u16 = 0;
  const char* begin = text_.c_str();
  const char* end = begin + text_.size();
  for (const char* p = begin; p < end; p = g_utf8_next_char(p)) {
    const int byte = static_cast<int>(p - begin);
    const char* next = g_utf8_next_char(p);
    for (const char* q = p; q < next && q < end; ++q) {
      byte_to_u16_[q - begin] = u16;
    }
    const gunichar c = g_utf8_get_char(p);
    u16_to_byte_.push_back(byte);
    if (c >= 0x10000) {
      u16_to_byte_.push_back(byte);
      u16 += 2;
    } else {
      u16 += 1;
    }
  }
  u16_to_byte_.push_back(static_cast<int>(text_.size()));
  byte_to_u16_[text_.size()] = u16;

  current_line_start_ = current_line_start;
  current_line_length_ = current_line_length;
  line_id_ = line_id;
  follow_current_line_ = current_line_start >= 0 && current_line_length > 0;
  highlight_start_ = -1;
  highlight_length_ = 0;
  // A whole new block, not appended: back to the top (following then scrolls
  // the current line to the middle).
  scroll_offset_ = 0;
  hover_lookup_index_ = -1;
  layout_dirty_ = true;
  Redraw();
}

void FloatingLyricWindow::Highlight(int start, int length) {
  highlight_start_ = start;
  highlight_length_ = length;
  Redraw();
}

void FloatingLyricWindow::UpdateStyle(const Style& style) {
  style_ = style;
  layout_dirty_ = true;
  ApplyStyleWidth();
  Redraw();
}

void FloatingLyricWindow::UpdateLabels(
    const std::map<std::string, std::string>& labels) {
  for (const auto& [key, value] : labels) labels_[key] = value;
}

void FloatingLyricWindow::SetPlaying(bool playing) {
  playing_ = playing;
  Redraw();
}

void FloatingLyricWindow::SetLocked(bool locked) {
  if (locked_ == locked) return;
  locked_ = locked;
  // A drag / resize in progress is dropped; the next press decides afresh.
  if (locked_) CancelPress();
  Redraw();
}

void FloatingLyricWindow::SetPassThrough(bool enabled) {
  if (enabled && backend_ == Backend::kWaylandToplevel) {
    // No input region on a window we cannot keep on top or put back: refuse,
    // and tell Dart (Windows BUG-951 contract).
    pass_through_ = false;
    UpdateInputShape();
    if (on_pass_through_) on_pass_through_(false);
    return;
  }
  if (pass_through_ == enabled) return;
  pass_through_ = enabled;
  CancelPress();
  // A pass-through body gets no leave event: clear hover here.
  hovered_ = false;
  hover_lookup_index_ = -1;
  UpdateInputShape();
  UpdateHoverTimer();
  if (on_pass_through_) on_pass_through_(enabled);
  Redraw();
}

void FloatingLyricWindow::SetHoverAutoLookup(bool enabled) {
  hover_auto_lookup_ = enabled;
  hover_lookup_index_ = -1;
}

void FloatingLyricWindow::SetTopmost(bool topmost) {
  topmost_ = topmost;
  switch (backend_) {
    case Backend::kX11:
      // Popup <-> managed window: rebuilt off the signal handler that asked.
      if (window_ != nullptr && recreate_idle_ == 0) {
        recreate_idle_ = g_idle_add(OnRecreateIdle, this);
      }
      break;
    case Backend::kLayerShell:
      ApplyLayer();
      break;
    case Backend::kWaylandToplevel:
      // A request only; GTK 3 on Wayland cannot keep a window on top.
      if (window_ != nullptr) {
        gtk_window_set_keep_above(GTK_WINDOW(window_), topmost_);
      }
      break;
  }
  Redraw();
}

gboolean FloatingLyricWindow::OnRecreateIdle(gpointer data) {
  auto* self = static_cast<FloatingLyricWindow*>(data);
  self->recreate_idle_ = 0;
  const bool popup_wanted = self->topmost_;
  const bool is_popup =
      self->window_ != nullptr &&
      gtk_window_get_window_type(GTK_WINDOW(self->window_)) == GTK_WINDOW_POPUP;
  if (self->window_ == nullptr || popup_wanted == is_popup) {
    return G_SOURCE_REMOVE;
  }
  const bool was_visible = self->visible_;
  self->CancelPress();
  self->DestroyWindow();
  if (!self->CreateWindow()) {
    self->visible_ = false;
    return G_SOURCE_REMOVE;
  }
  if (was_visible) gtk_widget_show(self->window_);
  self->UpdateHoverTimer();
  return G_SOURCE_REMOVE;
}

// ── layout ───────────────────────────────────────────────────────────────────

FloatingLyricWindow::Rect FloatingLyricWindow::TextRect() const {
  const double pad = std::clamp(style_.text_padding, 0.0, 120.0);
  const double controls = kButtonSize + kControlsTop;
  return Rect{pad, controls, std::max(1.0, width_ - pad * 2),
              std::max(1.0, height_ - controls - pad * 0.5)};
}

FloatingLyricWindow::Rect FloatingLyricWindow::ToolbarRect() const {
  const double n = static_cast<double>(SlotActions().size());
  const double w = n * kButtonSize + (n - 1) * kButtonGap + 2 * kToolbarMargin;
  const double h = kButtonSize + 2 * kToolbarMargin;
  return Rect{std::round((width_ - w) / 2), kControlsTop - kToolbarMargin, w,
              h};
}

FloatingLyricWindow::Rect FloatingLyricWindow::SlotRect(int slot) const {
  const Rect tb = ToolbarRect();
  return Rect{tb.x + kToolbarMargin + slot * (kButtonSize + kButtonGap),
              tb.y + kToolbarMargin, kButtonSize, kButtonSize};
}

int FloatingLyricWindow::SlotAt(double x, double y) const {
  for (int i = 0; i < static_cast<int>(SlotActions().size()); ++i) {
    if (SlotRect(i).Contains(x, y)) return i;
  }
  return -1;
}

void FloatingLyricWindow::EnsureFontMap() {
  // A font file from the font library: registered with fontconfig and a fresh
  // font map built (an existing map does not see fonts added later).
  if (!style_.font_path.empty() && style_.font_path != font_map_path_) {
    font_map_path_ = style_.font_path;
    loaded_family_.clear();
    const auto* file = reinterpret_cast<const FcChar8*>(font_map_path_.c_str());
    if (FcConfigAppFontAddFile(FcConfigGetCurrent(), file)) {
      int count = 0;
      FcPattern* pattern = FcFreeTypeQuery(file, 0, nullptr, &count);
      FcChar8* family = nullptr;
      if (pattern != nullptr &&
          FcPatternGetString(pattern, FC_FAMILY, 0, &family) == FcResultMatch) {
        loaded_family_ = reinterpret_cast<const char*>(family);
      }
      if (pattern != nullptr) FcPatternDestroy(pattern);
      g_clear_object(&layout_);
      g_clear_object(&pango_context_);
      g_clear_object(&font_map_);
    } else {
      g_warning("floating lyric: cannot load font %s", font_map_path_.c_str());
    }
  }
  if (font_map_ == nullptr) font_map_ = pango_cairo_font_map_new();
  if (pango_context_ == nullptr) {
    pango_context_ = pango_font_map_create_context(font_map_);
    pango_cairo_context_set_resolution(pango_context_, 96.0);
  }
  if (layout_ == nullptr) layout_ = pango_layout_new(pango_context_);
}

void FloatingLyricWindow::EnsureLayout(double width) {
  if (!layout_dirty_ && std::fabs(width - layout_width_) < 0.5 &&
      layout_ != nullptr) {
    return;
  }
  EnsureFontMap();
  layout_dirty_ = false;
  layout_width_ = width;
  pango_layout_set_text(layout_, text_.c_str(),
                        static_cast<int>(text_.size()));

  std::string families = !style_.font_family.empty() ? style_.font_family
                                                      : loaded_family_;
  families = families.empty() ? kFallbackFamilies
                              : families + ", " + kFallbackFamilies;
  PangoFontDescription* desc = pango_font_description_new();
  pango_font_description_set_family(desc, families.c_str());
  pango_font_description_set_weight(
      desc, style_.bold ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
  pango_font_description_set_absolute_size(
      desc, std::max(4.0, style_.font_size) * PANGO_SCALE);
  pango_layout_set_font_description(layout_, desc);
  pango_font_description_free(desc);

  pango_layout_set_width(layout_,
                         static_cast<int>(std::max(1.0, width) * PANGO_SCALE));
  pango_layout_set_wrap(layout_, PANGO_WRAP_WORD_CHAR);
  pango_layout_set_alignment(layout_, style_.text_alignment == 1
                                          ? PANGO_ALIGN_LEFT
                                          : PANGO_ALIGN_CENTER);
  const double line_height = std::clamp(style_.line_height, 0.8, 2.0);
  pango_layout_set_line_spacing(
      layout_, std::fabs(line_height - 1.0) < 0.01
                   ? 0.0f
                   : static_cast<float>(line_height));

  PangoAttrList* attrs = pango_attr_list_new();
  const double spacing = std::clamp(style_.letter_spacing, -5.0, 20.0);
  if (std::fabs(spacing) > 0.01) {
    pango_attr_list_insert(attrs, pango_attr_letter_spacing_new(static_cast<int>(
                                      spacing * PANGO_SCALE)));
  }
  // Fill: the current line in full colour (or current_line_color), the rest
  // dimmed to context_line_opacity.
  const auto length = static_cast<guint>(text_.size());
  AddColor(attrs, style_.text_color, 0, length);
  if (auto current = CurrentLineBytes()) {
    const uint32_t dim =
        ScaleAlpha(style_.text_color, style_.context_line_opacity);
    AddColor(attrs, dim, 0, static_cast<guint>(current->first));
    AddColor(attrs, dim, static_cast<guint>(current->second), length);
    if ((style_.current_line_color >> 24) != 0) {
      AddColor(attrs, style_.current_line_color,
               static_cast<guint>(current->first),
               static_cast<guint>(current->second));
    }
  }
  pango_layout_set_attributes(layout_, attrs);
  pango_attr_list_unref(attrs);

  PangoRectangle logical;
  pango_layout_get_pixel_extents(layout_, nullptr, &logical);
  content_height_ = logical.height;
}

std::optional<std::pair<int, int>> FloatingLyricWindow::CurrentLineBytes()
    const {
  const int n16 = static_cast<int>(u16_to_byte_.size()) - 1;
  if (current_line_start_ < 0 || current_line_length_ <= 0 || n16 <= 0) {
    return std::nullopt;
  }
  const int start = std::min(current_line_start_, n16);
  const int end = std::min(current_line_start_ + current_line_length_, n16);
  if (end <= start) return std::nullopt;
  return std::make_pair(ByteOf(start), ByteOf(end));
}

int FloatingLyricWindow::ByteOf(int utf16) const {
  if (u16_to_byte_.empty()) return 0;
  const int last = static_cast<int>(u16_to_byte_.size()) - 1;
  return u16_to_byte_[std::clamp(utf16, 0, last)];
}

int FloatingLyricWindow::Utf16Of(int byte) const {
  if (byte_to_u16_.empty()) return 0;
  const int last = static_cast<int>(byte_to_u16_.size()) - 1;
  return byte_to_u16_[std::clamp(byte, 0, last)];
}

bool FloatingLyricWindow::CharBox(int byte, Rect* box) const {
  if (layout_ == nullptr || byte < 0 ||
      byte >= static_cast<int>(text_.size())) {
    return false;
  }
  PangoRectangle pos;
  pango_layout_index_to_pos(layout_, byte, &pos);
  double x = static_cast<double>(pos.x) / PANGO_SCALE;
  double w = static_cast<double>(pos.width) / PANGO_SCALE;
  if (w < 0) {
    x += w;
    w = -w;
  }
  *box = Rect{x, static_cast<double>(pos.y) / PANGO_SCALE, w,
              static_cast<double>(pos.height) / PANGO_SCALE};
  return true;
}

void FloatingLyricWindow::TextOrigin(const Rect& rect, double* ox,
                                     double* oy) {
  scroll_max_ = std::max(0.0, content_height_ - rect.h);
  const bool overflow = scroll_max_ > 0;
  if (overflow && follow_current_line_) {
    if (auto current = CurrentLineBytes()) {
      Rect first, last;
      const char* begin = text_.c_str();
      const int last_byte = static_cast<int>(
          g_utf8_find_prev_char(begin, begin + current->second) - begin);
      if (CharBox(current->first, &first) && CharBox(last_byte, &last)) {
        const double mid = (first.y + last.y + last.h) / 2;
        scroll_offset_ = mid - rect.h / 2;
      }
    }
  }
  scroll_offset_ = std::clamp(scroll_offset_, 0.0, scroll_max_);
  *ox = rect.x;
  *oy = overflow || style_.vertical_alignment == 1
            ? rect.y - scroll_offset_
            : rect.y + (rect.h - content_height_) / 2;
}

bool FloatingLyricWindow::CharHit(double x, double y, int* index, Rect* box) {
  if (text_.empty()) return false;
  const Rect rect = TextRect();
  if (!rect.Contains(x, y)) return false;
  EnsureLayout(rect.w);
  double ox = 0, oy = 0;
  TextOrigin(rect, &ox, &oy);
  const double px = x - ox;
  const double py = y - oy;
  int byte = 0, trailing = 0;
  if (!pango_layout_xy_to_index(layout_, static_cast<int>(px * PANGO_SCALE),
                                static_cast<int>(py * PANGO_SCALE), &byte,
                                &trailing)) {
    return false;
  }
  Rect hit;
  if (!CharBox(byte, &hit) || hit.w <= 0 || !hit.Contains(px, py)) {
    return false;
  }
  const char c = text_[byte];
  if (c == '\n' || c == '\r') return false;
  *index = Utf16Of(byte);
  *box = Rect{hit.x + ox, hit.y + oy, hit.w, hit.h};
  return true;
}

// ── drawing ──────────────────────────────────────────────────────────────────

void FloatingLyricWindow::Draw(cairo_t* cr) {
  cairo_save(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0, 0, 0, 0);
  cairo_paint(cr);
  cairo_restore(cr);

  // Background (alpha floor: a transparent background still catches clicks).
  uint32_t bg = style_.bg_color;
  if ((bg >> 24) < kMinCatchAlpha) bg = (kMinCatchAlpha << 24) | (bg & 0xFFFFFF);
  RoundedRect(cr, 0, 0, width_, height_, style_.corner_radius);
  SetSource(cr, bg);
  cairo_fill(cr);

  const Rect rect = TextRect();
  EnsureLayout(rect.w);
  double ox = 0, oy = 0;
  TextOrigin(rect, &ox, &oy);
  cairo_save(cr);
  cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h);
  cairo_clip(cr);

  // Range highlight (syllable / in-line range; Dart sends it on boundaries).
  const int n16 = static_cast<int>(u16_to_byte_.size()) - 1;
  if (highlight_start_ >= 0 && highlight_length_ > 0 && highlight_start_ < n16) {
    const int start = ByteOf(highlight_start_);
    const int end = ByteOf(std::min(highlight_start_ + highlight_length_, n16));
    std::vector<Rect> boxes;
    const char* begin = text_.c_str();
    for (const char* p = begin + start; p < begin + end;
         p = g_utf8_next_char(p)) {
      if (*p == '\n' || *p == '\r') continue;
      Rect box;
      if (!CharBox(static_cast<int>(p - begin), &box) || box.w <= 0) continue;
      if (!boxes.empty() && std::fabs(boxes.back().y - box.y) < 0.5 &&
          std::fabs(boxes.back().x + boxes.back().w - box.x) < 1.0) {
        boxes.back().w = box.x + box.w - boxes.back().x;
      } else {
        boxes.push_back(box);
      }
    }
    SetSource(cr, style_.highlight_color);
    for (const Rect& b : boxes) {
      RoundedRect(cr, b.x + ox, b.y + oy, b.w, b.h, kHighlightRadius);
      cairo_fill(cr);
    }
  }
  const double outline = std::clamp(style_.outline_width, 0.0, 8.0);
  if (outline > 0 && (style_.outline_color >> 24) != 0) {
    // Stroked on the glyph outline, half of it hidden under the fill: twice
    // the width (macOS strokes 2 x outlineWidth for the same reason).
    cairo_move_to(cr, ox, oy);
    pango_cairo_layout_path(cr, layout_);
    SetSource(cr, style_.outline_color);
    cairo_set_line_width(cr, 2 * outline);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    cairo_stroke(cr);
  }
  cairo_move_to(cr, ox, oy);
  pango_cairo_show_layout(cr, layout_);
  cairo_restore(cr);

  // Resize grip bottom-right (not drawn and not hit when locked).
  if (!locked_ && !pass_through_) {
    SetSource(cr, ScaleAlpha(style_.text_color, hovered_ ? 0.7 : 0.2));
    cairo_set_line_width(cr, 1.5);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    for (int i = 1; i <= 3; ++i) {
      const double d = i * 4.0;
      cairo_move_to(cr, width_ - 4 - d, height_ - 4);
      cairo_line_to(cr, width_ - 4, height_ - 4 - d);
    }
    cairo_stroke(cr);
  }
  if (ToolbarVisible()) DrawToolbar(cr);
}

void FloatingLyricWindow::DrawToolbar(cairo_t* cr) {
  const ToolbarColors colors = ColorsFor(style_);
  const Rect tb = ToolbarRect();
  RoundedRect(cr, tb.x, tb.y, tb.w, tb.h, tb.h / 2);
  SetSource(cr, colors.surface);
  cairo_fill(cr);
  const auto& actions = SlotActions();
  for (int slot = 0; slot < static_cast<int>(actions.size()); ++slot) {
    const Rect r = SlotRect(slot);
    const bool active = (actions[slot] == "lock" && locked_) ||
                        (actions[slot] == "topmost" && topmost_);
    if (active || slot == hovered_slot_) {
      RoundedRect(cr, r.x, r.y, r.w, r.h, r.w / 2);
      SetSource(cr, active ? colors.active_bg : colors.hover);
      cairo_fill(cr);
    }
    SetSource(cr, active ? colors.active_icon : colors.icon);
    DrawIcon(cr, actions[slot], r.x + r.w / 2, r.y + r.h / 2);
  }
}

// Plain vector glyphs (no icon theme dependency); current source colour.
void FloatingLyricWindow::DrawIcon(cairo_t* cr, const std::string& action,
                                   double cx, double cy) {
  cairo_save(cr);
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
  cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
  if (action == "previousCue" || action == "nextCue") {
    const double dir = action == "nextCue" ? 1 : -1;
    cairo_rectangle(cr, cx + dir * 5 - (dir > 0 ? 0 : 2), cy - 6, 2, 12);
    cairo_fill(cr);
    cairo_move_to(cr, cx - dir * 5, cy - 6);
    cairo_line_to(cr, cx - dir * 5, cy + 6);
    cairo_line_to(cr, cx + dir * 4, cy);
    cairo_close_path(cr);
    cairo_fill(cr);
  } else if (action == "playPause") {
    if (playing_) {
      cairo_rectangle(cr, cx - 5, cy - 6, 3.5, 12);
      cairo_rectangle(cr, cx + 1.5, cy - 6, 3.5, 12);
    } else {
      cairo_move_to(cr, cx - 4, cy - 7);
      cairo_line_to(cr, cx - 4, cy + 7);
      cairo_line_to(cr, cx + 6, cy);
      cairo_close_path(cr);
    }
    cairo_fill(cr);
  } else if (action == "lock") {
    RoundedRect(cr, cx - 6, cy - 1, 12, 8, 1.5);
    cairo_fill(cr);
    cairo_set_line_width(cr, 2);
    if (locked_) {
      cairo_move_to(cr, cx - 4, cy - 1);
      cairo_arc(cr, cx, cy - 4, 4, M_PI, 2 * M_PI);
      cairo_line_to(cr, cx + 4, cy - 1);
    } else {
      cairo_move_to(cr, cx - 4, cy - 3);
      cairo_arc(cr, cx, cy - 6, 4, M_PI, 2 * M_PI);
      cairo_line_to(cr, cx + 4, cy - 1);
    }
    cairo_stroke(cr);
  } else if (action == "topmost") {
    cairo_arc(cr, cx, cy - 3, 4, 0, 2 * M_PI);
    cairo_fill(cr);
    cairo_set_line_width(cr, 2);
    cairo_move_to(cr, cx, cy + 1);
    cairo_line_to(cr, cx, cy + 7);
    cairo_stroke(cr);
    if (!topmost_) {
      cairo_set_line_width(cr, 1.6);
      cairo_move_to(cr, cx - 6, cy + 6);
      cairo_line_to(cr, cx + 6, cy - 6);
      cairo_stroke(cr);
    }
  } else {
    cairo_set_line_width(cr, 2);
    cairo_move_to(cr, cx - 5, cy - 5);
    cairo_line_to(cr, cx + 5, cy + 5);
    cairo_move_to(cr, cx + 5, cy - 5);
    cairo_line_to(cr, cx - 5, cy + 5);
    cairo_stroke(cr);
  }
  cairo_restore(cr);
}

// ── interaction ──────────────────────────────────────────────────────────────

bool FloatingLyricWindow::ToolbarVisible() const {
  return visible_ &&
         (pass_through_ || hovered_ || press_ == Press::kDrag ||
          press_ == Press::kResize || press_ == Press::kToolbarButton ||
          press_ == Press::kToolbarBackground);
}

void FloatingLyricWindow::SetHovered(bool hovered) {
  hovered_ = hovered && !pass_through_;
  if (!hovered) {
    hover_lookup_index_ = -1;
    hovered_slot_ = -1;
  }
  UpdateHoverTimer();
  Redraw();
}

bool FloatingLyricWindow::InResizeGrip(double x, double y) const {
  return !locked_ && x >= width_ - kResizeGrip && y >= height_ - kResizeGrip;
}

void FloatingLyricWindow::PointerDown(double x, double y, double root_x,
                                      double root_y, guint button,
                                      guint32 time) {
  if (button != 1) return;
  press_x_ = x;
  press_y_ = y;
  press_root_x_ = root_x;
  press_root_y_ = root_y;
  press_win_x_ = x_;
  press_win_y_ = y_;
  press_w_ = width_;
  press_h_ = height_;
  press_button_ = button;
  press_time_ = time;
  if (ToolbarVisible() && ToolbarRect().Contains(x, y)) {
    press_slot_ = SlotAt(x, y);
    press_ = press_slot_ >= 0 ? Press::kToolbarButton
                              : Press::kToolbarBackground;
    Redraw();
    return;
  }
  if (pass_through_) return;
  if (InResizeGrip(x, y)) {
    if (backend_ == Backend::kWaylandToplevel) {
      // The compositor resizes it.
      gtk_window_begin_resize_drag(
          GTK_WINDOW(window_), GDK_WINDOW_EDGE_SOUTH_EAST,
          static_cast<gint>(button), static_cast<gint>(std::lround(root_x)),
          static_cast<gint>(std::lround(root_y)), time);
      press_ = Press::kNone;
      return;
    }
    press_ = Press::kResize;
    return;
  }
  press_ = Press::kBody;
}

void FloatingLyricWindow::PointerMoved(double x, double y, double root_x,
                                       double root_y, GdkModifierType state) {
  switch (press_) {
    case Press::kNone: {
      const int slot = ToolbarVisible() ? SlotAt(x, y) : -1;
      if (slot != hovered_slot_) {
        hovered_slot_ = slot;
        Redraw();
      }
      MaybeHoverLookup(x, y, (state & GDK_SHIFT_MASK) != 0);
      return;
    }
    case Press::kResize: {
      // Top-left corner fixed: local coordinates stay valid while resizing.
      double w = press_w_ + (x - press_x_);
      double h = press_h_ + (y - press_y_);
      ClampSize(&w, &h);
      if (w == width_ && h == height_) return;
      width_ = w;
      height_ = h;
      ApplySize();
      layout_dirty_ = true;
      UpdateInputShape();
      Redraw();
      return;
    }
    case Press::kBody:
    case Press::kToolbarBackground:
    case Press::kDrag: {
      if (locked_) return;
      // X11 reports real root coordinates. A layer surface does not know its
      // own position: pointer = window origin (ours) + local point.
      double dx = 0, dy = 0;
      if (backend_ == Backend::kX11) {
        dx = root_x - press_root_x_;
        dy = root_y - press_root_y_;
      } else {
        dx = (x_ + x) - (press_win_x_ + press_x_);
        dy = (y_ + y) - (press_win_y_ + press_y_);
      }
      if (press_ != Press::kDrag) {
        if (std::hypot(dx, dy) < kDragThreshold) return;
        if (backend_ == Backend::kWaylandToplevel) {
          // The compositor moves it (and keeps the pointer grab).
          gtk_window_begin_move_drag(
              GTK_WINDOW(window_), static_cast<gint>(press_button_),
              static_cast<gint>(std::lround(press_root_x_)),
              static_cast<gint>(std::lround(press_root_y_)), press_time_);
          press_ = Press::kNone;
          return;
        }
        press_ = Press::kDrag;
      }
      double nx = press_win_x_ + dx;
      double ny = press_win_y_ + dy;
      // Clamped to the monitor under the pointer: windows cross monitors but
      // never leave the screen (Windows MoveBodyTo).
      const double px = press_win_x_ + press_x_ + dx;
      const double py = press_win_y_ + press_y_ + dy;
      if (auto m = MonitorAt(px, py)) ClampOriginInto(m->workarea, &nx, &ny);
      x_ = nx;
      y_ = ny;
      ApplyPosition();
      return;
    }
    case Press::kToolbarButton:
      return;
  }
}

void FloatingLyricWindow::EndDragOrResize() {
  ClampOriginOnScreen();
  ApplyPosition();
  NotifyBounds();
}

void FloatingLyricWindow::PointerUp(double x, double y) {
  const Press finished = press_;
  press_ = Press::kNone;
  switch (finished) {
    case Press::kDrag:
    case Press::kResize:
      EndDragOrResize();
      break;
    case Press::kBody:
      if (click_lookup_enabled_) DispatchLookup(x, y);
      break;
    case Press::kToolbarButton:
      if (SlotAt(x, y) == press_slot_ && press_slot_ >= 0) {
        DispatchControl(SlotActions()[press_slot_]);
      }
      break;
    case Press::kToolbarBackground:
    case Press::kNone:
      break;
  }
  press_slot_ = -1;
  Redraw();
}

bool FloatingLyricWindow::DispatchLookup(double x, double y) {
  int index = 0;
  Rect box;
  if (!CharHit(x, y, &index, &box)) return false;
  std::optional<WordRect> word;
  if (KnowsPosition()) {
    word = WordRect{x_ + box.x, y_ + box.y, box.w, box.h};
  }
  if (on_lookup_) on_lookup_(text_, line_id_, index, word);
  return true;
}

// Lock / topmost flip natively (lock reports lockChanged); the rest goes to
// Dart (Windows DispatchControlAction).
void FloatingLyricWindow::DispatchControl(const std::string& action) {
  if (action == "lock") {
    SetLocked(!locked_);
    if (on_lock_) on_lock_(locked_);
  } else if (action == "topmost") {
    SetTopmost(!topmost_);
  } else if (on_control_) {
    on_control_(action);
  }
}

// Shift-hover (or "hover to look up"): the same character is not looked up
// twice; no lookup while pressing; pass-through only answers Shift (Windows
// MaybeHoverLookup).
void FloatingLyricWindow::MaybeHoverLookup(double x, double y, bool shift) {
  if (!click_lookup_enabled_ || !visible_ || press_ != Press::kNone) return;
  if ((pass_through_ && !shift) || (!shift && !hover_auto_lookup_)) {
    hover_lookup_index_ = -1;
    return;
  }
  int index = 0;
  Rect box;
  if (!CharHit(x, y, &index, &box)) {
    hover_lookup_index_ = -1;
    return;
  }
  if (index == hover_lookup_index_) return;
  hover_lookup_index_ = index;
  if (!DispatchLookup(x, y)) hover_lookup_index_ = -1;
}

// Polls the pointer while it is over the window (Shift pressed without moving
// sends no event) and, on X11, while passing through (no events at all then).
void FloatingLyricWindow::UpdateHoverTimer() {
  const bool want = visible_ && window_ != nullptr &&
                    (hovered_ || (pass_through_ && backend_ == Backend::kX11));
  if (want && hover_timer_ == 0) {
    hover_timer_ = g_timeout_add(kHoverPollMs, OnHoverTick, this);
  } else if (!want && hover_timer_ != 0) {
    g_source_remove(hover_timer_);
    hover_timer_ = 0;
  }
}

gboolean FloatingLyricWindow::OnHoverTick(gpointer data) {
  auto* self = static_cast<FloatingLyricWindow*>(data);
  if (self->window_ == nullptr) {
    self->hover_timer_ = 0;
    return G_SOURCE_REMOVE;
  }
  GdkWindow* gdk_window = gtk_widget_get_window(self->window_);
  GdkDisplay* display = gdk_display_get_default();
  if (gdk_window == nullptr || display == nullptr) return G_SOURCE_CONTINUE;
  GdkDevice* pointer =
      gdk_seat_get_pointer(gdk_display_get_default_seat(display));
  if (pointer == nullptr) return G_SOURCE_CONTINUE;
  double x = 0, y = 0;
  GdkModifierType mask = static_cast<GdkModifierType>(0);
  gdk_window_get_device_position_double(gdk_window, pointer, &x, &y, &mask);
  const bool inside =
      x >= 0 && y >= 0 && x < self->width_ && y < self->height_;
  if (!inside) {
    self->hover_lookup_index_ = -1;
    if (!self->pass_through_ && self->hovered_) self->SetHovered(false);
    return G_SOURCE_CONTINUE;
  }
  self->MaybeHoverLookup(x, y, (mask & GDK_SHIFT_MASK) != 0);
  return G_SOURCE_CONTINUE;
}

void FloatingLyricWindow::ScrollBy(double delta) {
  if (scroll_max_ <= 0) return;
  follow_current_line_ = false;
  scroll_offset_ = std::clamp(scroll_offset_ + delta, 0.0, scroll_max_);
  hover_lookup_index_ = -1;
  Redraw();
}

std::string FloatingLyricWindow::TooltipFor(int slot) const {
  const auto& actions = SlotActions();
  if (slot < 0 || slot >= static_cast<int>(actions.size())) return {};
  if (slot < static_cast<int>(slot_tooltips_.size()) &&
      !slot_tooltips_[slot].empty()) {
    return slot_tooltips_[slot];
  }
  auto label = [this](const char* key) -> std::string {
    auto it = labels_.find(key);
    return it == labels_.end() ? std::string() : it->second;
  };
  const std::string& action = actions[slot];
  if (action == "previousCue") return label("previous");
  if (action == "playPause") return label("playPause");
  if (action == "nextCue") return label("next");
  if (action == "lock") return label(locked_ ? "unlock" : "lock");
  if (action == "close") return label("close");
  return {};
}

void FloatingLyricWindow::Redraw() {
  if (window_ != nullptr) gtk_widget_queue_draw(window_);
}

// ── GTK signal trampolines ───────────────────────────────────────────────────

gboolean FloatingLyricWindow::OnDraw(GtkWidget*, cairo_t* cr, gpointer data) {
  static_cast<FloatingLyricWindow*>(data)->Draw(cr);
  return TRUE;
}

gboolean FloatingLyricWindow::OnPress(GtkWidget*, GdkEventButton* e,
                                      gpointer data) {
  if (e->type != GDK_BUTTON_PRESS) return TRUE;
  static_cast<FloatingLyricWindow*>(data)->PointerDown(
      e->x, e->y, e->x_root, e->y_root, e->button, e->time);
  return TRUE;
}

gboolean FloatingLyricWindow::OnRelease(GtkWidget*, GdkEventButton* e,
                                        gpointer data) {
  if (e->button != 1) return TRUE;
  static_cast<FloatingLyricWindow*>(data)->PointerUp(e->x, e->y);
  return TRUE;
}

gboolean FloatingLyricWindow::OnMotion(GtkWidget*, GdkEventMotion* e,
                                       gpointer data) {
  auto* self = static_cast<FloatingLyricWindow*>(data);
  if (!self->hovered_ && !self->pass_through_) self->SetHovered(true);
  self->PointerMoved(e->x, e->y, e->x_root, e->y_root,
                     static_cast<GdkModifierType>(e->state));
  return TRUE;
}

gboolean FloatingLyricWindow::OnEnter(GtkWidget*, GdkEventCrossing*,
                                      gpointer data) {
  static_cast<FloatingLyricWindow*>(data)->SetHovered(true);
  return FALSE;
}

gboolean FloatingLyricWindow::OnLeave(GtkWidget*, GdkEventCrossing* e,
                                      gpointer data) {
  if (e->detail == GDK_NOTIFY_INFERIOR) return FALSE;
  auto* self = static_cast<FloatingLyricWindow*>(data);
  // While dragging the pointer may run ahead of the window: keep the state.
  if (self->press_ == Press::kNone) self->SetHovered(false);
  return FALSE;
}

gboolean FloatingLyricWindow::OnScroll(GtkWidget*, GdkEventScroll* e,
                                       gpointer data) {
  auto* self = static_cast<FloatingLyricWindow*>(data);
  double delta = 0;
  switch (e->direction) {
    case GDK_SCROLL_UP:
      delta = -kScrollStep;
      break;
    case GDK_SCROLL_DOWN:
      delta = kScrollStep;
      break;
    case GDK_SCROLL_SMOOTH:
      delta = e->delta_y * kScrollStep;
      break;
    default:
      return FALSE;
  }
  self->ScrollBy(delta);
  return TRUE;
}

gboolean FloatingLyricWindow::OnQueryTooltip(GtkWidget*, gint x, gint y,
                                             gboolean, GtkTooltip* tooltip,
                                             gpointer data) {
  auto* self = static_cast<FloatingLyricWindow*>(data);
  if (!self->ToolbarVisible()) return FALSE;
  const std::string text = self->TooltipFor(self->SlotAt(x, y));
  if (text.empty()) return FALSE;
  gtk_tooltip_set_text(tooltip, text.c_str());
  return TRUE;
}

gboolean FloatingLyricWindow::OnConfigure(GtkWidget*, GdkEventConfigure* e,
                                          gpointer data) {
  auto* self = static_cast<FloatingLyricWindow*>(data);
  // Only the compositor / window manager can size a Wayland toplevel (its
  // interactive resize); everywhere else the size is ours and this echoes it.
  if (self->backend_ == Backend::kWaylandToplevel && e->width > 0 &&
      e->height > 0 &&
      (e->width != std::lround(self->width_) ||
       e->height != std::lround(self->height_))) {
    self->width_ = e->width;
    self->height_ = e->height;
    self->layout_dirty_ = true;
    self->Redraw();
  }
  return FALSE;
}

void FloatingLyricWindow::OnMonitorsChanged(GdkScreen*, gpointer data) {
  static_cast<FloatingLyricWindow*>(data)->RelayoutForScreenChange();
}

// ── test hooks ───────────────────────────────────────────────────────────────

FloatingLyricWindow::Probe FloatingLyricWindow::GetProbe() {
  Probe p;
  p.visible = IsShowing();
  p.locked = locked_;
  p.topmost = topmost_;
  p.pass_through = pass_through_;
  p.toolbar_shown = ToolbarVisible();
  p.text = text_;
  p.highlight_start = highlight_start_;
  p.highlight_length = highlight_length_;
  p.x = x_;
  p.y = y_;
  p.width = width_;
  p.height = height_;
  p.physical = ToPhysical();
  p.backend = BackendName(backend_);
  if (window_ != nullptr) {
    p.override_redirect =
        gtk_window_get_window_type(GTK_WINDOW(window_)) == GTK_WINDOW_POPUP;
    p.composited = gdk_screen_is_composited(gtk_widget_get_screen(window_));
#ifdef GDK_WINDOWING_X11
    GdkWindow* gdk_window = gtk_widget_get_window(window_);
    if (gdk_window != nullptr && GDK_IS_X11_WINDOW(gdk_window)) {
      p.xid = GDK_WINDOW_XID(gdk_window);
    }
#endif
  }
  const Rect rect = TextRect();
  EnsureLayout(rect.w);
  double ox = 0, oy = 0;
  TextOrigin(rect, &ox, &oy);
  p.scroll_offset = scroll_offset_;
  p.scroll_max = scroll_max_;
  p.content_height = content_height_;
  return p;
}

bool FloatingLyricWindow::ClickChar(int index, double* local_x,
                                    double* local_y) {
  const Rect rect = TextRect();
  EnsureLayout(rect.w);
  double ox = 0, oy = 0;
  TextOrigin(rect, &ox, &oy);
  const int n16 = static_cast<int>(u16_to_byte_.size()) - 1;
  if (index < 0 || index >= n16) return false;
  Rect box;
  if (!CharBox(ByteOf(index), &box) || box.w <= 0) return false;
  const double cx = ox + box.x + box.w / 2;
  const double cy = oy + box.y + box.h / 2;
  // The real cursor does not move: below the drag threshold = a click.
  PointerDown(cx, cy, x_ + cx, y_ + cy, 1, GDK_CURRENT_TIME);
  PointerUp(cx, cy);
  *local_x = cx;
  *local_y = cy;
  return true;
}

void FloatingLyricWindow::DragBy(double dx, double dy) {
  if (window_ == nullptr) return;
  // Grab the middle of the text area (never the toolbar or the grip).
  const Rect rect = TextRect();
  const double lx = rect.x + rect.w / 2;
  const double ly = rect.y + rect.h / 2;
  const double root_x = x_ + lx;
  const double root_y = y_ + ly;
  PointerDown(lx, ly, root_x, root_y, 1, GDK_CURRENT_TIME);
  constexpr int kSteps = 8;
  for (int i = 1; i <= kSteps; ++i) {
    const double t = static_cast<double>(i) / kSteps;
    const double rx = root_x + dx * t;
    const double ry = root_y + dy * t;
    // Local = pointer - current window origin, as a real motion event reports.
    PointerMoved(rx - x_, ry - y_, rx, ry, static_cast<GdkModifierType>(0));
  }
  PointerUp(root_x + dx - x_, root_y + dy - y_);
}

void FloatingLyricWindow::ToolbarAction(const std::string& action) {
  DispatchControl(action);
}

bool FloatingLyricWindow::Snapshot(const std::string& path) {
  const int w = static_cast<int>(std::lround(width_));
  const int h = static_cast<int>(std::lround(height_));
  if (w <= 0 || h <= 0) return false;
  cairo_surface_t* surface =
      cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
  cairo_t* cr = cairo_create(surface);
  Draw(cr);
  cairo_destroy(cr);
  const bool ok =
      cairo_surface_write_to_png(surface, path.c_str()) == CAIRO_STATUS_SUCCESS;
  cairo_surface_destroy(surface);
  return ok;
}
