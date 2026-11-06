#ifndef RUNNER_FLOATING_BALL_WINDOW_H_
#define RUNNER_FLOATING_BALL_WINDOW_H_

#include <gtk/gtk.h>

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

// Shared with the Windows runner: pure geometry and animation curves, no
// platform API (spec docs/specs/2026-09-30-desktop-system-floating-ball.md).
#include "../../windows/runner/floating_ball_geometry.h"

// Desktop system floating ball on Linux (X11 sessions, e.g. Steam Deck desktop
// mode). Same shape as the Windows FloatingBallWindow:
//   - ball window: fixed size (ball + shadow pad), only ever moves;
//   - button window: built at the final expanded geometry when the ball opens,
//     buttons start fully transparent and only animate (BUG-2793: no grow-then-
//     move jump); destroyed when the collapse animation ends.
// Both are unmanaged (override-redirect) popups: never placed, constrained or
// focused by the window manager (selection lookup must still read the app the
// user is in), above all managed windows, moved directly. An input shape lets
// transparent pixels click through. Native only draws, drags, snaps and animates; it reports "which
// button, where is the ball" to Dart and runs no lookup logic.
//
// Coordinates are GDK root coordinates (logical pixels). Values sent to Dart are
// physical pixels (logical x monitor scale factor), top-left origin, like the
// global_lookup channel. All methods run on the GTK main thread.
class FloatingBallWindow {
 public:
  struct Config {
    bool animate = true;
    bool show_labels = true;
    bool show_open_app = true;
    std::vector<std::string> actions;
    std::map<std::string, std::string> labels;
    std::map<std::string, std::vector<uint8_t>> icon_images;
    std::vector<uint8_t> ball_image;
    uint32_t surface = 0xFFFEF7FF;
    uint32_t on_surface = 0xFF1D1B20;
    uint32_t primary = 0xFF6750A4;
    uint32_t ball_container = 0xFFEADDFF;
    uint32_t button_container = 0;
    uint32_t on_button_container = 0;
    uint32_t outline = 0;
    uint32_t ball_open = 0xFF6750A4;
    uint32_t on_ball_open = 0xFFFFFFFF;
  };

  struct PhysicalRect {
    int left = 0;
    int top = 0;
    int right = 0;
    int bottom = 0;
  };

  struct ProfileMenuItem {
    int64_t id = 0;
    std::string label;
    bool checked = false;
  };

  using ActionCallback =
      std::function<void(const std::string& id, const PhysicalRect& anchor)>;
  using ClosedCallback = std::function<void()>;
  using PositionCallback = std::function<void(bool dock_left, double fraction)>;
  using ProfileMenuCallback = std::function<void(std::optional<int64_t>)>;

  FloatingBallWindow();
  ~FloatingBallWindow();

  FloatingBallWindow(const FloatingBallWindow&) = delete;
  FloatingBallWindow& operator=(const FloatingBallWindow&) = delete;

  void SetActionCallback(ActionCallback callback) {
    on_action_ = std::move(callback);
  }
  void SetClosedCallback(ClosedCallback callback) {
    on_closed_ = std::move(callback);
  }
  void SetPositionCallback(PositionCallback callback) {
    on_position_ = std::move(callback);
  }

  // Not running: create on the monitor of |monitor_hint| at |dock_left| +
  // |fraction|. Running: update buttons / colours / images in place (collapse,
  // keep the position). False when the windows cannot be created.
  bool Start(const Config& config, bool dock_left, double fraction,
             GtkWindow* monitor_hint);
  // Destroys all windows without callbacks, except a pending profile menu which
  // finishes with an empty result (Dart awaits it).
  void Stop();
  bool IsRunning() const { return ball_ != nullptr; }

  // Screen OCR: hide the ball while the screen is captured, restore afterwards.
  void HideForCapture();
  void RestoreAfterCapture();
  // Fushi is in front with the in-app ball on: hide (Dart setAppForeground).
  // Kept across Stop / Start.
  void SetHiddenForApp(bool hidden);

  // Native popup menu beside the ball (Dart showProfileMenu). |anchor| is the
  // physical rect systemBallAction reported; empty = at the pointer. |done| runs
  // exactly once.
  void ShowProfileMenu(std::vector<ProfileMenuItem> items,
                       std::optional<PhysicalRect> anchor,
                       ProfileMenuCallback done);

 private:
  struct Screen {
    GdkMonitor* monitor = nullptr;
    fushi::floating_ball::Rect viewport;
    double scale = 1.0;
    bool tuck_left = true;
    bool tuck_right = true;
  };

  struct Label {
    std::string text;
    double width = 0;
  };

