// knife (Rust reimplementation of the Switch engine of "Tsukihime -A piece of
// blue glass moon-") - pure, host-independent pieces of the adapter.
//
// Runtime contract (knife source, AuroraWright/knife):
//   * text: the engine serves every displayed message as one plain-text
//     WebSocket message (`--text-websocket HOST:PORT`, or `text-websocket =`
//     in knife.ini next to the exe). Ruby and control codes are already
//     removed; a message's continuation (`@k` addition) is sent separately.
//   * voice: a message start plays the VPLY voice by reading the whole loose
//     file `<assets>/stream/<name>.opus` (std::fs::read) and only then sends
//     the message text (game.rs Op::Message: play_voice -> text_stream::message).
//     The file is Nintendo Opus (header chunk 0x80000001, data chunk
//     0x80000004 of `u32be size, u32be final_range, packet` records), not Ogg.
//
// Everything here is bounded and allocation-light so the adapter can run it on
// its own text thread; nothing here touches the game process.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cwchar>
#include <string>
#include <vector>

namespace fushi_voice_hook::knife {

constexpr uint32_t kNopusHeaderMagic = 0x80000001u;
constexpr uint32_t kNopusDataMagic = 0x80000004u;
// A voice line belongs to the text the engine sends right after reading it.
// Reading the file and sending the text happen in the same script step; the
// text then crosses knife's WebSocket client thread (50 ms poll). Anything
// older is a replay / test voice or a mid-message VPL2 voice of an earlier
// line and must not be glued onto the next text.
constexpr uint64_t kVoiceToTextWindowMs = 1000u;
// Upper bound for one voice file: the longest line is well under a minute of
// mono 48 kHz Opus; a larger file is not a voice line.
constexpr uint32_t kMaxVoiceFileBytes = 8u * 1024u * 1024u;

inline uint32_t ReadLe32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

inline uint16_t ReadLe16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (p[1] << 8));
}

