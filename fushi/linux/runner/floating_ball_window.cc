#include "floating_ball_window.h"

#include <pango/pangocairo.h>

#include <algorithm>
#include <cmath>
#include <limits>

namespace fb = fushi::floating_ball;

namespace {

// Never "Fushi": that title belongs to the main window.
constexpr char kBallTitle[] = "Fushi Floating Ball";
constexpr char kMenuTitle[] = "Fushi Floating Ball Menu";

constexpr guint kAnimationTimerMs = 10;
// Buttons fainter than this are not clickable (Windows kMenuMinHitOpacity).
constexpr double kMenuMinHitOpacity = 0.05;
// Strips a circle is approximated by in input shapes (regions are rectangles).
constexpr int kCircleStrips = 12;

using fb::kActionClose;
using fb::kActionOpenApp;
constexpr char kProfileIdKey[] = "fushi-profile-id";

double NowMs() { return g_get_monotonic_time() / 1000.0; }

double EaseOutBackPeakCached() {
  static const double peak = fb::EaseOutBackPeak();
  return peak;
}

void SetArgb(cairo_t* cr, uint32_t argb, double extra_alpha = 1.0) {
  const double a = ((argb >> 24) & 0xFF) / 255.0;
  cairo_set_source_rgba(cr, ((argb >> 16) & 0xFF) / 255.0,
                        ((argb >> 8) & 0xFF) / 255.0, (argb & 0xFF) / 255.0,
                        a * extra_alpha);
}

uint32_t WithAlpha(uint32_t argb, double alpha) {
  const uint32_t a = static_cast<uint32_t>(
      std::lround(std::clamp(alpha, 0.0, 1.0) * ((argb >> 24) & 0xFF)));
  return (a << 24) | (argb & 0x00FFFFFF);
}

// Source-over of |top| on opaque |bottom| (Windows AlphaBlend).
uint32_t AlphaBlend(uint32_t top, uint32_t bottom) {
  const double a = ((top >> 24) & 0xFF) / 255.0;
  auto mix = [a](uint32_t t, uint32_t b) {
    return static_cast<uint32_t>(std::lround(t * a + b * (1.0 - a)));
  };
  return 0xFF000000 | (mix((top >> 16) & 0xFF, (bottom >> 16) & 0xFF) << 16) |
         (mix((top >> 8) & 0xFF, (bottom >> 8) & 0xFF) << 8) |
         mix(top & 0xFF, bottom & 0xFF);
}

void RoundedRectPath(cairo_t* cr, double x, double y, double w, double h,
                     double r) {
  r = std::clamp(r, 0.0, std::min(w, h) / 2);
  cairo_new_sub_path(cr);
  cairo_arc(cr, x + w - r, y + r, r, -G_PI / 2, 0);
  cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI / 2);
  cairo_arc(cr, x + r, y + h - r, r, G_PI / 2, G_PI);
  cairo_arc(cr, x + r, y + r, r, G_PI, 3 * G_PI / 2);
  cairo_close_path(cr);
}

// Material-like shadow: solid inside the circle (minus half the blur), fading
// to 0 at radius + blur (Windows DrawSoftShadow).
void DrawSoftShadow(cairo_t* cr, double cx, double cy, double radius,
                    double blur, double alpha) {
  if (alpha <= 0 || radius <= 0) return;
  const double outer = radius + std::max(blur, 0.5);
  const double solid = std::clamp((radius - blur * 0.5) / outer, 0.0, 1.0);
  cairo_pattern_t* p = cairo_pattern_create_radial(cx, cy, 0, cx, cy, outer);
  cairo_pattern_add_color_stop_rgba(p, 0, 0, 0, 0, alpha);
  cairo_pattern_add_color_stop_rgba(p, solid, 0, 0, 0, alpha);
  cairo_pattern_add_color_stop_rgba(p, 1, 0, 0, 0, 0);
  cairo_set_source(cr, p);
  cairo_arc(cr, cx, cy, outer, 0, 2 * G_PI);
  cairo_fill(cr);
  cairo_pattern_destroy(p);
}

void AddCircle(cairo_region_t* region, double cx, double cy, double r) {
  if (r <= 0) return;
  const double step = 2 * r / kCircleStrips;
  for (int i = 0; i < kCircleStrips; ++i) {
    // Widest point of the strip, so the shape never cuts into the circle.
    const double y0 = cy - r + i * step;
    const double y1 = y0 + step;
    const double near = std::clamp(cy, y0, y1) - cy;
    const double half = std::sqrt(std::max(0.0, r * r - near * near));
    const cairo_rectangle_int_t rect = {
        static_cast<int>(std::floor(cx - half)),
        static_cast<int>(std::floor(y0)),
        static_cast<int>(std::ceil(2 * half)) + 1,
        static_cast<int>(std::ceil(step)) + 1};
    cairo_region_union_rectangle(region, &rect);
  }
}

bool MonitorValid(GdkDisplay* display, GdkMonitor* monitor) {
  if (monitor == nullptr) return false;
  const int n = gdk_display_get_n_monitors(display);
  for (int i = 0; i < n; ++i) {
    if (gdk_display_get_monitor(display, i) == monitor) return true;
  }
  return false;
}

// Monitor whose area contains the point; null when the point is off-screen
// (unlike gdk_display_get_monitor_at_point, which returns the nearest).
GdkMonitor* MonitorContaining(GdkDisplay* display, int x, int y) {
  const int n = gdk_display_get_n_monitors(display);
  for (int i = 0; i < n; ++i) {
    GdkMonitor* m = gdk_display_get_monitor(display, i);
    GdkRectangle g;
    gdk_monitor_get_geometry(m, &g);
    if (x >= g.x && x < g.x + g.width && y >= g.y && y < g.y + g.height) {
      return m;
    }
  }
  return nullptr;
}

}  // namespace

FloatingBallWindow::FloatingBallWindow() = default;

FloatingBallWindow::~FloatingBallWindow() {
  // App shutdown: no callbacks (Dart goes away with the engine).
  Teardown();
  ClearPixbufCache();
}

// ── windows ──────────────────────────────────────────────────────────────────

