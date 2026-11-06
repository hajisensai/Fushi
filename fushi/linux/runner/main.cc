#include <langinfo.h>

#include <clocale>

#include "external_open_handoff.h"
#include "my_application.h"

namespace {

bool IsCLocaleName(const gchar* name) {
  return g_strcmp0(name, "C") == 0 || g_strcmp0(name, "POSIX") == 0;
}

// Steam 游戏模式（gamescope 会话）以 LC_ALL=C 启动非 Steam 游戏：既遮住会话语言
// (LANG)，又让字符集变成纯 ASCII。Flatpak 里 WebKit 把整份环境（含 flatpak 自设、带
// 📦 的 PS1）当参数交给 flatpak-spawn，ASCII 下转码失败 → Web 进程起不来 → app abort。
// 所以：LC_ALL=C/POSIX 时去掉它回到会话语言；最终仍是 ASCII（没设语言 / 语言包缺失）
// 就用同语义的 C.UTF-8。必须在 GTK / 任何子进程之前跑。
void EnsureUtf8Locale() {
  if (IsCLocaleName(g_getenv("LC_ALL"))) g_unsetenv("LC_ALL");
  const char* locale = setlocale(LC_ALL, "");
  if (locale == nullptr ||
      g_strcmp0(nl_langinfo(CODESET), "ANSI_X3.4-1968") == 0) {
    g_setenv("LC_ALL", "C.UTF-8", TRUE);
    setlocale(LC_ALL, "");
  }
}

// 等旧实例让出单实例 D-Bus 名的上界（数据迁移重启与「首实例正在退出」共用）。
// 下限由 Dart 侧退出看门狗推出：main.dart 的 `_exitWatchdogTimeout` = 退出链各串行
// 步骤超时之和 + 余量（当前约 14.1s），本上界再留进程拆除余量；守卫
// test/platform/exit_watchdog_runner_wait_guard_test.dart 把两者钉在一起。
constexpr guint kPreviousInstanceWaitMs = 20000;

// 跑一次 GApplication。[forwarded_to_exiting_primary] 置 TRUE 表示本进程只是把
// argv 转交给了首实例，而首实例回答「我正在退出」（kFushiPrimaryExitingStatus）。
int RunApplication(int argc, char** argv,
                   gboolean* forwarded_to_exiting_primary) {
  g_autoptr(MyApplication) app = my_application_new();
  GApplication* application = G_APPLICATION(app);
  const int status = g_application_run(application, argc, argv);
  // 不能用 g_application_get_is_remote：run 返回时远端实例已被 GLib 注销。
  *forwarded_to_exiting_primary = !my_application_became_primary(app) &&
                                  status == kFushiPrimaryExitingStatus;
  return status;
}

}  // namespace

int main(int argc, char** argv) {
  EnsureUtf8Locale();
  // 数据迁移自动重启：先等旧实例让出单实例名，再注册（见该函数注释）。
  fushi_wait_for_previous_instance_exit(argc, argv, APPLICATION_ID,
                                        kPreviousInstanceWaitMs);
  gboolean forwarded_to_exiting_primary = FALSE;
  const int status =
      RunApplication(argc, argv, &forwarded_to_exiting_primary);
  if (!forwarded_to_exiting_primary) return status;

  // 首实例正在退出（BUG-3087）：它拒收了这次命令行、也没前置窗口。等它让出
  // D-Bus 名，再用同一份 argv 按首实例启动，由新实例自己打开那个文件——与
  // Windows main.cpp「窗口不可见 ⇔ 正在退出 → 等所有权后按首实例启动」同义。
  // 上一个 GApplication 已在 RunApplication 里释放，D-Bus 对象一并注销。
  if (!fushi_wait_for_bus_name_released(APPLICATION_ID,
                                        kPreviousInstanceWaitMs)) {
    // 旧进程到上界仍未退出（卡死）：不再重试，避免无限挂起一个看不见的进程。
    return status;
  }
  return RunApplication(argc, argv, &forwarded_to_exiting_primary);
}