inline uint32_t ReadBe32(const uint8_t* p) {
  return (static_cast<uint32_t>(p[0]) << 24) |
         (static_cast<uint32_t>(p[1]) << 16) |
         (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}

inline bool IsNintendoOpus(const uint8_t* data, size_t size) {
  return data != nullptr && size >= 0x20 &&
         ReadLe32(data) == kNopusHeaderMagic;
}

// Samples (at 48 kHz) of one Opus packet from its TOC byte (RFC 6716 sec. 3.1).
// Returns 0 for a malformed packet.
inline uint32_t OpusPacketSamples(const uint8_t* packet, size_t size) {
  if (packet == nullptr || size == 0) return 0;
  const uint8_t toc = packet[0];
  const uint32_t config = toc >> 3;
  uint32_t frame = 0;
  if (config < 12) {
    static constexpr uint32_t kSilk[4] = {480, 960, 1920, 2880};
    frame = kSilk[config & 3u];
  } else if (config < 16) {
    frame = (config & 1u) != 0 ? 960 : 480;
  } else {
    static constexpr uint32_t kCelt[4] = {120, 240, 480, 960};
    frame = kCelt[config & 3u];
  }
  uint32_t frames = 0;
  switch (toc & 3u) {
    case 0:
      frames = 1;
      break;
    case 1:
    case 2:
      frames = 2;
      break;
    default:
      if (size < 2) return 0;
      frames = packet[1] & 0x3Fu;
      break;
  }
  const uint32_t samples = frame * frames;
  // RFC 6716: a packet never exceeds 120 ms.
  return samples == 0 || samples > 5760 ? 0 : samples;
}

inline uint32_t OggCrcUpdate(uint32_t crc, uint8_t byte) {
  crc ^= static_cast<uint32_t>(byte) << 24;
  for (int bit = 0; bit < 8; ++bit) {
    crc = (crc & 0x80000000u) != 0u ? (crc << 1) ^ 0x04c11db7u : crc << 1;
  }
  return crc;
}

inline void PutLe16(std::vector<uint8_t>* out, uint16_t v) {
  out->push_back(static_cast<uint8_t>(v));
  out->push_back(static_cast<uint8_t>(v >> 8));
}

inline void PutLe32(std::vector<uint8_t>* out, uint32_t v) {
  for (int i = 0; i < 4; ++i) out->push_back(static_cast<uint8_t>(v >> (8 * i)));
}

inline void PutLe64(std::vector<uint8_t>* out, uint64_t v) {
  for (int i = 0; i < 8; ++i) out->push_back(static_cast<uint8_t>(v >> (8 * i)));
}

struct OggPacketRef {
  const uint8_t* data = nullptr;
  uint32_t size = 0;
};

// Appends one Ogg page holding [packets] (each complete on this page).
inline void AppendOggPage(std::vector<uint8_t>* out, uint32_t serial,
                          uint32_t sequence, uint64_t granule, uint8_t flags,
                          const std::vector<OggPacketRef>& packets) {
  const size_t start = out->size();
  out->insert(out->end(), {'O', 'g', 'g', 'S', 0, flags});
  PutLe64(out, granule);
  PutLe32(out, serial);
  PutLe32(out, sequence);
  PutLe32(out, 0);  // CRC, filled below
  std::vector<uint8_t> lacing;
  for (const OggPacketRef& packet : packets) {
    uint32_t left = packet.size;
    while (left >= 255) {
      lacing.push_back(255);
      left -= 255;
    }
    lacing.push_back(static_cast<uint8_t>(left));
  }
  out->push_back(static_cast<uint8_t>(lacing.size()));
  out->insert(out->end(), lacing.begin(), lacing.end());
  for (const OggPacketRef& packet : packets) {
    out->insert(out->end(), packet.data, packet.data + packet.size);
  }
  uint32_t crc = 0;
  for (size_t i = start; i < out->size(); ++i) crc = OggCrcUpdate(crc, (*out)[i]);
  for (int i = 0; i < 4; ++i) {
    (*out)[start + 22 + i] = static_cast<uint8_t>(crc >> (8 * i));
  }
}

inline uint32_t LacingSegments(uint32_t size) { return size / 255u + 1u; }

// Rewraps a Nintendo Opus file into a standard Ogg Opus stream (RFC 7845),
// packet for packet: no decoding, the Opus payload bytes are unchanged.
// Only channel mapping family 0 (mono / stereo) exists in knife's data.
inline bool RemuxNintendoOpusToOgg(const uint8_t* data, size_t size,
                                   uint32_t serial,
                                   std::vector<uint8_t>* out) {
  if (out == nullptr || !IsNintendoOpus(data, size)) return false;
  out->clear();
  const uint8_t channels = data[9];
  const uint32_t sample_rate = ReadLe32(data + 0x0C);
  const uint32_t data_offset = ReadLe32(data + 0x10);
  // 16-bit pre-skip at 0x1C, as vgmstream reads it; 0x1E is a separate field
  // that is non-zero in some titles and is not part of the pre-skip.
  const uint32_t pre_skip = ReadLe16(data + 0x1C);
  if (channels == 0 || channels > 2 || sample_rate == 0 ||
      data_offset > size || size - data_offset < 8 ||
      ReadLe32(data + data_offset) != kNopusDataMagic) {
    return false;
  }
  const uint32_t data_bytes = ReadLe32(data + data_offset + 4);
  const size_t end = data_offset + 8 + static_cast<size_t>(data_bytes) < size
                         ? data_offset + 8 + static_cast<size_t>(data_bytes)
                         : size;
  std::vector<OggPacketRef> packets;
  for (size_t at = data_offset + 8; at + 8 <= end;) {
    const uint32_t packet_bytes = ReadBe32(data + at);
    if (packet_bytes == 0 || packet_bytes > end - at - 8) return false;
    packets.push_back({data + at + 8, packet_bytes});
    at += 8 + static_cast<size_t>(packet_bytes);
  }
  if (packets.empty()) return false;

  std::vector<uint8_t> head = {'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1,
                               channels};
  PutLe16(&head, static_cast<uint16_t>(pre_skip));
  PutLe32(&head, sample_rate);
  PutLe16(&head, 0);  // output gain
  head.push_back(0);  // mapping family 0
  static constexpr char kVendor[] = "fushi knife remux";
  std::vector<uint8_t> tags = {'O', 'p', 'u', 's', 'T', 'a', 'g', 's'};
  PutLe32(&tags, static_cast<uint32_t>(sizeof(kVendor) - 1));
  tags.insert(tags.end(), kVendor, kVendor + sizeof(kVendor) - 1);
  PutLe32(&tags, 0);  // no user comments

  uint32_t sequence = 0;
  AppendOggPage(out, serial, sequence++, 0, 0x02,
                {{head.data(), static_cast<uint32_t>(head.size())}});
  AppendOggPage(out, serial, sequence++, 0, 0x00,
                {{tags.data(), static_cast<uint32_t>(tags.size())}});
  uint64_t granule = 0;
  std::vector<OggPacketRef> page;
  uint32_t page_segments = 0;
  for (size_t i = 0; i < packets.size(); ++i) {
    const uint32_t samples =
        OpusPacketSamples(packets[i].data, packets[i].size);
    if (samples == 0) return false;
    const uint32_t segments = LacingSegments(packets[i].size);
    if (segments > 255) return false;
    if (!page.empty() && page_segments + segments > 255) {
      AppendOggPage(out, serial, sequence++, granule, 0x00, page);
      page.clear();
      page_segments = 0;
    }
    page.push_back(packets[i]);
    page_segments += segments;
    granule += samples;
  }
  AppendOggPage(out, serial, sequence++, granule, 0x04, page);
  return true;
}

inline bool IsPathSeparator(wchar_t c) { return c == L'\\' || c == L'/'; }

// Basename of a path that may mix '\' and '/' (knife joins "stream/<name>.opus"
// onto a Windows assets path). Points into [path]; never allocates, so the
// kernel file detour can call it on a game thread.
inline const wchar_t* PathBaseName(const wchar_t* path) {
  if (path == nullptr) return nullptr;
  const wchar_t* base = path;
  for (const wchar_t* p = path; *p != 0; ++p) {
    if (IsPathSeparator(*p)) base = p + 1;
  }
  return base;
}

// A knife voice line: `<assets>/stream/<name>.opus` whose name is a script
// voice id - a speaker letter, two digits and '_' (A00_01_00_0000_0,
// M02_...). BGM, songs and stream sound effects share the folder but are named
// MOON01_BGM01, ..., so they never qualify. Allocation-free (game thread).
inline bool IsVoiceStreamPath(const wchar_t* path) {
  if (path == nullptr) return false;
  const size_t length = wcslen(path);
  if (length < 12 || _wcsicmp(path + length - 5, L".opus") != 0) return false;
  const wchar_t* base = PathBaseName(path);
  const size_t base_length = length - static_cast<size_t>(base - path);
  if (base_length < 9 || base == path) return false;
  const size_t dir_end = static_cast<size_t>(base - path) - 1;  // separator
  if (dir_end < 7) return false;
  const wchar_t* dir = path + dir_end - 7;
  if (!IsPathSeparator(dir[0]) || _wcsnicmp(dir + 1, L"stream", 6) != 0) {
    return false;
  }
  const wchar_t letter = base[0];
  const bool is_letter =
      (letter >= L'A' && letter <= L'Z') || (letter >= L'a' && letter <= L'z');
  return is_letter && base[1] >= L'0' && base[1] <= L'9' && base[2] >= L'0' &&
         base[2] <= L'9' && base[3] == L'_';
}

// Index (into [voice_ticks]) of the voice that belongs to a text published at
// [text_tick]: the latest voice read no later than the text and no earlier
// than [window_ms] before it. -1 when none qualifies.
inline int SelectVoiceForText(const std::vector<uint64_t>& voice_ticks,
                              uint64_t text_tick,
                              uint64_t window_ms = kVoiceToTextWindowMs) {
  int best = -1;
  for (size_t i = 0; i < voice_ticks.size(); ++i) {
    const uint64_t tick = voice_ticks[i];
    if (tick > text_tick || text_tick - tick > window_ms) continue;
    if (best < 0 || tick >= voice_ticks[static_cast<size_t>(best)]) {
      best = static_cast<int>(i);
    }
  }
  return best;
}

// -- configuration: knife.ini and the command line --------------------------

struct LaunchOptions {
  std::wstring assets_dir;      // as given (may be relative)
  std::wstring text_websocket;  // HOST:PORT
};

inline std::wstring Trim(const std::wstring& value) {
  size_t begin = 0;
  size_t end = value.size();
  while (begin < end && (value[begin] == L' ' || value[begin] == L'\t' ||
                         value[begin] == L'\r' || value[begin] == L'\n' ||
                         value[begin] == 0xFEFF)) {
    ++begin;
  }
  while (end > begin && (value[end - 1] == L' ' || value[end - 1] == L'\t' ||
                         value[end - 1] == L'\r' || value[end - 1] == L'\n')) {
    --end;
  }
  return value.substr(begin, end - begin);
}

// knife.ini: `key = value` per line, long option names, `;` / `#` comments,
// an empty value leaves the option unset (knife/src/ini.rs).
inline LaunchOptions ParseIni(const std::wstring& text) {
  LaunchOptions options;
  size_t at = 0;
  while (at <= text.size()) {
    size_t line_end = text.find(L'\n', at);
    if (line_end == std::wstring::npos) line_end = text.size();
    const std::wstring line = Trim(text.substr(at, line_end - at));
    at = line_end + 1;
    if (line.empty() || line[0] == L';' || line[0] == L'#') continue;
    const size_t eq = line.find(L'=');
    if (eq == std::wstring::npos) continue;
    const std::wstring key = Trim(line.substr(0, eq));
    const std::wstring value = Trim(line.substr(eq + 1));
    if (value.empty()) continue;
    if (key == L"assets-dir") options.assets_dir = value;
    if (key == L"text-websocket") options.text_websocket = value;
  }
  return options;
}

// Splits a Windows command line the way the CRT does for the cases knife's
// options use (quoted values, no escaped quotes inside option values).
inline std::vector<std::wstring> SplitCommandLine(const wchar_t* command_line) {
  std::vector<std::wstring> args;
  if (command_line == nullptr) return args;
  std::wstring current;
  bool quoted = false;
  bool has_arg = false;
  for (const wchar_t* p = command_line; *p != 0; ++p) {
    if (*p == L'"') {
      quoted = !quoted;
      has_arg = true;
    } else if (!quoted && (*p == L' ' || *p == L'\t')) {
      if (has_arg) args.push_back(current);
      current.clear();
      has_arg = false;
    } else {
      current.push_back(*p);
      has_arg = true;
    }
  }
  if (has_arg) args.push_back(current);
  return args;
}

// Command-line options override knife.ini (knife/src/ini.rs). Accepts
// `-t V`, `-tV`, `--text-websocket V`, `--text-websocket=V` and the same for
// `-a` / `--assets-dir`. The first argument is the executable.
inline LaunchOptions ApplyCommandLine(LaunchOptions options,
                                      const std::vector<std::wstring>& args) {
  struct Option {
    const wchar_t* shortName;
    const wchar_t* longName;
    std::wstring* target;
  };
  const Option kOptions[] = {
      {L"-t", L"--text-websocket", &options.text_websocket},
      {L"-a", L"--assets-dir", &options.assets_dir},
  };
  for (size_t i = 1; i < args.size(); ++i) {
    const std::wstring& arg = args[i];
    for (const Option& option : kOptions) {
      const std::wstring long_name = option.longName;
      if (arg == option.shortName || arg == long_name) {
        if (i + 1 < args.size()) *option.target = args[++i];
        break;
      }
      if (arg.rfind(long_name + L"=", 0) == 0) {
        *option.target = arg.substr(long_name.size() + 1);
        break;
      }
      if (arg.size() > 2 && arg.rfind(option.shortName, 0) == 0 &&
          arg[1] != L'-') {
        *option.target = arg.substr(2);
        break;
      }
    }
  }
  return options;
}

// HOST:PORT -> host and port. IPv6 literals use the `[::1]:6677` form.
inline bool SplitHostPort(const std::wstring& address, std::wstring* host,
                          uint16_t* port) {
  if (host == nullptr || port == nullptr) return false;
  const size_t colon = address.rfind(L':');
  if (colon == std::wstring::npos || colon == 0 ||
      colon + 1 >= address.size()) {
    return false;
  }
  std::wstring name = address.substr(0, colon);
  if (name.size() >= 2 && name.front() == L'[' && name.back() == L']') {
    name = name.substr(1, name.size() - 2);
  }
  uint32_t value = 0;
  for (size_t i = colon + 1; i < address.size(); ++i) {
    const wchar_t c = address[i];
    if (c < L'0' || c > L'9') return false;
    value = value * 10 + static_cast<uint32_t>(c - L'0');
    if (value > 65535) return false;
  }
  if (value == 0 || name.empty()) return false;
  // knife binds the address it is given; "0.0.0.0" / "::" listen everywhere,
  // so the in-process client connects over loopback.
  if (name == L"0.0.0.0") name = L"127.0.0.1";
  if (name == L"::") name = L"::1";
  *host = name;
  *port = static_cast<uint16_t>(value);
  return true;
}

// Resolves a possibly relative path against [base_dir] (no trailing slash).
inline std::wstring ResolveAgainst(const std::wstring& base_dir,
                                   const std::wstring& path) {
  if (path.empty()) return base_dir;
  const bool absolute = (path.size() >= 2 && path[1] == L':') ||
                        (path.size() >= 2 && IsPathSeparator(path[0]) &&
                         IsPathSeparator(path[1]));
  if (absolute) return path;
  if (IsPathSeparator(path[0])) return base_dir.substr(0, 2) + path;
  return base_dir + L"\\" + path;
}

}  // namespace fushi_voice_hook::knife