GtkWidget* FloatingBallWindow::NewOverlayWindow(int width, int height) {
  // Unmanaged (override-redirect) X11 window, like the Windows layered popups:
  // the window manager neither places, constrains nor focuses it, moves go
  // straight to the X server (a managed window trailed the finger during a drag
  // on Plasma, every move waiting on KWin), and KWin stacks unmanaged windows
  // above all managed ones.
  GtkWidget* widget = gtk_window_new(GTK_WINDOW_POPUP);
  GtkWindow* window = GTK_WINDOW(widget);
  gtk_window_set_resizable(window, FALSE);
  gtk_widget_set_app_paintable(widget, TRUE);
  GdkScreen* screen = gtk_widget_get_screen(widget);
  GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
  if (visual != nullptr && gdk_screen_is_composited(screen)) {
    gtk_widget_set_visual(widget, visual);
  }
  gtk_widget_set_size_request(widget, width, height);
  gtk_window_resize(window, width, height);
  gtk_widget_add_events(widget, GDK_BUTTON_PRESS_MASK |
                                    GDK_BUTTON_RELEASE_MASK |
                                    GDK_POINTER_MOTION_MASK |
                                    GDK_LEAVE_NOTIFY_MASK);
  return widget;
}

void FloatingBallWindow::ConnectScreenSignals() {
  if (monitors_changed_handler_ != 0) return;
  GdkScreen* screen = gdk_screen_get_default();
  monitors_changed_handler_ = g_signal_connect(
      screen, "monitors-changed", G_CALLBACK(OnScreenChanged), this);
  size_changed_handler_ = g_signal_connect(screen, "size-changed",
                                           G_CALLBACK(OnScreenChanged), this);
}

void FloatingBallWindow::DisconnectScreenSignals() noexcept {
  GdkScreen* screen = gdk_screen_get_default();
  if (monitors_changed_handler_ != 0) {
    g_signal_handler_disconnect(screen, monitors_changed_handler_);
  }
  if (size_changed_handler_ != 0) {
    g_signal_handler_disconnect(screen, size_changed_handler_);
  }
  monitors_changed_handler_ = 0;
  size_changed_handler_ = 0;
}

std::string FloatingBallWindow::LabelFor(const std::string& id) const {
  const auto it = config_.labels.find(id);
  if (it != config_.labels.end() && !it->second.empty()) return it->second;
  // Native keeps no translations: English fallback (Windows LabelFor).
  if (id == "lookup") return "Look up";
  if (id == "popup_lookup") return "App-external lookup";
  if (id == "clipboard") return "Clipboard";
  if (id == "sync") return "Sync now";
  if (id == "switch_profile") return "Switch profile";
  if (id == kActionOpenApp) return "Open Fushi";
  if (id == kActionClose) return "Close";
  if (id == "ball") return "Floating ball";
  return id;
}

// ── geometry ─────────────────────────────────────────────────────────────────

FloatingBallWindow::Screen FloatingBallWindow::ScreenFor(
    GdkMonitor* monitor, double probe_y) const {
  GdkDisplay* display = gdk_display_get_default();
  if (!MonitorValid(display, monitor)) {
    monitor = gdk_display_get_primary_monitor(display);
    if (monitor == nullptr) monitor = gdk_display_get_monitor(display, 0);
  }
  Screen screen;
  screen.monitor = monitor;
  GdkRectangle work = {0, 0, 1280, 800};
  if (monitor != nullptr) gdk_monitor_get_workarea(monitor, &work);
  screen.viewport = fb::Rect{static_cast<double>(work.x),
                             static_cast<double>(work.y),
                             static_cast<double>(work.x + work.width),
                             static_cast<double>(work.y + work.height)};
  // GDK coordinates already include the integer scale factor; the font DPI
  // carries fractional scaling (Plasma X11 sets Xft.dpi, e.g. 120 for 125%).
  const double dpi = gdk_screen_get_resolution(gdk_screen_get_default());
  screen.scale = dpi > 0 ? dpi / 96.0 : 1.0;

  // No tuck when another monitor touches the docking edge: a third of the ball
  // would be drawn (and clickable) on the neighbour.
  int y = work.y + work.height / 2;
  if (std::isfinite(probe_y)) {
    y = std::clamp(static_cast<int>(std::lround(probe_y)), work.y,
                   std::max(work.y, work.y + work.height - 1));
  }
  GdkRectangle geometry = work;
  if (monitor != nullptr) gdk_monitor_get_geometry(monitor, &geometry);
  auto neighbour_at = [&](int x) {
    GdkMonitor* other = MonitorContaining(display, x, y);
    return other != nullptr && other != monitor;
  };
  screen.tuck_left = !neighbour_at(geometry.x - 1);
  screen.tuck_right = !neighbour_at(geometry.x + geometry.width);
  return screen;
}

fb::Geometry FloatingBallWindow::GeometryFor(const Screen& screen,
                                             bool dock_left,
                                             double fraction) const {
  return fb::Geometry(screen.viewport, dock_left, fraction,
                      static_cast<int>(ButtonIds().size()), screen.scale,
                      dock_left ? screen.tuck_left : screen.tuck_right);
}

fb::Geometry FloatingBallWindow::CurrentGeometry() {
  const Screen first =
      ScreenFor(monitor_, std::numeric_limits<double>::quiet_NaN());
  const fb::Geometry rough = GeometryFor(first, dock_left_, fraction_);
  const Screen screen =
      ScreenFor(first.monitor, rough.BallTop() + rough.ball() / 2);
  monitor_ = screen.monitor;
  scale_ = screen.scale;
  last_work_ = screen.viewport;
  return GeometryFor(screen, dock_left_, fraction_);
}

GdkMonitor* FloatingBallWindow::MonitorAt(double x, double y) const {
  return gdk_display_get_monitor_at_point(gdk_display_get_default(),
                                          static_cast<int>(std::lround(x)),
                                          static_cast<int>(std::lround(y)));
}

double FloatingBallWindow::BallPx() const { return fb::kBallDip * scale_; }

int FloatingBallWindow::BallWindowSize() const {
  return static_cast<int>(
      std::ceil((fb::kBallDip + 2 * fb::kBallShadowPadDip) * scale_));
}

FloatingBallWindow::PhysicalRect FloatingBallWindow::BallPhysicalRect() const {
  const int factor =
      monitor_ != nullptr ? std::max(1, gdk_monitor_get_scale_factor(monitor_))
                          : 1;
  const double ball = BallPx();
  return PhysicalRect{static_cast<int>(std::lround(ball_left_ * factor)),
                      static_cast<int>(std::lround(ball_top_ * factor)),
                      static_cast<int>(std::lround((ball_left_ + ball) * factor)),
                      static_cast<int>(std::lround((ball_top_ + ball) * factor))};
}

// ── lifecycle ────────────────────────────────────────────────────────────────

