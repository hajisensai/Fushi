#ifndef FUSHI_VOICE_HOOK_XWMA_RESOURCE_H_
#define FUSHI_VOICE_HOOK_XWMA_RESOURCE_H_

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

#include "xaudio_source_format.h"

namespace fushi_voice_hook {

inline void AppendXwmaU16(std::vector<uint8_t>* output, uint16_t value) {
  output->push_back(static_cast<uint8_t>(value));
  output->push_back(static_cast<uint8_t>(value >> 8));
}

inline void AppendXwmaU32(std::vector<uint8_t>* output, uint32_t value) {
  output->push_back(static_cast<uint8_t>(value));
  output->push_back(static_cast<uint8_t>(value >> 8));
  output->push_back(static_cast<uint8_t>(value >> 16));
  output->push_back(static_cast<uint8_t>(value >> 24));
}

inline void AppendXwmaFourCc(std::vector<uint8_t>* output,
                             const char value[4]) {
  output->insert(output->end(), value, value + 4);
}

// Rebuild only the RIFF envelope while preserving an engine adapter's exact
// `fmt`, `dpds`, and compressed payload bytes. Using the proved source chunks
// verbatim is stronger than synthesizing metadata from normalized XAudio2 data.
inline bool BuildXwmaResourceFromChunks(
    const uint8_t* fmt, uint32_t fmt_bytes, const uint8_t* dpds,
    uint32_t dpds_bytes, const uint8_t* encoded, uint32_t encoded_bytes,
    std::vector<uint8_t>* output) {
  if (output == nullptr || fmt == nullptr || fmt_bytes == 0 ||
      dpds == nullptr || dpds_bytes == 0 || encoded == nullptr ||
      encoded_bytes == 0) {
    return false;
  }
  const uint64_t fmt_padded =
      static_cast<uint64_t>(fmt_bytes) + (fmt_bytes & 1u);
  const uint64_t dpds_padded =
      static_cast<uint64_t>(dpds_bytes) + (dpds_bytes & 1u);
  const uint64_t data_padded =
      static_cast<uint64_t>(encoded_bytes) + (encoded_bytes & 1u);
  const uint64_t riff_payload = 4u + 8u + fmt_padded + 8u + dpds_padded +
                                8u + data_padded;
  const uint64_t file_bytes = 8u + riff_payload;
  if (riff_payload > std::numeric_limits<uint32_t>::max() ||
      file_bytes > std::numeric_limits<size_t>::max()) {
    return false;
  }

  output->clear();
  output->reserve(static_cast<size_t>(file_bytes));
  AppendXwmaFourCc(output, "RIFF");
  AppendXwmaU32(output, static_cast<uint32_t>(riff_payload));
  AppendXwmaFourCc(output, "XWMA");
  AppendXwmaFourCc(output, "fmt ");
  AppendXwmaU32(output, fmt_bytes);
  output->insert(output->end(), fmt, fmt + fmt_bytes);
  if ((fmt_bytes & 1u) != 0) output->push_back(0);
  AppendXwmaFourCc(output, "dpds");
  AppendXwmaU32(output, dpds_bytes);
  output->insert(output->end(), dpds, dpds + dpds_bytes);
  if ((dpds_bytes & 1u) != 0) output->push_back(0);
  AppendXwmaFourCc(output, "data");
  AppendXwmaU32(output, encoded_bytes);
  output->insert(output->end(), encoded, encoded + encoded_bytes);
  if ((encoded_bytes & 1u) != 0) output->push_back(0);
  return output->size() == file_bytes;
}

// Restore the standard RIFF/XWMA wrapper around the exact compressed bytes
// supplied to SubmitSourceBuffer. Microsoft defines XAUDIO2_BUFFER_WMA as the
// verbatim UINT32 table from the resource's `dpds` chunk, so neither audio nor
// packet metadata is decoded or re-encoded here.
inline bool BuildXwmaResource(
    const XAudioSourceFormat& format, const uint8_t* encoded,
    uint32_t encoded_bytes, const uint8_t* decoded_packet_cumulative_bytes,
    uint32_t packet_count, std::vector<uint8_t>* output) {
  if (output == nullptr || encoded == nullptr || encoded_bytes == 0 ||
      decoded_packet_cumulative_bytes == nullptr || packet_count == 0 ||
      format.encoding != XAudioSourceEncoding::kWmaudio2 ||
      format.sample_rate == 0 || format.channels == 0 ||
      format.block_align == 0 || format.avg_bytes_per_second == 0) {
    return false;
  }
  constexpr uint32_t kFmtBytes = 18;
  uint8_t fmt[kFmtBytes] = {};
  std::vector<uint8_t> fmt_builder;
  fmt_builder.reserve(kFmtBytes);
  AppendXwmaU16(&fmt_builder, WAVE_FORMAT_WMAUDIO2);
  AppendXwmaU16(&fmt_builder, static_cast<uint16_t>(format.channels));
  AppendXwmaU32(&fmt_builder, format.sample_rate);
  AppendXwmaU32(&fmt_builder, format.avg_bytes_per_second);
  AppendXwmaU16(&fmt_builder, static_cast<uint16_t>(format.block_align));
  AppendXwmaU16(&fmt_builder, static_cast<uint16_t>(format.bits_per_sample));
  AppendXwmaU16(&fmt_builder, 0);
  std::memcpy(fmt, fmt_builder.data(), kFmtBytes);

  const uint64_t dpds_bytes64 = static_cast<uint64_t>(packet_count) * 4u;
  if (dpds_bytes64 > std::numeric_limits<uint32_t>::max()) return false;
  const uint32_t dpds_bytes = static_cast<uint32_t>(dpds_bytes64);
  std::vector<uint8_t> dpds;
  dpds.reserve(dpds_bytes);
  for (uint32_t i = 0; i < packet_count; ++i) {
    uint32_t cumulative = 0;
    std::memcpy(&cumulative, decoded_packet_cumulative_bytes + i * 4u,
                sizeof(cumulative));
    AppendXwmaU32(&dpds, cumulative);
  }
  return BuildXwmaResourceFromChunks(fmt, kFmtBytes, dpds.data(), dpds_bytes,
                                     encoded, encoded_bytes, output);
}

// 时长判据：这次 xWMA 提交解码后是否长到像一句台词（>=700ms）。
//
// 这**不是**角色身份证明，只是一道便宜的预筛。没有引擎归档可用时，通用路径靠它把
// 逐块流入的 BGM/SE 挡在资源发布之外——否则每一小块 BGM 都会落成一个资源文件，既
// 撑爆 dump 目录，也会在按时间戳配对时和真语音抢。
inline bool IsLikelyVoiceWmaSubmission(const XAudioSourceFormat& format,
                                       uint32_t packet_count,
                                       uint32_t decoded_bytes) {
  // WAVEFORMATEX 对 WMAUDIO2 通常填 wBitsPerSample=16，但不是所有引擎都填。填 0 时
  // 直接算会让 bytes_per_second 恒为 0、判据恒假 —— 那是一条**静默丢弃**路径，比
  // 判错更糟。WMA 解码输出按定义是 16-bit PCM，所以缺值时按 16 算，而不是放弃。
  const uint32_t bits =
      format.bits_per_sample != 0 ? format.bits_per_sample : 16u;
  const uint64_t bytes_per_second =
      static_cast<uint64_t>(format.sample_rate) * format.channels * bits / 8u;
  return format.encoding == XAudioSourceEncoding::kWmaudio2 &&
         packet_count != 0 && decoded_bytes != 0 && bytes_per_second != 0 &&
         static_cast<uint64_t>(decoded_bytes) * 1000u >=
             bytes_per_second * 700u;
}
}  // namespace fushi_voice_hook

#endif  // FUSHI_VOICE_HOOK_XWMA_RESOURCE_H_
