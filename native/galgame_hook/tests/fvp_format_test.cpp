// Release builds define NDEBUG. Undefine it before every include so these
// assertions remain executable focused test code.
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "fvp_format.h"

namespace fvp = fushi_voice_hook::fvp;

namespace {

void Put32(std::vector<uint8_t>* out, uint32_t value) {
  for (int k = 0; k < 4; ++k) out->push_back(static_cast<uint8_t>(value >> (8 * k)));
}
void Put16(std::vector<uint8_t>* out, uint16_t value) {
  out->push_back(static_cast<uint8_t>(value));
  out->push_back(static_cast<uint8_t>(value >> 8));
}

struct Syscall {
  uint8_t argc;
  std::string name;
};

// A whole synthetic HCB: 4-byte header, `code_bytes` of bytecode, trailer.
std::vector<uint8_t> BuildHcb(const std::vector<Syscall>& syscalls,
                              uint32_t code_bytes = 64u, uint32_t slack = 2u) {
  std::vector<uint8_t> file;
  const uint32_t trailer_offset = 4u + code_bytes;
  Put32(&file, trailer_offset);
  file.resize(trailer_offset, 0x01u);
  Put32(&file, 8u);  // entry
  Put16(&file, 10u);
  Put16(&file, 12u);
  Put16(&file, 7u);  // screen mode
  const char title[] = "title";
  file.push_back(static_cast<uint8_t>(sizeof(title)));
  file.insert(file.end(), title, title + sizeof(title));
  Put16(&file, static_cast<uint16_t>(syscalls.size()));
  for (const Syscall& call : syscalls) {
    file.push_back(call.argc);
    file.push_back(static_cast<uint8_t>(call.name.size() + 1u));
    file.insert(file.end(), call.name.begin(), call.name.end());
    file.push_back(0u);
  }
  file.resize(file.size() + slack, 0u);
  return file;
}

bool Parse(const std::vector<uint8_t>& file, fvp::HcbSummary* summary) {
  const uint32_t trailer = fvp::ReadLe32(file.data());
  if (trailer >= file.size()) return false;
  return fvp::ParseHcbTrailer(file.data() + trailer, file.size() - trailer,
                              trailer, file.size(), summary);
}

void TestHcb() {
  const std::vector<Syscall> calls = {
      {2u, "AudioLoad"}, {2u, "TextPrint"}, {4u, "PrimSetText"}};
  fvp::HcbSummary summary;
  assert(Parse(BuildHcb(calls), &summary));
  assert(summary.has_text_print);
  assert(summary.syscall_count == 3u);
  assert(summary.screen_mode == 7u);

  // Without the text syscall (or with another arity) the script parses but is
  // not an FVP dialogue script.
  assert(Parse(BuildHcb({{2u, "AudioLoad"}}), &summary));
  assert(!summary.has_text_print);
  assert(Parse(BuildHcb({{3u, "TextPrint"}}), &summary));
  assert(!summary.has_text_print);

  // Non-identifier name bytes, too much trailing slack, an entry outside the
  // bytecode and a truncated table are all refused.
  assert(!Parse(BuildHcb({{2u, "Text Print"}}), &summary));
  assert(!Parse(BuildHcb(calls, 64u, 64u), &summary));
  std::vector<uint8_t> bad_entry = BuildHcb(calls);
  const uint32_t trailer = fvp::ReadLe32(bad_entry.data());
  bad_entry[trailer] = 0xffu;
  bad_entry[trailer + 1u] = 0xffu;
  assert(!Parse(bad_entry, &summary));
  std::vector<uint8_t> truncated = BuildHcb(calls, 64u, 0u);
  truncated.resize(truncated.size() - 3u);
  assert(!Parse(truncated, &summary));
  // A file that is not an HCB at all (a BGI arc header) is refused.
  std::vector<uint8_t> other(256u, 0u);
  std::memcpy(other.data(), "BURIKO ARC20", 12u);
  assert(!Parse(other, &summary));
}

std::vector<uint8_t> OggHead(uint8_t channels) {
  std::vector<uint8_t> head(27u, 0u);
  std::memcpy(head.data(), "OggS", 4u);
  head[5] = 0x02u;  // beginning of stream
  head[26] = 1u;    // one segment
  head.push_back(30u);
  head.push_back(0x01u);
  const char vorbis[] = "vorbis";
  head.insert(head.end(), vorbis, vorbis + 6);
  Put32(&head, 0u);  // version
  head.push_back(channels);
  Put32(&head, 48000u);
  head.resize(head.size() + 16u, 0u);
  return head;
}

void TestVorbis() {
  const auto mono = OggHead(1u);
  const auto stereo = OggHead(2u);
  assert(fvp::VorbisChannels(mono.data(), mono.size()) == 1u);
  assert(fvp::VorbisChannels(stereo.data(), stereo.size()) == 2u);
  assert(fvp::VorbisChannels(stereo.data(), 20u) == 0u);  // truncated head
  const uint8_t riff[64] = {'R', 'I', 'F', 'F'};
  assert(fvp::VorbisChannels(riff, sizeof(riff)) == 0u);
  auto continued = mono;
  continued[5] = 0x00u;  // not a beginning-of-stream page
  assert(fvp::VorbisChannels(continued.data(), continued.size()) == 0u);
  auto other = mono;
  other[28] = 0x03u;  // a comment packet, not identification
  assert(fvp::VorbisChannels(other.data(), other.size()) == 0u);
}

// The resource name decides what is a voice line, whatever its channels.
void TestVoiceResourceName() {
  const auto is_voice = [](const char* name) {
    return fvp::IsVoiceResourceName(name, std::strlen(name) + 1u);
  };
  assert(is_voice("voice/02000750"));
  assert(is_voice("VOICE/02000750"));
  assert(is_voice("voice\\02000750"));
  assert(is_voice("data/voice/02000750"));
  assert(!is_voice("se/02000750"));
  assert(!is_voice("bgm/voice"));      // `voice` is the entry, not a directory
  assert(!is_voice("voice/"));         // no entry after it
  assert(!is_voice("voices/02000750"));
  assert(!is_voice("myvoice/02000750"));
  assert(!is_voice("voice"));
  assert(!is_voice(""));
  assert(!fvp::IsVoiceResourceName(nullptr, 16u));
  // Bounded: only the first `name_bytes` count.
  assert(!fvp::IsVoiceResourceName("voice/02000750", 6u));
  assert(fvp::IsVoiceResourceName("voice/02000750", 7u));
}

}  // namespace

int main() {
  TestHcb();
  TestVorbis();
  TestVoiceResourceName();
  std::printf("fvp_format_test ok\n");
  return 0;
}
