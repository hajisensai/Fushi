#include "floating_ball_channel.h"

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <algorithm>
#include <cmath>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "floating_ball_window.h"
#include "screen_capture.h"
#include "screen_ocr_overlay.h"

struct _FushiFloatingBall {
  FlMethodChannel* channel = nullptr;
  std::unique_ptr<FloatingBallWindow> window;
  std::unique_ptr<ScreenOcrOverlay> screen_ocr;
  GtkWindow* main_window = nullptr;
  // Screen OCR captures finish asynchronously (portal): a finished capture
  // checks that this object still lives and that it is still the latest one.
  std::shared_ptr<bool> alive = std::make_shared<bool>(true);
  uint64_t capture_generation = 0;
};

namespace {

FlValue* Find(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(args, key);
}

bool BoolArg(FlValue* args, const char* key, bool fallback) {
  FlValue* v = Find(args, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL
             ? fl_value_get_bool(v)
             : fallback;
}

std::string StringArg(FlValue* args, const char* key, const char* fallback) {
  FlValue* v = Find(args, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(v)
             : fallback;
}

double DoubleArg(FlValue* args, const char* key, double fallback) {
  FlValue* v = Find(args, key);
  if (v == nullptr) return fallback;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) {
    return static_cast<double>(fl_value_get_int(v));
  }
  return fallback;
}

// Opaque ARGB does not fit int32: Dart sends int64 (always FL_VALUE_TYPE_INT).
uint32_t ArgbArg(FlValue* colors, const char* key, uint32_t fallback) {
  FlValue* v = Find(colors, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_INT
             ? static_cast<uint32_t>(fl_value_get_int(v))
             : fallback;
}

double Number(FlValue* v) {
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) {
    return static_cast<double>(fl_value_get_int(v));
  }
  return NAN;
}

// [left, top, right, bottom] in physical pixels.
std::optional<FloatingBallWindow::PhysicalRect> RectArg(FlValue* v) {
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(v) != 4) {
    return std::nullopt;
  }
  FlValue* list = v;
  double edges[4];
  for (int i = 0; i < 4; ++i) {
    edges[i] = Number(fl_value_get_list_value(list, i));
    if (!std::isfinite(edges[i])) return std::nullopt;
  }
  return FloatingBallWindow::PhysicalRect{
      static_cast<int>(std::lround(edges[0])),
      static_cast<int>(std::lround(edges[1])),
      static_cast<int>(std::lround(edges[2])),
      static_cast<int>(std::lround(edges[3]))};
}

bool IsX11() {
#ifdef GDK_WINDOWING_X11
  return GDK_IS_X11_DISPLAY(gdk_display_get_default());
#else
  return false;
#endif
}

FloatingBallWindow::Config ConfigFrom(FlValue* args) {
  FloatingBallWindow::Config config;
  config.animate = BoolArg(args, "animate", true);
  config.show_labels = BoolArg(args, "showLabels", true);
  config.show_open_app = BoolArg(args, "showOpenApp", true);
  if (FlValue* v = Find(args, "actions");
      v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_LIST) {
    FlValue* list = v;
    for (size_t i = 0; i < fl_value_get_length(list); ++i) {
      FlValue* item = fl_value_get_list_value(list, i);
      if (fl_value_get_type(item) == FL_VALUE_TYPE_STRING) {
        config.actions.emplace_back(fl_value_get_string(item));
      }
    }
  }
  if (FlValue* v = Find(args, "labels");
      v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_MAP) {
    FlValue* map = v;
    for (size_t i = 0; i < fl_value_get_length(map); ++i) {
      FlValue* key = fl_value_get_map_key(map, i);
      FlValue* value = fl_value_get_map_value(map, i);
      if (fl_value_get_type(key) == FL_VALUE_TYPE_STRING &&
          fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
        config.labels[fl_value_get_string(key)] = fl_value_get_string(value);
      }
    }
  }
  if (FlValue* v = Find(args, "iconImages");
      v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_MAP) {
    FlValue* map = v;
    for (size_t i = 0; i < fl_value_get_length(map); ++i) {
      FlValue* key = fl_value_get_map_key(map, i);
      FlValue* value = fl_value_get_map_value(map, i);
      if (fl_value_get_type(key) == FL_VALUE_TYPE_STRING &&
          fl_value_get_type(value) == FL_VALUE_TYPE_UINT8_LIST) {
        const uint8_t* bytes = fl_value_get_uint8_list(value);
        config.icon_images[fl_value_get_string(key)] =
            std::vector<uint8_t>(bytes, bytes + fl_value_get_length(value));
      }
    }
  }
  if (FlValue* v = Find(args, "ballImage");
      v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_UINT8_LIST) {
    FlValue* value = v;
    const uint8_t* bytes = fl_value_get_uint8_list(value);
    config.ball_image =
        std::vector<uint8_t>(bytes, bytes + fl_value_get_length(value));
  }
  if (FlValue* v = Find(args, "colors");
      v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_MAP) {
    FlValue* colors = v;
    config.surface = ArgbArg(colors, "surface", config.surface);
    config.on_surface = ArgbArg(colors, "onSurface", config.on_surface);
    config.primary = ArgbArg(colors, "primary", config.primary);
    config.ball_container =
        ArgbArg(colors, "ballContainer", config.ball_container);
    config.button_container =
        ArgbArg(colors, "buttonContainer", config.button_container);
    config.on_button_container =
        ArgbArg(colors, "onButtonContainer", config.on_button_container);
    config.outline = ArgbArg(colors, "outline", config.outline);
    config.ball_open = ArgbArg(colors, "ballOpen", config.primary);
    config.on_ball_open = ArgbArg(colors, "onBallOpen", config.on_ball_open);
  }
  return config;
}

void RespondValue(FlMethodCall* call, FlValue* value) {
  fl_method_call_respond_success(call, value, nullptr);
}

void ShowProfileMenu(FushiFloatingBall* self, FlMethodCall* call,
                     FlValue* args) {
  std::vector<FloatingBallWindow::ProfileMenuItem> items;
  if (FlValue* v = Find(args, "items");
      v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_LIST) {
    FlValue* list = v;
    for (size_t i = 0; i < fl_value_get_length(list); ++i) {
      FlValue* entry = fl_value_get_list_value(list, i);
      FlValue* id = Find(entry, "id");
      if (id == nullptr || fl_value_get_type(id) != FL_VALUE_TYPE_INT) continue;
      FloatingBallWindow::ProfileMenuItem item;
      item.id = fl_value_get_int(id);
      item.label = StringArg(entry, "label", "");
      item.checked = BoolArg(entry, "checked", false);
      items.push_back(std::move(item));
    }
  }
  // Answered once the menu closes (the menu runs after this handler returns).
  g_object_ref(call);
  self->window->ShowProfileMenu(
      std::move(items), RectArg(Find(args, "anchor")),
      [call](std::optional<int64_t> selected) {
        g_autoptr(FlValue) value =
            selected ? fl_value_new_int(*selected) : fl_value_new_null();
        RespondValue(call, value);
        g_object_unref(call);
      });
}

// ── screen OCR ──────────────────────────────────────────────────────────────

std::optional<fushi::screen_ocr::RectD> RectDArg(FlValue* v) {
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(v) != 4) {
    return std::nullopt;
  }
  double edges[4];
  for (size_t i = 0; i < 4; ++i) {
    edges[i] = Number(fl_value_get_list_value(v, i));
    if (!std::isfinite(edges[i])) return std::nullopt;
  }
  return fushi::screen_ocr::RectD{edges[0], edges[1], edges[2], edges[3]};
}

