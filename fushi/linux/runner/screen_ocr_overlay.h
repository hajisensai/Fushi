#ifndef RUNNER_SCREEN_OCR_OVERLAY_H_
#define RUNNER_SCREEN_OCR_OVERLAY_H_

#include <gtk/gtk.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// Shared with the Windows runner: drawing constants, banner layout, click
// classification and monitor choice (no platform API).
#include "../../windows/runner/screen_ocr_logic.h"

// Freeze layer of the desktop floating ball's screen OCR on Linux (X11 and
// XWayland). Same contract as windows/runner/screen_ocr_overlay.h (spec
// docs/specs/2026-09-30-desktop-system-floating-ball.md, "截屏识字"): covers
// one monitor with its screenshot (the screen "freezes"), draws the recognized
// line boxes and a top banner with a close button.
//
// The window is an unmanaged (override-redirect) popup: KWin stacks it above
// managed windows without focusing it, like the ball. The lookup card (also
// unmanaged) raises itself when it appears, so it lands above this layer.
// While shown the layer grabs the keyboard so Esc works; on XWayland a grab
// only covers X clients, so Esc may not reach it while a Wayland app is
// focused (the close button and right click always work).
//
// Native only draws and takes input: a left press / touch (not on the banner)
// goes to TapCallback in screenshot pixels and Dart decides; Esc, right click
// and the close button close the layer, then DismissCallback runs.
// All methods run on the GTK main thread.
class ScreenOcrOverlay {
 public:
  struct Style {
    std::string recognizing;  // banner while recognizing
    std::string hint;         // banner after recognizing, without a message
    std::string close;        // close button tooltip
    uint32_t primary = 0xFF6750A4;
    uint32_t surface = 0xFFFEF7FF;
    uint32_t on_surface = 0xFF1D1B20;
  };

  using TapCallback = std::function<void(int x, int y)>;
  using DismissCallback = std::function<void()>;

  ScreenOcrOverlay() = default;
  ~ScreenOcrOverlay();

  ScreenOcrOverlay(const ScreenOcrOverlay&) = delete;
  ScreenOcrOverlay& operator=(const ScreenOcrOverlay&) = delete;

  void SetTapCallback(TapCallback callback) { on_tap_ = std::move(callback); }
  void SetDismissCallback(DismissCallback callback) {
    on_dismiss_ = std::move(callback);
  }

  // Covers |monitor| with |screenshot| (physical pixels of that monitor). An
  // open layer is closed first, without a callback. Shows style.recognizing.
  bool Show(GdkMonitor* monitor, std::shared_ptr<GdkPixbuf> screenshot,
            const Style& style);
  // Line boxes in screenshot pixels; |message| replaces the banner text,
  // otherwise style.hint is shown.
  void Update(std::vector<fushi::screen_ocr::RectD> lines,
              std::optional<std::string> message);
  // Closes without a callback (Dart stopScreenOcr, a new capture).
  void Close() noexcept;
  // Closes as if the user pressed Esc: DismissCallback runs. Used by the Steam
  // Deck back button that also opens the layer in Game Mode.
  void DismissByUser();
  bool IsShowing() const { return window_ != nullptr; }

 private:
  static gboolean OnDraw(GtkWidget* widget, cairo_t* cr, gpointer data);
  static gboolean OnPress(GtkWidget* widget, GdkEventButton* event,
                          gpointer data);
  static gboolean OnMotion(GtkWidget* widget, GdkEventMotion* event,
                           gpointer data);
  static gboolean OnKey(GtkWidget* widget, GdkEventKey* event, gpointer data);
  static gboolean OnMapped(GtkWidget* widget, GdkEvent* event, gpointer data);

  void Draw(cairo_t* cr);
  void SetBannerText(const std::string& text);
  // Window (GDK logical) coordinates -> screenshot pixels.
  void ToImage(double x, double y, double* image_x, double* image_y) const;
  void Dismiss();
  void Ungrab() noexcept;

  GtkWidget* window_ = nullptr;
  std::shared_ptr<GdkPixbuf> screenshot_;
  int image_width_ = 0;
  int image_height_ = 0;
  double scale_ = 1.0;  // monitor scale: DIP constants -> screenshot pixels
  Style style_;
  std::vector<fushi::screen_ocr::RectD> lines_;
  std::string banner_text_;
  PangoLayout* banner_layout_ = nullptr;
  fushi::screen_ocr::BannerLayout banner_;
  bool close_hovered_ = false;
  GdkSeat* grabbed_seat_ = nullptr;

  TapCallback on_tap_;
  DismissCallback on_dismiss_;
};

#endif  // RUNNER_SCREEN_OCR_OVERLAY_H_
