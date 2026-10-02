// RIFF/WAVE PCM 载荷是不是「静音」。纯函数，hook/测试共用。
//
// 背景（BUG-2888，Fate/stay night[Realta Nua] 真机）：KAG 脚本常用播放一段极短的静音语音
// （`mute.wav`，0.108 s、8-bit、样本全在零点 ±2）来**掐断上一条语音**。语音资源落盘只按容器魔数
// 认音频，于是这段静音照样落盘、照样配给紧跟其后的那句旁白——宿主报 matched/game_resource，
// 制卡拿到一段听不见的 0.1 秒。判据按**内容**而不是名字：解析 fmt/data 块，取整段峰值
// （折算到 16-bit 标度，与位深/浮点无关），低于 kSilentPeak16 就是静音。
//
// 为什么用峰值不用均值：真人声句子里有停顿，整段均值会被拉低；静音文件的峰值只有量化抖动
// （8-bit 的 ±1~2 折算后 256~512）。阈值 1024 ≈ -30 dBFS，远低于任何能听清的配音。
// 解析不了的载荷（压缩 fmt、块残缺）一律判「不是静音」，交给下游照旧处理——这里只做减法。
#pragma once

#include <cstddef>
#include <cstdint>

#include "voice_clip_energy.h"

namespace fushi_voice_hook {

constexpr double kSilentPeak16 = 1024.0;

struct PcmWavView {
  const uint8_t* samples = nullptr;
  size_t bytes = 0;  // 只含完整样本帧
  uint32_t bits = 0;
  bool is_float = false;
};

inline uint32_t ReadLe32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

inline uint16_t ReadLe16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (p[1] << 8));
}

// 解析 RIFF/WAVE 的 PCM（1）/ IEEE float（3）/ EXTENSIBLE（0xFFFE，子格式取 GUID 首两字节）。
// data 块按文件里实际剩余字节截断。成功返回 true。
inline bool ParsePcmWav(const uint8_t* d, size_t len, PcmWavView* out) {
  if (d == nullptr || out == nullptr || len < 12) return false;
  if (!(d[0] == 'R' && d[1] == 'I' && d[2] == 'F' && d[3] == 'F' && d[8] == 'W' &&
        d[9] == 'A' && d[10] == 'V' && d[11] == 'E')) {
    return false;
  }
  bool have_fmt = false;
  uint16_t format = 0;
  uint16_t channels = 0;
  uint16_t bits = 0;
  size_t pos = 12;
  while (pos + 8 <= len) {
    const uint8_t* ck = d + pos;
    const uint32_t size = ReadLe32(ck + 4);
    const size_t body = pos + 8;
    const size_t avail = len - body;
    if (ck[0] == 'f' && ck[1] == 'm' && ck[2] == 't' && ck[3] == ' ') {
      if (size < 16 || avail < 16) return false;
      format = ReadLe16(d + body);
      channels = ReadLe16(d + body + 2);
      bits = ReadLe16(d + body + 14);
      if (format == 0xFFFE) {
        if (size < 40 || avail < 40) return false;
        format = ReadLe16(d + body + 24);  // SubFormat GUID 的前两字节就是格式标签
      }
      have_fmt = true;
    } else if (ck[0] == 'd' && ck[1] == 'a' && ck[2] == 't' && ck[3] == 'a') {
      if (!have_fmt || channels == 0) return false;
      if (format != 1 && format != 3) return false;
      const bool is_float = format == 3;
      if (is_float ? bits != 32 : (bits == 0 || bits % 8 != 0 || bits > 32)) return false;
      const size_t frame = static_cast<size_t>(channels) * (bits / 8);
      size_t bytes = size < avail ? size : avail;
      bytes -= bytes % frame;
      if (bytes == 0) return false;
      out->samples = d + body;
      out->bytes = bytes;
      out->bits = bits;
      out->is_float = is_float;
      return true;
    }
    if (size > avail) return false;
    pos = body + size + (size & 1u);  // 块按偶数字节对齐
  }
  return false;
}

// 整段峰值（16-bit 标度）。格式不支持返回 -1。
inline double PcmPeak16Scale(const PcmWavView& v) {
  if (!ClipEnergySupportsFormat(v.bits, v.is_float)) return -1.0;
  const size_t bps = v.bits / 8;
  double peak = 0.0;
  for (size_t off = 0; off + bps <= v.bytes; off += bps) {
    const double a = ClipSampleAbs16Scale(v.samples + off, v.bits, v.is_float);
    if (a > peak) peak = a;
  }
  return peak;
}

// 载荷是能解析的 PCM WAV 且整段峰值低于阈值。
inline bool IsSilentPcmWav(const uint8_t* d, size_t len) {
  PcmWavView v;
  if (!ParsePcmWav(d, len, &v)) return false;
  const double peak = PcmPeak16Scale(v);
  return peak >= 0.0 && peak < kSilentPeak16;
}

}  // namespace fushi_voice_hook