bool FloatingBallWindow::Start(const Config& config, bool dock_left,
                               double fraction, GtkWindow* monitor_hint) {
  if (IsRunning()) {
    // In place: buttons, icons and colours may all change. Collapse (the next
    // expand builds the button window from the new config) and redraw the ball;
    // the position stays (Dart sends back what it last received from us).
    config_ = config;
    ClearPixbufCache();
    CollapseImmediately();
    gtk_widget_queue_draw(ball_);
    return true;
  }
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) return false;

  config_ = config;
  ClearPixbufCache();
  dock_left_ = dock_left;
  fraction_ = std::isfinite(fraction) ? std::clamp(fraction, 0.0, 1.0) : 0.5;
  monitor_ = nullptr;
  GdkWindow* hint = monitor_hint != nullptr
                        ? gtk_widget_get_window(GTK_WIDGET(monitor_hint))
                        : nullptr;
  if (hint != nullptr) {
    monitor_ = gdk_display_get_monitor_at_window(display, hint);
  }
  progress_ = 0;
  expand_target_ = false;
  const fb::Geometry g = CurrentGeometry();
  ball_left_ = g.CollapsedBallLeft();
  ball_top_ = g.BallTop();

  const int size = BallWindowSize();
  ball_ = NewOverlayWindow(size, size);
  gtk_window_set_title(GTK_WINDOW(ball_), kBallTitle);
  g_signal_connect(ball_, "draw", G_CALLBACK(OnBallDraw), this);
  g_signal_connect(ball_, "button-press-event", G_CALLBACK(OnBallPress), this);
  g_signal_connect(ball_, "motion-notify-event", G_CALLBACK(OnBallMotion),
                   this);
  g_signal_connect(ball_, "button-release-event", G_CALLBACK(OnBallRelease),
                   this);
  g_signal_connect(ball_, "grab-broken-event", G_CALLBACK(OnBallGrabBroken),
                   this);
  PlaceBall();
  ConnectScreenSignals();
  // Fushi is usually in front when the ball starts: a yielding ball is created
  // but not shown.
  if (!Suppressed()) gtk_widget_show(ball_);
  return true;
}

void FloatingBallWindow::Stop() {
  FinishProfileMenu(std::nullopt);
  Teardown();
}

void FloatingBallWindow::Teardown() noexcept {
  profile_menu_done_ = nullptr;
  if (profile_menu_ != nullptr) {
    GtkWidget* menu = profile_menu_;
    profile_menu_ = nullptr;
    gtk_widget_destroy(menu);
  }
  // After the destroy above: destroying an open menu deactivates it, which
  // queues the idle.
  if (profile_menu_idle_ != 0) {
    g_source_remove(profile_menu_idle_);
    profile_menu_idle_ = 0;
  }
  CancelAnimations();
  pressing_ball_ = false;
  dragging_ = false;
  DestroyMenuWindow();
  if (ball_ != nullptr) {
    GtkWidget* ball = ball_;
    ball_ = nullptr;
    gtk_widget_destroy(ball);
  }
  DisconnectScreenSignals();
  progress_ = 0;
  expand_target_ = false;
  hidden_for_capture_ = false;
}

void FloatingBallWindow::HideForCapture() {
  if (!IsRunning()) return;
  hidden_for_capture_ = true;
  HideWindows();
}

void FloatingBallWindow::RestoreAfterCapture() {
  if (!hidden_for_capture_) return;
  hidden_for_capture_ = false;
  ShowWindows();
}

void FloatingBallWindow::SetHiddenForApp(bool hidden) {
  if (hidden == hidden_for_app_) return;
  hidden_for_app_ = hidden;
  if (!IsRunning()) return;
  if (hidden) {
    // Collapse on the way out: coming back shows a collapsed ball, not a
    // column of buttons left hanging.
    CollapseImmediately();
    HideWindows();
    return;
  }
  ShowWindows();
}

void FloatingBallWindow::ShowWindows() {
  if (Suppressed() || !IsRunning()) return;
  gtk_widget_show(ball_);
  if (menu_ != nullptr) {
    gtk_widget_show(menu_);
    // The ball sits above its button window (buttons come out from under it).
    GdkWindow* window = gtk_widget_get_window(ball_);
    if (window != nullptr) gdk_window_raise(window);
  }
}

void FloatingBallWindow::HideWindows() {
  if (ball_ != nullptr) gtk_widget_hide(ball_);
  if (menu_ != nullptr) gtk_widget_hide(menu_);
}

// ── profile menu ─────────────────────────────────────────────────────────────

void FloatingBallWindow::ShowProfileMenu(std::vector<ProfileMenuItem> items,
                                         std::optional<PhysicalRect> anchor,
                                         ProfileMenuCallback done) {
  if (profile_menu_done_ || !IsRunning() || items.empty() || Suppressed()) {
    done(std::nullopt);
    return;
  }
  profile_menu_done_ = std::move(done);
  profile_menu_selected_.reset();
  GtkWidget* menu = gtk_menu_new();
  profile_menu_ = menu;
  for (const ProfileMenuItem& item : items) {
    GtkWidget* entry = gtk_check_menu_item_new_with_label(item.label.c_str());
    gtk_check_menu_item_set_draw_as_radio(GTK_CHECK_MENU_ITEM(entry), TRUE);
    gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(entry), item.checked);
    auto* id = g_new(gint64, 1);
    *id = item.id;
    g_object_set_data_full(G_OBJECT(entry), kProfileIdKey, id, g_free);
    g_signal_connect(
        entry, "activate", G_CALLBACK(+[](GtkMenuItem* entry, gpointer data) {
          auto* self = static_cast<FloatingBallWindow*>(data);
          const auto* id = static_cast<const gint64*>(
              g_object_get_data(G_OBJECT(entry), kProfileIdKey));
          if (id != nullptr) self->profile_menu_selected_ = *id;
        }),
        this);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), entry);
  }
  // GtkMenuShell deactivates before it activates the chosen item: finish on
  // the next idle, once the item had its say.
  g_signal_connect(
      menu, "deactivate", G_CALLBACK(+[](GtkMenuShell*, gpointer data) {
        auto* self = static_cast<FloatingBallWindow*>(data);
        if (self->profile_menu_idle_ != 0) return;
        self->profile_menu_idle_ = g_idle_add(
            [](gpointer data) -> gboolean {
              auto* self = static_cast<FloatingBallWindow*>(data);
              self->profile_menu_idle_ = 0;
              if (self->profile_menu_done_) {
                self->FinishProfileMenu(self->profile_menu_selected_);
              }
              return G_SOURCE_REMOVE;
            },
            data);
      }),
      this);
  gtk_widget_show_all(menu);
  gtk_menu_attach_to_widget(GTK_MENU(menu), ball_, nullptr);

  GdkWindow* ball_window = gtk_widget_get_window(ball_);
  GdkRectangle rect = {0, 0, 1, 1};
  int origin_x = 0;
  int origin_y = 0;
  if (ball_window != nullptr) gdk_window_get_origin(ball_window, &origin_x, &origin_y);
  const int factor =
      monitor_ != nullptr ? std::max(1, gdk_monitor_get_scale_factor(monitor_))
                          : 1;
  if (anchor) {
    rect = {anchor->left / factor - origin_x, anchor->top / factor - origin_y,
            std::max(1, (anchor->right - anchor->left) / factor),
            std::max(1, (anchor->bottom - anchor->top) / factor)};
  } else {
    GdkSeat* seat = gdk_display_get_default_seat(gdk_display_get_default());
    int px = 0;
    int py = 0;
    gdk_device_get_position(gdk_seat_get_pointer(seat), nullptr, &px, &py);
    rect = {px - origin_x, py - origin_y, 1, 1};
  }
  // Open towards the middle of the screen, top-aligned with the ball.
  gtk_menu_popup_at_rect(
      GTK_MENU(menu), ball_window, &rect,
      dock_left_ ? GDK_GRAVITY_NORTH_EAST : GDK_GRAVITY_NORTH_WEST,
      dock_left_ ? GDK_GRAVITY_NORTH_WEST : GDK_GRAVITY_NORTH_EAST, nullptr);
  // The popup needs a seat grab; without one GTK gives up silently.
  if (!gtk_widget_get_mapped(menu)) FinishProfileMenu(std::nullopt);
}

