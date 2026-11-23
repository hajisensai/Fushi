#include "floating_lyric_channel.h"

#include <cmath>
#include <cstdlib>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "floating_lyric_window.h"

struct _FushiFloatingLyric {
  FlMethodChannel* channel = nullptr;
  FlMethodChannel* test_channel = nullptr;
  std::unique_ptr<FloatingLyricWindow> window;
};

namespace {

constexpr const char* kChannel = "app.fushi.reader/floating_lyric";
constexpr const char* kTestChannel = "app.fushi.test/floating_lyric";
constexpr const char* kTestEnv = "FUSHI_TEST_FLOATING_LYRIC";

FlValue* Find(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(args, key);
}

bool BoolArg(FlValue* args, const char* key, bool fallback) {
  FlValue* v = Find(args, key);
  if (v == nullptr) return fallback;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_BOOL) return fl_value_get_bool(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) return fl_value_get_int(v) != 0;
  return fallback;
}

std::optional<double> NumberArg(FlValue* args, const char* key) {
  FlValue* v = Find(args, key);
  if (v == nullptr) return std::nullopt;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) {
    return static_cast<double>(fl_value_get_int(v));
  }
  return std::nullopt;
}

double DoubleArg(FlValue* args, const char* key, double fallback) {
  const std::optional<double> v = NumberArg(args, key);
  return v && std::isfinite(*v) ? *v : fallback;
}

int IntArg(FlValue* args, const char* key, int fallback) {
  const std::optional<double> v = NumberArg(args, key);
  return v && std::isfinite(*v) ? static_cast<int>(*v) : fallback;
}

