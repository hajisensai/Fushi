#ifndef RUNNER_FLOATING_LYRIC_WINDOW_H_
#define RUNNER_FLOATING_LYRIC_WINDOW_H_

#include <gtk/gtk.h>
#include <pango/pangocairo.h>

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

// Floating subtitles / desktop lyrics on Linux (audiobook floating subtitles and
// music desktop lyrics share one window). Same `app.fushi.reader/floating_lyric`
// contract as windows/runner/floating_lyric_window.cpp and
// macos/Runner/FushiFloatingLyric.swift: Dart owns text, style, playback state
// and the persisted window rect; this class only draws, hit-tests, drags and
// resizes, and reports "which character (with its screen rect) / which button /
// where the window is now".
//
// One window: body text below a toolbar band at the top. The toolbar pill (same
// six slots as Windows kAudiobookSlotActions: previous / play-pause / next /
// lock / topmost / close) shows while the pointer is over the window, and always
// in pass-through mode. Pass-through is an input shape that only covers the
// pill: the text lets clicks fall to the window below, the pill stays clickable
// (the BUG-951 escape hatch), so no second window is needed.
//
// Back-ends, picked once per process from the GDK display:
//   - kX11 (X11 sessions, and GDK_BACKEND=x11 under XWayland, which is what the
//     Flatpak pins): topmost = unmanaged (override-redirect) popup, above every
//     managed window including full-screen ones, never focused, moved directly;
//     not topmost = an undecorated managed window the user can bury under other
//     windows (no taskbar entry, never takes focus). Toggling recreates the
//     window in place.
//   - kLayerShell (Wayland compositors with wlr-layer-shell: KDE Plasma, wlroots
//     based, Hyprland ...; libgtk-layer-shell.so.0 loaded at runtime, so it is
//     neither a build nor a hard runtime dependency): an overlay-layer surface
//     anchored top-left whose margins are the position; not topmost = bottom
//     layer (under application windows, above the wallpaper). Same drag /
//     resize / restore / pass-through as X11. Shift-hover lookup while passing
//     through is unavailable: Wayland does not report the pointer outside the
//     surface's input region.
//   - kWaylandToplevel (Wayland without layer-shell, e.g. GNOME Mutter): degraded
//     to an undecorated normal window. Wayland lets no client place itself or
//     stay on top, so the compositor places it, dragging / resizing are handed
//     to the compositor (interactive move / resize), the position is neither
//     restored nor reported, topmost is not enforced, pass-through is refused
//     (passThroughChanged(false)) and clicks report no word rect (Dart anchors
//     the lookup card at the pointer).
//
// Coordinates: GDK root coordinates (logical px). Word rects sent to Dart are
// logical screen px (Dart multiplies by the main window's device pixel ratio,
// like on Windows / macOS); window rects are physical px (logical x the scale of
// the monitor the window is on). All methods run on the GTK main thread.
class FloatingLyricWindow {
 public:
  enum class Backend { kX11, kLayerShell, kWaylandToplevel };

  // Channel style keys (same names as Windows StyleFromArgs / macOS
  // FloatingLyricMacStyle). Every show / updateStyle parses from defaults again:
  // a missing key means the default, not "keep the previous value".
  struct Style {
    double font_size = 20;
    std::string font_family;
    std::string font_path;
    double letter_spacing = 0;
    double line_height = 1.0;
    bool bold = true;
    // 0 = centred, 1 = left.
    int text_alignment = 0;
    // 0 = vertically centred (top when overflowing), 1 = always top.
    int vertical_alignment = 0;
    uint32_t text_color = 0xFFFFFFFF;
    uint32_t bg_color = 0xCC000000;
    uint32_t outline_color = 0xE0000000;
    double outline_width = 1.6;
    double text_padding = 20;
    uint32_t button_text_color = 0xFFFFFFFF;
    uint32_t button_bg_color = 0x33000000;
    uint32_t highlight_color = 0x80FFD54F;
    uint32_t active_color = 0xFFFFD54F;
    uint32_t toolbar_bg_color = 0;
    uint32_t toolbar_icon_color = 0;
    uint32_t toolbar_hover_color = 0;
    uint32_t toolbar_active_bg_color = 0;
    uint32_t toolbar_active_icon_color = 0;
    // 0 is a real value (square corners), not a sentinel.
    double corner_radius = 14;
    // 0 = platform default width (720 + draggable).
    double window_width = 0;
    double window_height = 0;
    // Alpha 0 = the current line keeps text_color.
    uint32_t current_line_color = 0;
    double context_line_opacity = 0.55;
  };

  struct PhysicalRect {
    int left = 0;
    int top = 0;
    int width = 0;
    int height = 0;
  };

  // Logical screen px rect of the clicked character; empty on kWaylandToplevel.
  struct WordRect {
    double left = 0;
    double top = 0;
    double width = 0;
    double height = 0;
  };