void FloatingBallWindow::FinishProfileMenu(std::optional<int64_t> selected) {
  ProfileMenuCallback done = std::move(profile_menu_done_);
  profile_menu_done_ = nullptr;
  if (profile_menu_ != nullptr) {
    GtkWidget* menu = profile_menu_;
    profile_menu_ = nullptr;
    gtk_widget_destroy(menu);
  }
  if (done) done(selected);
}

// ── expand / collapse ────────────────────────────────────────────────────────

void FloatingBallWindow::SetExpanded(bool expand) {
  if (expand == expand_target_ || ball_ == nullptr) return;
  expand_target_ = expand;
  snap_anim_.active = false;
  if (expand) EnsureMenuWindow();
  AnimateProgress(expand ? 1.0 : 0.0, expand ? fb::kExpandMs : fb::kCollapseMs);
}

void FloatingBallWindow::AnimateProgress(double target, int full_ms) {
  if (!config_.animate) {
    CancelAnimations();
    SetProgress(target);
    if (target <= 0.0) DestroyMenuWindow();
    return;
  }
  progress_anim_.Start(progress_, target, full_ms, NowMs());
  EnsureAnimationTimer();
}

void FloatingBallWindow::CollapseImmediately() {
  CancelAnimations();
  expand_target_ = false;
  DestroyMenuWindow();
  SetProgress(0);
}

void FloatingBallWindow::CancelAnimations() noexcept {
  progress_anim_.active = false;
  snap_anim_.active = false;
  if (timer_id_ != 0) {
    g_source_remove(timer_id_);
    timer_id_ = 0;
  }
}

void FloatingBallWindow::SetProgress(double t) {
  progress_ = t;
  if (ball_ == nullptr) return;
  const fb::Geometry g = CurrentGeometry();
  ball_left_ = g.BallLeftAt(t);
  ball_top_ = g.BallTopAt(t);
  PlaceBall();
  if (menu_ != nullptr) {
    UpdateMenuInputShape();
    gtk_widget_queue_draw(menu_);
  }
}

void FloatingBallWindow::EnsureAnimationTimer() {
  if (timer_id_ != 0 || ball_ == nullptr) return;
  timer_id_ = g_timeout_add(kAnimationTimerMs, OnAnimationTick, this);
}

gboolean FloatingBallWindow::OnAnimationTick(gpointer data) {
  auto* self = static_cast<FloatingBallWindow*>(data);
  if (self->Tick()) return G_SOURCE_CONTINUE;
  self->timer_id_ = 0;
  return G_SOURCE_REMOVE;
}

bool FloatingBallWindow::Tick() {
  const double now = NowMs();
  if (progress_anim_.active) {
    SetProgress(progress_anim_.Sample(now));
    // The button window goes only once the collapse has finished.
    if (!progress_anim_.active && progress_anim_.to <= 0.0) DestroyMenuWindow();
  }
  if (snap_anim_.active) {
    snap_anim_.Sample(now, &ball_left_, &ball_top_);
    PlaceBall();
  }
  return (progress_anim_.active || snap_anim_.active) && ball_ != nullptr;
}

// ── button window ────────────────────────────────────────────────────────────

void FloatingBallWindow::EnsureMenuWindow() {
  if (menu_ != nullptr || ball_ == nullptr) return;
  // Laid out once at the final geometry: expanded ball centre plus every
  // button's landing spot. The window must hold each button's whole path from
  // the ball centre to past its landing spot (easeOutBack overshoot) plus the
  // shadow; after that only animation, the window never moves or resizes.
  const fb::Geometry g = CurrentGeometry();
  menu_ids_ = ButtonIds();
  menu_scale_ = scale_;
  PrepareMenuLabels(g);
  std::vector<double> label_widths;
  for (const Label& label : menu_labels_) label_widths.push_back(label.width);
  menu_layout_ =
      fb::LayoutMenu(g, menu_scale_, EaseOutBackPeakCached(), label_widths);
  hovered_ = -1;
  pressed_ = -1;

  menu_ = NewOverlayWindow(menu_layout_.width, menu_layout_.height);
  gtk_window_set_title(GTK_WINDOW(menu_), kMenuTitle);
  g_signal_connect(menu_, "draw", G_CALLBACK(OnMenuDraw), this);
  g_signal_connect(menu_, "button-press-event", G_CALLBACK(OnMenuPress), this);
  g_signal_connect(menu_, "motion-notify-event", G_CALLBACK(OnMenuMotion),
                   this);
  g_signal_connect(menu_, "button-release-event", G_CALLBACK(OnMenuRelease),
                   this);
  g_signal_connect(menu_, "leave-notify-event", G_CALLBACK(OnMenuLeave), this);
  gtk_widget_set_has_tooltip(menu_, TRUE);
  g_signal_connect(menu_, "query-tooltip", G_CALLBACK(OnMenuQueryTooltip),
                   this);
  gtk_window_move(GTK_WINDOW(menu_), menu_layout_.x, menu_layout_.y);
  // Shaped and painted at the current progress (usually 0: all transparent)
  // before it is shown; the buttons then come out from under the ball.
  UpdateMenuInputShape();
  if (!Suppressed()) ShowWindows();
}

void FloatingBallWindow::DestroyMenuWindow() noexcept {
  hovered_ = -1;
  pressed_ = -1;
  if (menu_ != nullptr) {
    GtkWidget* menu = menu_;
    menu_ = nullptr;
    gtk_widget_destroy(menu);
  }
}

