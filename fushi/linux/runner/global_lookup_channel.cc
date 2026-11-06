#include "global_lookup_channel.h"

#include <gio/gio.h>
#include <gtk/gtk.h>
#include <signal.h>

#include <map>
#include <memory>
#include <string>

#include "../lookup_card/line_pipe.h"
#ifdef FUSHI_WAYLAND_SELECTION
#include "wayland_selection.h"
#endif

namespace {

constexpr char kGlobalLookupChannel[] = "app.fushi.reader/global_lookup";
constexpr char kSelectionChannel[] = "app.fushi.reader/foreground_selection";
constexpr char kHelperName[] = "fushi_lookup_card";

// Calls answered here while no helper runs: nothing can be showing, so there
// is no reason to start a web view just to say so.
FlMethodResponse* AnswerWithoutHelper(const std::string& method) {
  if (method == "isShowing" || method == "isWebViewReady" ||
      method == "suspendForCapture" || method == "restoreAfterCapture") {
    g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }
  if (method == "hide") {
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }
  return nullptr;
}

// State that outlives one lookup; replayed into a restarted helper, in this
// order (prepare first: it names the assets folder).
constexpr const char* kStickyMethods[] = {"prepare", "setBlockCapture",
                                          "setGlobalMouseTrigger"};

bool IsSticky(const std::string& method) {
  for (const char* sticky : kStickyMethods) {
    if (method == sticky) {
      return true;
    }
  }
  return false;
}

// The helper sits next to the fushi executable.
std::string HelperPath() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) {
    return std::string();
  }
  g_autofree gchar* dir = g_path_get_dirname(exe);
  g_autofree gchar* path = g_build_filename(dir, kHelperName, nullptr);
  return path;
}

void Respond(FlMethodCall* call, FlMethodResponse* response) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("global_lookup: respond failed: %s", error->message);
  }
}

}  // namespace

struct _FushiGlobalLookup {
  FlMethodChannel* channel = nullptr;
  FlMethodChannel* selection_channel = nullptr;
  FlJsonMessageCodec* json = nullptr;
  GCancellable* cancellable = nullptr;
  GSubprocess* helper = nullptr;
  std::unique_ptr<fushi::lookup_card::LinePipe> pipe;
  int64_t next_id = 0;
  std::map<int64_t, FlMethodCall*> pending;  // owned refs
  std::map<std::string, FlValue*> sticky;    // owned refs

  ~_FushiGlobalLookup();

  void OnCall(FlMethodCall* call);
  bool EnsureHelper();
  void Send(int64_t id, const gchar* method, FlValue* args);
  void SendValue(FlValue* message);
  void OnHelperLine(const std::string& line);
  void OnHelperEvent(const gchar* event, FlValue* message);
  void OnHelperReply(int64_t id, FlValue* message);
  void OnHelperClosed();
  void StopHelper();
};

namespace {

struct MediaRequest {
  FushiGlobalLookup* lookup;
  int64_t cid;
};

void OnMediaResponse(GObject* source, GAsyncResult* result, gpointer data) {
  std::unique_ptr<MediaRequest> request(static_cast<MediaRequest*>(data));
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(source), result, &error);
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
    return;  // The lookup object is gone.
  }
  g_autoptr(FlValue) reply = fl_value_new_map();
  fl_value_set_string_take(reply, "mediaReply", fl_value_new_int(request->cid));
  if (response != nullptr && FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
    FlValue* bytes = fl_method_success_response_get_result(
        FL_METHOD_SUCCESS_RESPONSE(response));
    if (bytes != nullptr &&
        fl_value_get_type(bytes) == FL_VALUE_TYPE_UINT8_LIST &&
        fl_value_get_length(bytes) > 0) {
      g_autofree gchar* encoded = g_base64_encode(
          fl_value_get_uint8_list(bytes), fl_value_get_length(bytes));
      fl_value_set_string_take(reply, "data", fl_value_new_string(encoded));
    }
  }
  request->lookup->SendValue(reply);
}

void OnLookupMethodCall(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  static_cast<FushiGlobalLookup*>(data)->OnCall(call);
}

void RespondSelection(FlMethodCall* call, const gchar* text,
                      const gchar* method) {
  g_autoptr(FlValue) result = fl_value_new_map();
  fl_value_set_string_take(result, "text",
                           fl_value_new_string(text != nullptr ? text : ""));
  fl_value_set_string_take(result, "method", fl_value_new_string(method));
  fl_value_set_string_take(result, "trusted", fl_value_new_bool(TRUE));
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  Respond(call, response);
}

void OnPrimaryText(GtkClipboard*, const gchar* text, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  RespondSelection(call, text, "primary");
}