// The monitor whose physical rect (logical geometry x scale) holds |probe|;
// none -> the monitor under the pointer.
GdkMonitor* MonitorAtPhysical(fushi::screen_ocr::ProbePoint probe) {
  GdkDisplay* display = gdk_display_get_default();
  const int count = gdk_display_get_n_monitors(display);
  for (int i = 0; i < count; ++i) {
    GdkMonitor* monitor = gdk_display_get_monitor(display, i);
    GdkRectangle g;
    gdk_monitor_get_geometry(monitor, &g);
    const int s = std::max(1, gdk_monitor_get_scale_factor(monitor));
    if (probe.x >= g.x * s && probe.x < (g.x + g.width) * s &&
        probe.y >= g.y * s && probe.y < (g.y + g.height) * s) {
      return monitor;
    }
  }
  return nullptr;
}

fushi::screen_ocr::ProbePoint PointerPhysical() {
  GdkDisplay* display = gdk_display_get_default();
  GdkSeat* seat = gdk_display_get_default_seat(display);
  GdkDevice* pointer = seat != nullptr ? gdk_seat_get_pointer(seat) : nullptr;
  int x = 0;
  int y = 0;
  if (pointer != nullptr) gdk_device_get_position(pointer, nullptr, &x, &y);
  GdkMonitor* monitor = gdk_display_get_monitor_at_point(display, x, y);
  const int s =
      monitor != nullptr ? std::max(1, gdk_monitor_get_scale_factor(monitor))
                         : 1;
  return fushi::screen_ocr::ProbePoint{x * s, y * s};
}

