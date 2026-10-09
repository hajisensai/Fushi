#ifndef FLUTTER_MY_APPLICATION_H_
#define FLUTTER_MY_APPLICATION_H_

#include <gtk/gtk.h>

G_DECLARE_FINAL_TYPE(MyApplication,
                     my_application,
                     MY,
                     APPLICATION,
                     GtkApplication)

/**
 * my_application_new:
 *
 * Creates a new Flutter-based application.
 *
 * Returns: a new #MyApplication.
 */
MyApplication* my_application_new();

// 本进程这次 g_application_run 是否以首实例身份启动过（GApplication::startup 只在
// 首实例里跑）。g_application_run 返回后 GLib 已注销远端实例，
// g_application_get_is_remote 不再可用，所以由 startup 记下这一位。
gboolean my_application_became_primary(MyApplication* self);

// 首实例已进入退出链（Dart 经 `app.fushi/external_video` 的 `appExiting` 通知）时，
// 对二次启动转交来的命令行返回这个退出码：不接管、不前置窗口。二次启动进程的
// g_application_run 拿到的正是首实例回给它的这个码，`main.cc` 据此等旧实例让出
// D-Bus 名后自己按首实例启动（BUG-3087，Windows 对应物见 windows/runner/main.cpp
// 「窗口不可见 ⇔ 正在退出」）。取 EX_TEMPFAIL：「暂时不行，稍后重试」。
constexpr int kFushiPrimaryExitingStatus = 75;

#endif  // FLUTTER_MY_APPLICATION_H_
