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
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  // 单实例：D-Bus 激活（桌面环境再点一次图标、`gapplication launch`）会再次走
  // activate；已有主窗口时只前置，不再起第二个 FlView / 第二个 Dart isolate。
  if (self->window != nullptr) {
    gtk_window_present(self->window);
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

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::command_line.
//
// 单实例（BUG-437 / TODO-904 的 Linux 对应）：应用以 G_APPLICATION_HANDLES_COMMAND_LINE
// 注册到会话 D-Bus，第二次启动的进程只把自己的 argv 经 D-Bus 交给首实例、随即
// 退出，这个回调总是在**首实例**里跑：
//   - 首次（还没有主窗口）：argv 作为 Dart 入口参数起引擎，等价于原模板的冷启动；
//   - 之后：第一条非 flag 参数转交 Dart（`openExternalVideo`），再前置主窗口。
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

  g_autofree gchar* external = fushi_first_external_arg(cmdline, args);
  if (external != nullptr && self->external_video_channel != nullptr) {
    g_autoptr(FlValue) value = fl_value_new_string(external);
    fl_method_channel_invoke_method(self->external_video_channel,
                                    "openExternalVideo", value, nullptr,
                                    nullptr, nullptr);
  }
  gtk_window_present(self->window);
  return 0;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

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

static void my_application_init(MyApplication* self) {}

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
