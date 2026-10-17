#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

#include "clipboard_image_channel.h"
#include "external_open_handoff.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // 复制图片到剪贴板（`app.fushi.reader/clipboard_image`）。必须存住这个引用：
  // channel 一被回收，Dart 侧的调用就落成 MissingPluginException。
  FlMethodChannel* clipboard_image_channel;
  // 第二次启动（文件关联 / `fushi://` 深链 / 终端 `fushi <路径>`）转交过来的参数，
  // 经 `app.fushi/external_video` 的 `openExternalVideo` 推给 Dart——与 Windows
  // WM_COPYDATA 落到的是同一个 Dart 处理（`_handleExternalVideoChannel`）。
  FlMethodChannel* external_video_channel;
  // 主窗口（弱引用：窗口销毁时自动置空）。单实例下二次启动只前置它，不再开新窗。
  GtkWindow* window;
  // 首帧已出、窗口已显示过。之前不 present：present 一个还没画过的 FlView 就是
  // 一块黑窗（BUG-3089）；首帧到了 first_frame_cb 自己会显示窗口。
  gboolean first_frame_shown;
  // Dart 的 `_handleExternalVideoChannel` 已注册（收到 `externalOpenReady`）。之前
  // invoke 过去的消息只由 framework 的 ChannelBuffers 暂存、每通道仅 1 条，更早的
  // 被挤掉，所以先排在 pending_external_args（元素 gchar*）里，ready 时按到达
  // 顺序冲出（BUG-3089）。
  gboolean external_open_ready;
  GPtrArray* pending_external_args;
  // Dart 退出链已开始（收到 `appExiting`，紧接着就是 windowManager.hide()，进程
  // 再活几秒做 flush，D-Bus 名一直占着）。此后不再接管二次启动的命令行：参数
  // 交给将死的进程 = 丢失、present = 把正在退出的窗口又显示出来（BUG-3087）。
  gboolean exiting;
  // GApplication::startup 跑过 = 本进程是首实例（见 my_application_became_primary）。
  gboolean became_primary;
};

// `app.fushi/external_video` 上 Dart → runner 的两个方法（Dart 侧常量见
// `lib/src/platform/desktop/linux_external_open_channel.dart`）。
static constexpr const char* kExternalOpenReadyMethod = "externalOpenReady";
static constexpr const char* kAppExitingMethod = "appExiting";

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  self->first_frame_shown = TRUE;
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// 二次启动后把主窗口提到前台。首帧前不 present（黑窗），退出链里不 present
// （把隐藏的将死窗口又显示出来）。
static void present_main_window(MyApplication* self) {
  if (self->window == nullptr || self->exiting || !self->first_frame_shown) {
    return;
  }
  gtk_window_present(self->window);
}

static void send_external_arg(MyApplication* self, const gchar* arg) {
  g_autoptr(FlValue) value = fl_value_new_string(arg);
  fl_method_channel_invoke_method(self->external_video_channel,
                                  "openExternalVideo", value, nullptr, nullptr,
                                  nullptr);
}

// Dart 处理器就绪前排队，就绪后直接发。
static void deliver_external_arg(MyApplication* self, const gchar* arg) {
  if (self->external_video_channel == nullptr) return;
  if (!self->external_open_ready) {
    g_ptr_array_add(self->pending_external_args, g_strdup(arg));
    return;
  }
  send_external_arg(self, arg);
}