// X11 PRIMARY: text selected in an X11 app (or a Wayland app's selection that
// KWin copied over while an X11 window had focus).
void CaptureX11Primary(FlMethodCall* call) {
  gtk_clipboard_request_text(gtk_clipboard_get(GDK_SELECTION_PRIMARY),
                             OnPrimaryText, g_object_ref(call));
}

#ifdef FUSHI_WAYLAND_SELECTION
// Bound for the whole Wayland read (round trips + the source app's pipe).
constexpr int kWaylandSelectionTimeoutMs = 500;

void ReadWaylandSelectionInThread(GTask* task, gpointer, gpointer,
                                  GCancellable*) {
  std::optional<std::string> text =
      ReadWaylandPrimarySelection(kWaylandSelectionTimeoutMs);
  g_task_return_pointer(
      task, text.has_value() ? g_strdup(text->c_str()) : nullptr, g_free);
}

void OnWaylandSelection(GObject*, GAsyncResult* result, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autofree gchar* text =
      static_cast<gchar*>(g_task_propagate_pointer(G_TASK(result), nullptr));
  if (text != nullptr && *text != 0) {
    RespondSelection(call, text, "wayland-primary");
    return;
  }
  CaptureX11Primary(call);
}
#endif

void OnSelectionMethodCall(FlMethodChannel*, FlMethodCall* call, gpointer) {
  if (g_strcmp0(fl_method_call_get_name(call), "captureSelection") == 0) {
#ifdef FUSHI_WAYLAND_SELECTION
    // The compositor's primary selection first: it covers Wayland and X11 apps
    // alike; X11 PRIMARY when there is no Wayland display or it is empty.
    g_autoptr(GTask) task =
        g_task_new(nullptr, nullptr, OnWaylandSelection, g_object_ref(call));
    g_task_run_in_thread(task, ReadWaylandSelectionInThread);
#else
    CaptureX11Primary(call);
#endif
    return;
  }
  // captureContext (UI Automation / AX on Windows / macOS) has no X11
  // counterpart; Dart falls back to captureSelection.
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  Respond(call, response);
}

}  // namespace

_FushiGlobalLookup::~_FushiGlobalLookup() {
  g_cancellable_cancel(cancellable);
  fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
  fl_method_channel_set_method_call_handler(selection_channel, nullptr,
                                            nullptr, nullptr);
  StopHelper();
  for (auto& [method, args] : sticky) {
    fl_value_unref(args);
  }
  g_object_unref(channel);
  g_object_unref(selection_channel);
  g_object_unref(json);
  g_object_unref(cancellable);
}

void _FushiGlobalLookup::OnCall(FlMethodCall* call) {
  const std::string method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (!pipe) {
    g_autoptr(FlMethodResponse) local = AnswerWithoutHelper(method);
    if (local != nullptr) {
      Respond(call, local);
      return;
    }
  }
  if (!EnsureHelper()) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_error_response_new(
            "card_unavailable", "fushi_lookup_card could not be started",
            nullptr));
    Respond(call, response);
    return;
  }
  if (IsSticky(method)) {
    auto it = sticky.find(method);
    if (it != sticky.end()) {
      fl_value_unref(it->second);
    }
    sticky[method] = args != nullptr ? fl_value_ref(args) : fl_value_new_null();
  }
  const int64_t id = ++next_id;
  pending[id] = FL_METHOD_CALL(g_object_ref(call));
  Send(id, method.c_str(), args);
}

bool _FushiGlobalLookup::EnsureHelper() {
  if (pipe) {
    return true;
  }
  const std::string path = HelperPath();
  if (path.empty() || !g_file_test(path.c_str(), G_FILE_TEST_IS_EXECUTABLE)) {
    g_warning("global_lookup: %s not found next to the executable",
              kHelperName);
    return false;
  }
  const gchar* argv[] = {path.c_str(), nullptr};
  g_autoptr(GError) error = nullptr;
  helper = g_subprocess_newv(
      argv,
      static_cast<GSubprocessFlags>(G_SUBPROCESS_FLAGS_STDIN_PIPE |
                                    G_SUBPROCESS_FLAGS_STDOUT_PIPE),
      &error);
  if (helper == nullptr) {
    g_warning("global_lookup: cannot start %s: %s", kHelperName,
              error->message);
    return false;
  }
  pipe = std::make_unique<fushi::lookup_card::LinePipe>(
      g_subprocess_get_stdout_pipe(helper), g_subprocess_get_stdin_pipe(helper),
      [this](const std::string& line) { OnHelperLine(line); },
      [this] { OnHelperClosed(); });
  for (const char* method : kStickyMethods) {
    auto it = sticky.find(method);
    if (it != sticky.end()) {
      Send(0, method, it->second);  // id 0: no answer expected
    }
  }
  return true;
}