bool FloatingBallWindow::ButtonCircle(int index, double* cx, double* cy,
                                      double* radius, double* opacity) const {
  const int n = static_cast<int>(menu_layout_.centers.size());
  if (index < 0 || index >= n) return false;
  const double k = fb::ButtonProgress(progress_, index, n);
  const fb::Offset& c = menu_layout_.centers[index];
  *cx = fb::Lerp(menu_layout_.ball_cx, c.dx, k);
  *cy = fb::Lerp(menu_layout_.ball_cy, c.dy, k);
  *radius = fb::kButtonDip * menu_scale_ / 2 * fb::ButtonScale(k);
  *opacity = fb::ButtonOpacity(k);
  return true;
}

bool FloatingBallWindow::LabelRect(int index, double* left, double* top,
                                   double* width, double* height,
                                   double* opacity) const {
  if (index < 0 || index >= static_cast<int>(menu_labels_.size())) {
    return false;
  }
  double cx, cy, r, o;
  if (!ButtonCircle(index, &cx, &cy, &r, &o)) return false;
  const double s = menu_scale_;
  const double w = menu_labels_[index].width;
  const double h = fb::kLabelHeightDip * s;
  const double near_edge = fb::kButtonDip * s / 2 + fb::kLabelGapDip * s;
  *left = dock_left_ ? cx + near_edge : cx - near_edge - w;
  *top = cy - h / 2;
  *width = w;
  *height = h;
  *opacity = o;
  return true;
}

int FloatingBallWindow::ButtonAt(double x, double y) const {
  for (int i = static_cast<int>(menu_layout_.centers.size()) - 1; i >= 0;
       --i) {
    double cx, cy, r, o;
    if (!ButtonCircle(i, &cx, &cy, &r, &o) || o < kMenuMinHitOpacity) continue;
    // Drawn at 40, hit at 48 (kReaderFloatingBallMinTouchTarget).
    const double hit = fb::ButtonHitRadius(r);
    const double dx = x - cx;
    const double dy = y - cy;
    if (dx * dx + dy * dy <= hit * hit) return i;
    double l, t, w, h, lo;
    if (LabelRect(i, &l, &t, &w, &h, &lo) && lo >= kMenuMinHitOpacity &&
        x >= l && x <= l + w && y >= t && y <= t + h) {
      return i;
    }
  }
  return -1;
}

PangoFontDescription* FloatingBallWindow::LabelFont() const {
  PangoFontDescription* font = pango_font_description_from_string("Sans");
  // M3E label large: 14, medium weight.
  pango_font_description_set_weight(font, PANGO_WEIGHT_MEDIUM);
  pango_font_description_set_absolute_size(
      font, fb::kLabelFontDip * menu_scale_ * PANGO_SCALE);
  return font;
}

void FloatingBallWindow::PrepareMenuLabels(const fb::Geometry& g) {
  menu_labels_.clear();
  // Several columns: labels would cover the next column (in-app ball likewise).
  if (!config_.show_labels || g.ColumnCount() != 1) return;
  const double s = menu_scale_;
  const double available = g.viewport().Width() - 2 * g.margin() - g.button() -
                           fb::kLabelGapDip * s;
  const double cap = std::min(fb::kLabelMaxWidthDip * s, available);
  const double pad = fb::kLabelPaddingDip * s;
  if (cap < 2 * pad + 24 * s) return;
  cairo_surface_t* surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
  cairo_t* cr = cairo_create(surface);
  PangoLayout* layout = pango_cairo_create_layout(cr);
  PangoFontDescription* font = LabelFont();
  pango_layout_set_font_description(layout, font);
  std::vector<Label> labels;
  for (const std::string& id : menu_ids_) {
    Label label;
    label.text = LabelFor(id);
    pango_layout_set_text(layout, label.text.c_str(), -1);
    PangoRectangle logical;
    pango_layout_get_pixel_extents(layout, nullptr, &logical);
    label.width = std::min(cap, std::ceil(logical.width + 2 * pad));
    labels.push_back(std::move(label));
  }
  pango_font_description_free(font);
  g_object_unref(layout);
  cairo_destroy(cr);
  cairo_surface_destroy(surface);
  menu_labels_ = std::move(labels);
}

void FloatingBallWindow::UpdateMenuInputShape() {
  if (menu_ == nullptr) return;
  // Only the buttons (48 hit circle) and their labels take clicks; everything
  // else in the window falls through to the app below.
  cairo_region_t* region = cairo_region_create();
  for (int i = 0; i < static_cast<int>(menu_ids_.size()); ++i) {
    double cx, cy, r, o;
    if (!ButtonCircle(i, &cx, &cy, &r, &o) || o < kMenuMinHitOpacity) continue;
    AddCircle(region, cx, cy, fb::ButtonHitRadius(r));
    double l, t, w, h, lo;
    if (LabelRect(i, &l, &t, &w, &h, &lo) && lo >= kMenuMinHitOpacity) {
      const cairo_rectangle_int_t rect = {
          static_cast<int>(std::floor(l)), static_cast<int>(std::floor(t)),
          static_cast<int>(std::ceil(w)) + 1, static_cast<int>(std::ceil(h)) + 1};
      cairo_region_union_rectangle(region, &rect);
    }
  }
  gtk_widget_input_shape_combine_region(menu_, region);
  if (!gdk_screen_is_composited(gtk_widget_get_screen(menu_))) {
    gtk_widget_shape_combine_region(menu_, region);
  }
  cairo_region_destroy(region);
}

void FloatingBallWindow::RunButton(int index) {
  if (index < 0 || index >= static_cast<int>(menu_ids_.size()) ||
      !expand_target_) {
    return;
  }
  const std::string id = menu_ids_[index];
  if (id == kActionClose) {
    // Windows go first: when Dart hears about it there is no ball left, it only
    // turns the "show outside the app" switch off.
    Stop();
    if (on_closed_) on_closed_();
    return;
  }
  // Anchor = the expanded ball (fully on screen); the card goes beside it.
  const PhysicalRect anchor = BallPhysicalRect();
  SetExpanded(false);
  if (on_action_) on_action_(id, anchor);
}

// ── drag ─────────────────────────────────────────────────────────────────────

void FloatingBallWindow::BeginDrag() {
  CollapseImmediately();
  dragging_ = true;
  drag_start_left_ = ball_left_;
  drag_start_top_ = ball_top_;
  PlaceBall();
}

void FloatingBallWindow::DragTo(double root_x, double root_y) {
  const double left = drag_start_left_ + (root_x - down_x_);
  const double top = drag_start_top_ + (root_y - down_y_);
  // Viewport = work area of the monitor under the ball centre (dragging onto
  // another monitor makes that one the viewport).
  const double ball = BallPx();
  GdkMonitor* monitor = MonitorAt(left + ball / 2, top + ball / 2);
  const Screen screen = ScreenFor(monitor, top + ball / 2);
  monitor_ = screen.monitor;
  scale_ = screen.scale;
  const fb::Geometry as_left = GeometryFor(screen, true, fraction_);
  const fb::Geometry as_right = GeometryFor(screen, false, fraction_);
  const fb::Offset clamped = fb::ClampDrag(as_left, as_right, left, top);
  ball_left_ = clamped.dx;
  ball_top_ = clamped.dy;
  PlaceBall();
}

