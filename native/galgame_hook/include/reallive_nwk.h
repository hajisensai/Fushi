#pragma once

// RealLive 语音容器 NWK（koe/z####.nwk）与其成员 NWA 的纯解析 / 解码。
//
// 纯函数、零分配：调用方（HookWorker）自己按本文件给的上界分配缓冲区，本文件只读入参、
// 只写调用方给的输出区。游戏线程上的 ReadFile 回调只允许调 LooksLikeNwaHeaderPrefix()
// ——固定 16 字节的常量时间检查——其余全部在 worker 上跑。
//
// NWK 布局（与 xclannad / rlvm 的 koe 读取一致，并在 planetarian Kinetic Novel 版
// z0001.nwk / z0002.nwk 上实测：索引项偏移单调、首项紧跟索引表、各项首尾相接）：
//   u32 count
//   count × { u32 byte_len, u32 absolute_offset, u32 voice_id }
// 每个成员是一条完整 NWA 流。
//
// NWA 布局（VisualArt's 无损差分压缩，参考 xclannad nwatowav.cc）：
//   0x00 u16 channels   0x02 u16 bits_per_sample   0x04 u32 sample_rate
//   0x08 i32 complevel（-1 = 未压缩 PCM；0..5 = 压缩等级）
//   0x0c i32 use_runlength   0x10 i32 blocks   0x14 i32 data_bytes（解码后字节数）
//   0x18 i32 compressed_bytes（整条 NWA 的字节数）   0x1c i32 sample_count（全声道样本数）
//   0x20 i32 block_samples   0x24 i32 last_block_samples   0x28 i32 reserved
//   0x2c 起 blocks × i32 块偏移（相对 NWA 起点）；每块 = 各声道一个原样 16-bit 起始样本
//   + LSB-first 比特流差分。
//
// 只支持 16-bit：8-bit NWA 的样本符号约定没有实测样本可证，宁可拒绝也不输出可能反相/
// 偏置的波形。

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook::reallive {

constexpr uint32_t kNwkEntryBytes = 12u;
// 实测 z0001.nwk 754 项；上界兜住损坏索引诱导的大分配（1.2 MB 索引）。
constexpr uint32_t kMaxNwkEntryCount = 100000u;
constexpr uint32_t kNwaHeaderBytes = 0x2cu;
// 单条语音压缩体上界（实测最大 0.66 MB）。
constexpr uint32_t kMaxNwaEntryBytes = 32u * 1024u * 1024u;
// 解码后 PCM 上界：64 MiB ≈ 44.1 kHz 立体声 6 分钟，远超任何一句台词。
constexpr uint32_t kMaxNwaDecodedBytes = 64u * 1024u * 1024u;
constexpr uint32_t kMaxNwaBlocks = 1000000u;
constexpr uint32_t kWavHeaderBytes = 44u;

struct NwkEntry {
  uint32_t byte_len = 0;
  uint32_t offset = 0;
  uint32_t voice_id = 0;
};

struct NwaHeader {
  uint16_t channels = 0;
  uint16_t bits_per_sample = 0;
  uint32_t sample_rate = 0;
  int32_t complevel = 0;
  bool use_runlength = false;
  uint32_t blocks = 0;
  uint32_t data_bytes = 0;
  uint32_t compressed_bytes = 0;
  uint32_t sample_count = 0;
  uint32_t block_samples = 0;
  uint32_t last_block_samples = 0;
};

inline uint32_t NwkReadLe32(const uint8_t* data) {
  uint32_t value = 0;
  std::memcpy(&value, data, sizeof(value));
  return value;
}

inline uint16_t NwkReadLe16(const uint8_t* data) {
  return static_cast<uint16_t>(data[0] | (static_cast<uint16_t>(data[1]) << 8));
}

// 游戏线程 ReadFile 回调里用的常量时间门：返回 buffer 前 16 字节像不像一个 NWA 头。
// 只用来决定「值不值得投一个固定大小任务」，不是资源证明——worker 仍要按索引精确
// 对上 entry 起点并完整解码。
inline bool LooksLikeNwaHeaderPrefix(const uint8_t* data, size_t bytes) {
  if (data == nullptr || bytes < 16) return false;
  const uint16_t channels = NwkReadLe16(data);
  const uint16_t bits = NwkReadLe16(data + 2);
  const uint32_t rate = NwkReadLe32(data + 4);
  const int32_t complevel = static_cast<int32_t>(NwkReadLe32(data + 8));
  const uint32_t runlength = NwkReadLe32(data + 12);
  return (channels == 1 || channels == 2) && bits == 16 && rate >= 4000 &&
         rate <= 192000 && complevel >= -1 && complevel <= 5 && runlength <= 1;
}

// 在索引里找起点恰为 wanted_offset 的项，并校验**整张**索引的自洽性（count 上界、每项
// 落在文件内且不压住索引表）。任何一项越界都判整个归档不可信。
inline bool FindNwkEntryAtOffset(const uint8_t* index, size_t index_bytes,
                                 uint64_t file_bytes, uint64_t wanted_offset,
                                 NwkEntry* out) {
  if (index == nullptr || out == nullptr || index_bytes < sizeof(uint32_t)) {
    return false;
  }
  const uint32_t count = NwkReadLe32(index);
  if (count == 0 || count > kMaxNwkEntryCount) return false;
  const uint64_t table_bytes =
      sizeof(uint32_t) + static_cast<uint64_t>(count) * kNwkEntryBytes;
  if (table_bytes > index_bytes || table_bytes > file_bytes) return false;
  bool found = false;
  NwkEntry hit;
  for (uint32_t i = 0; i < count; ++i) {
    const uint8_t* row =
        index + sizeof(uint32_t) + static_cast<size_t>(i) * kNwkEntryBytes;
    NwkEntry entry;
    entry.byte_len = NwkReadLe32(row);
    entry.offset = NwkReadLe32(row + 4);
    entry.voice_id = NwkReadLe32(row + 8);
    const uint64_t end = static_cast<uint64_t>(entry.offset) + entry.byte_len;
    if (entry.byte_len < kNwaHeaderBytes || entry.byte_len > kMaxNwaEntryBytes ||
        entry.offset < table_bytes || end > file_bytes) {
      return false;
    }
    if (!found && entry.offset == wanted_offset) {
      hit = entry;
      found = true;
    }
  }
  if (found) *out = hit;
  return found;
}

// 解析并校验 NWA 头与块偏移表（压缩时）。nwa 是整条成员字节。
inline bool ParseNwaHeader(const uint8_t* nwa, size_t bytes, NwaHeader* out) {
  if (nwa == nullptr || out == nullptr || bytes < kNwaHeaderBytes ||
      bytes > kMaxNwaEntryBytes) {
    return false;
  }
  NwaHeader h;
  h.channels = NwkReadLe16(nwa);
  h.bits_per_sample = NwkReadLe16(nwa + 2);
  h.sample_rate = NwkReadLe32(nwa + 4);
  h.complevel = static_cast<int32_t>(NwkReadLe32(nwa + 8));
  const uint32_t runlength = NwkReadLe32(nwa + 12);
  h.blocks = NwkReadLe32(nwa + 16);
  h.data_bytes = NwkReadLe32(nwa + 20);
  h.compressed_bytes = NwkReadLe32(nwa + 24);
  h.sample_count = NwkReadLe32(nwa + 28);
  h.block_samples = NwkReadLe32(nwa + 32);
  h.last_block_samples = NwkReadLe32(nwa + 36);
  if ((h.channels != 1 && h.channels != 2) || h.bits_per_sample != 16 ||
      h.sample_rate < 4000 || h.sample_rate > 192000 || h.complevel < -1 ||
      h.complevel > 5 || runlength > 1) {
    return false;
  }
  h.use_runlength = runlength != 0;
  const uint32_t frame_bytes = static_cast<uint32_t>(h.channels) * 2u;
  if (h.data_bytes == 0 || h.data_bytes > kMaxNwaDecodedBytes ||
      h.data_bytes % frame_bytes != 0) {
    return false;
  }
  if (h.complevel == -1) {
    // 未压缩：data_bytes 字节 PCM 紧跟 44 字节头。其余块字段在该形态下没有约束力。
    if (h.data_bytes > bytes - kNwaHeaderBytes) return false;
    h.sample_count = h.data_bytes / 2u;
    *out = h;
    return true;
  }
  if (h.blocks == 0 || h.blocks > kMaxNwaBlocks || h.block_samples == 0 ||
      h.block_samples % h.channels != 0 || h.last_block_samples == 0 ||
      h.last_block_samples > h.block_samples ||
      h.last_block_samples % h.channels != 0 ||
      h.compressed_bytes > bytes || h.compressed_bytes < kNwaHeaderBytes) {
    return false;
  }
  const uint64_t expected_samples =
      static_cast<uint64_t>(h.blocks - 1u) * h.block_samples +
      h.last_block_samples;
  if (expected_samples != h.sample_count ||
      static_cast<uint64_t>(h.sample_count) * 2u != h.data_bytes) {
    return false;
  }
  const uint64_t table_end =
      kNwaHeaderBytes + static_cast<uint64_t>(h.blocks) * 4u;
  if (table_end > h.compressed_bytes) return false;
  uint32_t previous = 0;
  for (uint32_t i = 0; i < h.blocks; ++i) {
    const uint32_t offset = NwkReadLe32(nwa + kNwaHeaderBytes + i * 4u);
    // 每块至少带各声道一个 16-bit 起始样本，且块偏移单调、不压住偏移表。
    if (offset < table_end || (i > 0 && offset < previous) ||
        static_cast<uint64_t>(offset) + frame_bytes > h.compressed_bytes) {
      return false;
    }
    previous = offset;
  }
  *out = h;
  return true;
}

// LSB-first 比特流读取器，越界读零并记录溢出（溢出即判块损坏）。
class NwaBitReader {
 public:
  NwaBitReader(const uint8_t* data, size_t bytes) : data_(data), bytes_(bytes) {}
  uint32_t Read(uint32_t bits) {
    uint32_t value = 0;
    for (uint32_t i = 0; i < bits; ++i) {
      const uint64_t at = position_ + i;
      const size_t byte = static_cast<size_t>(at >> 3);
      if (byte >= bytes_) {
        overrun_ = true;
        continue;
      }
      value |= static_cast<uint32_t>((data_[byte] >> (at & 7u)) & 1u) << i;
    }
    position_ += bits;
    return value;
  }
  bool overrun() const { return overrun_; }

 private:
  const uint8_t* data_;
  size_t bytes_;
  uint64_t position_ = 0;
  bool overrun_ = false;
};

// 解一块：block 指向块首（各声道起始样本 + 比特流），输出 samples 个 16-bit 交织样本。
inline bool DecodeNwaBlock(const uint8_t* block, size_t block_bytes,
                           const NwaHeader& h, uint32_t samples,
                           int16_t* out) {
  const uint32_t channels = h.channels;
  if (block_bytes < channels * 2u || samples == 0) return false;
  int32_t d[2] = {0, 0};
  for (uint32_t c = 0; c < channels; ++c) {
    d[c] = static_cast<int16_t>(NwkReadLe16(block + c * 2u));
  }
  NwaBitReader bits(block + channels * 2u, block_bytes - channels * 2u);
  const int32_t level = h.complevel;
  uint32_t flip = 0;
  uint32_t runlength = 0;
  for (uint32_t i = 0; i < samples; ++i) {
    if (runlength == 0) {
      const uint32_t type = bits.Read(3);
      if (type == 7) {
        if (bits.Read(1) == 1) {
          d[flip] = 0;
        } else {
          const uint32_t width = level >= 3 ? 8u : static_cast<uint32_t>(8 - level);
          const uint32_t shift = level >= 3 ? 9u : static_cast<uint32_t>(9 + level);
          const uint32_t sign = 1u << (width - 1u);
          const uint32_t value = bits.Read(width);
          const int32_t delta = static_cast<int32_t>((value & (sign - 1u)) << shift);
          d[flip] += (value & sign) != 0 ? -delta : delta;
        }
      } else if (type != 0) {
        const uint32_t width = level >= 3 ? static_cast<uint32_t>(level + 3)
                                          : static_cast<uint32_t>(5 - level);
        const uint32_t shift = level >= 3 ? 1u + type
                                          : static_cast<uint32_t>(2 + level) + type;
        const uint32_t sign = 1u << (width - 1u);
        const uint32_t value = bits.Read(width);
        const int32_t delta = static_cast<int32_t>((value & (sign - 1u)) << shift);
        d[flip] += (value & sign) != 0 ? -delta : delta;
      } else if (h.use_runlength) {
        runlength = bits.Read(1);
        if (runlength == 1) {
          runlength = bits.Read(2);
          if (runlength == 3) runlength = bits.Read(8);
        }
      }
    } else {
      --runlength;
    }
    // 与参考实现一致按 16 位截断写出。
    out[i] = static_cast<int16_t>(static_cast<uint16_t>(d[flip] & 0xffff));
    if (channels == 2) flip ^= 1u;
  }
  return !bits.overrun();
}

inline void PutWavLe16(uint8_t* at, uint16_t value) {
  at[0] = static_cast<uint8_t>(value);
  at[1] = static_cast<uint8_t>(value >> 8);
}

inline void PutWavLe32(uint8_t* at, uint32_t value) {
  for (int i = 0; i < 4; ++i) at[i] = static_cast<uint8_t>(value >> (8 * i));
}

// 完整 WAV（PCM 16-bit）所需字节数；h 必须已通过 ParseNwaHeader。
inline size_t NwaWavBytes(const NwaHeader& h) {
  return static_cast<size_t>(kWavHeaderBytes) + h.data_bytes;
}

inline void WriteWavHeader(const NwaHeader& h, uint8_t* out) {
  const uint16_t block_align = static_cast<uint16_t>(h.channels * 2u);
  std::memcpy(out, "RIFF", 4);
  PutWavLe32(out + 4, 36u + h.data_bytes);
  std::memcpy(out + 8, "WAVE", 4);
  std::memcpy(out + 12, "fmt ", 4);
  PutWavLe32(out + 16, 16u);
  PutWavLe16(out + 20, 1u);
  PutWavLe16(out + 22, h.channels);
  PutWavLe32(out + 24, h.sample_rate);
  PutWavLe32(out + 28, h.sample_rate * block_align);
  PutWavLe16(out + 32, block_align);
  PutWavLe16(out + 34, 16u);
  std::memcpy(out + 36, "data", 4);
  PutWavLe32(out + 40, h.data_bytes);
}

// NWA → 完整 WAV。out 至少 NwaWavBytes(h) 字节（调用方先 ParseNwaHeader 求出）。
// 任何块越界 / 比特流溢出都整体失败，不输出半截音频。
inline bool DecodeNwaToWav(const uint8_t* nwa, size_t bytes, const NwaHeader& h,
                           uint8_t* out, size_t out_bytes) {
  if (nwa == nullptr || out == nullptr || out_bytes < NwaWavBytes(h)) {
    return false;
  }
  WriteWavHeader(h, out);
  uint8_t* pcm_bytes = out + kWavHeaderBytes;
  if (h.complevel == -1) {
    // 小端主机上 WAV 与 NWA 的 16-bit PCM 字节序一致，原样复制。
    std::memcpy(pcm_bytes, nwa + kNwaHeaderBytes, h.data_bytes);
    return true;
  }
  // 输出区按字节给出，逐样本以 memcpy 写回避免对齐假设。
  int16_t scratch[512];
  uint32_t produced = 0;
  for (uint32_t b = 0; b < h.blocks; ++b) {
    const uint32_t start = NwkReadLe32(nwa + kNwaHeaderBytes + b * 4u);
    const uint32_t end =
        b + 1 < h.blocks ? NwkReadLe32(nwa + kNwaHeaderBytes + (b + 1) * 4u)
                         : h.compressed_bytes;
    const uint32_t samples =
        b + 1 < h.blocks ? h.block_samples : h.last_block_samples;
    if (end < start || end > h.compressed_bytes ||
        static_cast<uint64_t>(produced) + samples > h.sample_count) {
      return false;
    }
    // 大块分段解会破坏差分状态，所以块样本数超过栈暂存时直接写入输出区。
    if (samples <= sizeof(scratch) / sizeof(scratch[0])) {
      if (!DecodeNwaBlock(nwa + start, end - start, h, samples, scratch)) {
        return false;
      }
      std::memcpy(pcm_bytes + static_cast<size_t>(produced) * 2u, scratch,
                  static_cast<size_t>(samples) * 2u);
    } else {
      // 输出区来自 malloc（对齐足够），且 WAV 头 44 字节保持 2 字节对齐。
      int16_t* direct = reinterpret_cast<int16_t*>(
          pcm_bytes + static_cast<size_t>(produced) * 2u);
      if (!DecodeNwaBlock(nwa + start, end - start, h, samples, direct)) {
        return false;
      }
    }
    produced += samples;
  }
  return produced == h.sample_count;
}

}  // namespace fushi_voice_hook::reallive
