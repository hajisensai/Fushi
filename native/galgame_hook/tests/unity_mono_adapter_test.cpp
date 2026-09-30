// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

// Unity Mono 身份判据用真临时目录验：判据读的是磁盘布局，只有文件系统自己能作证。
// 重点覆盖**与 unity_il2cpp 的互斥**——两家同时认领同一局，registry 的引擎身份汇总就
// 说不清是哪家，而那份汇总是用户界面上「这游戏支持到哪一步」的唯一来源。
#include "../hook/adapters/unity_mono_profile.h"

#include <cassert>
#include <cstdio>
#include <initializer_list>
#include <string>

namespace {

std::wstring MakeTempRoot(const wchar_t* tag) {
  wchar_t temp[MAX_PATH] = {0};
  assert(GetTempPathW(MAX_PATH, temp) != 0);
  std::wstring root = std::wstring(temp) + L"fushi_unitymono_test_" + tag + L"_" +
                      std::to_wstring(GetCurrentProcessId());
  assert(CreateDirectoryW(root.c_str(), nullptr) ||
         GetLastError() == ERROR_ALREADY_EXISTS);
  return root;
}

void Touch(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  DWORD written = 0;
  WriteFile(file, "x", 1, &written, nullptr);
  CloseHandle(file);
}

// <root>\Game_Data\Managed\Assembly-CSharp.dll + <root>\Game_Data\Mono\mono.dll
void MakeMonoTree(const std::wstring& root, bool managed, bool mono) {
  CreateDirectoryW((root + L"\\Game_Data").c_str(), nullptr);
  if (managed) {
    CreateDirectoryW((root + L"\\Game_Data\\Managed").c_str(), nullptr);
    Touch(root + L"\\Game_Data\\Managed\\Assembly-CSharp.dll");
  }
  if (mono) {
    CreateDirectoryW((root + L"\\Game_Data\\Mono").c_str(), nullptr);
    Touch(root + L"\\Game_Data\\Mono\\mono.dll");
  }
}

// 2017+ 的 MonoBleedingEdge 布局：<root>\MonoBleedingEdge\EmbedRuntime\<runtime>，
// 在 exe 同级、不在 _Data 下。
void MakeBleedingEdgeRuntime(const std::wstring& root, const wchar_t* runtime) {
  CreateDirectoryW((root + L"\\MonoBleedingEdge").c_str(), nullptr);
  CreateDirectoryW((root + L"\\MonoBleedingEdge\\EmbedRuntime").c_str(), nullptr);
  Touch(root + L"\\MonoBleedingEdge\\EmbedRuntime\\" + runtime);
}

void RemoveTree(const std::wstring& root) {
  for (const wchar_t* runtime :
       {L"mono-2.0-bdwgc.dll", L"mono-2.0-sgen.dll", L"mono.dll"}) {
    DeleteFileW((root + L"\\MonoBleedingEdge\\EmbedRuntime\\" + runtime).c_str());
  }
  DeleteFileW(
      (root + L"\\Game_Data\\MonoBleedingEdge\\EmbedRuntime\\mono-2.0-bdwgc.dll")
          .c_str());
  RemoveDirectoryW((root + L"\\Game_Data\\MonoBleedingEdge\\EmbedRuntime").c_str());
  RemoveDirectoryW((root + L"\\Game_Data\\MonoBleedingEdge").c_str());
  RemoveDirectoryW((root + L"\\MonoBleedingEdge\\EmbedRuntime").c_str());
  RemoveDirectoryW((root + L"\\MonoBleedingEdge").c_str());
  DeleteFileW((root + L"\\UnityPlayer.dll").c_str());
  DeleteFileW((root + L"\\GameAssembly.dll").c_str());
  DeleteFileW((root + L"\\Game_Data\\Managed\\Assembly-CSharp.dll").c_str());
  DeleteFileW((root + L"\\Game_Data\\Mono\\mono.dll").c_str());
  RemoveDirectoryW((root + L"\\Game_Data\\Managed").c_str());
  RemoveDirectoryW((root + L"\\Game_Data\\Mono").c_str());
  RemoveDirectoryW((root + L"\\Game_Data").c_str());
  RemoveDirectoryW(root.c_str());
}

}  // namespace

