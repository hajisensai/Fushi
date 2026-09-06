// KiriKiri 资源流落盘时的载荷判据。纯函数，injector/hook/测试共用。
//
// 背景（tenshi_sz 真机，2026-09-04，BUG-2115）：KiriKiri 对每次文件访问给的是**放置路径**
// （`…voice.xp3>坒`，归档内条目名被哈希、无扩展名）或脚本逻辑名（`yuz_001_0004.ogg`）。旧的
// 落盘名生成只切 `/`、`\`，于是放置路径的 base 成了 `voice.xp3>坒`——里头的 `.xp3` 那个点骗过
// 「无点补 .ogg」，落盘名 `voice.xp3_坒` **没有音频扩展名**，host 的资源索引按扩展名扫就看不见
// 它，于是明明源资源已落盘（6.86 s）却退回 5 s loopback。这里提供两件事：
//   1) 路径分隔符要含 `>`（KiriKiri 归档放置路径）；
//   2) 扩展名按**载荷容器魔数**补（Ogg/RIFF-WAVE），不按名字猜，顺带把同前缀的非音频 sidecar
//      条目（几百字节的口形/元数据）从落盘名上区分开。
#pragma once

#include <cstddef>
#include <cstdint>
#include <cwchar>

namespace fushi_voice_hook {

// `>` 也是 KiriKiri 归档放置路径的分隔符（`归档>条目`）。取最后一段作落盘基名。
inline bool IsKirikiriPathSeparator(wchar_t c) {
  return c == L'/' || c == L'\\' || c == L'>';
}

// 读出来的资源字节是不是音频容器，返回应使用的扩展名（`.ogg` / `.wav`），非音频返回 nullptr。
// 按容器魔数判：Ogg（vorbis/opus 都在里面）与 RIFF/WAVE。
inline const wchar_t* KirikiriVoicePayloadExtension(const uint8_t* data,
                                                    size_t len) {
  if (data == nullptr || len < 12) return nullptr;
  if (data[0] == 'O' && data[1] == 'g' && data[2] == 'g' && data[3] == 'S') {
    return L".ogg";
  }
  if (data[0] == 'R' && data[1] == 'I' && data[2] == 'F' && data[3] == 'F' &&
      data[8] == 'W' && data[9] == 'A' && data[10] == 'V' && data[11] == 'E') {
    return L".wav";
  }
  return nullptr;
}

}  // namespace fushi_voice_hook