FlValue* CaptureError(const std::string& error, const std::string& diagnostic) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "error", fl_value_new_string(error.c_str()));
  if (!diagnostic.empty()) {
    fl_value_set_string_take(map, "diagnostic",
                             fl_value_new_string(diagnostic.c_str()));
  }
  return map;
}

void StopScreenOcr(FushiFloatingBall* self) {
  ++self->capture_generation;  // a capture still in flight is dropped
  self->screen_ocr->Close();
  self->window->RestoreAfterCapture();
}

// Dart: {anchor, labels, colors} -> {png, screen} | {error}. Answered when the
// capture finishes (the portal is asynchronous).
void StartScreenOcrCapture(FushiFloatingBall* self, FlMethodCall* call,
                           FlValue* args) {
  ScreenOcrOverlay::Style style;
  if (FlValue* labels = Find(args, "labels"); labels != nullptr) {
    style.recognizing = StringArg(labels, "recognizing", "");
    style.hint = StringArg(labels, "hint", "");
    style.close = StringArg(labels, "close", "");
  }
  if (FlValue* colors = Find(args, "colors"); colors != nullptr) {
    style.primary = ArgbArg(colors, "primary", style.primary);
    style.surface = ArgbArg(colors, "surface", style.surface);
    style.on_surface = ArgbArg(colors, "onSurface", style.on_surface);
  }
  const fushi::screen_ocr::ProbePoint probe =
      fushi::screen_ocr::MonitorProbePoint(RectDArg(Find(args, "anchor")),
                                           PointerPhysical());
  GdkMonitor* monitor = MonitorAtPhysical(probe);
  if (monitor == nullptr) {
    monitor = gdk_display_get_primary_monitor(gdk_display_get_default());
  }
  if (monitor == nullptr) {
    g_autoptr(FlValue) reply = CaptureError("capture_failed", "no monitor");
    RespondValue(call, reply);
    return;
  }

  // A layer still open (the ball was tapped again) and the ball itself must
  // not end up in the picture. The X round trip makes sure the X server has
  // unmapped them before the capture is requested.
  self->screen_ocr->Close();
  self->window->HideForCapture();
  gdk_display_sync(gdk_display_get_default());

  const uint64_t generation = ++self->capture_generation;
  std::weak_ptr<bool> alive = self->alive;
  g_object_ref(call);
  g_object_ref(monitor);
  fushi::screen_capture::CaptureMonitor(
      monitor, [self, call, monitor, style, generation, alive](
                   fushi::screen_capture::MonitorCapture capture,
                   const std::string& error) {
        auto finish = [call, monitor](FlValue* reply) {
          RespondValue(call, reply);
          fl_value_unref(reply);
          g_object_unref(call);
          g_object_unref(monitor);
        };
        if (alive.expired()) {
          finish(CaptureError("capture_failed", "runner closed"));
          return;
        }
        if (generation != self->capture_generation) {
          // stopScreenOcr or a newer capture came first.
          finish(CaptureError("capture_failed", "superseded"));
          return;
        }
        if (!error.empty() || capture.pixbuf == nullptr) {
          self->window->RestoreAfterCapture();
          finish(CaptureError(error.empty() ? "capture_failed" : error,
                              capture.diagnostic));
          return;
        }
        // Freeze first (shows "recognizing"), then encode the PNG.
        if (!self->screen_ocr->Show(monitor, capture.pixbuf, style)) {
          self->window->RestoreAfterCapture();
          finish(CaptureError("capture_failed", capture.diagnostic));
          return;
        }
        gchar* buffer = nullptr;
        gsize size = 0;
        GError* encode_error = nullptr;
        // Fast compression: the PNG only travels to Dart in memory.
        if (!gdk_pixbuf_save_to_buffer(capture.pixbuf.get(), &buffer, &size,
                                       "png", &encode_error, "compression",
                                       "1", nullptr)) {
          const std::string message = encode_error != nullptr
                                          ? encode_error->message
                                          : "png encode failed";
          g_clear_error(&encode_error);
          StopScreenOcr(self);
          finish(CaptureError("capture_failed", message));
          return;
        }
        FlValue* screen = fl_value_new_list();
        fl_value_append_take(screen, fl_value_new_int(capture.screen.x));
        fl_value_append_take(screen, fl_value_new_int(capture.screen.y));
        fl_value_append_take(
            screen, fl_value_new_int(capture.screen.x + capture.screen.width));
        fl_value_append_take(
            screen, fl_value_new_int(capture.screen.y + capture.screen.height));
        FlValue* reply = fl_value_new_map();
        fl_value_set_string_take(
            reply, "png",
            fl_value_new_uint8_list(reinterpret_cast<const uint8_t*>(buffer),
                                    size));
        g_free(buffer);
        fl_value_set_string_take(reply, "screen", screen);
        if (!capture.diagnostic.empty()) {
          fl_value_set_string_take(
              reply, "diagnostic",
              fl_value_new_string(capture.diagnostic.c_str()));
        }
        finish(reply);
      });
}