  // GTK signal trampolines.
  static gboolean OnBallDraw(GtkWidget* widget, cairo_t* cr, gpointer data);
  static gboolean OnMenuDraw(GtkWidget* widget, cairo_t* cr, gpointer data);
  static gboolean OnBallPress(GtkWidget* widget, GdkEventButton* event,
                              gpointer data);
  static gboolean OnBallMotion(GtkWidget* widget, GdkEventMotion* event,
                               gpointer data);
  static gboolean OnBallRelease(GtkWidget* widget, GdkEventButton* event,
                                gpointer data);
  static gboolean OnBallGrabBroken(GtkWidget* widget, GdkEvent* event,
                                   gpointer data);
  static gboolean OnMenuPress(GtkWidget* widget, GdkEventButton* event,
                              gpointer data);
  static gboolean OnMenuMotion(GtkWidget* widget, GdkEventMotion* event,
                               gpointer data);
  static gboolean OnMenuRelease(GtkWidget* widget, GdkEventButton* event,
                                gpointer data);
  static gboolean OnMenuLeave(GtkWidget* widget, GdkEventCrossing* event,
                              gpointer data);
  static gboolean OnMenuQueryTooltip(GtkWidget* widget, gint x, gint y,
                                     gboolean keyboard, GtkTooltip* tooltip,
                                     gpointer data);
  static gboolean OnAnimationTick(gpointer data);
  static void OnScreenChanged(GdkScreen* screen, gpointer data);

  GtkWidget* NewOverlayWindow(int width, int height);
  void ConnectScreenSignals();
  void DisconnectScreenSignals() noexcept;
  // Destroys every window and drops a pending profile menu without answering it.
  void Teardown() noexcept;

  std::vector<std::string> ButtonIds() const {
    return fushi::floating_ball::ButtonIds(config_.show_open_app,
                                           config_.actions);
  }
  std::string LabelFor(const std::string& id) const;

  Screen ScreenFor(GdkMonitor* monitor, double probe_y) const;
  fushi::floating_ball::Geometry GeometryFor(const Screen& screen,
                                             bool dock_left,
                                             double fraction) const;
  fushi::floating_ball::Geometry CurrentGeometry();
  GdkMonitor* MonitorAt(double x, double y) const;

  int BallWindowSize() const;
  double BallPx() const;
  PhysicalRect BallPhysicalRect() const;

  void SetExpanded(bool expand);
  void AnimateProgress(double target, int full_ms);
  void CollapseImmediately();
  void CancelAnimations() noexcept;
  void SetProgress(double t);
  void EnsureAnimationTimer();
  bool Tick();

  void EnsureMenuWindow();
  void DestroyMenuWindow() noexcept;
  bool ButtonCircle(int index, double* cx, double* cy, double* radius,
                    double* opacity) const;
  bool LabelRect(int index, double* left, double* top, double* width,
                 double* height, double* opacity) const;
  int ButtonAt(double x, double y) const;
  void PrepareMenuLabels(const fushi::floating_ball::Geometry& g);
  void RunButton(int index);

  void BeginDrag();
  void DragTo(double root_x, double root_y);
  void EndDrag();
  void OnDisplayEnvironmentChanged();

  void PlaceBall();
  void UpdateMenuInputShape();
  void DrawBall(cairo_t* cr);
  void DrawMenu(cairo_t* cr);
  // Decoded, scaled image for |key| (cached per pixel size).
  GdkPixbuf* PixbufFor(const std::string& key, const std::vector<uint8_t>& png,
                       int px, bool crop_square);
  void ClearPixbufCache() noexcept;
  PangoFontDescription* LabelFont() const;

  bool Suppressed() const { return hidden_for_capture_ || hidden_for_app_; }
  void ShowWindows();
  void HideWindows();
  void FinishProfileMenu(std::optional<int64_t> selected);

  Config config_;
  bool dock_left_ = false;
  double fraction_ = 1.0 / 3.0;
  GdkMonitor* monitor_ = nullptr;
  double scale_ = 1.0;
  fushi::floating_ball::Rect last_work_;

  GtkWidget* ball_ = nullptr;
  GtkWidget* menu_ = nullptr;
  bool hidden_for_capture_ = false;
  bool hidden_for_app_ = false;
  gulong monitors_changed_handler_ = 0;
  gulong size_changed_handler_ = 0;

  double ball_left_ = 0;
  double ball_top_ = 0;
  int ball_window_x_ = 0;
  int ball_window_y_ = 0;

  double progress_ = 0;
  bool expand_target_ = false;
  fushi::floating_ball::ProgressAnimation progress_anim_;
  fushi::floating_ball::SnapAnimation snap_anim_;
  guint timer_id_ = 0;

  bool pressing_ball_ = false;
  bool dragging_ = false;
  double down_x_ = 0;
  double down_y_ = 0;
  double drag_start_left_ = 0;
  double drag_start_top_ = 0;

  // Button window: bounding box, expanded ball centre and landing spots.
  fushi::floating_ball::MenuLayout menu_layout_;
  std::vector<std::string> menu_ids_;
  std::vector<Label> menu_labels_;
  double menu_scale_ = 1.0;
  int hovered_ = -1;
  int pressed_ = -1;

  struct CachedPixbuf {
    int px = 0;
    GdkPixbuf* pixbuf = nullptr;
    bool failed = false;
  };
  std::map<std::string, CachedPixbuf> pixbufs_;

  GtkWidget* profile_menu_ = nullptr;
  ProfileMenuCallback profile_menu_done_;
  std::optional<int64_t> profile_menu_selected_;

  ActionCallback on_action_;
  ClosedCallback on_closed_;
  PositionCallback on_position_;
};

#endif  // RUNNER_FLOATING_BALL_WINDOW_H_
