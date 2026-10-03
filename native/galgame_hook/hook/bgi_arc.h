#pragma once

// BGI / Ethornell 归档与 `bw` 音频头的纯解析层（无 Windows 依赖，可单测）。
//
// 两代归档并列支持，字段均按真实样本逐字节核对过：
//
//   PackFile（旧，2011 年前后，如 Ethornell 1.519.x）
//     +0  "PackFile    "（12 字节，4 个空格）
//     +12 u32 count
//     +16 count × 32 字节条目：name[16]（NUL 结尾）、+16 u32 offset、+20 u32 size、
//         +24 8 字节保留（样本里恒为 0，不作判据）
//     data_base = 16 + count × 32；成员绝对偏移 = data_base + offset。
//
//   BURIKO ARC20（新）
//     +0  "BURIKO ARC20"，+12 u32 count
//     +16 count × 128 字节条目：name[96]、+96 u32 offset、+100 u32 size、其余保留
//     data_base = 16 + count × 128。
//
// 两代的成员都按索引顺序首尾相接地排在 data_base 之后（首条目 offset == 0）。
// 身份判据用这条自洽性，而不只看 12 字节魔数：`PackFile` 是个很泛的词。
//
// `bw  ` 音频包装头（两代归档里的语音 / BGM / SE 成员都是它，64 字节）：
//   +0 u32 header_bytes（样本恒 64）  +4 "bw  "  +8 u32 payload_bytes（== size - header）
//   +12 u32 sample_count  +16 u32 sample_rate  +20 u32 channels  +24..+47 0
//   +48 u32 3（含义未知）  +52..+63 0；其后紧跟 Ogg Vorbis。

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook::bgi {

constexpr char kArc20Signature[] = "BURIKO ARC20";
constexpr char kPackFileSignature[] = "PackFile    ";
constexpr size_t kArcSignatureBytes = 12;
constexpr size_t kArc20SignatureBytes = kArcSignatureBytes;
constexpr size_t kArcHeaderBytes = 16;
constexpr size_t kArc20HeaderBytes = kArcHeaderBytes;
constexpr size_t kArc20EntryBytes = 128;
constexpr size_t kArc20NameBytes = 96;
constexpr size_t kPackFileEntryBytes = 32;
constexpr size_t kPackFileNameBytes = 16;
constexpr size_t kMaxNameBytes = kArc20NameBytes;
constexpr uint32_t kMaxEntryCount = 1u << 20;
constexpr uint32_t kMaxVoiceBytes = 64u * 1024u * 1024u;

enum class ArcFormat : uint8_t { kNone = 0, kPackFile = 1, kArc20 = 2 };

struct ArcLayout {
  ArcFormat format = ArcFormat::kNone;
  uint32_t count = 0;
  uint32_t entry_bytes = 0;
  uint32_t name_bytes = 0;
  uint64_t data_base = 0;  // == 索引总字节数（含 16 字节头）
};

struct ArcEntry {
  char name[kMaxNameBytes + 1] = {0};
  uint64_t member_offset = 0;  // 绝对文件偏移
  uint32_t member_size = 0;
};
using Arc20Entry = ArcEntry;  // 旧名兼容

inline uint32_t ReadLe32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

// 只看 16 字节头：魔数 + count 上界。file_size 为 0 表示调用方不知道文件大小
// （例如只拿到一段内存索引），此时跳过「索引不得超过文件」这条。
inline bool ParseArcHeader(const uint8_t* header, size_t header_bytes,
                           uint64_t file_size, ArcLayout* out) {
  if (header == nullptr || header_bytes < kArcHeaderBytes) return false;
  ArcLayout layout;
  if (std::memcmp(header, kArc20Signature, kArcSignatureBytes) == 0) {
    layout.format = ArcFormat::kArc20;
    layout.entry_bytes = static_cast<uint32_t>(kArc20EntryBytes);
    layout.name_bytes = static_cast<uint32_t>(kArc20NameBytes);
  } else if (std::memcmp(header, kPackFileSignature, kArcSignatureBytes) == 0) {
    layout.format = ArcFormat::kPackFile;
    layout.entry_bytes = static_cast<uint32_t>(kPackFileEntryBytes);
    layout.name_bytes = static_cast<uint32_t>(kPackFileNameBytes);
  } else {
    return false;
  }
  layout.count = ReadLe32(header + kArcSignatureBytes);
  if (layout.count == 0 || layout.count > kMaxEntryCount) return false;
  layout.data_base = kArcHeaderBytes +
      static_cast<uint64_t>(layout.count) * layout.entry_bytes;
  if (file_size != 0 && layout.data_base > file_size) return false;
  if (out != nullptr) *out = layout;
  return true;
}

// 读第 i 条目。index 必须至少覆盖到该条目末尾；成员必须完整落在文件内。
inline bool ReadArcEntry(const uint8_t* index, size_t index_bytes,
                         const ArcLayout& layout, uint32_t i,
                         uint64_t file_size, ArcEntry* out) {
  if (index == nullptr || layout.format == ArcFormat::kNone ||
      i >= layout.count) {
    return false;
  }
  const uint64_t record_end = kArcHeaderBytes +
      (static_cast<uint64_t>(i) + 1) * layout.entry_bytes;
  if (record_end > index_bytes) return false;
  const uint8_t* record = index + kArcHeaderBytes +
                          static_cast<size_t>(i) * layout.entry_bytes;
  const uint32_t relative = ReadLe32(record + layout.name_bytes);
  const uint32_t size = ReadLe32(record + layout.name_bytes + 4);
  const uint64_t member = layout.data_base + relative;
  if (file_size != 0 && (member > file_size || size > file_size - member)) {
    return false;
  }
  if (out != nullptr) {
    std::memset(out->name, 0, sizeof(out->name));
    std::memcpy(out->name, record, layout.name_bytes);
    out->member_offset = member;
    out->member_size = size;
  }
  return true;
}

inline bool IsArcIndex(const uint8_t* index, size_t index_bytes,
                       ArcLayout* layout_out = nullptr) {
  ArcLayout layout;
  if (!ParseArcHeader(index, index_bytes, 0, &layout) ||
      layout.data_base > index_bytes) {
    return false;
  }
  if (layout_out != nullptr) *layout_out = layout;
  return true;
}

// 旧接口（仅 ARC20）：保留给既有调用点。
inline bool IsArc20Index(const uint8_t* index, size_t index_bytes,
                         uint32_t* count_out = nullptr,
                         uint64_t* data_base_out = nullptr) {
  ArcLayout layout;
  if (!IsArcIndex(index, index_bytes, &layout) ||
      layout.format != ArcFormat::kArc20) {
    return false;
  }
  if (count_out != nullptr) *count_out = layout.count;
  if (data_base_out != nullptr) *data_base_out = layout.data_base;
  return true;
}

// 身份判据：头合法，且 prefix 里能看到的前若干条目满足「首条目 offset 为 0、条目首尾
// 相接、名字非空且在字段内 NUL 结尾、成员落在文件内」。prefix 至少要含头和第一条目。
// 只看前 max_entries 条，保证身份探测是有界读。
inline bool IsArcIdentityPrefix(const uint8_t* prefix, size_t prefix_bytes,
                                uint64_t file_size, uint32_t max_entries = 8) {
  ArcLayout layout;
  if (!ParseArcHeader(prefix, prefix_bytes, file_size, &layout)) return false;
  uint32_t checked = 0;
  uint64_t expected_relative = 0;
  for (uint32_t i = 0; i < layout.count && checked < max_entries; ++i) {
    const uint64_t record_end = kArcHeaderBytes +
        (static_cast<uint64_t>(i) + 1) * layout.entry_bytes;
    if (record_end > prefix_bytes) break;
    const uint8_t* record = prefix + kArcHeaderBytes +
                            static_cast<size_t>(i) * layout.entry_bytes;
    if (record[0] == 0 ||
        std::memchr(record, 0, layout.name_bytes) == nullptr) {
      return false;
    }
    for (uint32_t c = 0; c < layout.name_bytes && record[c] != 0; ++c) {
      if (record[c] < 0x20) return false;
    }
    const uint32_t relative = ReadLe32(record + layout.name_bytes);
    const uint32_t size = ReadLe32(record + layout.name_bytes + 4);
    if (relative != expected_relative) return false;
    const uint64_t member = layout.data_base + relative;
    if (file_size != 0 && (member > file_size || size > file_size - member)) {
      return false;
    }
    expected_relative = static_cast<uint64_t>(relative) + size;
    ++checked;
  }
  return checked > 0;
}

// 给定读偏移找成员。BGI 读语音时要么 seek 到 64 字节 `bw` 包装头、要么直接到内嵌
// Ogg；窗口收窄到成员前 4 KiB，避免一次大块顺序读被误当成后面某个成员。
inline bool FindEntryForRead(const uint8_t* index, size_t index_bytes,
                             uint64_t file_size, uint64_t read_offset,
                             ArcEntry* out) {
  ArcLayout layout;
  if (out == nullptr || !IsArcIndex(index, index_bytes, &layout) ||
      layout.data_base > file_size) {
    return false;
  }
  for (uint32_t i = 0; i < layout.count; ++i) {
    ArcEntry entry;
    if (!ReadArcEntry(index, index_bytes, layout, i, file_size, &entry) ||
        entry.member_size < 12) {
      return false;
    }
    const uint64_t probe_end = entry.member_offset +
        (entry.member_size < 4096 ? entry.member_size : 4096);
    if (read_offset < entry.member_offset || read_offset >= probe_end) {
      continue;
    }
    *out = entry;
    return true;
  }
  return false;
}

struct BwHeader {
  uint32_t header_bytes = 0;
  uint32_t payload_bytes = 0;
  uint32_t sample_count = 0;
  uint32_t sample_rate = 0;
  uint32_t channels = 0;
};

// 解析 `bw  ` 包装头的定长字段（不要求后面跟着 Ogg；那是 ParseBwOggHeader 的事）。
inline bool ParseBwHeader(const uint8_t* header, size_t header_bytes,
                          uint32_t member_size, BwHeader* out) {
  if (header == nullptr || header_bytes < 24 || member_size < 24 ||
      std::memcmp(header + 4, "bw  ", 4) != 0) {
    return false;
  }
  BwHeader parsed;
  parsed.header_bytes = ReadLe32(header);
  parsed.payload_bytes = ReadLe32(header + 8);
  parsed.sample_count = ReadLe32(header + 12);
  parsed.sample_rate = ReadLe32(header + 16);
  parsed.channels = ReadLe32(header + 20);
  if (parsed.header_bytes < 24 || parsed.header_bytes >= member_size ||
      parsed.channels == 0 || parsed.channels > 8 ||
      parsed.sample_rate < 8000 || parsed.sample_rate > 192000) {
    return false;
  }
  if (out != nullptr) *out = parsed;
  return true;
}

// ── 逐句语音包的包级判据 ───────────────────────────────────────────────────────
//
// 判据：**包内每个（抽检到的）成员都是合法 `bw` 包装、且 bw 头声道数 == 1**。
//
// 证据（两代样本全部 `bw` 成员的 +20 声道字段；与内嵌 Ogg 识别头的声道数逐条一致）：
//   * 语音包：Eustia(PackFile) data04xxx 17 包 3529 条、千の刃濤(ARC20) data04xxx
//     19 包 4371 条，全部单声道 44100 Hz；两作其余 BGI 归档（图像 / 脚本 / BGM / SE / 环境音 / 视频包）全部被本判据拒绝
//     （包括千の刃濤的 data03110——旧的 `data031*` 文件名判据指向的其实是 SE 包）。
//   * BGM：两作 data05000 全部立体声。
//   * SE：Eustia data03000 100/102 立体声；千の刃濤 data03110 143/146、data03100 3/3
//     立体声。环境音 data05010 / data05100 同样以立体声为主（各有 0/2 条单声道）。
//   * 混合包（千の刃濤 data10001：17 条单声道 bw + 7 条 CompressedBG + 1 条其它；
//     system.arc：DSC + 立体声 bw + OTF 字体）因含非 bw 成员被拒。
// 单条成员级判据不够：SE 包里各有 2~3 条单声道短音效（0.2~0.9 s），与最短语音
// （0.5~0.6 s）时长重叠，只能按包判。
//
// 这是内容约定而不是格式字段：一个全单声道的 SE 包、或立体声语音的 BGI 作品会被判错
// （前者误收、后者漏收），这就是本判据的已知风险。
//
// 大包按等距抽检（含首尾），读量有界。
constexpr uint32_t kMaxVoiceClassifyMembers = 512;

inline uint32_t VoiceClassifySampleCount(uint32_t count) {
  return count < kMaxVoiceClassifyMembers ? count : kMaxVoiceClassifyMembers;
}

// 第 k 个抽检成员的索引（0 <= k < VoiceClassifySampleCount(count)）。
inline uint32_t VoiceClassifySampleIndex(uint32_t count, uint32_t k) {
  const uint32_t samples = VoiceClassifySampleCount(count);
  if (samples <= 1 || samples == count) return k;
  return static_cast<uint32_t>(
      (static_cast<uint64_t>(k) * (count - 1)) / (samples - 1));
}

struct VoiceArchiveTally {
  uint32_t examined = 0;
  uint32_t mono_bw = 0;
  uint32_t rejected = 0;  // 非 bw、bw 头畸形或多声道

  // member_head 是成员开头的若干字节（至少 24）。
  void Add(const uint8_t* member_head, size_t head_bytes,
           uint32_t member_size) {
    ++examined;
    BwHeader bw;
    if (ParseBwHeader(member_head, head_bytes, member_size, &bw) &&
        bw.channels == 1) {
      ++mono_bw;
    } else {
      ++rejected;
    }
  }

  bool IsVoiceArchive() const { return examined > 0 && rejected == 0; }
};

inline bool ParseBwOggHeader(const uint8_t* header, size_t header_bytes,
                             uint32_t member_size, uint32_t* ogg_offset,
                             uint32_t* ogg_size) {
  if (header == nullptr || header_bytes < 12 || member_size < 12) return false;
  const uint32_t offset = ReadLe32(header);
  if (std::memcmp(header + 4, "bw  ", 4) != 0 || offset < 8 ||
      offset > member_size - 4 || offset + 4 > header_bytes ||
      std::memcmp(header + offset, "OggS", 4) != 0) {
    return false;
  }
  const uint32_t size = member_size - offset;
  if (size == 0 || size > kMaxVoiceBytes) return false;
  if (ogg_offset != nullptr) *ogg_offset = offset;
  if (ogg_size != nullptr) *ogg_size = size;
  return true;
}

}  // namespace fushi_voice_hook::bgi