// Opaque ARGB does not fit int32: Dart sends int64 (FL_VALUE_TYPE_INT).
uint32_t ArgbArg(FlValue* args, const char* key, uint32_t fallback) {
  FlValue* v = Find(args, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_INT
             ? static_cast<uint32_t>(fl_value_get_int(v))
             : fallback;
}

std::string StringArg(FlValue* args, const char* key) {
  FlValue* v = Find(args, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(v)
             : std::string();
}

// Same keys as Windows StyleFromArgs / macOS FloatingLyricMacStyle(args:).
FloatingLyricWindow::Style StyleFrom(FlValue* args) {
  const FloatingLyricWindow::Style d;
  FloatingLyricWindow::Style s;
  s.font_size = DoubleArg(args, "fontSize", d.font_size);
  s.font_family = StringArg(args, "fontFamily");
  s.font_path = StringArg(args, "fontPath");
  s.letter_spacing = DoubleArg(args, "letterSpacing", d.letter_spacing);
  s.line_height = DoubleArg(args, "lineHeight", d.line_height);
  s.bold = BoolArg(args, "bold", d.bold);
  s.text_alignment = IntArg(args, "textAlignment", d.text_alignment);
  s.vertical_alignment =
      IntArg(args, "verticalAlignment", d.vertical_alignment);
  s.text_color = ArgbArg(args, "textColor", d.text_color);
  s.bg_color = ArgbArg(args, "bgColor", d.bg_color);
  s.outline_color = ArgbArg(args, "outlineColor", d.outline_color);
  s.outline_width = DoubleArg(args, "outlineWidth", d.outline_width);
  s.text_padding = DoubleArg(args, "textPadding", d.text_padding);
  s.button_text_color = ArgbArg(args, "buttonTextColor", d.button_text_color);
  s.button_bg_color = ArgbArg(args, "buttonBgColor", d.button_bg_color);
  s.highlight_color = ArgbArg(args, "highlightColor", d.highlight_color);
  s.active_color = ArgbArg(args, "activeColor", d.active_color);
  s.toolbar_bg_color = ArgbArg(args, "toolbarBgColor", d.toolbar_bg_color);
  s.toolbar_icon_color =
      ArgbArg(args, "toolbarIconColor", d.toolbar_icon_color);
  s.toolbar_hover_color =
      ArgbArg(args, "toolbarHoverColor", d.toolbar_hover_color);
  s.toolbar_active_bg_color =
      ArgbArg(args, "toolbarActiveBgColor", d.toolbar_active_bg_color);
  s.toolbar_active_icon_color =
      ArgbArg(args, "toolbarActiveIconColor", d.toolbar_active_icon_color);
  s.corner_radius = DoubleArg(args, "cornerRadius", d.corner_radius);
  s.window_width = DoubleArg(args, "windowWidth", d.window_width);
  s.window_height = DoubleArg(args, "windowHeight", d.window_height);
  s.current_line_color =
      ArgbArg(args, "currentLineColor", d.current_line_color);
  s.context_line_opacity =
      DoubleArg(args, "contextLineOpacity", d.context_line_opacity);
  return s;
}

void Respond(FlMethodCall* call, FlValue* value) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(call, response, nullptr);
}

void Invoke(FushiFloatingLyric* self, const char* method, FlValue* args) {
  fl_method_channel_invoke_method(self->channel, method, args, nullptr,
                                  nullptr, nullptr);
}

void MethodCallCb(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  auto* self = static_cast<FushiFloatingLyric*>(user_data);
  FloatingLyricWindow* window = self->window.get();
  const std::string method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (method == "canDrawOverlays") {
    // The runner's own window: no overlay permission to ask for.
    g_autoptr(FlValue) value = fl_value_new_bool(TRUE);
    Respond(call, value);
  } else if (method == "show") {
    FloatingLyricWindow::ShowOptions options;
    options.style = StyleFrom(args);
    options.click_lookup_enabled = BoolArg(args, "clickLookupEnabled", true);
    options.hover_auto_lookup = BoolArg(args, "hoverAutoLookup", false);
    options.pass_through = BoolArg(args, "passThrough", false);
    options.topmost = BoolArg(args, "topmost", true);
    if (Find(args, "locked") != nullptr) {
      options.locked = BoolArg(args, "locked", false);
    }
    if (FlValue* tips = Find(args, "slotTooltips");
        tips != nullptr && fl_value_get_type(tips) == FL_VALUE_TYPE_LIST) {
      std::vector<std::string> list;
      for (size_t i = 0; i < fl_value_get_length(tips); ++i) {
        FlValue* item = fl_value_get_list_value(tips, i);
        list.emplace_back(fl_value_get_type(item) == FL_VALUE_TYPE_STRING
                              ? fl_value_get_string(item)
                              : "");
      }
      options.slot_tooltips = std::move(list);
    }
    const int w = IntArg(args, "width", 0);
    const int h = IntArg(args, "height", 0);
    if (w > 0 && h > 0) {
      options.rect = FloatingLyricWindow::PhysicalRect{
          IntArg(args, "left", 0), IntArg(args, "top", 0), w, h};
    }
    g_autoptr(FlValue) value = fl_value_new_bool(window->Show(options));
    Respond(call, value);
  } else if (method == "hide") {
    window->Hide();
    Respond(call, nullptr);
  } else if (method == "isShowing") {
    g_autoptr(FlValue) value = fl_value_new_bool(window->IsShowing());
    Respond(call, value);
  } else if (method == "updateText") {
    // rubySpans are accepted and not drawn (macOS does not draw them either).
    window->UpdateText(StringArg(args, "text"),
                       IntArg(args, "currentLineStart", -1),
                       IntArg(args, "currentLineLength", 0),
                       StringArg(args, "lineId"));
    Respond(call, nullptr);
  } else if (method == "highlight") {
    window->Highlight(IntArg(args, "start", -1), IntArg(args, "length", 0));
    Respond(call, nullptr);
  } else if (method == "updateStyle") {
    window->UpdateStyle(StyleFrom(args));
    Respond(call, nullptr);
  } else if (method == "updateLabels") {
    std::map<std::string, std::string> labels;
    for (const char* key :
         {"previous", "playPause", "next", "lock", "unlock", "close"}) {
      FlValue* v = Find(args, key);
      if (v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_STRING) {
        labels[key] = fl_value_get_string(v);
      }
    }
    window->UpdateLabels(labels);
    Respond(call, nullptr);
  } else if (method == "setPlaybackState") {
    window->SetPlaying(BoolArg(args, "playing", false));
    Respond(call, nullptr);
  } else if (method == "setClickLookupEnabled") {
    window->SetClickLookupEnabled(BoolArg(args, "enabled", true));
    Respond(call, nullptr);
  } else if (method == "setLocked") {
    window->SetLocked(BoolArg(args, "locked", false));
    Respond(call, nullptr);
  } else if (method == "setPassThrough") {
    window->SetPassThrough(BoolArg(args, "enabled", false));
    Respond(call, nullptr);
  } else if (method == "setHoverAutoLookup") {
    window->SetHoverAutoLookup(BoolArg(args, "enabled", false));
    Respond(call, nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

FlValue* ProbeValue(FloatingLyricWindow* window) {
  const FloatingLyricWindow::Probe p = window->GetProbe();
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "visible", fl_value_new_bool(p.visible));
  fl_value_set_string_take(map, "locked", fl_value_new_bool(p.locked));
  fl_value_set_string_take(map, "topmost", fl_value_new_bool(p.topmost));
  fl_value_set_string_take(map, "passThrough",
                           fl_value_new_bool(p.pass_through));
  fl_value_set_string_take(map, "toolbarVisible",
                           fl_value_new_bool(p.toolbar_shown));
  fl_value_set_string_take(map, "overrideRedirect",
                           fl_value_new_bool(p.override_redirect));
  fl_value_set_string_take(map, "composited", fl_value_new_bool(p.composited));
  fl_value_set_string_take(map, "text", fl_value_new_string(p.text.c_str()));
  fl_value_set_string_take(map, "highlightStart",
                           fl_value_new_int(p.highlight_start));
  fl_value_set_string_take(map, "highlightLength",
                           fl_value_new_int(p.highlight_length));
  fl_value_set_string_take(map, "scrollOffset",
                           fl_value_new_float(p.scroll_offset));
  fl_value_set_string_take(map, "scrollMax", fl_value_new_float(p.scroll_max));
  fl_value_set_string_take(map, "contentHeight",
                           fl_value_new_float(p.content_height));
  FlValue* frame = fl_value_new_list();
  for (double v : {p.x, p.y, p.width, p.height}) {
    fl_value_append_take(frame, fl_value_new_float(v));
  }
  fl_value_set_string_take(map, "frameTopLeft", frame);
  FlValue* physical = fl_value_new_list();
  for (int v : {p.physical.left, p.physical.top, p.physical.width,
                p.physical.height}) {
    fl_value_append_take(physical, fl_value_new_int(v));
  }
  fl_value_set_string_take(map, "physical", physical);
  fl_value_set_string_take(map, "xid",
                           fl_value_new_int(static_cast<int64_t>(p.xid)));
  fl_value_set_string_take(map, "backend",
                           fl_value_new_string(p.backend.c_str()));
  return map;
}

void TestMethodCallCb(FlMethodChannel*, FlMethodCall* call,
                      gpointer user_data) {
  auto* self = static_cast<FushiFloatingLyric*>(user_data);
  FloatingLyricWindow* window = self->window.get();
  const std::string method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (method == "probe") {
    g_autoptr(FlValue) value = ProbeValue(window);
    Respond(call, value);
  } else if (method == "clickChar") {
    double x = 0, y = 0;
    const int index = IntArg(args, "index", 0);
    if (!window->ClickChar(index, &x, &y)) {
      g_autoptr(FlMethodResponse) response =
          FL_METHOD_RESPONSE(fl_method_error_response_new(
              "no_char", "character not laid out", nullptr));
      fl_method_call_respond(call, response, nullptr);
      return;
    }
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "x", fl_value_new_float(x));
    fl_value_set_string_take(map, "y", fl_value_new_float(y));
    Respond(call, map);
  } else if (method == "dragBy") {
    window->DragBy(DoubleArg(args, "dx", 0), DoubleArg(args, "dy", 0));
    g_autoptr(FlValue) value = ProbeValue(window);
    Respond(call, value);
  } else if (method == "toolbarAction") {
    window->ToolbarAction(StringArg(args, "action"));
    g_autoptr(FlValue) value = ProbeValue(window);
    Respond(call, value);
  } else if (method == "snapshot") {
    // In-process render with the real draw code (window compositing aside).
    std::string path = StringArg(args, "path");
    if (path.empty()) {
      const std::string tag = StringArg(args, "tag");
      gchar* p = g_build_filename(
          g_get_tmp_dir(),
          ("flyric-" + (tag.empty() ? std::string("snap") : tag) + ".png")
              .c_str(),
          nullptr);
      path = p;
      g_free(p);
    }
    g_autoptr(FlValue) map = fl_value_new_map();
    if (window->Snapshot(path)) {
      fl_value_set_string_take(map, "body", fl_value_new_string(path.c_str()));
    }
    Respond(call, map);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

}  // namespace

FushiFloatingLyric* fushi_floating_lyric_new(FlBinaryMessenger* messenger,
                                             GtkWindow* main_window) {
  auto* self = new FushiFloatingLyric();
  self->window = std::make_unique<FloatingLyricWindow>(main_window);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel =
      fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, MethodCallCb, self,
                                            nullptr);

  // Native -> Dart, all on the GTK main thread.
  self->window->SetLookupCallback(
      [self](const std::string& text, const std::string& line_id, int index,
             const std::optional<FloatingLyricWindow::WordRect>& word) {
        g_autoptr(FlValue) map = fl_value_new_map();
        fl_value_set_string_take(map, "lineId",
                                 fl_value_new_string(line_id.c_str()));
        fl_value_set_string_take(map, "text",
                                 fl_value_new_string(text.c_str()));
        fl_value_set_string_take(map, "index", fl_value_new_int(index));
        if (word) {
          fl_value_set_string_take(map, "wordLeft",
                                   fl_value_new_float(word->left));
          fl_value_set_string_take(map, "wordTop",
                                   fl_value_new_float(word->top));
          fl_value_set_string_take(map, "wordWidth",
                                   fl_value_new_float(word->width));
          fl_value_set_string_take(map, "wordHeight",
                                   fl_value_new_float(word->height));
        }
        Invoke(self, "lookupText", map);
      });
  self->window->SetControlCallback(
      [self](const std::string& action) {
        Invoke(self, action.c_str(), nullptr);
      });
  self->window->SetLockCallback([self](bool locked) {
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "locked", fl_value_new_bool(locked));
    Invoke(self, "lockChanged", map);
  });
  self->window->SetPassThroughCallback([self](bool pass_through) {
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "passThrough",
                             fl_value_new_bool(pass_through));
    Invoke(self, "passThroughChanged", map);
  });
  self->window->SetBoundsCallback(
      [self](const FloatingLyricWindow::PhysicalRect& r) {
        g_autoptr(FlValue) map = fl_value_new_map();
        fl_value_set_string_take(map, "left", fl_value_new_int(r.left));
        fl_value_set_string_take(map, "top", fl_value_new_int(r.top));
        fl_value_set_string_take(map, "width", fl_value_new_int(r.width));
        fl_value_set_string_take(map, "height", fl_value_new_int(r.height));
        Invoke(self, "windowRectChanged", map);
      });

  if (g_getenv(kTestEnv) != nullptr) {
    self->test_channel =
        fl_method_channel_new(messenger, kTestChannel, FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(self->test_channel,
                                              TestMethodCallCb, self, nullptr);
  }
  return self;
}

void fushi_floating_lyric_free(FushiFloatingLyric* self) {
  if (self == nullptr) return;
  for (FlMethodChannel** channel : {&self->channel, &self->test_channel}) {
    if (*channel != nullptr) {
      fl_method_channel_set_method_call_handler(*channel, nullptr, nullptr,
                                                nullptr);
      g_clear_object(channel);
    }
  }
  self->window.reset();
  delete self;
}