int main() {
  // 1. 完整 Mono 布局 → 匹配。注意**没有** UnityPlayer.dll：老 Unity 把引擎静态链进 exe，
  //    真实样本就是这样，判据不得要求它。
  {
    const std::wstring root = MakeTempRoot(L"mono");
    MakeMonoTree(root, true, true);
    assert(fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    RemoveTree(root);
  }
  // 2. 只有 Managed、没有 Mono 运行时 → 不匹配（fail closed）。
  //    这条挡住 IL2CPP 之外的其它托管布局，也挡住只解压了一半的目录。
  {
    const std::wstring root = MakeTempRoot(L"nomono");
    MakeMonoTree(root, true, false);
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    RemoveTree(root);
  }
  // 3. 只有 Mono、没有 Managed 程序集 → 不匹配。
  {
    const std::wstring root = MakeTempRoot(L"nomanaged");
    MakeMonoTree(root, false, true);
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    RemoveTree(root);
  }
  // 4. **与 unity_il2cpp 互斥**：Mono 布局齐全，但同级有 GameAssembly.dll → 不匹配。
  //    两家同时认领会让 registry 的引擎身份汇总说不清是哪家。
  {
    const std::wstring root = MakeTempRoot(L"il2cpp");
    MakeMonoTree(root, true, true);
    Touch(root + L"\\GameAssembly.dll");
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    RemoveTree(root);
  }
  // 5. exe 主名对不上 → 不匹配：`<主名>_Data` 是跟着 exe 名走的，拿别的名字查不该命中。
  {
    const std::wstring root = MakeTempRoot(L"stem");
    MakeMonoTree(root, true, true);
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(root, L"Other"));
    assert(fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    RemoveTree(root);
  }
  // 6. 退化输入：空目录名 / 空主名 / 不存在的目录，都不匹配且不崩。
  {
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(L"", L"Game"));
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(L"C:\\nope_zzz", L""));
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(L"C:\\nope_zzz", L"Game"));
  }
  // 7. 目录同名也不算文件：Assembly-CSharp.dll 是个目录时必须判否。
  {
    const std::wstring root = MakeTempRoot(L"dirnotfile");
    CreateDirectoryW((root + L"\\Game_Data").c_str(), nullptr);
    CreateDirectoryW((root + L"\\Game_Data\\Managed").c_str(), nullptr);
    CreateDirectoryW((root + L"\\Game_Data\\Managed\\Assembly-CSharp.dll").c_str(),
                     nullptr);
    CreateDirectoryW((root + L"\\Game_Data\\Mono").c_str(), nullptr);
    Touch(root + L"\\Game_Data\\Mono\\mono.dll");
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    RemoveDirectoryW((root + L"\\Game_Data\\Managed\\Assembly-CSharp.dll").c_str());
    RemoveTree(root);
  }
  // 8. 2017+ MonoBleedingEdge 布局（真实样本形态：exe 同级 UnityPlayer.dll +
  //    MonoBleedingEdge\EmbedRuntime\mono-2.0-bdwgc.dll，_Data 下只有 Managed、没有 Mono）
  //    → 匹配。bdwgc 与 sgen 两种 GC 构建都认。
  for (const wchar_t* runtime : {L"mono-2.0-bdwgc.dll", L"mono-2.0-sgen.dll"}) {
    const std::wstring root = MakeTempRoot(L"bleeding");
    MakeMonoTree(root, true, false);
    Touch(root + L"\\UnityPlayer.dll");
    MakeBleedingEdgeRuntime(root, runtime);
    assert(fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    // 同目录的 UnityCrashHandler32.exe 之类：主名对不上 `_Data` → 不认领。
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(root, L"UnityCrashHandler32"));
    RemoveTree(root);
  }
  // 9. MonoBleedingEdge 布局同样守 IL2CPP 互斥门：同级有 GameAssembly.dll → 不匹配。
  {
    const std::wstring root = MakeTempRoot(L"bleeding_il2cpp");
    MakeMonoTree(root, true, false);
    Touch(root + L"\\UnityPlayer.dll");
    MakeBleedingEdgeRuntime(root, L"mono-2.0-bdwgc.dll");
    Touch(root + L"\\GameAssembly.dll");
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    RemoveTree(root);
  }
  // 10. IL2CPP 构建的典型形态（UnityPlayer.dll + GameAssembly.dll，_Data 下无 Managed）
  //     → 不匹配。
  {
    const std::wstring root = MakeTempRoot(L"il2cpp_plain");
    CreateDirectoryW((root + L"\\Game_Data").c_str(), nullptr);
    Touch(root + L"\\UnityPlayer.dll");
    Touch(root + L"\\GameAssembly.dll");
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    RemoveTree(root);
  }
  // 11. MonoBleedingEdge 运行时在、但没有 Managed 程序集 → 不匹配（fail closed）。
  {
    const std::wstring root = MakeTempRoot(L"bleeding_nomanaged");
    CreateDirectoryW((root + L"\\Game_Data").c_str(), nullptr);
    MakeBleedingEdgeRuntime(root, L"mono-2.0-bdwgc.dll");
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    RemoveTree(root);
  }
  // 12. 位置/名字不对的运行时不算：MonoBleedingEdge 挂在 _Data 下、或 EmbedRuntime 里放的
  //     是别名 mono.dll → 都不是这一代的真实布局，不匹配（不做子串宽匹配）。
  {
    const std::wstring root = MakeTempRoot(L"bleeding_misplaced");
    MakeMonoTree(root, true, false);
    CreateDirectoryW((root + L"\\Game_Data\\MonoBleedingEdge").c_str(), nullptr);
    CreateDirectoryW((root + L"\\Game_Data\\MonoBleedingEdge\\EmbedRuntime").c_str(),
                     nullptr);
    Touch(root + L"\\Game_Data\\MonoBleedingEdge\\EmbedRuntime\\mono-2.0-bdwgc.dll");
    MakeBleedingEdgeRuntime(root, L"mono.dll");
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    RemoveTree(root);
  }
  // 13. 非 Unity 目录：exe 同级只有个名叫 UnityPlayer.dll 的文件，没有 _Data\Managed、
  //     也没有任何 Mono 运行时 → 不匹配。
  {
    const std::wstring root = MakeTempRoot(L"nonunity");
    Touch(root + L"\\UnityPlayer.dll");
    assert(!fushi_voice_hook::MatchesUnityMonoLayout(root, L"Game"));
    RemoveTree(root);
  }
  // 14. 测试进程自己的目录不是 Unity Mono 游戏 → 进程级探测为假。
  assert(!fushi_voice_hook::MatchesUnityMonoProfile(nullptr));
  std::printf("unity_mono_adapter_test: ok\n");
  return 0;
}
