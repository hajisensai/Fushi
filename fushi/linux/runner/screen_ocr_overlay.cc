#include "screen_ocr_overlay.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "gamescope_overlay.h"
#include "screen_capture.h"

namespace so = fushi::screen_ocr;

namespace {

void SetSource(cairo_t* cr, uint32_t argb, double alpha_factor = 1.0) {
  cairo_set_source_rgba(cr, ((argb >> 16) & 0xFF) / 255.0,
                        ((argb >> 8) & 0xFF) / 255.0, (argb & 0xFF) / 255.0,
                        ((argb >> 24) & 0xFF) / 255.0 * alpha_factor);
}

void RoundedRect(cairo_t* cr, double left, double top, double right,
                 double bottom, double radius) {
  radius = std::min({radius, (right - left) / 2, (bottom - top) / 2});
  cairo_new_sub_path(cr);
  cairo_arc(cr, right - radius, top + radius, radius, -M_PI / 2, 0);
  cairo_arc(cr, right - radius, bottom - radius, radius, 0, M_PI / 2);
  cairo_arc(cr, left + radius, bottom - radius, radius, M_PI / 2, M_PI);
  cairo_arc(cr, left + radius, top + radius, radius, M_PI, 3 * M_PI / 2);
  cairo_close_path(cr);
}

}  // namespace

ScreenOcrOverlay::~ScreenOcrOverlay() { Close(); }

bool ScreenOcrOverlay::Show(GdkMonitor* monitor,
                            std::shared_ptr<GdkPixbuf> screenshot,
                            const Style& style) {
  Close();
  if (monitor == nullptr || screenshot == nullptr) return false;
  GdkRectangle geometry;
  gdk_monitor_get_geometry(monitor, &geometry);
  if (geometry.width <= 0 || geometry.height <= 0) return false;

  screenshot_ = std::move(screenshot);
  image_width_ = gdk_pixbuf_get_width(screenshot_.get());
  image_height_ = gdk_pixbuf_get_height(screenshot_.get());
  scale_ = std::max(1, gdk_monitor_get_scale_factor(monitor));
  style_ = style;
  lines_.clear();
  close_hovered_ = false;

  window_ = gtk_window_new(GTK_WINDOW_POPUP);
  gtk_window_set_title(GTK_WINDOW(window_), "Fushi screen OCR");
  gtk_widget_set_app_paintable(window_, TRUE);
  gtk_window_set_default_size(GTK_WINDOW(window_), geometry.width,
                              geometry.height);
  gtk_widget_set_size_request(window_, geometry.width, geometry.height);
  gtk_window_move(GTK_WINDOW(window_), geometry.x, geometry.y);
  gtk_widget_add_events(window_, GDK_BUTTON_PRESS_MASK |
                                     GDK_POINTER_MOTION_MASK |
                                     GDK_KEY_PRESS_MASK);
  g_signal_connect(window_, "draw", G_CALLBACK(OnDraw), this);
  g_signal_connect(window_, "button-press-event", G_CALLBACK(OnPress), this);
  g_signal_connect(window_, "motion-notify-event", G_CALLBACK(OnMotion), this);
  g_signal_connect(window_, "key-press-event", G_CALLBACK(OnKey), this);
  g_signal_connect(window_, "map-event", G_CALLBACK(OnMapped), this);
  g_object_set(window_, "has-tooltip", TRUE, nullptr);
  g_signal_connect(
      window_, "query-tooltip",
      G_CALLBACK(+[](GtkWidget*, gint x, gint y, gboolean, GtkTooltip* tooltip,
                     gpointer data) -> gboolean {
        auto* self = static_cast<ScreenOcrOverlay*>(data);
        double ix = 0;
        double iy = 0;
        self->ToImage(x, y, &ix, &iy);
        if (self->style_.close.empty() || !self->banner_.close.Contains(ix, iy)) {
          return FALSE;
        }
        gtk_tooltip_set_text(tooltip, self->style_.close.c_str());
        return TRUE;
      }),
      this);
  SetBannerText(style_.recognizing);
  // Tapping the ball again closes this layer and captures at once.
  fushi::screen_capture::SkipCloseAnimation(window_);
  // Steam Deck Game Mode: Gamescope draws no other app's windows over the
  // game. As an external overlay the layer is drawn (and stays drawn under the
  // lookup card); in Steam's overlay slot it gets the touches. The card ranks
  // higher, so it takes the touches while it is open and hands them back when
  // it closes. The window covers the whole output, as both slots require.
  fushi::gamescope::SetRole(
      window_, fushi::gamescope::kDraw | fushi::gamescope::kInput,
      fushi::gamescope::kFreezeLayerRank);
  gtk_widget_show(window_);
  return true;
}

