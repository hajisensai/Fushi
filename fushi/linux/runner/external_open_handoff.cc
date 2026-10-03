#include "external_open_handoff.h"

#include <string.h>

gchar* fushi_normalize_external_arg(GApplicationCommandLine* cmdline,
                                    const gchar* arg) {
  if (arg == nullptr) return nullptr;
  if (arg[0] == '-' || arg[0] == '\0') return g_strdup(arg);

  g_autofree gchar* scheme = g_uri_parse_scheme(arg);
  if (scheme != nullptr) {
    if (g_ascii_strcasecmp(scheme, "file") != 0) return g_strdup(arg);
    g_autoptr(GFile) file = g_file_new_for_uri(arg);
    gchar* path = g_file_get_path(file);
    return path != nullptr ? path : g_strdup(arg);
  }

  g_autoptr(GFile) file =
      cmdline != nullptr
          ? g_application_command_line_create_file_for_arg(cmdline, arg)
          : g_file_new_for_commandline_arg(arg);
  gchar* path = g_file_get_path(file);
  return path != nullptr ? path : g_strdup(arg);
}

gchar* fushi_first_external_arg(GApplicationCommandLine* cmdline,
                                gchar** argv) {
  if (argv == nullptr) return nullptr;
  for (gchar** it = argv; *it != nullptr; ++it) {
    if ((*it)[0] == '\0' || (*it)[0] == '-') continue;
    return fushi_normalize_external_arg(cmdline, *it);
  }
  return nullptr;
}

namespace {

constexpr const char* kRestartMarkerArg = "--fushi-restarted";

bool HasRestartMarker(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    if (argv[i] != nullptr && g_strcmp0(argv[i], kRestartMarkerArg) == 0) {
      return true;
    }
  }
  return false;
}

// 名字当前是否有 owner；查询失败按「没有」处理（不挡启动）。
bool NameHasOwner(GDBusConnection* bus, const gchar* name) {
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", name),
      G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
  if (reply == nullptr) return false;
  gboolean has_owner = FALSE;
  g_variant_get(reply, "(b)", &has_owner);
  return has_owner;
}

}  // namespace

void fushi_wait_for_previous_instance_exit(int argc, char** argv,
                                           const gchar* application_id,
                                           guint timeout_ms) {
  if (!HasRestartMarker(argc, argv)) return;
  g_autoptr(GDBusConnection) bus =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (bus == nullptr) return;
  const gint64 deadline =
      g_get_monotonic_time() + timeout_ms * G_GINT64_CONSTANT(1000);
  while (NameHasOwner(bus, application_id)) {
    if (g_get_monotonic_time() >= deadline) {
      // 旧进程卡住没退：照常注册（会转交给它并退出），与超时前的行为一致，
      // 不在这里无限挂起一个用户看不见的进程。
      g_warning("previous instance still owns %s after %u ms", application_id,
                timeout_ms);
      return;
    }
    g_usleep(100 * 1000);
  }
}
