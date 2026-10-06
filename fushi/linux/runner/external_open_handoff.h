#ifndef RUNNER_EXTERNAL_OPEN_HANDOFF_H_
#define RUNNER_EXTERNAL_OPEN_HANDOFF_H_

#include <gio/gio.h>

// 「从 app 外打开」的 argv 归一化（Linux 单实例转交，Windows 的对应物是
// `windows/runner/external_video_handoff.*` + WM_COPYDATA）。
//
// 桌面环境按 .desktop 的 `%u` / `%U` 传参时给的是 `file:///…` URI，终端里则是
// 相对路径，且相对的是**发起那个进程**的工作目录——转交到首实例后首实例的 cwd
// 对不上。所以在 runner 边界把参数统一成 Dart 侧认的形态：
//   - `file://` URI → 本地绝对路径；
//   - 其它带 scheme 的（`fushi://lookup?…`、`fushi://pair?…`、源 URL）原样；
//   - 以 `-` 开头的 flag 原样（Dart 侧会忽略）；
//   - 其余按 [cmdline] 的工作目录解析成绝对路径。
// 返回新分配的字符串（g_free）。
gchar* fushi_normalize_external_arg(GApplicationCommandLine* cmdline,
                                    const gchar* arg);

// [argv]（不含 argv[0]）里第一条非 flag 参数，归一化后返回（g_free）；没有返回
// nullptr。与 Windows `FirstFileArgFromCommandLine` 同口径：只转交第一条。
gchar* fushi_first_external_arg(GApplicationCommandLine* cmdline,
                                gchar** argv);

// 数据迁移自动重启（`DesktopLifecycleService.restartApp`）以 detached 方式拉起带
// `--fushi-restarted` 的新进程，**旧进程此刻还持有单实例 D-Bus 名**。不等的话新进程
// 会把参数转交给正在退出的旧进程然后自己退出，重启落空。与 Windows main.cpp 的
// TODO-935 豁免同义：argv 带该标志时，先等 [application_id] 在会话总线上没有
// owner（最多 [timeout_ms]），再照常注册成首实例。没有会话总线 / 名字本就空闲时
// 立即返回。
void fushi_wait_for_previous_instance_exit(int argc, char** argv,
                                           const gchar* application_id,
                                           guint timeout_ms);

#endif  // RUNNER_EXTERNAL_OPEN_HANDOFF_H_
