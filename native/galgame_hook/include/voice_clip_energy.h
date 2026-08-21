#ifndef FUSHI_VOICE_CLIP_ENERGY_H_
#define FUSHI_VOICE_CLIP_ENERGY_H_

#include <cstddef>
#include <cstdint>
#include <cstring>

// 一条 `VoiceClip` 的平均绝对幅值，**归一到 16-bit 标度**（0..32767），与位深/浮点无关。
//
// 为什么必须与格式无关（BUG-1769）：
// 这个值是 `GrabUtterance` **选语音源**的唯一判据——同一时刻环里通常同时有语音源、BGM 源、
// 混音输出好几个 `source_ptr`，靠「文本时刻窗能量 - 说话前窗能量」最大者挑出「从静音跳到有
// 声」的那一个。旧实现 `ClipEnergy16` 只认 16-bit，遇到 float32 / 8 / 24 / 32-bit 一律返回
// -1，于是 `any_energy` 恒假、`filter_by_src` 退化成 false，拼接循环把窗口内**每一个源**的
// PCM 顺序 memcpy 进同一句。用户听到的就是「同一句念两遍、中间夹一段断续杂音」——即
// 「音频提取卡顿重复」。XAudio2 的默认输出格式就是 float32，所以任何走 XAudio2 的引擎
// （没有专属 resource_audio adapter 的游戏都会落到这条通用路径）必中。
//
// 同一处也修掉 BUG-1165 的老症状：非 16-bit 轨在捕获工作台里 `avg_energy` 恒为 -1，
// 手动选轨时没有任何强弱参考。
//
// 为什么在环形上就地扫、不先 memcpy 出来：
// `GrabUtterance` 全程持锁跑在 Flutter 平台线程上，收敛循环每行要调 ~24 次
// （`_settleLineUtterance` 250ms 一次、最长 6s），每次遍历最多 1024 条 clip。旧实现每条 clip
// 做「全量拷贝到新 vector + 全量扫描」，而且**选源与拼接各算一遍**；环上限 64MB 时单次调用
// 可达几百 MB 的拷贝与扫描，直接表现为宿主侧卡顿。这里改成零拷贝单遍扫描，跨环边界按两段
// 处理（外加至多一个跨界样本），调用方再把结果缓存复用，总工作量降一个量级。
namespace fushi_voice_hook {

// 单个样本的绝对幅值，折算到 16-bit 标度。[p] 必须指向 bits/8 个可读字节。
// 支持 PCM 8（无符号，128 为零点）/ 16 / 24 / 32-bit 整数与 32-bit 浮点；其余返回 -1。
inline double ClipSampleAbs16Scale(const uint8_t* p, uint32_t bits,
                                   bool is_float) {
  if (is_float) {
    if (bits != 32) {
      return -1.0;
    }
    float f = 0.0f;
    std::memcpy(&f, p, sizeof(f));
    const double a = (f < 0.0f) ? -static_cast<double>(f)
                                : static_cast<double>(f);
    return a * 32768.0;  // float 名义满刻度 ±1.0
  }
  switch (bits) {
    case 8: {
      // WAVE 的 8-bit PCM 是无符号，零点在 128。
      const int v = static_cast<int>(p[0]) - 128;
      return static_cast<double>(v < 0 ? -v : v) * 256.0;
    }
    case 16: {
      int16_t v = 0;
      std::memcpy(&v, p, sizeof(v));
      return (v < 0) ? -static_cast<double>(v) : static_cast<double>(v);
    }
    case 24: {
      // 小端 3 字节有符号：搬到 int32 高 24 位再算术右移做符号扩展。
      const uint32_t u = (static_cast<uint32_t>(p[2]) << 24) |
                         (static_cast<uint32_t>(p[1]) << 16) |
                         (static_cast<uint32_t>(p[0]) << 8);
      const int32_t v = static_cast<int32_t>(u) / 256;
      const double a = (v < 0) ? -static_cast<double>(v)
                               : static_cast<double>(v);
      return a / 256.0;
    }
    case 32: {
      int32_t v = 0;
      std::memcpy(&v, p, sizeof(v));
      const double a = (v < 0) ? -static_cast<double>(v)
                               : static_cast<double>(v);
      return a / 65536.0;
    }
    default:
      return -1.0;
  }
}

// 该位深/浮点组合是否算得出能量。选源判据是否可用**只取决于这个**，不再取决于
// 「是不是恰好 16-bit」。
inline bool ClipEnergySupportsFormat(uint32_t bits, bool is_float) {
  const uint8_t probe[8] = {0, 0, 0, 0, 0, 0, 0, 0};
  return ClipSampleAbs16Scale(probe, bits, is_float) >= 0.0;
}

// 一段**连续**字节里所有完整样本的绝对幅值之和，样本数累加进 [n]。
//
// 格式分派放在循环外：逐样本调 `ClipSampleAbs16Scale` 会挡住自动向量化，实测比旧的
// 「memcpy 出来 + int16 紧凑循环」还慢 19%（改起来本意是提速，基准直接打脸）。这里每种
// 格式各写一条紧凑循环，16-bit 那条与旧实现的内层完全同形，省掉的是那次 memcpy。
//
// 指针可能不按样本大小对齐（clip 在环里的起点是任意字节）。本文件只用于 Windows x86/x64，
// 非对齐标量读在这两个架构上合法且无额外代价；旧实现靠 memcpy 到对齐缓冲绕开这点，代价
// 就是那次全量拷贝。
inline double ClipSumAbs16ScaleRange(const uint8_t* p, size_t bytes,
                                     uint32_t bits, bool is_float, size_t* n) {
  double acc = 0.0;
  if (is_float) {
    const size_t count = bytes / 4;
    for (size_t i = 0; i < count; ++i) {
      float f;
      std::memcpy(&f, p + i * 4, sizeof(f));
      acc += (f < 0.0f) ? -static_cast<double>(f) : static_cast<double>(f);
    }
    *n += count;
    return acc * 32768.0;
  }
  switch (bits) {
    case 8: {
      for (size_t i = 0; i < bytes; ++i) {
        const int v = static_cast<int>(p[i]) - 128;
        acc += static_cast<double>(v < 0 ? -v : v);
      }
      *n += bytes;
      return acc * 256.0;
    }
    case 16: {
      const size_t count = bytes / 2;
      const int16_t* s = reinterpret_cast<const int16_t*>(p);
      for (size_t i = 0; i < count; ++i) {
        acc += (s[i] < 0) ? -static_cast<double>(s[i])
                          : static_cast<double>(s[i]);
      }
      *n += count;
      return acc;
    }
    case 24: {
      const size_t count = bytes / 3;
      for (size_t i = 0; i < count; ++i) {
        const uint8_t* q = p + i * 3;
        const uint32_t u = (static_cast<uint32_t>(q[2]) << 24) |
                           (static_cast<uint32_t>(q[1]) << 16) |
                           (static_cast<uint32_t>(q[0]) << 8);
        const int32_t v = static_cast<int32_t>(u) / 256;
        acc += (v < 0) ? -static_cast<double>(v) : static_cast<double>(v);
      }
      *n += count;
      return acc / 256.0;
    }
    case 32: {
      const size_t count = bytes / 4;
      const int32_t* s = reinterpret_cast<const int32_t*>(p);
      for (size_t i = 0; i < count; ++i) {
        acc += (s[i] < 0) ? -static_cast<double>(s[i])
                          : static_cast<double>(s[i]);
      }
      *n += count;
      return acc / 65536.0;
    }
    default:
      return 0.0;
  }
}

// 环形缓冲上就地计算平均绝对幅值（16-bit 标度）。
// [ring]/[cap] 是环基址与容量，[off] 是本段起始偏移（已 % cap），[len] 是本段字节数。
// 格式不支持或段为空返回 -1。调用方负责先判「该段是否已被环形覆盖」。
inline double ClipEnergy16Scale(const uint8_t* ring, uint32_t cap, uint32_t off,
                                uint32_t len, uint32_t bits, bool is_float) {
  if (ring == nullptr || cap == 0 || len == 0 || len > cap) {
    return -1.0;
  }
  if (bits == 0 || (bits % 8) != 0 || bits > 32) {
    return -1.0;
  }
  if (!ClipEnergySupportsFormat(bits, is_float)) {
    return -1.0;
  }
  const uint32_t bps = bits / 8;
  off %= cap;

  double acc = 0.0;
  size_t n = 0;
  // A 段：[off, off+first)，不跨环尾。
  const uint32_t first = (len <= cap - off) ? len : (cap - off);
  const uint32_t a_whole = (first / bps) * bps;
  acc += ClipSumAbs16ScaleRange(ring + off, a_whole, bits, is_float, &n);

  const uint32_t a_rem = first - a_whole;   // A 段尾部不足一个样本的零头
  const uint32_t b_len = len - first;       // B 段：从环首开始的剩余字节
  uint32_t b_start = 0;
  if (a_rem != 0) {
    if (a_rem + b_len >= bps) {
      // 恰好跨环边界的那一个样本：按字节拼起来单独算（整段里最多一个）。
      uint8_t straddle[4] = {0, 0, 0, 0};
      for (uint32_t k = 0; k < a_rem; ++k) {
        straddle[k] = ring[off + a_whole + k];
      }
      for (uint32_t k = 0; k < bps - a_rem; ++k) {
        straddle[a_rem + k] = ring[k];
      }
      acc += ClipSampleAbs16Scale(straddle, bits, is_float);
      ++n;
      b_start = bps - a_rem;
    } else {
      // 连一个完整样本都补不齐：这点零头丢掉（不足一帧，没有听感意义）。
      b_start = b_len;
    }
  }
  if (b_len > b_start) {
    const uint32_t b_whole = ((b_len - b_start) / bps) * bps;
    acc += ClipSumAbs16ScaleRange(ring + b_start, b_whole, bits, is_float, &n);
  }
  if (n == 0) {
    return -1.0;
  }
  return acc / static_cast<double>(n);
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_VOICE_CLIP_ENERGY_H_