void _FushiGlobalLookup::Send(int64_t id, const gchar* method, FlValue* args) {
  g_autoptr(FlValue) message = fl_value_new_map();
  fl_value_set_string_take(message, "id", fl_value_new_int(id));
  fl_value_set_string_take(message, "method", fl_value_new_string(method));
  if (args != nullptr) {
    fl_value_set_string(message, "args", args);
  }
  SendValue(message);
}

void _FushiGlobalLookup::SendValue(FlValue* message) {
  if (!pipe) {
    return;
  }
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* text = fl_json_message_codec_encode(json, message, &error);
  if (text == nullptr) {
    g_warning("global_lookup: cannot encode message: %s", error->message);
    return;
  }
  pipe->Send(text);
}

void _FushiGlobalLookup::OnHelperLine(const std::string& line) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlValue) message =
      fl_json_message_codec_decode(json, line.c_str(), &error);
  if (message == nullptr || fl_value_get_type(message) != FL_VALUE_TYPE_MAP) {
    return;
  }
  FlValue* event = fl_value_lookup_string(message, "event");
  if (event != nullptr && fl_value_get_type(event) == FL_VALUE_TYPE_STRING) {
    OnHelperEvent(fl_value_get_string(event), message);
    return;
  }
  FlValue* id = fl_value_lookup_string(message, "id");
  if (id != nullptr && fl_value_get_type(id) == FL_VALUE_TYPE_INT) {
    OnHelperReply(fl_value_get_int(id), message);
  }
}

void _FushiGlobalLookup::OnHelperEvent(const gchar* event, FlValue* message) {
  FlValue* args = fl_value_lookup_string(message, "args");
  if (g_strcmp0(event, "getMedia") == 0) {
    FlValue* cid = fl_value_lookup_string(message, "cid");
    if (cid == nullptr || fl_value_get_type(cid) != FL_VALUE_TYPE_INT) {
      return;
    }
    fl_method_channel_invoke_method(
        channel, event, args, cancellable, OnMediaResponse,
        new MediaRequest{this, fl_value_get_int(cid)});
    return;
  }
  fl_method_channel_invoke_method(channel, event, args, nullptr, nullptr,
                                  nullptr);
}

void _FushiGlobalLookup::OnHelperReply(int64_t id, FlValue* message) {
  auto it = pending.find(id);
  if (it == pending.end()) {
    return;
  }
  g_autoptr(FlMethodCall) call = it->second;
  pending.erase(it);
  g_autoptr(FlMethodResponse) response = nullptr;
  FlValue* error = fl_value_lookup_string(message, "error");
  if (fl_value_lookup_string(message, "notImplemented") != nullptr) {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  } else if (error != nullptr &&
             fl_value_get_type(error) == FL_VALUE_TYPE_MAP) {
    FlValue* code = fl_value_lookup_string(error, "code");
    FlValue* text = fl_value_lookup_string(error, "message");
    response = FL_METHOD_RESPONSE(fl_method_error_response_new(
        code != nullptr ? fl_value_get_string(code) : "card_error",
        text != nullptr ? fl_value_get_string(text) : nullptr, nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_lookup_string(message, "result")));
  }
  Respond(call, response);
}

// The helper exited (crash, or killed). Calls in flight get the answer a dead
// card would give; the next call starts a new helper and replays the sticky
// state, so the following lookup works again.
void _FushiGlobalLookup::OnHelperClosed() {
  g_warning("global_lookup: %s exited", kHelperName);
  std::map<int64_t, FlMethodCall*> orphans;
  orphans.swap(pending);
  StopHelper();
  for (auto& [id, call] : orphans) {
    g_autoptr(FlMethodResponse) response =
        AnswerWithoutHelper(fl_method_call_get_name(call));
    if (response == nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "card_exited", "fushi_lookup_card exited", nullptr));
    }
    Respond(call, response);
    g_object_unref(call);
  }
}

void _FushiGlobalLookup::StopHelper() {
  // Safe from inside the pipe's own callbacks (LinePipe is built for it).
  pipe.reset();
  if (helper != nullptr) {
    g_subprocess_send_signal(helper, SIGTERM);
    g_clear_object(&helper);
  }
  for (auto& [id, call] : pending) {
    g_object_unref(call);
  }
  pending.clear();
}

FushiGlobalLookup* fushi_global_lookup_new(FlBinaryMessenger* messenger) {
  auto* lookup = new FushiGlobalLookup();
  lookup->json = fl_json_message_codec_new();
  lookup->cancellable = g_cancellable_new();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  lookup->channel = fl_method_channel_new(messenger, kGlobalLookupChannel,
                                          FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(lookup->channel,
                                            OnLookupMethodCall, lookup, nullptr);
  lookup->selection_channel = fl_method_channel_new(
      messenger, kSelectionChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      lookup->selection_channel, OnSelectionMethodCall, lookup, nullptr);
  return lookup;
}

void fushi_global_lookup_free(FushiGlobalLookup* lookup) { delete lookup; }
