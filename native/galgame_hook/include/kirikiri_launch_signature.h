#pragma once

// KiriKiri 引擎的 launch 期结构判据与 launch profile（纯逻辑，可离线测试）。
//
// 注入器在 CreateProcess 之前只能看磁盘。KiriKiri 的 exe 本身靠不住：Yuzusoft 原版
// CafeStella.exe 不导出 TVPGetFunctionExporter，汉化版 exe 又被 Enigma 整体加壳（导入 /
// 节名 / 版本资源都是壳的），exe 名更是随发行方改。但 KiriKiri（2 / Z）的数据归档格式
// XP3 始终随 exe 同目录（data.xp3 / voice.xp3 / patch.xp3 …，汉化 exe 与原版 exe 共用同一
// 目录的归档），且 XP3 文件头是 11 字节固定魔数 `XP3\r\n \n\x1A\x8B\x67\x01`——这是
// KiriKiri 归档格式本身的结构特征，与游戏名、exe 名、哈希都无关。判据：exe 所在目录里至少
// 一个 `*.xp3` 以该魔数开头。只认魔数，不认扩展名（fail closed：同后缀的别家文件不算）。
//
// 已知且刻意的缺口：把 XP3 附在 exe 尾部的单文件发行（目录里没有独立 .xp3）不匹配；没有
// 这种形态的真机样本，量不到的形状不写进判据。
//
// 与 Siglus / Unreal 判据同一形态：目录枚举与读文件头由调用方注入（生产 = Win32，测试 =
// 假文件表），判据本身不碰真实文件系统。

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace fushi_voice_hook {

// XP3 归档头魔数（KiriKiri2 / KiriKiri Z 共用）。
inline constexpr uint8_t kKirikiriXp3Magic[11] = {
    'X', 'P', '3', 0x0D, 0x0A, 0x20, 0x0A, 0x1A, 0x8B, 0x67, 0x01};
inline constexpr size_t kKirikiriXp3MagicBytes = sizeof(kKirikiriXp3Magic);

// 目录里最多看几个 `*.xp3`：判据跑在启动路径上，不能退化成全目录扫描；正常游戏只有
// 几个到十几个归档，第一个 data.xp3 就能命中。
inline constexpr size_t kKirikiriXp3ScanLimit = 16;

inline bool IsKirikiriXp3ArchiveHeader(const uint8_t* data, size_t size) {
  return data != nullptr && size >= kKirikiriXp3MagicBytes &&
         std::memcmp(data, kKirikiriXp3Magic, kKirikiriXp3MagicBytes) == 0;
}

// 目录是否具备 KiriKiri 数据签名。
//   for_each_xp3(dir, visit)：枚举 dir 下匹配 `*.xp3` 的普通文件，对每个**全路径**调
//                             visit(path)，visit 返回 false 即停止。
//   read_prefix(path, out, capacity) -> size_t：读文件开头至多 capacity 字节，返回实际读到的
//                             字节数（打不开返回 0）。
template <typename ForEachXp3, typename ReadPrefix>
bool DirectoryLooksLikeKirikiri(const std::wstring& dir, ForEachXp3 for_each_xp3,
                                ReadPrefix read_prefix) {
  if (dir.empty()) return false;
  bool matched = false;
  size_t scanned = 0;
  for_each_xp3(dir, [&](const std::wstring& path) {
    if (++scanned > kKirikiriXp3ScanLimit) return false;
    uint8_t header[kKirikiriXp3MagicBytes] = {};
    const size_t got = read_prefix(path, header, sizeof(header));
    if (IsKirikiriXp3ArchiveHeader(header, got)) {
      matched = true;
      return false;
    }
    return true;
  });
  return matched;
}

// KiriKiri launch profile：该引擎声明的启动生命周期特例。
//
// loader_init_gate（见 loader_init_gate.h）：KiriKiri 游戏常见的汉化 / 移植 exe 是 Enigma
// 加壳的，壳代码在 TLS 回调里跑；挂起创建后若由注入线程替进程跑初始化，远程 LoadLibraryW
// 就卡死在壳里（BUG-2701《喫茶ステラと死神の蝶》汉化 exe、BUG-2704《千恋＊万花》光盘版
// SenrenBankaCHS.exe）。这道门只由引擎 profile 声明，不对「任何带 TLS 回调的 PE」生效：
// 非 KiriKiri 带 TLS 回调的 exe（MinGW 运行时、NW.js、Themida/VMProtect 加壳、用
// thread_local 的 MSVC exe）没有一个真机样本跑过这道门，启动时序必须与门出现之前逐字节
// 等价（所有者 2026-09-26 拍板收窄）。
struct KirikiriLaunchProfile {
  bool recognised = false;
  bool loader_init_gate = false;
};

inline KirikiriLaunchProfile SelectKirikiriLaunchProfile(bool directory_has_xp3_signature) {
  KirikiriLaunchProfile profile;
  profile.recognised = directory_has_xp3_signature;
  profile.loader_init_gate = directory_has_xp3_signature;
  return profile;
}

}  // namespace fushi_voice_hook