static void external_video_method_cb(FlMethodChannel* channel,
                                     FlMethodCall* method_call,
                                     gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, kExternalOpenReadyMethod) == 0) {
    self->external_open_ready = TRUE;
    for (guint i = 0; i < self->pending_external_args->len; ++i) {
      send_external_arg(self, static_cast<const gchar*>(g_ptr_array_index(
                                  self->pending_external_args, i)));
    }
    g_ptr_array_set_size(self->pending_external_args, 0);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, kAppExitingMethod) == 0) {
    self->exiting = TRUE;
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("external_video respond failed: %s", error->message);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  // 单实例：D-Bus 激活（桌面环境再点一次图标、`gapplication launch`）会再次走
  // activate；已有主窗口时只前置，不再起第二个 FlView / 第二个 Dart isolate。
  if (self->window != nullptr) {
    present_main_window(self);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->window));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Fushi");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Fushi");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  self->clipboard_image_channel = fushi_clipboard_image_channel_new(messenger);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->external_video_channel =
      fl_method_channel_new(messenger, "app.fushi/external_video",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->external_video_channel, external_video_method_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::command_line.
//
// 单实例（BUG-437 / TODO-904 的 Linux 对应）：应用以 G_APPLICATION_HANDLES_COMMAND_LINE
// 注册到会话 D-Bus，第二次启动的进程只把自己的 argv 经 D-Bus 交给首实例、随即
// 退出，这个回调总是在**首实例**里跑：
//   - 首次（还没有主窗口）：argv 作为 Dart 入口参数起引擎，等价于原模板的冷启动；
//   - 之后：第一条非 flag 参数转交 Dart（`openExternalVideo`；Dart 处理器就绪前
//     排队），再前置主窗口（首帧前不前置）；
//   - 首实例已进入退出链：返回 kFushiPrimaryExitingStatus，不转交、不前置。
// 没有会话总线时 GLib 自动退化为非唯一应用，行为与原来一致。
static int my_application_command_line(GApplication* application,
                                       GApplicationCommandLine* cmdline) {
  MyApplication* self = MY_APPLICATION(application);
  gint argc = 0;
  g_auto(GStrv) argv =
      g_application_command_line_get_arguments(cmdline, &argc);
  // argv[0] 是可执行文件名，不交给 Dart。
  gchar** args = argc > 0 ? argv + 1 : argv;

  if (self->window == nullptr) {
    GPtrArray* normalized = g_ptr_array_new();
    for (gchar** it = args; it != nullptr && *it != nullptr; ++it) {
      g_ptr_array_add(normalized, fushi_normalize_external_arg(cmdline, *it));
    }
    g_ptr_array_add(normalized, nullptr);
    g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
    self->dart_entrypoint_arguments =
        reinterpret_cast<gchar**>(g_ptr_array_free(normalized, FALSE));
    g_application_activate(application);
    return 0;
  }

  // 首实例正在退出：不接管这次启动。回 kFushiPrimaryExitingStatus，二次启动进程
  // 据此等本进程让出 D-Bus 名、再自己按首实例启动（main.cc），文件由新实例打开。
  if (self->exiting) {
    return kFushiPrimaryExitingStatus;
  }

  g_autofree gchar* external = fushi_first_external_arg(cmdline, args);
  if (external != nullptr) {
    deliver_external_arg(self, external);
  }
  present_main_window(self);
  return 0;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  MY_APPLICATION(application)->became_primary = TRUE;

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->clipboard_image_channel);
  g_clear_object(&self->external_video_channel);
  g_clear_pointer(&self->pending_external_args, g_ptr_array_unref);
  if (self->window != nullptr) {
    g_object_remove_weak_pointer(G_OBJECT(self->window),
                                 reinterpret_cast<gpointer*>(&self->window));
    self->window = nullptr;
  }
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->pending_external_args = g_ptr_array_new_with_free_func(g_free);
}

gboolean my_application_became_primary(MyApplication* self) {
  return self->became_primary;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // 集成测试 runner 必须以首实例语义启动，哪怕用户自己的 Fushi 正开着——否则
  // 测试进程会把参数转交给用户实例后退出，flutter_tool 永远 attach 不上。判据
  // 与 Windows `IsTestRunnerMode` 同源（FUSHI_TEST_HIDDEN），另认 FUSHI_TEST_ROOT：
  // 指到隔离数据根的实例本来就不和用户实例共享任何状态。
  GApplicationFlags flags = G_APPLICATION_HANDLES_COMMAND_LINE;
  if (g_getenv("FUSHI_TEST_HIDDEN") != nullptr ||
      g_getenv("FUSHI_TEST_ROOT") != nullptr) {
    flags = static_cast<GApplicationFlags>(flags | G_APPLICATION_NON_UNIQUE);
  }

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