void ScreenOcrOverlay::Update(std::vector<so::RectD> lines,
                              std::optional<std::string> message) {
  if (window_ == nullptr) return;
  lines_ = std::move(lines);
  SetBannerText(message ? *message : style_.hint);
  gtk_widget_queue_draw(window_);
}

void ScreenOcrOverlay::Close() noexcept {
  Ungrab();
  if (banner_layout_ != nullptr) {
    g_object_unref(banner_layout_);
    banner_layout_ = nullptr;
  }
  if (window_ != nullptr) {
    GtkWidget* window = window_;
    window_ = nullptr;
    gtk_widget_destroy(window);
  }
  screenshot_.reset();
  lines_.clear();
}

void ScreenOcrOverlay::DismissByUser() {
  if (window_ != nullptr) Dismiss();
}

void ScreenOcrOverlay::Dismiss() {
  Close();
  if (on_dismiss_) on_dismiss_();
}

void ScreenOcrOverlay::Ungrab() noexcept {
  if (grabbed_seat_ != nullptr) {
    gdk_seat_ungrab(grabbed_seat_);
    grabbed_seat_ = nullptr;
  }
}

void ScreenOcrOverlay::ToImage(double x, double y, double* image_x,
                               double* image_y) const {
  const double width =
      window_ != nullptr ? std::max(1, gtk_widget_get_allocated_width(window_))
                         : 1;
  const double height =
      window_ != nullptr ? std::max(1, gtk_widget_get_allocated_height(window_))
                         : 1;
  *image_x = x * image_width_ / width;
  *image_y = y * image_height_ / height;
}

// Measured in screenshot pixels: Draw scales the context to them.
void ScreenOcrOverlay::SetBannerText(const std::string& text) {
  banner_text_ = text;
  if (window_ == nullptr) return;
  if (banner_layout_ == nullptr) {
    banner_layout_ = gtk_widget_create_pango_layout(window_, nullptr);
    PangoFontDescription* font = pango_font_description_new();
    pango_font_description_set_family(font, "sans-serif");
    pango_font_description_set_absolute_size(
        font, so::kBannerFontDip * scale_ * PANGO_SCALE);
    pango_layout_set_font_description(banner_layout_, font);
    pango_font_description_free(font);
    pango_layout_set_ellipsize(banner_layout_, PANGO_ELLIPSIZE_END);
  }
  const double max_width = so::MaxBannerTextWidth(image_width_, scale_);
  pango_layout_set_width(banner_layout_,
                         static_cast<int>(max_width * PANGO_SCALE));
  pango_layout_set_text(banner_layout_, banner_text_.c_str(), -1);
  int text_w = 0;
  int text_h = 0;
  pango_layout_get_pixel_size(banner_layout_, &text_w, &text_h);
  banner_ = so::LayoutBanner(image_width_, scale_, text_w, text_h);
}

