// Fushi: thin registrar that lazily loads the WPE WebKit implementation.
//
// Why this file exists (not in upstream flutter_inappwebview_linux):
// upstream links the whole plugin -- and therefore libWPEWebKit-2.0 -- straight
// into the runner executable. WPE WebKit is a system library that many distros
// (Ubuntu 24.04 among them) do not ship, so on such a machine the dynamic
// loader refuses to start the *entire app*, not just the web views. The reader,
// manga reader and dictionary popup need WPE, but the video player, library,
// sync, downloads, etc. do not.
//
// So the runner links only this shim (no WPE dependency). At registration time
// it dlopen()s the real implementation, libflutter_inappwebview_linux_wpe.so,
// from the same directory as itself (bundle/lib). If that fails (WPE missing,
// or the bundle was built on a machine without WPE and the implementation was
// never produced) the app keeps running and the Dart side gets a clear status
// over `fushi/flutter_inappwebview_linux/runtime` to explain what to install.

#include "include/flutter_inappwebview_linux/flutter_inappwebview_linux_plugin.h"

#include <dlfcn.h>
#include <flutter_linux/flutter_linux.h>
#include <sched.h>
#include <sys/wait.h>
#include <unistd.h>

#include <string>

namespace {

constexpr char kImplLibraryName[] = "libflutter_inappwebview_linux_wpe.so";
constexpr char kImplRegisterSymbol[] =
    "fushi_inappwebview_wpe_register_with_registrar";
constexpr char kRuntimeChannel[] = "fushi/flutter_inappwebview_linux/runtime";

using RegisterFn = void (*)(FlPluginRegistrar*);

bool g_available = false;
std::string g_load_error;

std::string ShimDirectory() {
  Dl_info info;
  if (dladdr(reinterpret_cast<void*>(&ShimDirectory), &info) == 0 ||
      info.dli_fname == nullptr) {
    return std::string();
  }
  std::string path(info.dli_fname);
  const size_t slash = path.rfind('/');
  return slash == std::string::npos ? std::string() : path.substr(0, slash);
}

// WPE WebKit 2.x always sandboxes its web/network processes with bubblewrap,
// which needs unprivileged user namespaces. Where those are forbidden (Docker
// default profile, Ubuntu 24.04+ AppArmor userns restriction for unconfined
// apps, hardened kernels) bwrap fails and WebKit g_error()s -- aborting the
// whole app the first time any web view (even the startup prewarm) is created.
// Probe once in a throwaway child so that environment degrades to "web views
// unavailable" with a reason instead. WebKit's own escape hatch env var skips
// the probe because the sandbox is then not used at all.
bool UserNamespacesUsable(std::string* reason) {
  if (g_getenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS") != nullptr) {
    return true;
  }
  const pid_t pid = fork();
  if (pid < 0) return true;  // cannot probe; let WebKit decide
  if (pid == 0) {
    _exit(unshare(CLONE_NEWUSER) == 0 ? 0 : 1);
  }
  int status = 0;
  if (waitpid(pid, &status, 0) < 0) return true;
  if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return true;
  *reason =
      "unprivileged user namespaces are not permitted here, but WPE WebKit's "
      "bubblewrap sandbox requires them (allow them, e.g. sysctl "
      "kernel.apparmor_restrict_unprivileged_userns=0 / "
      "kernel.unprivileged_userns_clone=1, or set "
      "WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1)";
  return false;
}

void LoadImplementation(FlPluginRegistrar* registrar) {
  std::string userns_reason;
  if (!UserNamespacesUsable(&userns_reason)) {
    g_load_error = userns_reason;
    g_warning("flutter_inappwebview_linux: WPE WebKit backend disabled: %s",
              g_load_error.c_str());
    return;
  }
  const std::string dir = ShimDirectory();
  const std::string path =
      dir.empty() ? std::string(kImplLibraryName) : dir + "/" + kImplLibraryName;
  // RTLD_LOCAL: the implementation's symbols (GType names, nlohmann, ...) stay
  // out of the global namespace. Never dlclose -- it registers GTypes.
  void* handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (handle == nullptr) {
    const char* err = dlerror();
    g_load_error = err != nullptr ? err : "dlopen failed";
    g_warning("flutter_inappwebview_linux: WPE WebKit backend unavailable: %s",
              g_load_error.c_str());
    return;
  }
  auto fn = reinterpret_cast<RegisterFn>(dlsym(handle, kImplRegisterSymbol));
  if (fn == nullptr) {
    const char* err = dlerror();
    g_load_error = err != nullptr ? err : "register symbol missing";
    g_warning("flutter_inappwebview_linux: %s", g_load_error.c_str());
    return;
  }
  fn(registrar);
  g_available = true;
}

void HandleRuntimeCall(FlMethodChannel* channel, FlMethodCall* call,
                       gpointer user_data) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(call), "status") == 0) {
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "available",
                             fl_value_new_bool(g_available));
    fl_value_set_string_take(result, "error",
                             fl_value_new_string(g_load_error.c_str()));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void flutter_inappwebview_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  LoadImplementation(registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // Leaked on purpose: lives for the whole engine lifetime, like every
  // plugin channel registered here.
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), kRuntimeChannel,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, HandleRuntimeCall, nullptr,
                                            nullptr);
}
