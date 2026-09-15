#include "clipboard_image_channel.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gtk/gtk.h>

// GTK 的剪贴板吃的是解码后的 GdkPixbuf，不像 Windows 那样接受任意容器字节，所以这里
// 用 gdk_pixbuf_new_from_file() 解码（PNG/JPEG 都由 gdk-pixbuf 自带 loader 处理，随
// gtk+-3.0 已经链进来，不需要任何新依赖）。
//
// 一条平台限制要如实说清、不要包装成「已支持」：X11/Wayland 上剪贴板内容的所有权
// **随进程走**。app 退出后这张图还在不在，取决于桌面环境有没有跑 clipboard manager；
// gtk_clipboard_store() 也只是向它「请求」接管，没有 manager 时该请求无人应答。
// 这是协议层面的事实，不是这里能修的 bug。

static const char kChannelName[] = "app.fushi.reader/clipboard_image";
static const char kMethodCopyImageFile[] = "copyImageFile";

static void respond_error(FlMethodCall* method_call,
                          const char* code,
                          const char* message) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to clipboard_image call: %s", error->message);
  }
}

static void respond_success(FlMethodCall* method_call) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to clipboard_image call: %s", error->message);
  }
}

static void handle_copy_image_file(FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  FlValue* path_value =
      args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
          ? fl_value_lookup_string(args, "path")
          : nullptr;
  if (path_value == nullptr ||
      fl_value_get_type(path_value) != FL_VALUE_TYPE_STRING) {
    respond_error(method_call, "INVALID_ARGUMENTS",
                  "copyImageFile requires a non-empty 'path'");
    return;
  }
  const gchar* path = fl_value_get_string(path_value);
  if (path == nullptr || path[0] == '\0') {
    respond_error(method_call, "INVALID_ARGUMENTS",
                  "copyImageFile requires a non-empty 'path'");
    return;
  }

  g_autoptr(GError) error = nullptr;
  g_autoptr(GdkPixbuf) pixbuf = gdk_pixbuf_new_from_file(path, &error);
  if (pixbuf == nullptr) {
    // 解不出来就如实报出来，绝不静默成功——静默失败会让用户以为复制好了，粘贴时
    // 才发现是空的。
    respond_error(method_call, "READ_FAILED",
                  error != nullptr ? error->message : "Could not decode image");
    return;
  }

  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  if (clipboard == nullptr) {
    respond_error(method_call, "CLIPBOARD_FAILED",
                  "GTK clipboard is unavailable");
    return;
  }
  gtk_clipboard_set_image(clipboard, pixbuf);
  // 请求 clipboard manager 接管，使内容在本进程退出后仍可粘贴（没有 manager 时无效，
  // 见文件头说明）。
  gtk_clipboard_store(clipboard);
  respond_success(method_call);
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  (void)channel;
  (void)user_data;
  if (g_strcmp0(fl_method_call_get_name(method_call), kMethodCopyImageFile) ==
      0) {
    handle_copy_image_file(method_call);
    return;
  }
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to clipboard_image call: %s", error->message);
  }
}

FlMethodChannel* fushi_clipboard_image_channel_new(
    FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(messenger, kChannelName,
                                                   FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                            nullptr);
  return channel;
}
