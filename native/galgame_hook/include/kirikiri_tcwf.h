#pragma once

// KiriKiri2 TCWF 语音（`.tcw`，wutcwf.dll 解码）的纯解析 / 解码。
//
// 纯函数、零分配：调用方（HookWorker）按 TcwfWavBytes() 分配输出区。引擎线程上的取流
// detour 只允许调 LooksLikeTcwf()——固定 6 字节的常量时间检查——其余全部在 worker 上跑。
//
// 布局（W.Dee 的 TCWF0.a；Fate/stay night[Realta Nua] voice.xp3 的 11998 条成员全是它）：
//   0x00 "TCWF0\x1a"   0x06 u8 channels   0x07 u8 reserved
//   0x08 i32 frequency 0x0c i32 numblocks 0x10 i32 bytesperblock 0x14 i32 samplesperblock
// 之后是 numblocks 组块，每组 channels 个块，依次落到输出声道 0、1，块 = 32 字节块头 +
// (bytesperblock - 32) 字节码流：
//   i16 ms_sample0  i16 ms_sample1  i16 ms_idelta  u8 ms_bpred  u8 ima_stepindex
//   6 × { u16 pos, i16 revise }（「意外峰值」修正）
// 每字节低 4 位是 MS ADPCM 码（还原主信号），高 4 位是 IMA ADPCM 码（还原主信号的误差，
// 从 0 起累积后叠加），最后把记录在块头里的峰值位置减去 revise。两种 ADPCM 的表都是公开
// 标准表。块的前两个样本由块头直接给出、码流从第 3 个样本起。
//
// 文件末尾不足一组块的残余直接丢弃（与 wutcwf 同：读不满一块就结束）。

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook {
namespace tcwf {

constexpr size_t kHeaderBytes = 24;
constexpr size_t kBlockHeaderBytes = 32;
constexpr size_t kWavHeaderBytes = 44;
// 上界防御：真实文件是单 / 双声道、每块 1024 样本上下；超出即视为不是 TCWF。
constexpr uint32_t kMaxChannels = 2;
constexpr int32_t kMaxSamplesPerBlock = 8192;

struct Header {
  uint32_t channels = 0;
  uint32_t frequency = 0;
  uint32_t blocks = 0;          // 完整可解的块组数（按实际字节数截断）
  uint32_t bytes_per_block = 0;
  uint32_t samples_per_block = 0;
};

inline int32_t ReadLe32(const uint8_t* p) {
  return static_cast<int32_t>(static_cast<uint32_t>(p[0]) |
                              (static_cast<uint32_t>(p[1]) << 8) |
                              (static_cast<uint32_t>(p[2]) << 16) |
                              (static_cast<uint32_t>(p[3]) << 24));
}

inline int16_t ReadLe16(const uint8_t* p) {
  return static_cast<int16_t>(static_cast<uint16_t>(p[0]) |
                              (static_cast<uint16_t>(p[1]) << 8));
}

// 常量时间魔数检查，引擎线程可调。
inline bool LooksLikeTcwf(const uint8_t* data, size_t len) {
  return data != nullptr && len >= kHeaderBytes &&
         std::memcmp(data, "TCWF0\x1a", 6) == 0;
}

// 校验头并按实际字节数求出可解块组数。任何字段越出真实格式的范围都整体拒绝。
inline bool ParseHeader(const uint8_t* data, size_t len, Header* out) {
  if (!LooksLikeTcwf(data, len) || out == nullptr) return false;
  const uint32_t channels = data[6];
  const int32_t frequency = ReadLe32(data + 8);
  const int32_t blocks = ReadLe32(data + 12);
  const int32_t bytes_per_block = ReadLe32(data + 16);
  const int32_t samples_per_block = ReadLe32(data + 20);
  if (channels == 0 || channels > kMaxChannels) return false;
  if (frequency <= 0 || frequency > 192000) return false;
  if (blocks <= 0) return false;
  if (samples_per_block < 2 || samples_per_block > kMaxSamplesPerBlock) {
    return false;
  }
  // 码流每字节一个样本（低 / 高半字节是同一样本的两层），从第 3 个样本起。
  const int64_t code_bytes = static_cast<int64_t>(samples_per_block) - 2;
  if (bytes_per_block < static_cast<int32_t>(kBlockHeaderBytes) ||
      bytes_per_block - static_cast<int64_t>(kBlockHeaderBytes) < code_bytes) {
    return false;
  }
  const uint64_t group_bytes =
      static_cast<uint64_t>(bytes_per_block) * channels;
  const uint64_t available = (len - kHeaderBytes) / group_bytes;
  const uint64_t usable =
      available < static_cast<uint64_t>(blocks) ? available
                                                : static_cast<uint64_t>(blocks);
  if (usable == 0) return false;
  out->channels = channels;
  out->frequency = static_cast<uint32_t>(frequency);
  out->blocks = static_cast<uint32_t>(usable);
  out->bytes_per_block = static_cast<uint32_t>(bytes_per_block);
  out->samples_per_block = static_cast<uint32_t>(samples_per_block);
  return true;
}

inline uint32_t PcmBytes(const Header& h) {
  return h.blocks * h.samples_per_block * h.channels * 2u;
}

// 完整 WAV（PCM 16-bit）所需字节数；h 必须已通过 ParseHeader。
inline size_t WavBytes(const Header& h) {
  return kWavHeaderBytes + PcmBytes(h);
}

inline int16_t Clamp16(int32_t v) {
  if (v > 32767) return 32767;
  if (v < -32768) return -32768;
  return static_cast<int16_t>(v);
}

// 解一个声道块，样本按 stride 交错写入 out（out 指向该声道第一个样本）。
inline bool DecodeBlock(const uint8_t* block, const Header& h, int16_t* out,
                        uint32_t stride) {
  static const int32_t kAdaptation[16] = {230, 230, 230, 230, 307, 409,
                                          512, 614, 768, 614, 512, 409,
                                          307, 230, 230, 230};
  static const int32_t kCoeff1[7] = {256, 512, 0, 192, 240, 460, 392};
  static const int32_t kCoeff2[7] = {0, -256, 0, 64, 0, -208, -232};
  static const int32_t kImaIndexAdjust[16] = {-1, -1, -1, -1, 2, 4, 6, 8,
                                              -1, -1, -1, -1, 2, 4, 6, 8};
  static const int32_t kImaStep[89] = {
      7,     8,     9,     10,    11,    12,    13,    14,    16,    17,
      19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
      50,    55,    60,    66,    73,    80,    88,    97,    107,   118,
      130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
      337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
      876,   963,   1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
      2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,
      5894,  6484,  7132,  7845,  8630,  9493,  10442, 11487, 12635, 13899,
      15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767};

  const uint32_t bpred = block[6];
  int32_t step_index = block[7];
  // bpred 越界意味着失步（块边界没对上）：整条拒绝，不输出噪声。
  if (bpred >= 7 || step_index > 88) return false;
  const uint8_t* codes = block + kBlockHeaderBytes;
  const uint32_t n = h.samples_per_block;

  // 第一层：MS ADPCM 还原主信号。
  out[0] = ReadLe16(block + 0);
  out[stride] = ReadLe16(block + 2);
  int32_t idelta = ReadLe16(block + 4);
  for (uint32_t k = 2; k < n; ++k) {
    int32_t code = codes[k - 2] & 0x0F;
    const int32_t delta = idelta;
    idelta = (kAdaptation[code] * idelta) >> 8;
    if (idelta < 16) idelta = 16;
    if (code & 0x8) code -= 0x10;
    const int32_t predict = (out[(k - 1) * stride] * kCoeff1[bpred] +
                             out[(k - 2) * stride] * kCoeff2[bpred]) >> 8;
    out[k * stride] = Clamp16(code * delta + predict);
  }

  // 第二层：IMA ADPCM 还原第一层的误差，从 0 起累积后叠加。
  int32_t residual = 0;
  for (uint32_t k = 2; k < n; ++k) {
    const int32_t code = (codes[k - 2] >> 4) & 0x0F;
    const int32_t step = kImaStep[step_index];
    int32_t diff = step >> 3;
    if (code & 1) diff += step >> 2;
    if (code & 2) diff += step >> 1;
    if (code & 4) diff += step;
    if (code & 8) diff = -diff;
    residual = Clamp16(residual + diff);
    step_index += kImaIndexAdjust[code];
    if (step_index < 0) step_index = 0;
    if (step_index > 88) step_index = 88;
    out[k * stride] = Clamp16(out[k * stride] + residual);
  }

  // 第三层：编码器记下的残余尖峰。
  for (uint32_t i = 0; i < 6; ++i) {
    const uint8_t* peak = block + 8 + i * 4;
    const int32_t revise = ReadLe16(peak + 2);
    if (revise == 0) continue;
    const uint32_t pos = static_cast<uint16_t>(peak[0] | (peak[1] << 8));
    if (pos >= n) return false;
    out[pos * stride] = Clamp16(out[pos * stride] - revise);
  }
  return true;
}

inline void PutLe16(uint8_t* at, uint16_t value) {
  at[0] = static_cast<uint8_t>(value);
  at[1] = static_cast<uint8_t>(value >> 8);
}

inline void PutLe32(uint8_t* at, uint32_t value) {
  for (int i = 0; i < 4; ++i) at[i] = static_cast<uint8_t>(value >> (8 * i));
}

inline void WriteWavHeader(const Header& h, uint8_t* out) {
  const uint32_t data_bytes = PcmBytes(h);
  const uint16_t block_align = static_cast<uint16_t>(h.channels * 2u);
  std::memcpy(out, "RIFF", 4);
  PutLe32(out + 4, 36u + data_bytes);
  std::memcpy(out + 8, "WAVE", 4);
  std::memcpy(out + 12, "fmt ", 4);
  PutLe32(out + 16, 16u);
  PutLe16(out + 20, 1u);
  PutLe16(out + 22, static_cast<uint16_t>(h.channels));
  PutLe32(out + 24, h.frequency);
  PutLe32(out + 28, h.frequency * block_align);
  PutLe16(out + 32, block_align);
  PutLe16(out + 34, 16u);
  std::memcpy(out + 36, "data", 4);
  PutLe32(out + 40, data_bytes);
}

// TCWF → 完整 WAV。out 至少 WavBytes(h) 字节（调用方先 ParseHeader 求出）。任何块失步都
// 整体失败，不输出半截音频。
inline bool DecodeToWav(const uint8_t* data, size_t len, const Header& h,
                        uint8_t* out, size_t out_bytes) {
  if (data == nullptr || out == nullptr || out_bytes < WavBytes(h)) {
    return false;
  }
  const uint64_t need = kHeaderBytes + static_cast<uint64_t>(h.blocks) *
                                           h.bytes_per_block * h.channels;
  if (need > len) return false;
  WriteWavHeader(h, out);
  int16_t group[kMaxSamplesPerBlock * kMaxChannels];
  const size_t group_bytes =
      static_cast<size_t>(h.samples_per_block) * h.channels * 2u;
  uint8_t* pcm = out + kWavHeaderBytes;
  const uint8_t* block = data + kHeaderBytes;
  for (uint32_t b = 0; b < h.blocks; ++b) {
    for (uint32_t c = 0; c < h.channels; ++c) {
      if (!DecodeBlock(block, h, group + c, h.channels)) return false;
      block += h.bytes_per_block;
    }
    // 小端主机上 WAV 的 16-bit PCM 字节序与内存一致；memcpy 避免对齐假设。
    std::memcpy(pcm, group, group_bytes);
    pcm += group_bytes;
  }
  return true;
}

}  // namespace tcwf
}  // namespace fushi_voice_hook