  using LookupCallback = std::function<void(
      const std::string& text, const std::string& line_id, int index,
      const std::optional<WordRect>& word)>;
  // previousCue / playPause / nextCue / close.
  using ControlCallback = std::function<void(const std::string& action)>;
  using BoolCallback = std::function<void(bool)>;
  using BoundsCallback = std::function<void(const PhysicalRect&)>;

  // Toolbar slot actions, same order as Windows hook_toolbar::
  // kAudiobookSlotActions, macOS kFloatingLyricSlotActions and Dart
  // `_slotTooltips` (change one, change all four).
  static const std::vector<std::string>& SlotActions();

  explicit FloatingLyricWindow(GtkWindow* main_window);
  ~FloatingLyricWindow();

  FloatingLyricWindow(const FloatingLyricWindow&) = delete;
  FloatingLyricWindow& operator=(const FloatingLyricWindow&) = delete;

  void SetLookupCallback(LookupCallback cb) { on_lookup_ = std::move(cb); }
  void SetControlCallback(ControlCallback cb) { on_control_ = std::move(cb); }
  void SetLockCallback(BoolCallback cb) { on_lock_ = std::move(cb); }
  void SetPassThroughCallback(BoolCallback cb) {
    on_pass_through_ = std::move(cb);
  }
  void SetBoundsCallback(BoundsCallback cb) { on_bounds_ = std::move(cb); }

  Backend backend() const { return backend_; }
  static const char* BackendName(Backend backend);

  struct ShowOptions {
    Style style;
    bool click_lookup_enabled = true;
    bool hover_auto_lookup = false;
    bool pass_through = false;
    bool topmost = true;
    std::optional<bool> locked;
    std::optional<std::vector<std::string>> slot_tooltips;
    std::optional<PhysicalRect> rect;
  };
  // False when the window cannot be created.
  bool Show(const ShowOptions& options);
  void Hide();
  bool IsShowing() const;

  void UpdateText(const std::string& text, int current_line_start,
                  int current_line_length, const std::string& line_id);
  void Highlight(int start, int length);
  void UpdateStyle(const Style& style);
  void UpdateLabels(const std::map<std::string, std::string>& labels);
  void SetPlaying(bool playing);
  void SetClickLookupEnabled(bool enabled) { click_lookup_enabled_ = enabled; }
  void SetLocked(bool locked);
  // Reports the outcome with the pass-through callback (it may be refused).
  void SetPassThrough(bool enabled);
  void SetHoverAutoLookup(bool enabled);

  // ── test hooks (FUSHI_TEST_FLOATING_LYRIC) ──────────────────────────────
  struct Probe {
    bool visible = false;
    bool locked = false;
    bool topmost = true;
    bool pass_through = false;
    bool toolbar_shown = false;
    bool override_redirect = false;
    bool composited = false;
    std::string text;
    int highlight_start = -1;
    int highlight_length = 0;
    double scroll_offset = 0;
    double scroll_max = 0;
    double content_height = 0;
    double x = 0, y = 0, width = 0, height = 0;  // logical root
    PhysicalRect physical;
    unsigned long xid = 0;
    std::string backend;
  };
  Probe GetProbe();
  // Presses and releases on the centre of UTF-16 character |index| through the
  // same handlers as a real pointer. False when it is not laid out.
  bool ClickChar(int index, double* local_x, double* local_y);
  // Drags the body by (dx, dy) logical px through the drag handlers.
  void DragBy(double dx, double dy);
  void ToolbarAction(const std::string& action);
  // Renders the window with the real draw code into a PNG.
  bool Snapshot(const std::string& path);

 private:
  enum class Press { kNone, kBody, kDrag, kResize, kToolbarButton,
                     kToolbarBackground };

  struct Monitor {
    GdkMonitor* monitor = nullptr;
    GdkRectangle geometry{};
    GdkRectangle workarea{};
    int scale = 1;
  };

  static gboolean OnDraw(GtkWidget* w, cairo_t* cr, gpointer data);
  static gboolean OnPress(GtkWidget* w, GdkEventButton* e, gpointer data);
  static gboolean OnRelease(GtkWidget* w, GdkEventButton* e, gpointer data);
  static gboolean OnMotion(GtkWidget* w, GdkEventMotion* e, gpointer data);
  static gboolean OnEnter(GtkWidget* w, GdkEventCrossing* e, gpointer data);
  static gboolean OnLeave(GtkWidget* w, GdkEventCrossing* e, gpointer data);
  static gboolean OnScroll(GtkWidget* w, GdkEventScroll* e, gpointer data);
  static gboolean OnQueryTooltip(GtkWidget* w, gint x, gint y, gboolean kb,
                                 GtkTooltip* tooltip, gpointer data);
  static gboolean OnHoverTick(gpointer data);
  static void OnMonitorsChanged(GdkScreen* screen, gpointer data);
  static gboolean OnConfigure(GtkWidget* w, GdkEventConfigure* e,
                              gpointer data);
  static gboolean OnRecreateIdle(gpointer data);

  // Window lifetime.
  bool CreateWindow();
  void DestroyWindow() noexcept;
  void ApplySize();
  void ApplyPosition();
  void ApplyLayer();
  void UpdateInputShape();

