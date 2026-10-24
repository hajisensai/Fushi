// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <windows.h>

#include <cassert>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "../hook/adapters/knife_core.h"
#include "../hook/adapters/knife_profile.h"

namespace knife = fushi_voice_hook::knife;

namespace {

void PutLe32(std::vector<uint8_t>* out, uint32_t v) {
  for (int i = 0; i < 4; ++i) out->push_back(static_cast<uint8_t>(v >> (8 * i)));
}

void PutBe32(std::vector<uint8_t>* out, uint32_t v) {
  for (int i = 3; i >= 0; --i) out->push_back(static_cast<uint8_t>(v >> (8 * i)));
}

// A synthetic Nintendo Opus file in knife's layout (codec.rs decode_nopus):
// 0x20-byte header chunk, then the data chunk of size/final_range/packet
// records. Payload bytes are arbitrary - remuxing never decodes them.
std::vector<uint8_t> MakeNopus(uint8_t channels,
                               const std::vector<std::vector<uint8_t>>& packets) {
  std::vector<uint8_t> out;
  PutLe32(&out, knife::kNopusHeaderMagic);
  PutLe32(&out, 0x18);
  out.push_back(0);
  out.push_back(channels);
  out.push_back(0);
  out.push_back(0);
  PutLe32(&out, 48000);
  PutLe32(&out, 0x20);  // data chunk offset
  PutLe32(&out, 0);
  PutLe32(&out, 0);
  PutLe32(&out, 120);  // pre-skip
  assert(out.size() == 0x20);
  std::vector<uint8_t> body;
  for (const auto& packet : packets) {
    PutBe32(&body, static_cast<uint32_t>(packet.size()));
    PutBe32(&body, 0);  // final range
    body.insert(body.end(), packet.begin(), packet.end());
  }
  PutLe32(&out, knife::kNopusDataMagic);
  PutLe32(&out, static_cast<uint32_t>(body.size()));
  out.insert(out.end(), body.begin(), body.end());
  return out;
}

struct OggPage {
  uint8_t flags = 0;
  uint64_t granule = 0;
  uint32_t sequence = 0;
  std::vector<std::vector<uint8_t>> packets;
};

uint32_t Le32(const uint8_t* p) { return knife::ReadLe32(p); }

// Parses [ogg] back into pages, verifying every page CRC and that each page
// ends on a packet boundary (the remuxer never splits packets).
std::vector<OggPage> ParseOgg(const std::vector<uint8_t>& ogg, uint32_t serial) {
  std::vector<OggPage> pages;
  size_t at = 0;
  while (at < ogg.size()) {
    assert(ogg.size() - at >= 27);
    assert(std::memcmp(ogg.data() + at, "OggS", 4) == 0);
    assert(ogg[at + 4] == 0);
    assert(Le32(ogg.data() + at + 14) == serial);
    const uint8_t segments = ogg[at + 26];
    size_t body = 0;
    for (int i = 0; i < segments; ++i) body += ogg[at + 27 + i];
    const size_t page_bytes = 27 + segments + body;
    assert(at + page_bytes <= ogg.size());
    uint32_t crc = 0;
    for (size_t i = 0; i < page_bytes; ++i) {
      crc = knife::OggCrcUpdate(
          crc, i >= 22 && i < 26 ? 0 : ogg[at + i]);
    }
    assert(crc == Le32(ogg.data() + at + 22));
    OggPage page;
    page.flags = ogg[at + 5];
    page.granule = static_cast<uint64_t>(Le32(ogg.data() + at + 6)) |
                   (static_cast<uint64_t>(Le32(ogg.data() + at + 10)) << 32);
    page.sequence = Le32(ogg.data() + at + 18);
    size_t data = at + 27 + segments;
    std::vector<uint8_t> packet;
    for (int i = 0; i < segments; ++i) {
      const uint8_t lace = ogg[at + 27 + i];
      packet.insert(packet.end(), ogg.begin() + data, ogg.begin() + data + lace);
      data += lace;
      if (lace < 255) {
        page.packets.push_back(packet);
        packet.clear();
      }
    }
    assert(packet.empty());
    pages.push_back(page);
    at += page_bytes;
  }
  return pages;
}

void TestPacketSamples() {
  // config 19 = CELT 20 ms, code 0: one frame.
  const uint8_t celt20[] = {static_cast<uint8_t>(19 << 3), 0xAA};
  assert(knife::OpusPacketSamples(celt20, sizeof(celt20)) == 960);
  // config 1 = SILK NB 20 ms, code 1: two frames.
  const uint8_t silk20x2[] = {static_cast<uint8_t>((1 << 3) | 1), 0};
  assert(knife::OpusPacketSamples(silk20x2, sizeof(silk20x2)) == 1920);
  // config 12 = hybrid 10 ms, code 2: two frames.
  const uint8_t hybrid10x2[] = {static_cast<uint8_t>((12 << 3) | 2), 0};
  assert(knife::OpusPacketSamples(hybrid10x2, sizeof(hybrid10x2)) == 960);
  // config 16 = CELT 2.5 ms, code 3 with 4 frames.
  const uint8_t celt25x4[] = {static_cast<uint8_t>((16 << 3) | 3), 4};
  assert(knife::OpusPacketSamples(celt25x4, sizeof(celt25x4)) == 480);
  // code 3 without its frame-count byte, zero frames, > 120 ms: malformed.
  const uint8_t truncated[] = {static_cast<uint8_t>((16 << 3) | 3)};
  assert(knife::OpusPacketSamples(truncated, sizeof(truncated)) == 0);
  const uint8_t zero_frames[] = {static_cast<uint8_t>((19 << 3) | 3), 0};
  assert(knife::OpusPacketSamples(zero_frames, sizeof(zero_frames)) == 0);
  const uint8_t too_long[] = {static_cast<uint8_t>((3 << 3) | 3), 3};  // 3x60ms
  assert(knife::OpusPacketSamples(too_long, sizeof(too_long)) == 0);
  assert(knife::OpusPacketSamples(nullptr, 0) == 0);
}

void TestRemuxRoundTrip() {
  std::vector<std::vector<uint8_t>> packets;
  for (int i = 0; i < 300; ++i) {
    // Mixed sizes, including exact multiples of 255 (needs a 0 lace) and
    // packets larger than one lace.
    const size_t size = i % 7 == 0 ? 510 : 40 + (i * 37) % 300;
    std::vector<uint8_t> packet(size, static_cast<uint8_t>(i));
    packet[0] = static_cast<uint8_t>(19 << 3);  // CELT 20 ms, 1 frame
    packets.push_back(packet);
  }
  const std::vector<uint8_t> nopus = MakeNopus(1, packets);
  std::vector<uint8_t> ogg;
  assert(knife::RemuxNintendoOpusToOgg(nopus.data(), nopus.size(), 77, &ogg));
  const std::vector<OggPage> pages = ParseOgg(ogg, 77);
  assert(pages.size() >= 4);
  // BOS page: OpusHead only.
  assert(pages[0].flags == 0x02 && pages[0].granule == 0);
  assert(pages[0].packets.size() == 1);
  const std::vector<uint8_t>& head = pages[0].packets[0];
  assert(head.size() == 19 && std::memcmp(head.data(), "OpusHead", 8) == 0);
  assert(head[8] == 1 && head[9] == 1);                   // version, channels
  assert((head[10] | (head[11] << 8)) == 120);             // pre-skip
  assert(Le32(head.data() + 12) == 48000 && head[18] == 0);  // rate, family 0
  assert(pages[1].packets.size() == 1 &&
         std::memcmp(pages[1].packets[0].data(), "OpusTags", 8) == 0);
  // Audio packets come back byte-identical, in order, with running granules.
  std::vector<std::vector<uint8_t>> audio;
  uint64_t expected_granule = 0;
  for (size_t p = 2; p < pages.size(); ++p) {
    assert(pages[p].sequence == p);
    for (const auto& packet : pages[p].packets) audio.push_back(packet);
    expected_granule = 960ull * audio.size();
    assert(pages[p].granule == expected_granule);
    assert((pages[p].flags & 0x04) == (p + 1 == pages.size() ? 0x04 : 0));
  }
  assert(audio == packets);
  assert(expected_granule == 960ull * 300);
}

void TestRemuxRejects() {
  std::vector<uint8_t> ogg;
  const std::vector<uint8_t> one = {static_cast<uint8_t>(19 << 3), 1, 2};
  std::vector<uint8_t> nopus = MakeNopus(1, {one});
  assert(knife::RemuxNintendoOpusToOgg(nopus.data(), nopus.size(), 1, &ogg));
  // Not Nintendo Opus (an Ogg file, wrong magic).
  std::vector<uint8_t> bad = nopus;
  bad[3] = 0x00;
  assert(!knife::RemuxNintendoOpusToOgg(bad.data(), bad.size(), 1, &ogg));
  // More channels than mapping family 0 allows.
  std::vector<uint8_t> surround = MakeNopus(6, {one});
  assert(!knife::RemuxNintendoOpusToOgg(surround.data(), surround.size(), 1, &ogg));
  // A record that runs past the data chunk.
  std::vector<uint8_t> overrun = nopus;
  overrun[0x28 + 3] = 0x40;
  assert(!knife::RemuxNintendoOpusToOgg(overrun.data(), overrun.size(), 1, &ogg));
  // A malformed packet (zero frames) is not silently remuxed.
  const std::vector<uint8_t> zero = {static_cast<uint8_t>((19 << 3) | 3), 0};
  std::vector<uint8_t> malformed = MakeNopus(1, {one, zero});
  assert(!knife::RemuxNintendoOpusToOgg(malformed.data(), malformed.size(), 1, &ogg));
  // No packets at all.
  std::vector<uint8_t> empty = MakeNopus(1, {});
  assert(!knife::RemuxNintendoOpusToOgg(empty.data(), empty.size(), 1, &ogg));
  assert(!knife::RemuxNintendoOpusToOgg(nopus.data(), 16, 1, &ogg));
  // 0x1E is not part of the 16-bit pre-skip; some titles store a value there.
  std::vector<uint8_t> tagged = nopus;
  tagged[0x1E] = 0x34;
  tagged[0x1F] = 0x12;
  assert(knife::RemuxNintendoOpusToOgg(tagged.data(), tagged.size(), 1, &ogg));
  assert(ogg.size() > 47 && ogg[28 + 10] == 120 && ogg[28 + 11] == 0);
}

void WriteBytes(const std::wstring& path, const std::vector<uint8_t>& bytes) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  DWORD written = 0;
  WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written,
            nullptr);
  CloseHandle(file);
}