void FloatingBallWindow::EndDrag() {
  dragging_ = false;
  // Dock to the half the ball centre is in, keep the height, snap to the
  // collapsed spot with easeOutCubic.
  const Screen screen = ScreenFor(monitor_, ball_top_ + BallPx() / 2);
  const fb::Geometry g = GeometryFor(screen, dock_left_, fraction_);
  dock_left_ = g.DockLeftForBallLeft(ball_left_);
  fraction_ = g.FractionForTop(ball_top_);
  const fb::Geometry settled = CurrentGeometry();
  if (config_.animate) {
    snap_anim_.Start(ball_left_, ball_top_, settled.CollapsedBallLeft(),
                     settled.BallTop(), NowMs());
    EnsureAnimationTimer();
  } else {
    CancelAnimations();
    ball_left_ = settled.CollapsedBallLeft();
    ball_top_ = settled.BallTop();
  }
  PlaceBall();
  if (on_position_) on_position_(dock_left_, fraction_);
}

void FloatingBallWindow::OnScreenChanged(GdkScreen*, gpointer data) {
  static_cast<FloatingBallWindow*>(data)->OnDisplayEnvironmentChanged();
}

void FloatingBallWindow::OnDisplayEnvironmentChanged() {
  if (ball_ == nullptr || dragging_) return;
  const double ball = BallPx();
  GdkMonitor* monitor = MonitorAt(ball_left_ + ball / 2, ball_top_ + ball / 2);
  const Screen screen = ScreenFor(monitor, ball_top_ + ball / 2);
  const fb::Rect& v = screen.viewport;
  // Only when the viewport or scale really changed (the signals also fire for
  // unrelated changes): otherwise a freshly opened menu would snap shut.
  if (screen.monitor == monitor_ && v.left == last_work_.left &&
      v.top == last_work_.top && v.right == last_work_.right &&
      v.bottom == last_work_.bottom && screen.scale == scale_) {
    return;
  }
  // The position is stored as edge + fraction: recomputed in the new viewport,
  // it always lands on screen.
  monitor_ = screen.monitor;
  CollapseImmediately();
}

// ── drawing ──────────────────────────────────────────────────────────────────

void FloatingBallWindow::PlaceBall() {
  if (ball_ == nullptr) return;
  const int size = BallWindowSize();
  const double ball = BallPx();
  const int x = static_cast<int>(std::lround(ball_left_ + ball / 2 - size / 2.0));
  const int y = static_cast<int>(std::lround(ball_top_ + ball / 2 - size / 2.0));
  int width = 0;
  int height = 0;
  gtk_widget_get_size_request(ball_, &width, &height);
  if (width != size || height != size) {
    gtk_widget_set_size_request(ball_, size, size);
    gtk_window_resize(GTK_WINDOW(ball_), size, size);
  }
  // Only the ball takes clicks, not the shadow pad around it.
  const double pad = (size - ball) / 2;
  cairo_region_t* region = cairo_region_create();
  const cairo_rectangle_int_t rect = {
      static_cast<int>(std::floor(pad)), static_cast<int>(std::floor(pad)),
      static_cast<int>(std::ceil(ball)), static_cast<int>(std::ceil(ball))};
  cairo_region_union_rectangle(region, &rect);
  gtk_widget_input_shape_combine_region(ball_, region);
  if (!gdk_screen_is_composited(gtk_widget_get_screen(ball_))) {
    cairo_region_destroy(region);
    region = cairo_region_create();
    AddCircle(region, size / 2.0, size / 2.0, ball / 2);
    gtk_widget_shape_combine_region(ball_, region);
  }
  cairo_region_destroy(region);
  if (x != ball_window_x_ || y != ball_window_y_ ||
      !gtk_widget_get_visible(ball_)) {
    gtk_window_move(GTK_WINDOW(ball_), x, y);
  }
  ball_window_x_ = x;
  ball_window_y_ = y;
  gtk_widget_queue_draw(ball_);
}

gboolean FloatingBallWindow::OnBallDraw(GtkWidget*, cairo_t* cr,
                                        gpointer data) {
  static_cast<FloatingBallWindow*>(data)->DrawBall(cr);
  return TRUE;
}

gboolean FloatingBallWindow::OnMenuDraw(GtkWidget*, cairo_t* cr,
                                        gpointer data) {
  static_cast<FloatingBallWindow*>(data)->DrawMenu(cr);
  return TRUE;
}

void FloatingBallWindow::DrawBall(cairo_t* cr) {
  cairo_save(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0, 0, 0, 0);
  cairo_paint(cr);
  cairo_restore(cr);

  const double ball = BallPx();
  const double bx = ball_left_ - ball_window_x_;
  const double by = ball_top_ - ball_window_y_;
  const double r = ball / 2;
  const double cx = bx + r;
  const double cy = by + r;
  const double t = std::clamp(progress_, 0.0, 1.0);
  const double scale = scale_;
  const bool outlined = ((config_.outline >> 24) & 0xFF) != 0;

  cairo_push_group(cr);
  // Shadow deepens as the ball opens (M3E elevation 1 → 3); none on e-ink.
  if (!outlined) {
    const double pad = fb::kBallShadowPadDip * scale;
    const double blur = std::min(pad, (1.5 + 3.0 * t) * scale);
    DrawSoftShadow(cr, cx, cy + (0.5 + t) * scale, r, blur, 0.14 + 0.10 * t);
  }
  // M3E FAB menu toggle: collapsed = rounded square (14) with the ball face;
  // opening morphs to a circle with primary fill and the onPrimary ×.
  const double corner = fb::kBallCollapsedRadiusDip * scale;
  const double radius = std::min(r, corner + (r - corner) * t);
  const int image_px = static_cast<int>(std::ceil(ball));
  GdkPixbuf* image =
      t < 1.0 ? PixbufFor("ball", config_.ball_image, image_px, true) : nullptr;
  cairo_save(cr);
  RoundedRectPath(cr, bx, by, 2 * r, 2 * r, radius);
  cairo_clip(cr);
  if (image != nullptr) {
    cairo_save(cr);
    cairo_translate(cr, bx, by);
    const double s = 2 * r / gdk_pixbuf_get_width(image);
    cairo_scale(cr, s, s);
    gdk_cairo_set_source_pixbuf(cr, image, 0, 0);
    cairo_paint(cr);
    cairo_restore(cr);
  } else {
    SetArgb(cr, config_.ball_container);
    cairo_paint(cr);
  }
  if (t > 0) {
    SetArgb(cr, config_.ball_open, t);
    cairo_paint(cr);
  }
  cairo_restore(cr);
  if (t > 0) {
    const auto it = config_.icon_images.find("ball_close");
    if (it != config_.icon_images.end()) {
      const int icon_px = static_cast<int>(std::ceil(fb::kIconDip * scale));
      GdkPixbuf* icon = PixbufFor("icon:ball_close", it->second, icon_px, false);
      if (icon != nullptr) {
        const double half = fb::kIconDip * scale / 2;
        cairo_save(cr);
        cairo_translate(cr, cx - half, cy - half);
        const double s = 2 * half / gdk_pixbuf_get_width(icon);
        cairo_scale(cr, s, s);
        gdk_cairo_set_source_pixbuf(cr, icon, 0, 0);
        cairo_paint_with_alpha(cr, t);
        cairo_restore(cr);
      }
    }
  }
  if (outlined) {
    const double stroke = 1.5 * scale;
    RoundedRectPath(cr, bx + stroke / 2, by + stroke / 2, 2 * r - stroke,
                    2 * r - stroke, std::max(0.0, radius - stroke / 2));
    SetArgb(cr, config_.outline);
    cairo_set_line_width(cr, stroke);
    cairo_stroke(cr);
  }
  cairo_pop_group_to_source(cr);
  cairo_paint_with_alpha(cr, fb::BallOpacity(t, dragging_));
}