  // Geometry.
  std::vector<Monitor> Monitors() const;
  std::optional<Monitor> MonitorAt(double x, double y) const;
  Monitor DefaultMonitor() const;
  void ClampSize(double* w, double* h) const;
  void ClampOriginInto(const GdkRectangle& work, double* x, double* y) const;
  void ClampOriginOnScreen();
  PhysicalRect ToPhysical() const;
  bool FromPhysical(const PhysicalRect& p, double* x, double* y, double* w,
                    double* h) const;
  bool KnowsPosition() const { return backend_ != Backend::kWaylandToplevel; }
  void NotifyBounds();
  void RelayoutForScreenChange();
  void ApplyStyleWidth();

  // Layout.
  struct Rect {
    double x = 0, y = 0, w = 0, h = 0;
    bool Contains(double px, double py) const {
      return px >= x && py >= y && px < x + w && py < y + h;
    }
  };
  Rect TextRect() const;
  Rect ToolbarRect() const;
  Rect SlotRect(int slot) const;
  int SlotAt(double x, double y) const;
  void EnsureLayout(double width);
  void EnsureFontMap();
  // Origin of the text block in window coordinates; refreshes scroll range and
  // current-line following.
  void TextOrigin(const Rect& rect, double* ox, double* oy);
  std::optional<std::pair<int, int>> CurrentLineBytes() const;
  int ByteOf(int utf16) const;
  int Utf16Of(int byte) const;
  bool CharBox(int byte, Rect* box) const;
  // UTF-16 index and window-coordinate box of the character under (x, y).
  bool CharHit(double x, double y, int* index, Rect* box);

  // Drawing.
  void Draw(cairo_t* cr);
  void DrawToolbar(cairo_t* cr);
  void DrawIcon(cairo_t* cr, const std::string& action, double cx, double cy);

  // Interaction.
  bool ToolbarVisible() const;
  void SetHovered(bool hovered);
  void CancelPress() { press_ = Press::kNone; }
  bool InResizeGrip(double x, double y) const;
  void PointerDown(double x, double y, double root_x, double root_y,
                   guint button, guint32 time);
  void PointerMoved(double x, double y, double root_x, double root_y,
                    GdkModifierType state);
  void PointerUp(double x, double y);
  void EndDragOrResize();
  bool DispatchLookup(double x, double y);
  void DispatchControl(const std::string& action);
  void MaybeHoverLookup(double x, double y, bool shift);
  void UpdateHoverTimer();
  void SetTopmost(bool topmost);
  void ScrollBy(double delta);
  std::string TooltipFor(int slot) const;
  void Redraw();

  GtkWindow* main_window_ = nullptr;
  Backend backend_ = Backend::kX11;

  // State from Dart.
  Style style_;
  std::string text_;
  std::string line_id_;
  int current_line_start_ = -1;
  int current_line_length_ = 0;
  int highlight_start_ = -1;
  int highlight_length_ = 0;
  bool playing_ = false;
  bool click_lookup_enabled_ = true;
  bool hover_auto_lookup_ = false;
  bool locked_ = false;
  bool pass_through_ = false;
  bool topmost_ = true;
  std::vector<std::string> slot_tooltips_;
  std::map<std::string, std::string> labels_;

  // UTF-16 index -> UTF-8 byte offset (size = UTF-16 length + 1) and back.
  std::vector<int> u16_to_byte_;
  std::vector<int> byte_to_u16_;

  // Window.
  GtkWidget* window_ = nullptr;
  bool visible_ = false;
  bool placed_ = false;
  double x_ = 0, y_ = 0, width_ = 720, height_ = 130;
  gulong monitors_changed_handler_ = 0;
  // X11 topmost toggle swaps popup <-> managed window, off the signal handler
  // that asked for it.
  guint recreate_idle_ = 0;

  // Layout cache (text / style / width change -> dirty).
  PangoFontMap* font_map_ = nullptr;
  std::string font_map_path_;
  std::string loaded_family_;
  PangoContext* pango_context_ = nullptr;
  PangoLayout* layout_ = nullptr;
  bool layout_dirty_ = true;
  double layout_width_ = -1;
  double content_height_ = 0;
  double scroll_offset_ = 0;
  double scroll_max_ = 0;
  bool follow_current_line_ = false;

  // Interaction.
  Press press_ = Press::kNone;
  int press_slot_ = -1;
  double press_x_ = 0, press_y_ = 0;
  double press_root_x_ = 0, press_root_y_ = 0;
  double press_win_x_ = 0, press_win_y_ = 0;
  double press_w_ = 0, press_h_ = 0;
  guint press_button_ = 0;
  guint32 press_time_ = 0;
  bool hovered_ = false;
  int hovered_slot_ = -1;
  int hover_lookup_index_ = -1;
  guint hover_timer_ = 0;

  LookupCallback on_lookup_;
  ControlCallback on_control_;
  BoolCallback on_lock_;
  BoolCallback on_pass_through_;
  BoundsCallback on_bounds_;
};

#endif  // RUNNER_FLOATING_LYRIC_WINDOW_H_
