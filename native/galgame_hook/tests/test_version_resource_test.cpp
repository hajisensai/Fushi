// 守卫：本目录的测试 exe 必须带 VERSIONINFO（tests/test_version.rc）。
//
// 缺版本资源的极小 x64 Release 测试 exe 会被 Kaspersky 泛型启发式误报并删除
// （fushi_utterance_window_test.exe → VHO:Trojan.Win32.Sdum.gen），CTest 静默少跑。
// CMakeLists.txt 末尾的循环给每个 *_test 目标挂上同一份 .rc；这条测试自身也是被
// 那个循环挂上的，所以循环失效或 .rc 丢了它就读不到自己的版本资源而转红。
#undef NDEBUG

#include <windows.h>

#include <cstdio>
#include <cwchar>
#include <vector>

int main() {
  wchar_t path[MAX_PATH] = {};
  const DWORD len = GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    printf("FAIL GetModuleFileNameW: %lu\n", GetLastError());
    return 1;
  }
  DWORD handle = 0;
  const DWORD size = GetFileVersionInfoSizeW(path, &handle);
  if (size == 0) {
    printf("FAIL test exe has no VERSIONINFO (err %lu)\n", GetLastError());
    return 1;
  }
  std::vector<unsigned char> data(size);
  if (!GetFileVersionInfoW(path, 0, size, data.data())) {
    printf("FAIL GetFileVersionInfoW: %lu\n", GetLastError());
    return 1;
  }
  void* value = nullptr;
  UINT value_len = 0;
  if (!VerQueryValueW(data.data(),
                      L"\\StringFileInfo\\040904b0\\FileDescription", &value,
                      &value_len) ||
      value_len == 0 ||
      wcscmp(static_cast<const wchar_t*>(value),
             L"Fushi galgame hook unit test") != 0) {
    printf("FAIL FileDescription missing or unexpected\n");
    return 1;
  }
  printf("test_version_resource_test: ok\n");
  return 0;
}