// The shared KernelBase file broker is enabled for knife only through this
// layout check, so other engines' layouts must fail it.
void TestAssetsLayout() {
  wchar_t temp[MAX_PATH] = {};
  GetTempPathW(MAX_PATH, temp);
  const std::wstring root = std::wstring(temp) + L"fushi_knife_layout_test_" +
                            std::to_wstring(GetCurrentProcessId());
  const std::wstring assets = root + L"\\assets";
  const std::wstring stream = assets + L"\\stream";
  CreateDirectoryW(root.c_str(), nullptr);
  CreateDirectoryW(assets.c_str(), nullptr);
  CreateDirectoryW(stream.c_str(), nullptr);
  const std::vector<uint8_t> one = {static_cast<uint8_t>(19 << 3), 1, 2};
  const std::wstring voice = stream + L"\\A00_01_00_0000_0.opus";
  const std::wstring scenario = assets + L"\\allscr.mrg";
  const std::wstring packed = stream + L"\\voice.hfa";

  // Only stream/ with Nintendo Opus, no scenario archive.
  WriteBytes(voice, MakeNopus(1, {one}));
  assert(!knife::AssetsLookLikeKnife(assets));
  // Scenario archive + stream/ holding Ogg Opus (another engine's stream/).
  WriteBytes(scenario, {0});
  WriteBytes(voice, {'O', 'g', 'g', 'S', 0, 2});
  assert(!knife::AssetsLookLikeKnife(assets));
  // HuneX-style packed audio instead of loose .opus files.
  DeleteFileW(voice.c_str());
  WriteBytes(packed, {'H', 'U', 'N', 'E', 'X'});
  assert(!knife::AssetsLookLikeKnife(assets));
  // knife's layout.
  WriteBytes(voice, MakeNopus(1, {one}));
  assert(knife::AssetsLookLikeKnife(assets));

  DeleteFileW(voice.c_str());
  DeleteFileW(packed.c_str());
  DeleteFileW(scenario.c_str());
  RemoveDirectoryW(stream.c_str());
  RemoveDirectoryW(assets.c_str());
  RemoveDirectoryW(root.c_str());
}