void ScreenOcrOverlay::Draw(cairo_t* cr) {
  if (screenshot_ == nullptr || image_width_ <= 0 || image_height_ <= 0) {
    return;
  }
  const double width = std::max(1, gtk_widget_get_allocated_width(window_));
  const double height = std::max(1, gtk_widget_get_allocated_height(window_));
  cairo_save(cr);
  cairo_scale(cr, width / image_width_, height / image_height_);
  gdk_cairo_set_source_pixbuf(cr, screenshot_.get(), 0, 0);
  cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_NEAREST);
  cairo_paint(cr);

  // Slight dim: the boxes and banner stand out, and the screen reads as frozen.
  cairo_set_source_rgba(cr, 0, 0, 0, so::kDimAlpha);
  cairo_paint(cr);

  const double outset = so::kLineOutsetDip * scale_;
  cairo_set_line_width(cr, so::kLineStrokeDip * scale_);
  for (const so::RectD& line : lines_) {
    if (!line.HasArea()) continue;
    RoundedRect(cr, line.left - outset, line.top - outset, line.right + outset,
                line.bottom + outset, 3.0 * scale_);
    SetSource(cr, style_.primary, so::kLineFillAlpha);
    cairo_fill_preserve(cr);
    SetSource(cr, style_.primary);
    cairo_stroke(cr);
  }

  // Top banner: surface fill, onSurface text, close button.
  const so::RectD& b = banner_.banner;
  const double radius = b.Height() / 2;
  const double shadow = 2.0 * scale_;
  RoundedRect(cr, b.left, b.top + shadow, b.right, b.bottom + shadow, radius);
  cairo_set_source_rgba(cr, 0, 0, 0, 0.22);
  cairo_fill(cr);
  RoundedRect(cr, b.left, b.top, b.right, b.bottom, radius);
  SetSource(cr, style_.surface);
  cairo_fill(cr);
  if (banner_layout_ != nullptr) {
    SetSource(cr, style_.on_surface);
    cairo_move_to(cr, banner_.text.left, banner_.text.top);
    pango_cairo_show_layout(cr, banner_layout_);
  }
  const double cx = (banner_.close.left + banner_.close.right) / 2;
  const double cy = (banner_.close.top + banner_.close.bottom) / 2;
  const double cr_radius = banner_.close.Width() / 2;
  cairo_new_path(cr);
  cairo_arc(cr, cx, cy, cr_radius, 0, 2 * M_PI);
  SetSource(cr, style_.on_surface, close_hovered_ ? 0.14 : 0.06);
  cairo_fill(cr);
  const double arm = cr_radius * 0.42;
  SetSource(cr, style_.on_surface);
  cairo_set_line_width(cr, 1.6 * scale_);
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
  cairo_move_to(cr, cx - arm, cy - arm);
  cairo_line_to(cr, cx + arm, cy + arm);
  cairo_move_to(cr, cx - arm, cy + arm);
  cairo_line_to(cr, cx + arm, cy - arm);
  cairo_stroke(cr);
  cairo_restore(cr);
}

gboolean ScreenOcrOverlay::OnDraw(GtkWidget*, cairo_t* cr, gpointer data) {
  static_cast<ScreenOcrOverlay*>(data)->Draw(cr);
  return TRUE;
}

gboolean ScreenOcrOverlay::OnPress(GtkWidget*, GdkEventButton* event,
                                   gpointer data) {
  auto* self = static_cast<ScreenOcrOverlay*>(data);
  // Double / triple presses arrive as extra events after the plain ones.
  if (event->type != GDK_BUTTON_PRESS) return TRUE;
  if (event->button == 3) {
    self->Dismiss();
    return TRUE;
  }
  if (event->button != 1) return TRUE;
  double x = 0;
  double y = 0;
  self->ToImage(event->x, event->y, &x, &y);
  switch (so::ClassifyLeftClick(self->banner_, x, y)) {
    case so::OverlayClick::kDismiss:
      self->Dismiss();
      break;
    case so::OverlayClick::kIgnore:
      break;
    case so::OverlayClick::kTap:
      // The layer stays: Dart hit-tests, then looks up or calls stopScreenOcr.
      if (self->on_tap_) {
        self->on_tap_(static_cast<int>(std::floor(x)),
                      static_cast<int>(std::floor(y)));
      }
      break;
  }
  return TRUE;
}

gboolean ScreenOcrOverlay::OnMotion(GtkWidget*, GdkEventMotion* event,
                                    gpointer data) {
  auto* self = static_cast<ScreenOcrOverlay*>(data);
  double x = 0;
  double y = 0;
  self->ToImage(event->x, event->y, &x, &y);
  const bool hovered = self->banner_.close.Contains(x, y);
  if (hovered != self->close_hovered_) {
    self->close_hovered_ = hovered;
    gtk_widget_queue_draw(self->window_);
  }
  return FALSE;
}

gboolean ScreenOcrOverlay::OnKey(GtkWidget*, GdkEventKey* event,
                                 gpointer data) {
  if (event->keyval == GDK_KEY_Escape) {
    static_cast<ScreenOcrOverlay*>(data)->Dismiss();
    return TRUE;
  }
  return FALSE;
}

// An override-redirect window never gets focus from the window manager: grab
// the keyboard once it is on screen so Esc reaches the layer.
gboolean ScreenOcrOverlay::OnMapped(GtkWidget* widget, GdkEvent*,
                                    gpointer data) {
  auto* self = static_cast<ScreenOcrOverlay*>(data);
  GdkWindow* gdk_window = gtk_widget_get_window(widget);
  GdkSeat* seat = gdk_display_get_default_seat(gtk_widget_get_display(widget));
  if (gdk_window != nullptr && seat != nullptr &&
      gdk_seat_grab(seat, gdk_window, GDK_SEAT_CAPABILITY_KEYBOARD, FALSE,
                    nullptr, nullptr, nullptr, nullptr) == GDK_GRAB_SUCCESS) {
    self->grabbed_seat_ = seat;
  }
  return FALSE;
}
