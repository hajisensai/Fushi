#pragma once

// FVP（Favorite View Point，FAVORITE）脚本与音频格式的纯解析层（无 Windows 依赖，可单测）。
//
// 字段均按真实样本逐字节核对过（2011《いろとりどりのセカイ》World.hcb、2019《星空のメモリア
// Eternal Heart HD》HoshimemoEH_HD.hcb，只读）：
//
//   HCB 脚本（游戏目录下的 `*.hcb`，引擎把它整份读进内存解释执行）
//     +0  u32 trailer_offset（字节码区 [4, trailer_offset)）
//     trailer:
//       u32 entry（入口字节码地址，必在字节码区内）
//       u16 global_count  u16 global_table_count  u16 screen_mode
//       u8  title_bytes   title[title_bytes]（CP932，NUL 结尾在字段内）
//       u16 syscall_count
//       syscall_count × { u8 argc, u8 name_bytes, name[name_bytes]（ASCII，NUL 结尾在字段内） }
//       末尾可有少量填充（样本 2 字节）
//     syscall 表就是引擎的原生调用名单——`TextPrint`（argc 2：文本缓冲号 + 字符串）
//     是对白的输出点。身份判据用整条 trailer 的自洽性 + 该名单里有 TextPrint/2，
//     不看文件名。
//
//   语音判据：以引擎交给 ChannelPlay → SoundLoad 的**资源名**为主判据——引擎的资源名是
//   「归档目录/条目」（`voice/02000750`），路径里有一个目录分量是 `voice` 才是逐句语音
//   （IsVoiceResourceName）。声道数只作辅证（VorbisChannels 非 0 = 确实是 Ogg Vorbis
//   流），不再作分类依据：单声道音效会被误认、立体声语音会被漏掉。这里只读资源名与
//   Ogg 首页的 Vorbis 识别包，不解析任何归档。

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook::fvp {

constexpr uint32_t kMaxHcbTrailerBytes = 64u * 1024u;
constexpr uint32_t kMaxHcbSyscalls = 1024u;
constexpr size_t kMaxHcbTrailerSlack = 16u;
// The Ogg identification page head this layer reads: 27-byte page header,
// up to 255 lacing values, the 30-byte Vorbis identification packet.
constexpr size_t kVorbisHeadBytes = 27u + 255u + 30u;

inline uint32_t ReadLe32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

inline uint16_t ReadLe16(const uint8_t* bytes) {
  return static_cast<uint16_t>(bytes[0] | (bytes[1] << 8));
}

// ── HCB ────────────────────────────────────────────────────────────────────

struct HcbSummary {
  uint32_t trailer_offset = 0u;
  uint32_t entry = 0u;
  uint16_t screen_mode = 0u;
  uint32_t syscall_count = 0u;
  bool has_text_print = false;  // `TextPrint` with argc 2
};

inline bool IsHcbNameByte(uint8_t byte) {
  return (byte >= '0' && byte <= '9') || (byte >= 'A' && byte <= 'Z') ||
         (byte >= 'a' && byte <= 'z') || byte == '_';
}

// `trailer` holds the file bytes [trailer_offset, file_size).  Every field is
// bounds-checked; any inconsistency is a refusal.
inline bool ParseHcbTrailer(const uint8_t* trailer, size_t trailer_bytes,
                            uint32_t trailer_offset, uint64_t file_size,
                            HcbSummary* out) {
  if (trailer == nullptr || trailer_offset < 8u ||
      file_size <= trailer_offset ||
      file_size - trailer_offset != trailer_bytes ||
      trailer_bytes > kMaxHcbTrailerBytes || trailer_bytes < 13u) {
    return false;
  }
  HcbSummary summary;
  summary.trailer_offset = trailer_offset;
  summary.entry = ReadLe32(trailer);
  if (summary.entry < 4u || summary.entry >= trailer_offset) return false;
  size_t at = 4u + 2u + 2u;
  summary.screen_mode = ReadLe16(trailer + at);
  at += 2u;
  const uint8_t title_bytes = trailer[at++];
  if (title_bytes == 0u || at + title_bytes + 2u > trailer_bytes ||
      trailer[at + title_bytes - 1u] != 0u) {
    return false;
  }
  at += title_bytes;
  const uint16_t count = ReadLe16(trailer + at);
  at += 2u;
  if (count == 0u || count > kMaxHcbSyscalls) return false;
  for (uint32_t index = 0u; index < count; ++index) {
    if (at + 2u > trailer_bytes) return false;
    const uint8_t argc = trailer[at];
    const uint8_t name_bytes = trailer[at + 1u];
    at += 2u;
    if (name_bytes < 2u || at + name_bytes > trailer_bytes ||
        trailer[at + name_bytes - 1u] != 0u) {
      return false;
    }
    const size_t name_length = name_bytes - 1u;
    for (size_t k = 0u; k < name_length; ++k) {
      if (!IsHcbNameByte(trailer[at + k])) return false;
    }
    if (argc == 2u && name_length == 9u &&
        std::memcmp(trailer + at, "TextPrint", 9u) == 0) {
      summary.has_text_print = true;
    }
    at += name_bytes;
  }
  if (trailer_bytes - at > kMaxHcbTrailerSlack) return false;
  summary.syscall_count = count;
  if (out != nullptr) *out = summary;
  return true;
}

// ── Ogg Vorbis identification ──────────────────────────────────────────────

// Channel count from the first Ogg page's Vorbis identification packet; 0 when
// the bytes are not an Ogg Vorbis stream start.
inline uint32_t VorbisChannels(const uint8_t* head, size_t head_bytes) {
  if (head == nullptr || head_bytes < 27u ||
      std::memcmp(head, "OggS", 4u) != 0 || head[4] != 0u ||
      (head[5] & 0x02u) == 0u) {  // version 0, beginning-of-stream page
    return 0u;
  }
  const size_t segments = head[26];
  const size_t packet = 27u + segments;
  if (segments == 0u || packet + 30u > head_bytes) return 0u;
  if (head[packet] != 0x01u ||
      std::memcmp(head + packet + 1u, "vorbis", 6u) != 0 ||
      ReadLe32(head + packet + 7u) != 0u) {
    return 0u;
  }
  return head[packet + 11u];
}

// ── voice resource name ────────────────────────────────────────────────────

// The engine names a sound resource "<archive directory>/<entry>"
// (`voice/02000750`, `se/...`, `bgm/...`).  A resource is a voice line when
// one of its directory components (not the entry itself) is `voice`, ASCII
// case-insensitive, with `/` or `\` separators.  `name` is read up to its NUL
// or `name_bytes`, whichever comes first.
inline bool IsVoiceResourceName(const char* name, size_t name_bytes) {
  if (name == nullptr) return false;
  size_t length = 0u;
  while (length < name_bytes && name[length] != '\0') ++length;
  static constexpr char kVoice[] = "voice";
  size_t start = 0u;
  for (size_t at = 0u; at < length; ++at) {
    if (name[at] != '/' && name[at] != '\\') continue;
    // [start, at) is a directory component: it is followed by a separator.
    if (at - start == 5u) {
      bool match = true;
      for (size_t k = 0u; k < 5u && match; ++k) {
        char c = name[start + k];
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        match = c == kVoice[k];
      }
      if (match && at + 1u < length) return true;  // an entry follows
    }
    start = at + 1u;
  }
  return false;
}

}  // namespace fushi_voice_hook::fvp