void TestVoicePaths() {
  // knife joins "stream/<name>.opus" onto the Windows assets path.
  assert(knife::IsVoiceStreamPath(
      L"E:\\game\\knife\\assets\\stream/A00_01_00_0000_0.opus"));
  assert(knife::IsVoiceStreamPath(
      L"E:\\game\\knife\\assets\\stream\\M02_10_01_0003_1.opus"));
  assert(knife::IsVoiceStreamPath(
      L"\\\\?\\E:\\game\\assets\\STREAM\\b03_01_0B_0012_0.OPUS"));
  // BGM / songs / staff roll share the folder.
  assert(!knife::IsVoiceStreamPath(L"E:\\g\\assets\\stream/MOON01_BGM01.opus"));
  assert(!knife::IsVoiceStreamPath(L"E:\\g\\assets\\stream/MOON01_SONG1.opus"));
  assert(!knife::IsVoiceStreamPath(L"E:\\g\\assets\\stream/arcstaffroll.opus"));
  assert(!knife::IsVoiceStreamPath(L"E:\\g\\assets\\stream/15aEDSample.opus"));
  // Same name outside stream/, another extension, the hook's own dump.
  assert(!knife::IsVoiceStreamPath(L"E:\\g\\assets\\movie\\A00_01_00_0000_0.opus"));
  assert(!knife::IsVoiceStreamPath(L"E:\\g\\assets\\stream\\A00_01_00_0000_0.ogg"));
  assert(!knife::IsVoiceStreamPath(L"E:\\g\\assets\\upstream\\A00_01_00_0000_0.opus"));
  assert(!knife::IsVoiceStreamPath(
      L"C:\\Temp\\fushi_gal_voice\\123_fushi_textseq4_A00_01_00_0000_0.opus"));
  assert(!knife::IsVoiceStreamPath(L"stream\\A00_0.opus"));
  assert(!knife::IsVoiceStreamPath(nullptr));
  assert(std::wstring(knife::PathBaseName(L"a\\b/c.opus")) == L"c.opus");
}

