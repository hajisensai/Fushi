// Unity（Mono 运行时）身份探测。
//
// 结构判据：
//   * `<exe 主名>_Data\Managed\Assembly-CSharp.dll` —— Unity 托管构建的固定产物；
//   * **Mono 运行时**本体（IL2CPP 构建没有它），两代布局任一即可：
//       - 旧 Mono（Unity 5.x 一代）：`<exe 主名>_Data\Mono\mono.dll`
//         （量自真实样本「カスタムメイド3D2 CHU-B LIP」KISS 2015-09，2026-09-05）；
//       - MonoBleedingEdge（Unity 2017+ 的 .NET 4.x 运行时）：**exe 同级**
//         `MonoBleedingEdge\EmbedRuntime\mono-2.0-bdwgc.dll`（Boehm GC，Unity 默认）或
//         `mono-2.0-sgen.dll`（同一运行时的 SGen GC 构建）
//         （量自真实样本「デスマッチラブコメ！」KEMCO Steam 版 x86，2026-09-27：旧判据只认
//         `_Data\Mono\mono.dll`，于是这一代两个 Unity adapter 都不认领）；
//   * exe 同级**不得**有 `GameAssembly.dll` —— 那是 IL2CPP 运行时。
// 前两条同时成立才匹配（fail closed），第三条是**与 `unity_il2cpp` 互斥**的显式否定门：
// 两个 adapter 同时认领同一局，registry 的引擎身份汇总就说不清是哪家，而那份汇总正是
// 用户界面上「这游戏支持到哪一步」的唯一来源。
//
// **刻意不要求 `UnityPlayer.dll`**（新一代有、老一代没有，它不是判别特征）：老 Unity（5.x 一代）把引擎静态链进 exe，根本没有这个
// DLL。真实样本实测就是这样（`data\` 下只有 CM3D2OHx64.exe + CM3D2OHx64_Data\，无
// UnityPlayer.dll）。仓库里 `UnityIl2CppAdapter::probe()` 与 injector 的
// `LooksLikeUnityRuntime()` 都以它为必要条件，所以这一族老 Unity 游戏两边都不认领——
// 这条 adapter 补的正是那个缺口。
//
// exe 名不进判据：`<主名>_Data` 是跟着 exe 名走的，判据已经把这层关系表达进去了。
#pragma once

#include <windows.h>

#include <cwchar>
#include <string>

namespace fushi_voice_hook {

constexpr const wchar_t* kUnityDataSuffix = L"_Data";
constexpr const wchar_t* kUnityManagedAssembly = L"\\Managed\\Assembly-CSharp.dll";
constexpr const wchar_t* kUnityMonoRuntime = L"\\Mono\\mono.dll";
// MonoBleedingEdge 运行时相对 **exe 所在目录**（不在 `_Data` 下）；bdwgc / sgen 是同一
// 运行时的两种 GC 构建，随包二选一。
constexpr const wchar_t* kUnityMonoBleedingEdgeRuntimes[] = {
    L"\\MonoBleedingEdge\\EmbedRuntime\\mono-2.0-bdwgc.dll",
    L"\\MonoBleedingEdge\\EmbedRuntime\\mono-2.0-sgen.dll",
};
constexpr const wchar_t* kUnityIl2CppRuntime = L"\\GameAssembly.dll";

inline bool UnityMonoFileExists(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

// 目录 + exe 主名（不含 .exe）；测试用临时目录直接喂它。
inline bool MatchesUnityMonoLayout(const std::wstring& directory,
                                   const std::wstring& stem) {
  if (directory.empty() || stem.empty()) return false;
  // IL2CPP 否定门先判：两家互斥，宁可这里早退也不要两个 adapter 同时认领。
  if (UnityMonoFileExists(directory + kUnityIl2CppRuntime)) return false;
  const std::wstring data = directory + L"\\" + stem + kUnityDataSuffix;
  if (!UnityMonoFileExists(data + kUnityManagedAssembly)) return false;
  if (UnityMonoFileExists(data + kUnityMonoRuntime)) return true;
  for (const wchar_t* runtime : kUnityMonoBleedingEdgeRuntimes) {
    if (UnityMonoFileExists(directory + runtime)) return true;
  }
  return false;
}

inline bool MatchesUnityMonoProfile(const wchar_t*) {
  wchar_t executable[MAX_PATH] = {0};
  if (GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) return false;
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  const std::wstring directory(executable);
  std::wstring stem(slash + 1);
  // 去掉扩展名；没有扩展名时整串就是主名。
  const size_t dot = stem.find_last_of(L'.');
  if (dot != std::wstring::npos) stem.erase(dot);
  return MatchesUnityMonoLayout(directory, stem);
}

}  // namespace fushi_voice_hook