void FloatingBallWindow::DrawMenu(cairo_t* cr) {
  cairo_save(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0, 0, 0, 0);
  cairo_paint(cr);
  cairo_restore(cr);

  const double scale = menu_scale_;
  // M3E tonal small buttons (in-app _ColumnButton): secondaryContainer fill,
  // onSecondaryContainer state layer; e-ink: surface + outline, no shadow.
  const uint32_t base =
      config_.button_container != 0
          ? config_.button_container
          : AlphaBlend(WithAlpha(config_.on_surface, 0.06), config_.surface);
  const uint32_t on_base = config_.on_button_container != 0
                               ? config_.on_button_container
                               : config_.on_surface;
  const bool outlined = ((config_.outline >> 24) & 0xFF) != 0;
  const int icon_px = static_cast<int>(std::ceil(fb::kIconDip * scale));
  PangoLayout* layout = nullptr;
  if (!menu_labels_.empty()) {
    layout = pango_cairo_create_layout(cr);
    PangoFontDescription* font = LabelFont();
    pango_layout_set_font_description(layout, font);
    pango_font_description_free(font);
    pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
  }
  for (int i = 0; i < static_cast<int>(menu_ids_.size()); ++i) {
    double cx, cy, r, opacity;
    if (!ButtonCircle(i, &cx, &cy, &r, &opacity) || opacity <= 0) continue;
    const bool active = i == pressed_ || i == hovered_;
    const double overlay = i == pressed_ ? 0.10 : 0.08;
    double l, t, w, h, lo;
    if (layout != nullptr && LabelRect(i, &l, &t, &w, &h, &lo) && lo > 0) {
      const double radius = h / 2;
      if (!outlined) {
        RoundedRectPath(cr, l, t + scale, w, h, radius);
        cairo_set_source_rgba(cr, 0, 0, 0, 0.12 * lo);
        cairo_fill(cr);
      }
      RoundedRectPath(cr, l, t, w, h, radius);
      SetArgb(cr, base, lo);
      cairo_fill_preserve(cr);
      if (active) {
        SetArgb(cr, WithAlpha(on_base, overlay), lo);
        cairo_fill_preserve(cr);
      }
      cairo_new_path(cr);
      if (outlined) {
        const double stroke = 1.5 * scale;
        RoundedRectPath(cr, l + stroke / 2, t + stroke / 2, w - stroke,
                        h - stroke, radius - stroke / 2);
        SetArgb(cr, config_.outline, lo);
        cairo_set_line_width(cr, stroke);
        cairo_stroke(cr);
      }
      const double pad = fb::kLabelPaddingDip * scale;
      pango_layout_set_text(layout, menu_labels_[i].text.c_str(), -1);
      pango_layout_set_width(
          layout, static_cast<int>(std::max(0.0, w - 2 * pad) * PANGO_SCALE));
      PangoRectangle logical;
      pango_layout_get_pixel_extents(layout, nullptr, &logical);
      cairo_move_to(cr, l + pad, t + (h - logical.height) / 2);
      SetArgb(cr, on_base, lo);
      pango_cairo_show_layout(cr, layout);
    }
    if (!outlined) {
      DrawSoftShadow(cr, cx, cy + 0.5 * scale, r, 1.5 * scale, 0.14 * opacity);
    }
    cairo_arc(cr, cx, cy, r, 0, 2 * G_PI);
    SetArgb(cr, base, opacity);
    cairo_fill_preserve(cr);
    if (active) {
      SetArgb(cr, WithAlpha(on_base, overlay), opacity);
      cairo_fill_preserve(cr);
    }
    cairo_new_path(cr);
    if (outlined) {
      const double stroke = 1.5 * scale;
      cairo_arc(cr, cx, cy, r - stroke / 2, 0, 2 * G_PI);
      SetArgb(cr, config_.outline, opacity);
      cairo_set_line_width(cr, stroke);
      cairo_stroke(cr);
    }
    const auto it = config_.icon_images.find(menu_ids_[i]);
    if (it != config_.icon_images.end()) {
      GdkPixbuf* icon =
          PixbufFor("icon:" + menu_ids_[i], it->second, icon_px, false);
      if (icon != nullptr) {
        // Icon scales with the button as it flies out.
        const double half =
            fb::kIconDip * scale / 2 * (r / (fb::kButtonDip * scale / 2));
        cairo_save(cr);
        cairo_translate(cr, cx - half, cy - half);
        const double s = 2 * half / gdk_pixbuf_get_width(icon);
        cairo_scale(cr, s, s);
        gdk_cairo_set_source_pixbuf(cr, icon, 0, 0);
        cairo_paint_with_alpha(cr, opacity);
        cairo_restore(cr);
      }
    }
  }
  if (layout != nullptr) g_object_unref(layout);
}

