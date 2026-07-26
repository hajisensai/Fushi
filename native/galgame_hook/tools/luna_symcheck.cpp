#include <windows.h>

#include <cstdio>
#include <string>

#include "luna_bridge.h"

// galgame 一键制卡 C 阶段 —— LunaHost DLL 符号解析校验器（**纯查符号，不注入、不跑游戏**）。
//
// 用途：编译后离线确认 vendored 的 LunaHost<arch>.dll 能被 LoadLibrary 且 injector 依赖的导出
// 都 GetProcAddress 得到——这是 injector 接 LunaHook 的编译/链接之外的运行期前提。DllMain 是
// no-op（LunaHostDll.cpp 各 case 仅 break），加载它不建线程、不注入、无副作用，故本工具可安全
// 运行。**它不加载 LunaHook<arch>.dll（那才是注入进游戏的那半），也不 CreatePipe/Start。**
//
// 退出码：0=必需导出齐全；1=DLL 加载失败或缺必需导出。
namespace {

#ifdef _WIN64
constexpr const wchar_t* kArch = L"64";
#else
constexpr const wchar_t* kArch = L"32";
#endif

std::wstring SelfDir() {
  wchar_t exe[MAX_PATH] = {0};
  const DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    return L"";
  }
  std::wstring path(exe, n);
  const size_t slash = path.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    path.resize(slash + 1);
  } else {
    path.clear();
  }
  return path;
}

}  // namespace

int main() {
  const std::wstring dll = SelfDir() + L"LunaHost" + kArch + L".dll";
  HMODULE h = LoadLibraryW(dll.c_str());
  if (h == nullptr) {
    fprintf(stderr, "LoadLibrary(LunaHost%ls.dll) 失败：%lu\n", kArch,
            GetLastError());
    return 1;
  }
  printf("LunaHost%ls.dll 已加载。\n", kArch);
  printf("bridge ABI=%u, vendored Luna=10.16.1.2 (0x%08x)\n",
         hibiki_voice_hook::kLunaBridgeAbiVersion,
         hibiki_voice_hook::kLunaVendoredVersion);

  int missing_required = 0;
  printf("== 必需导出 ==\n");
  for (const char* name : hibiki_voice_hook::kLunaRequiredExports) {
    void* p = reinterpret_cast<void*>(GetProcAddress(h, name));
    printf("  [%s] %s (%p)\n", p ? "OK" : "MISSING", name, p);
    if (p == nullptr) {
      missing_required++;
    }
  }
  printf("== 可选导出 ==\n");
  for (const char* name : hibiki_voice_hook::kLunaOptionalExports) {
    void* p = reinterpret_cast<void*>(GetProcAddress(h, name));
    printf("  [%s] %s (%p)\n", p ? "OK" : "absent", name, p);
  }

  FreeLibrary(h);
  const std::wstring hook = SelfDir() + L"LunaHook" + kArch + L".dll";
  if (GetFileAttributesW(hook.c_str()) == INVALID_FILE_ATTRIBUTES) {
    fprintf(stderr, "LunaHook%ls.dll 缺失。\n", kArch);
    return 1;
  }
  if (missing_required != 0) {
    fprintf(stderr, "缺 %d 个必需导出 —— injector 无法接 LunaHook。\n",
            missing_required);
    return 1;
  }
  printf("必需导出齐全，LunaHook 接线运行期前提满足。\n");
  return 0;
}
