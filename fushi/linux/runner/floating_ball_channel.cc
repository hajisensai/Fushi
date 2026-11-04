#include "floating_ball_channel.h"

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <cmath>
#include <memory>
#include <optional>
#include <string>

#include "floating_ball_window.h"

struct _FushiFloatingBall {
  FlMethodChannel* channel = nullptr;
  std::unique_ptr<FloatingBallWindow> window;
  GtkWindow* main_window = nullptr;
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
  return self;
}

void fushi_floating_ball_free(FushiFloatingBall* self) {
  if (self == nullptr) return;
  if (self->channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr,
                                              nullptr);
    g_clear_object(&self->channel);
  }
  self->window.reset();
  if (self->main_window != nullptr) {
    g_object_remove_weak_pointer(G_OBJECT(self->main_window),
                                 reinterpret_cast<gpointer*>(&self->main_window));
  }
  delete self;
}
