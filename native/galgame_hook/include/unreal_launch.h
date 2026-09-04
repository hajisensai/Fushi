// Unreal Engine（IoStore 打包形态）的结构判据。**唯一真相源**：
// hook 侧的 `hook/adapters/unreal_iostore_profile.h`（引擎身份）与 injector 侧的
// `LooksLikeUnrealRuntime`（决定是否自动开 LunaHook PC hooks）都调这里，不各写一份。
//
// 判据（全部量自真实样本「昨日魔女今日的梦 1.0 汉化版」，UE5，2026-09-05 静态 probe）：
//   * shipping 布局：可执行文件所在目录是 `...\Binaries\Win64`——UE 对每个平台固定
//     `<Game>\Binaries\<Platform>\`，样本里是
//     `kinomajo\Binaries\Win64\kinomajo-Win64-Shipping.exe`；
//   * 从该目录上溯两级得到 `<Game>` 根，其 `Content\Paks\` 下至少一个 `*.utoc` 以 16 字节
//     魔数 `-==--==--==--==-` 开头（IoStore 的 TOC 头）。样本里三个 utoc 魔数一致，
//     第 17 字节是版本 6。
// 两条必须**同时**成立（fail closed）：只有 `Binaries\Win64` 会命中任何把二进制放在同名
// 目录下的程序；只有 `.utoc` 后缀也可能是别家用同后缀的文件。
//
// **只锚 IoStore，是有意的**：UE4.25 之前只出 `Content\Paks\*.pak`，而 `.pak` 的魔数
// (0x5A6F12E1) 在**文件尾部**、偏移随 pak 版本变；本轮手上只有一个 UE5 IoStore 样本，
// 量不到的形状不写进判据。老 UE4 `.pak`-only 包因此**不匹配**，这是已知且刻意的覆盖面
// 缺口，补它需要一个真的 `.pak`-only 样本。
//
// exe 名的 `-Win64-Shipping` 后缀只作台账记录、不进判据：`-Win64-Test` / `-Win64-Debug`
// 同样是合法的 shipping 目录布局，而目录形状 + IoStore 魔数已经足够收敛。
#pragma once

#include <windows.h>

#include <cstdint>
#include <cstring>
#include <string>

namespace fushi_voice_hook {

// IoStore TOC 头 16 字节魔数（UE4.25+ / UE5）。
constexpr const char kUnrealIoStoreTocMagic[] = "-==--==--==--==-";
constexpr size_t kUnrealIoStoreTocMagicBytes = 16;
constexpr const wchar_t* kUnrealIoStorePakPattern = L"\\Content\\Paks\\*.utoc";
constexpr const wchar_t* kUnrealBinaryPlatformSegment = L"Win64";
constexpr const wchar_t* kUnrealBinaryParentSegment = L"Binaries";

inline bool UnrealReadFilePrefix(const std::wstring& path, uint8_t* out, DWORD capacity,
                                 DWORD* read_out) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD read = 0;
  const bool ok = ReadFile(file, out, capacity, &read, nullptr) != FALSE;
  CloseHandle(file);
  if (!ok) return false;
  *read_out = read;
  return true;
}

// 去掉末尾分隔符后取最后一段；没有分隔符时整串就是最后一段。
inline std::wstring UnrealLastSegment(const std::wstring& path) {
  size_t end = path.size();
  while (end > 0 && (path[end - 1] == L'\\' || path[end - 1] == L'/')) --end;
  if (end == 0) return std::wstring();
  const size_t slash = path.find_last_of(L"\\/", end - 1);
  if (slash == std::wstring::npos) return path.substr(0, end);
  return path.substr(slash + 1, end - slash - 1);
}

inline std::wstring UnrealParentDirectory(const std::wstring& path) {
  size_t end = path.size();
  while (end > 0 && (path[end - 1] == L'\\' || path[end - 1] == L'/')) --end;
  if (end == 0) return std::wstring();
  const size_t slash = path.find_last_of(L"\\/", end - 1);
  if (slash == std::wstring::npos) return std::wstring();
  return path.substr(0, slash);
}

// `...\Binaries\Win64`：UE 每平台固定的 shipping 二进制目录形状。
inline bool UnrealShippingBinaryLayout(const std::wstring& binary_directory) {
  if (_wcsicmp(UnrealLastSegment(binary_directory).c_str(),
               kUnrealBinaryPlatformSegment) != 0) {
    return false;
  }
  const std::wstring parent = UnrealParentDirectory(binary_directory);
  if (parent.empty()) return false;
  return _wcsicmp(UnrealLastSegment(parent).c_str(), kUnrealBinaryParentSegment) == 0;
}

// `<Game>\Content\Paks` 下至少一个 *.utoc 以 IoStore TOC 魔数开头。
inline bool UnrealIoStoreArchivePresent(const std::wstring& game_root) {
  WIN32_FIND_DATAW found = {};
  const std::wstring pattern = game_root + kUnrealIoStorePakPattern;
  HANDLE search = FindFirstFileW(pattern.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  bool matched = false;
  do {
    if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
    uint8_t magic[kUnrealIoStoreTocMagicBytes] = {0};
    DWORD read = 0;
    const std::wstring path = game_root + L"\\Content\\Paks\\" + found.cFileName;
    if (UnrealReadFilePrefix(path, magic, sizeof(magic), &read) &&
        read == kUnrealIoStoreTocMagicBytes &&
        memcmp(magic, kUnrealIoStoreTocMagic, kUnrealIoStoreTocMagicBytes) == 0) {
      matched = true;
      break;
    }
  } while (FindNextFileW(search, &found));
  FindClose(search);
  return matched;
}

// 给定 shipping 二进制所在目录的结构判据；测试用临时目录直接喂它。
inline bool MatchesUnrealIostoreLayout(const std::wstring& binary_directory) {
  if (!UnrealShippingBinaryLayout(binary_directory)) return false;
  const std::wstring game_root =
      UnrealParentDirectory(UnrealParentDirectory(binary_directory));
  if (game_root.empty()) return false;
  return UnrealIoStoreArchivePresent(game_root);
}

}  // namespace fushi_voice_hook