void UpdateScreenOcr(FushiFloatingBall* self, FlValue* args) {
  std::vector<fushi::screen_ocr::RectD> lines;
  if (FlValue* list = Find(args, "lines");
      list != nullptr && fl_value_get_type(list) == FL_VALUE_TYPE_LIST) {
    for (size_t i = 0; i < fl_value_get_length(list); ++i) {
      if (auto rect = RectDArg(fl_value_get_list_value(list, i))) {
        lines.push_back(*rect);
      }
    }
  }
  std::optional<std::string> message;
  if (FlValue* v = Find(args, "message");
      v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_STRING) {
    message = fl_value_get_string(v);
  }
  self->screen_ocr->Update(std::move(lines), std::move(message));
}

void MethodCallCb(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  auto* self = static_cast<FushiFloatingBall*>(user_data);
  const std::string method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (method == "startSystemBall") {
    // Own windows cannot be placed on Wayland: no ball there (Dart only offers
    // it on X11 and treats false as "try again on the next sync").
    bool started = false;
    if (IsX11()) {
      const bool dock_left = StringArg(args, "dock", "right") == "left";
      const double fraction = DoubleArg(args, "fraction", 1.0 / 3.0);
      started = self->window->Start(ConfigFrom(args), dock_left, fraction,
                                    self->main_window);
    }
    g_autoptr(FlValue) value = fl_value_new_bool(started);
    RespondValue(call, value);
  } else if (method == "stopSystemBall") {
    self->window->Stop();
    RespondValue(call, nullptr);
  } else if (method == "isSystemBallRunning") {
    g_autoptr(FlValue) value = fl_value_new_bool(self->window->IsRunning());
    RespondValue(call, value);
  } else if (method == "setAppForeground") {
    // true = Fushi in front with the in-app ball on: the system ball yields.
    self->window->SetHiddenForApp(BoolArg(args, "foreground", false));
    RespondValue(call, nullptr);
  } else if (method == "showProfileMenu") {
    ShowProfileMenu(self, call, args);
  } else if (method == "startScreenOcrCapture") {
    StartScreenOcrCapture(self, call, args);
  } else if (method == "updateScreenOcrOverlay") {
    UpdateScreenOcr(self, args);
    RespondValue(call, nullptr);
  } else if (method == "stopScreenOcr") {
    StopScreenOcr(self);
    RespondValue(call, nullptr);
  } else if (method == "takeSystemBallClosedByUser") {
    // Closing is pushed to Dart right away (the process is the app).
    g_autoptr(FlValue) value = fl_value_new_bool(false);
    RespondValue(call, value);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

void Invoke(FushiFloatingBall* self, const char* method, FlValue* args) {
  fl_method_channel_invoke_method(self->channel, method, args, nullptr, nullptr,
                                  nullptr);
}

}  // namespace

FushiFloatingBall* fushi_floating_ball_new(FlBinaryMessenger* messenger,
                                           GtkWindow* main_window) {
  auto* self = new FushiFloatingBall();
  self->main_window = main_window;
  if (main_window != nullptr) {
    g_object_add_weak_pointer(G_OBJECT(main_window),
                              reinterpret_cast<gpointer*>(&self->main_window));
  }
  self->window = std::make_unique<FloatingBallWindow>();
  self->screen_ocr = std::make_unique<ScreenOcrOverlay>();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      messenger, "app.fushi.reader/floating_ball", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, MethodCallCb, self,
                                            nullptr);

  // Native → Dart; all on the GTK main thread.
  self->window->SetActionCallback(
      [self](const std::string& id,
             const FloatingBallWindow::PhysicalRect& anchor) {
        g_autoptr(FlValue) rect = fl_value_new_list();
        fl_value_append_take(rect, fl_value_new_int(anchor.left));
        fl_value_append_take(rect, fl_value_new_int(anchor.top));
        fl_value_append_take(rect, fl_value_new_int(anchor.right));
        fl_value_append_take(rect, fl_value_new_int(anchor.bottom));
        g_autoptr(FlValue) map = fl_value_new_map();
        fl_value_set_string_take(map, "id", fl_value_new_string(id.c_str()));
        fl_value_set_string(map, "anchor", rect);
        Invoke(self, "systemBallAction", map);
      });
  self->window->SetClosedCallback(
      [self]() { Invoke(self, "systemBallClosedByUser", nullptr); });
  self->window->SetPositionCallback([self](bool dock_left, double fraction) {
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "dock",
                             fl_value_new_string(dock_left ? "left" : "right"));
    fl_value_set_string_take(map, "fraction", fl_value_new_float(fraction));
    Invoke(self, "systemBallPositionChanged", map);
  });
  self->screen_ocr->SetTapCallback([self](int x, int y) {
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "x", fl_value_new_int(x));
    fl_value_set_string_take(map, "y", fl_value_new_int(y));
    Invoke(self, "screenOcrTap", map);
  });
  // The layer closed itself (Esc / right click / close button): the ball
  // comes back, then Dart hears about it.
  self->screen_ocr->SetDismissCallback([self]() {
    self->window->RestoreAfterCapture();
    Invoke(self, "screenOcrDismissed", nullptr);
  });
  return self;
}

void fushi_floating_ball_free(FushiFloatingBall* self) {
  if (self == nullptr) return;
  if (self->channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr,
                                              nullptr);
    g_clear_object(&self->channel);
  }
  self->alive.reset();
  self->screen_ocr.reset();
  self->window.reset();
  if (self->main_window != nullptr) {
    g_object_remove_weak_pointer(G_OBJECT(self->main_window),
                                 reinterpret_cast<gpointer*>(&self->main_window));
  }
  delete self;
}