GdkPixbuf* FloatingBallWindow::PixbufFor(const std::string& key,
                                         const std::vector<uint8_t>& png,
                                         int px, bool crop_square) {
  if (px <= 0) return nullptr;
  CachedPixbuf& entry = pixbufs_[key];
  if (entry.px == px && (entry.pixbuf != nullptr || entry.failed)) {
    return entry.pixbuf;
  }
  g_clear_object(&entry.pixbuf);
  entry.px = px;
  entry.failed = true;
  if (png.empty()) return nullptr;
  GdkPixbufLoader* loader = gdk_pixbuf_loader_new();
  const bool ok =
      gdk_pixbuf_loader_write(loader, png.data(), png.size(), nullptr) &&
      gdk_pixbuf_loader_close(loader, nullptr);
  GdkPixbuf* decoded = ok ? gdk_pixbuf_loader_get_pixbuf(loader) : nullptr;
  if (decoded != nullptr) {
    // Ball face: centre square. Scale once to the target size (a 1024² face
    // drawn straight at 48 px would alias badly).
    int w = gdk_pixbuf_get_width(decoded);
    int h = gdk_pixbuf_get_height(decoded);
    GdkPixbuf* source = decoded;
    GdkPixbuf* cropped = nullptr;
    if (crop_square && w != h && w > 0 && h > 0) {
      const int side = std::min(w, h);
      cropped = gdk_pixbuf_new_subpixbuf(decoded, (w - side) / 2,
                                         (h - side) / 2, side, side);
      source = cropped;
    }
    entry.pixbuf = gdk_pixbuf_scale_simple(source, px, px, GDK_INTERP_HYPER);
    if (cropped != nullptr) g_object_unref(cropped);
    entry.failed = entry.pixbuf == nullptr;
  }
  g_object_unref(loader);
  return entry.pixbuf;
}

void FloatingBallWindow::ClearPixbufCache() noexcept {
  for (auto& [key, entry] : pixbufs_) g_clear_object(&entry.pixbuf);
  pixbufs_.clear();
}

// ── input ────────────────────────────────────────────────────────────────────

gboolean FloatingBallWindow::OnBallPress(GtkWidget*, GdkEventButton* event,
                                         gpointer data) {
  auto* self = static_cast<FloatingBallWindow*>(data);
  if (event->type != GDK_BUTTON_PRESS || event->button != 1) return TRUE;
  self->pressing_ball_ = true;
  self->dragging_ = false;
  self->down_x_ = event->x_root;
  self->down_y_ = event->y_root;
  return TRUE;
}

gboolean FloatingBallWindow::OnBallMotion(GtkWidget*, GdkEventMotion* event,
                                          gpointer data) {
  auto* self = static_cast<FloatingBallWindow*>(data);
  if (!self->pressing_ball_) return TRUE;
  if (!self->dragging_) {
    // Beyond the drag threshold it is a drag; within it, a click.
    int threshold = 8;
    g_object_get(gtk_settings_get_default(), "gtk-dnd-drag-threshold",
                 &threshold, nullptr);
    if (std::fabs(event->x_root - self->down_x_) <= threshold &&
        std::fabs(event->y_root - self->down_y_) <= threshold) {
      return TRUE;
    }
    self->BeginDrag();
  }
  self->DragTo(event->x_root, event->y_root);
  return TRUE;
}

gboolean FloatingBallWindow::OnBallRelease(GtkWidget*, GdkEventButton* event,
                                           gpointer data) {
  auto* self = static_cast<FloatingBallWindow*>(data);
  if (event->button != 1 || !self->pressing_ball_) return TRUE;
  self->pressing_ball_ = false;
  if (self->dragging_) {
    self->EndDrag();
  } else {
    self->SetExpanded(!self->expand_target_);
  }
  return TRUE;
}

gboolean FloatingBallWindow::OnBallGrabBroken(GtkWidget*, GdkEvent*,
                                              gpointer data) {
  // Someone else took the pointer: treat as a release.
  auto* self = static_cast<FloatingBallWindow*>(data);
  if (self->pressing_ball_) {
    self->pressing_ball_ = false;
    if (self->dragging_) self->EndDrag();
  }
  return FALSE;
}

gboolean FloatingBallWindow::OnMenuPress(GtkWidget*, GdkEventButton* event,
                                         gpointer data) {
  auto* self = static_cast<FloatingBallWindow*>(data);
  if (event->type != GDK_BUTTON_PRESS || event->button != 1) return TRUE;
  self->pressed_ = self->ButtonAt(event->x, event->y);
  if (self->menu_ != nullptr) gtk_widget_queue_draw(self->menu_);
  return TRUE;
}

gboolean FloatingBallWindow::OnMenuMotion(GtkWidget*, GdkEventMotion* event,
                                          gpointer data) {
  auto* self = static_cast<FloatingBallWindow*>(data);
  const int hit = self->ButtonAt(event->x, event->y);
  if (hit != self->hovered_) {
    self->hovered_ = hit;
    if (self->menu_ != nullptr) gtk_widget_queue_draw(self->menu_);
  }
  return TRUE;
}

gboolean FloatingBallWindow::OnMenuRelease(GtkWidget*, GdkEventButton* event,
                                           gpointer data) {
  auto* self = static_cast<FloatingBallWindow*>(data);
  if (event->button != 1) return TRUE;
  const int pressed = self->pressed_;
  self->pressed_ = -1;
  const int hit = self->ButtonAt(event->x, event->y);
  if (pressed >= 0 && pressed == hit) {
    // May Stop() and destroy this window: touch nothing after.
    self->RunButton(pressed);
    return TRUE;
  }
  if (self->menu_ != nullptr) gtk_widget_queue_draw(self->menu_);
  return TRUE;
}

gboolean FloatingBallWindow::OnMenuLeave(GtkWidget*, GdkEventCrossing*,
                                         gpointer data) {
  auto* self = static_cast<FloatingBallWindow*>(data);
  if (self->hovered_ >= 0) {
    self->hovered_ = -1;
    if (self->menu_ != nullptr) gtk_widget_queue_draw(self->menu_);
  }
  return FALSE;
}

gboolean FloatingBallWindow::OnMenuQueryTooltip(GtkWidget*, gint x, gint y,
                                                gboolean, GtkTooltip* tooltip,
                                                gpointer data) {
  auto* self = static_cast<FloatingBallWindow*>(data);
  // Labels already show the names; tooltips only stand in when they are off.
  if (!self->menu_labels_.empty() || self->pressed_ >= 0) return FALSE;
  const int hit = self->ButtonAt(x, y);
  if (hit < 0) return FALSE;
  gtk_tooltip_set_text(tooltip, self->LabelFor(self->menu_ids_[hit]).c_str());
  double cx, cy, r, o;
  if (self->ButtonCircle(hit, &cx, &cy, &r, &o)) {
    const GdkRectangle area = {static_cast<int>(cx - r), static_cast<int>(cy - r),
                               static_cast<int>(2 * r), static_cast<int>(2 * r)};
    gtk_tooltip_set_tip_area(tooltip, &area);
  }
  return TRUE;
}
