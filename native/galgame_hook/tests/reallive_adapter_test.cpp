// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>
#include <set>
#include <string>
#include <vector>

#include "../hook/adapters/reallive_profile.h"
#include "../hook/visual_arts_ovk.h"

namespace rl = fushi_voice_hook::reallive;

namespace {
void PutLe32(std::vector<uint8_t>* bytes, size_t at, uint32_t value) {
  std::memcpy(bytes->data() + at, &value, sizeof(value));
}

void AppendAscii(std::vector<uint8_t>* out, const char* text) {
  for (const char* p = text; *p != 0; ++p) out->push_back(static_cast<uint8_t>(*p));
  out->push_back(0);
}

void AppendWide(std::vector<uint8_t>* out, const char* text) {
  for (const char* p = text; *p != 0; ++p) {
    out->push_back(static_cast<uint8_t>(*p));
    out->push_back(0);
  }
  out->push_back(0);
  out->push_back(0);
}

std::vector<uint8_t> Filler(size_t bytes) {
  std::vector<uint8_t> out(bytes);
  for (size_t i = 0; i < bytes; ++i) out[i] = static_cast<uint8_t>((i * 131u) ^ 0x5au);
  return out;
}

uint32_t ScanInChunks(const std::vector<uint8_t>& image, size_t chunk) {
  rl::ImageSignatureScanner scanner;
  for (size_t at = 0; at < image.size(); at += chunk) {
    const size_t n = image.size() - at < chunk ? image.size() - at : chunk;
    scanner.Feed(image.data() + at, n);
  }
  return scanner.markers();
}

bool MatchesImage(const std::vector<uint8_t>& image) {
  rl::IdentityInputs in;
  in.image_measured = true;
  in.image_markers = ScanInChunks(image, 4096);
  return fushi_voice_hook::MatchesRealliveProfile(in);
}

// 形似 RealLive 系 exe（含 Kinetic Novel 改名版）的字符串表：ASCII 配置/剧本名。
std::vector<uint8_t> RealliveLikeImage() {
  std::vector<uint8_t> image = Filler(9000);
  AppendAscii(&image, "Gameexe.ini");
  AppendAscii(&image, "Seen%04d.txt");
  AppendAscii(&image, "#KOEFILE_MOD");
  std::vector<uint8_t> tail = Filler(5000);
  image.insert(image.end(), tail.begin(), tail.end());
  return image;
}

// 形似 SiglusEngine exe：同出 VisualArt's，以 UTF-16 带 Gameexe.ini / Gameexe.dat。
std::vector<uint8_t> SiglusLikeImage() {
  std::vector<uint8_t> image = Filler(7000);
  AppendWide(&image, "Gameexe.ini");
  AppendWide(&image, "Gameexe.dat");
  AppendWide(&image, "SiglusEngine");
  return image;
}

void TestImageSignature() {
  const std::vector<uint8_t> reallive = RealliveLikeImage();
  const uint32_t markers = ScanInChunks(reallive, 4096);
  assert((markers & rl::kImageMarkerGameexeIni) != 0);
  assert((markers & rl::kImageMarkerSeenScript) != 0);
  assert((markers & rl::kImageMarkerKoeConfig) != 0);
  assert((markers & rl::kImageMarkerSiglusVeto) == 0);
  assert(MatchesImage(reallive));

  // 任意分块（含 1 字节、跨针边界）都得到同一组标志。
  std::set<uint32_t> seen;
  for (size_t chunk : {1u, 3u, 7u, 31u, 32u, 33u, 4096u, 9005u, 100000u}) {
    seen.insert(ScanInChunks(reallive, chunk));
  }
  assert(seen.size() == 1 && *seen.begin() == markers);

  // 大小写不敏感：部分 RealLive 构建写成全大写。
  std::vector<uint8_t> upper = Filler(100);
  AppendAscii(&upper, "GAMEEXE.INI");
  AppendAscii(&upper, "SEEN.TXT");
  assert(MatchesImage(upper));

  // 只有配置、没有剧本名 → 不够。
  std::vector<uint8_t> config_only = Filler(100);
  AppendAscii(&config_only, "Gameexe.ini");
  assert(!MatchesImage(config_only));

  // 负向：SiglusEngine（UTF-16 Gameexe.ini 不能算 ASCII 配置名，且 Siglus 标志一票否决）。
  const std::vector<uint8_t> siglus = SiglusLikeImage();
  const uint32_t siglus_markers = ScanInChunks(siglus, 4096);
  assert((siglus_markers & rl::kImageMarkerGameexeIni) == 0);
  assert((siglus_markers & rl::kImageMarkerSiglusVeto) != 0);
  assert(!MatchesImage(siglus));

  // 负向：即便某个 Siglus 构建同时带有 RealLive 风格的 ASCII 名，也被否决。
  std::vector<uint8_t> mixed = RealliveLikeImage();
  AppendAscii(&mixed, "Scene.pck");
  assert(!MatchesImage(mixed));

  // 负向：KiriKiri 风格字符串表。
  std::vector<uint8_t> kirikiri = Filler(3000);
  AppendAscii(&kirikiri, "startup.tjs");
  AppendAscii(&kirikiri, "data.xp3");
  AppendWide(&kirikiri, "TVP(KIRIKIRI) Z core");
  assert(!MatchesImage(kirikiri));

  // 未测量的映像不得当作匹配。
  rl::IdentityInputs unmeasured;
  unmeasured.image_markers = markers;
  assert(!fushi_voice_hook::MatchesRealliveProfile(unmeasured));
  assert(!fushi_voice_hook::MatchesRealliveProfile(rl::IdentityInputs{}));
}

void TestDirectorySignature() {
  auto files = [](std::set<std::wstring> names) {
    return [names](const std::wstring&, const wchar_t* name) {
      return names.count(name) != 0;
    };
  };
  const std::wstring dir = L"C:\\Games\\Title";
  assert(rl::DirectoryLooksLikeReallive(dir, files({L"Gameexe.ini", L"Seen.txt"})));
  assert(!rl::DirectoryLooksLikeReallive(dir, files({L"Gameexe.ini"})));
  assert(!rl::DirectoryLooksLikeReallive(dir, files({L"Seen.txt"})));
  // Siglus 目录只有 Gameexe.dat + Scene.pck。
  assert(!rl::DirectoryLooksLikeReallive(dir, files({L"Gameexe.dat", L"Scene.pck"})));
  assert(!rl::DirectoryLooksLikeReallive(L"", files({L"Gameexe.ini", L"Seen.txt"})));

  rl::IdentityInputs in;
  in.reallive_directory = true;
  assert(fushi_voice_hook::MatchesRealliveProfile(in));
  // Siglus 目录或 Siglus exe 一票否决。
  in.siglus_directory = true;
  assert(!fushi_voice_hook::MatchesRealliveProfile(in));
  in.siglus_directory = false;
  in.siglus_executable = true;
  assert(!fushi_voice_hook::MatchesRealliveProfile(in));
  // 映像里有 Siglus 标志时，目录签名也不能翻案。
  in.siglus_executable = false;
  in.image_measured = true;
  in.image_markers = rl::kImageMarkerSiglusVeto;
  assert(!fushi_voice_hook::MatchesRealliveProfile(in));
}

void TestSharedOvkContainer() {
  std::vector<uint8_t> archive(20, 0);
  PutLe32(&archive, 0, 1);
  PutLe32(&archive, 4, 31);
  PutLe32(&archive, 8, 20);
  PutLe32(&archive, 12, 7);
  PutLe32(&archive, 16, 250);
  fushi_voice_hook::visual_arts::OvkEntry entry;
  assert(fushi_voice_hook::visual_arts::FindEntryAtOffset(
      archive.data(), archive.size(), 51, 20, &entry));
  assert(entry.byte_len == 31 && entry.member_id == 7 &&
         entry.sample_count == 250);
}
}  // namespace

int main() {
  TestImageSignature();
  TestDirectorySignature();
  TestSharedOvkContainer();
  return 0;
}