void TestVoiceSelection() {
  // The voice read in the same script step as the text wins over an older
  // replay voice; nothing after the text or outside the window qualifies.
  assert(knife::SelectVoiceForText({1000, 9950, 9990}, 10000) == 2);
  assert(knife::SelectVoiceForText({9990, 9950}, 10000) == 0);
  assert(knife::SelectVoiceForText({8000}, 10000) == -1);
  assert(knife::SelectVoiceForText({10001}, 10000) == -1);
  assert(knife::SelectVoiceForText({}, 10000) == -1);
  assert(knife::SelectVoiceForText({9000}, 10000) == 0);  // window edge
}

void TestLaunchOptions() {
  const knife::LaunchOptions ini = knife::ParseIni(
      L"\xFEFF; comment\r\nassets-dir = assets\r\n# text-websocket = x:1\r\n"
      L"text-websocket = 127.0.0.1:6677\r\nlanguage =\r\nskip-intro = true");
  assert(ini.assets_dir == L"assets");
  assert(ini.text_websocket == L"127.0.0.1:6677");
  const knife::LaunchOptions unset = knife::ParseIni(L"text-websocket =\n");
  assert(unset.text_websocket.empty());

  const auto args = knife::SplitCommandLine(
      L"\"E:\\My Games\\knife.exe\" -a \"D:\\rom fs\" --text-websocket=0.0.0.0:7000");
  assert(args.size() == 4 && args[0] == L"E:\\My Games\\knife.exe");
  const knife::LaunchOptions cli = knife::ApplyCommandLine(ini, args);
  assert(cli.assets_dir == L"D:\\rom fs");
  assert(cli.text_websocket == L"0.0.0.0:7000");
  const knife::LaunchOptions short_attached = knife::ApplyCommandLine(
      {}, knife::SplitCommandLine(L"knife.exe -t127.0.0.1:1 --skip-intro"));
  assert(short_attached.text_websocket == L"127.0.0.1:1");
  const knife::LaunchOptions spaced = knife::ApplyCommandLine(
      {}, knife::SplitCommandLine(L"knife.exe --text-websocket [::1]:6677"));
  assert(spaced.text_websocket == L"[::1]:6677");
  // The executable itself is never parsed as an option.
  assert(knife::ApplyCommandLine({}, knife::SplitCommandLine(L"-tx:1"))
             .text_websocket.empty());

  std::wstring host;
  uint16_t port = 0;
  assert(knife::SplitHostPort(L"127.0.0.1:6677", &host, &port));
  assert(host == L"127.0.0.1" && port == 6677);
  assert(knife::SplitHostPort(L"0.0.0.0:7000", &host, &port));
  assert(host == L"127.0.0.1" && port == 7000);
  assert(knife::SplitHostPort(L"[::1]:6677", &host, &port) && host == L"::1");
  assert(!knife::SplitHostPort(L"127.0.0.1", &host, &port));
  assert(!knife::SplitHostPort(L"127.0.0.1:0", &host, &port));
  assert(!knife::SplitHostPort(L"127.0.0.1:70000", &host, &port));
  assert(!knife::SplitHostPort(L":6677", &host, &port));

  assert(knife::ResolveAgainst(L"E:\\g", L"assets") == L"E:\\g\\assets");
  assert(knife::ResolveAgainst(L"E:\\g", L"D:\\romfs") == L"D:\\romfs");
  assert(knife::ResolveAgainst(L"E:\\g", L"\\romfs") == L"E:\\romfs");
}

}  // namespace

int main() {
  TestPacketSamples();
  TestRemuxRoundTrip();
  TestRemuxRejects();
  TestVoicePaths();
  TestVoiceSelection();
  TestLaunchOptions();
  TestAssetsLayout();
  return 0;
}
