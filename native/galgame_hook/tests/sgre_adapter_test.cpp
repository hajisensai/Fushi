#include <windows.h>

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "../hook/adapters/sgre_lookup.h"
#include "../hook/adapters/sgre_profile.h"
#include "../hook/adapters/sgre_voice_archive.h"
#include "../hook/xaudio_resource_dispatch.h"
#include "../hook/xwma_resource.h"

namespace {

int g_dispatch_calls = 0;

bool FakeOtherEngineHandler(
    const fushi_voice_hook::XAudioCompressedResourceSubmission&) {
  ++g_dispatch_calls;
  return true;
}

std::vector<uint8_t> MakeArchive(const std::vector<uint8_t>& payload,
                                 const uint32_t dpds[2]) {
  std::vector<uint8_t> archive(18 + 2 + 8 + payload.size(), 0);
  archive[0] = 0x61;
  archive[1] = 0x01;
  std::memcpy(archive.data() + 20, dpds, 8);
  std::memcpy(archive.data() + 28, payload.data(), payload.size());
  return archive;
}

}  // namespace

int main() {
  assert(fushi_voice_hook::MatchesSgreExecutableHash(
      fushi_voice_hook::kSgreExecutableSha256.data(),
      fushi_voice_hook::kSgreExecutableSha256.size()));
  auto wrong_hash = fushi_voice_hook::kSgreExecutableSha256;
  wrong_hash[0] ^= 0xff;
  assert(!fushi_voice_hook::MatchesSgreExecutableHash(wrong_hash.data(),
                                                      wrong_hash.size()));
  assert(!fushi_voice_hook::MatchesSgreExecutableHash(nullptr, 0));

  // The admitted build renders scenario text in a 1920x1080 design surface.
  // Geometry from TextRender is relative to the dialogue origin and scales to
  // the real client instead of assuming a particular Windows DPI mode.
  const fushi_voice_hook::SgreLookupGlyphGeometry glyphs[] = {
      {0.0f, 44.0f, 52.0f, 0},
      {44.0f, 44.0f, 52.0f, 0},
      {0.0f, 44.0f, 52.0f, 1},
  };
  fushi_voice_hook::SgreLookupRect rect;
  assert(fushi_voice_hook::SgreLookupRectForGlyph(glyphs[0], 56.0f, 1920, 1080,
                                                  &rect));
  assert(rect.x == 320 && rect.y == 830 && rect.width == 44);
  assert(fushi_voice_hook::FindSgreLookupGlyph(glyphs, 3, 56.0f, 1920, 1080,
                                               365, 840, &rect) == 1);
  assert(fushi_voice_hook::FindSgreLookupGlyph(glyphs, 3, 56.0f, 3840, 2160,
                                               650, 1670, &rect) == 0);
  // Non-16:9 clients keep the 1920x1080 render surface aspect-fitted. The
  // black-bar offset must be included in cursor hit testing.
  assert(fushi_voice_hook::SgreLookupRectForGlyph(glyphs[0], 56.0f, 2622, 1206,
                                                  &rect));
  assert(rect.x == 596 && rect.y == 927 && rect.width == 49);
  assert(fushi_voice_hook::FindSgreLookupGlyph(glyphs, 3, 56.0f, 2622, 1206,
                                               600, 940, &rect) == 0);
  assert(fushi_voice_hook::FindSgreLookupGlyph(glyphs, 3, 56.0f, 1920, 1080,
                                               320, 890, &rect) == 2);
  assert(fushi_voice_hook::FindSgreLookupGlyph(glyphs, 3, 56.0f, 1920, 1080,
                                               100, 100, &rect) == -1);
  auto invalid = glyphs[0];
  invalid.width = -1.0f;
  assert(!fushi_voice_hook::IsSaneSgreLookupGlyph(invalid));

  // SGRE continuously emits other TextRender surfaces after a valid scenario
  // layout. Invalid, short and genuinely mismatched captures are noise and
  // must retain the visible line. A wrapped line may contain more text than
  // the current visual row has glyphs; mapping that captured prefix is valid.
  using fushi_voice_hook::SgreLookupActiveUpdate;
  assert(fushi_voice_hook::ResolveSgreLookupActiveUpdate(false, 0, 0, 0) ==
         SgreLookupActiveUpdate::kIgnore);
  assert(fushi_voice_hook::ResolveSgreLookupActiveUpdate(true, 8, 8, 8) ==
         SgreLookupActiveUpdate::kReplace);
  assert(fushi_voice_hook::ResolveSgreLookupActiveUpdate(true, 8, 7, 8) ==
         SgreLookupActiveUpdate::kIgnore);
  assert(fushi_voice_hook::ResolveSgreLookupActiveUpdate(true, 37, 37, 32) ==
         SgreLookupActiveUpdate::kIgnore);
  assert(fushi_voice_hook::ResolveSgreLookupActiveUpdate(true, 37, 32, 32) ==
         SgreLookupActiveUpdate::kReplace);
  assert(fushi_voice_hook::ResolveSgreLookupActiveUpdate(true, 2, 2, 2) ==
         SgreLookupActiveUpdate::kIgnore);

  // Generic dispatch is inert until an explicitly matched engine registers a
  // handler. This is the cross-engine negative boundary: WMA by itself never
  // activates SGRE archive logic.
  fushi_voice_hook::XAudioCompressedResourceDispatch dispatch;
  fushi_voice_hook::XAudioCompressedResourceSubmission submission;
  assert(!dispatch.available());
  assert(!dispatch.Dispatch(submission));
  assert(g_dispatch_calls == 0);
  assert(dispatch.Register(&FakeOtherEngineHandler));
  assert(!dispatch.Register(&FakeOtherEngineHandler));
  assert(dispatch.Dispatch(submission));
  assert(g_dispatch_calls == 1);
  dispatch.Unregister(&FakeOtherEngineHandler);
  assert(!dispatch.available());

  // A deliberately short synthetic submission remains valid when exact
  // voice_body membership and dpds identity prove it is a role voice. Duration
  // is not part of the classifier contract.
  std::vector<uint8_t> payload(256);
  for (size_t i = 0; i < payload.size(); ++i) {
    payload[i] = static_cast<uint8_t>(i);
  }
  const uint32_t dpds[2] = {2048, 4096};
  std::vector<uint8_t> archive_bytes = MakeArchive(payload, dpds);
  fushi_voice_hook::SgreVoiceArchiveView archive;
  archive.data = archive_bytes.data();
  archive.bytes = archive_bytes.size();
  fushi_voice_hook::SgreVoiceArchiveResourceParts parts;
  assert(fushi_voice_hook::FindSgreVoiceArchiveResourceParts(
      archive, payload.data(), payload.size(),
      reinterpret_cast<const uint8_t*>(dpds), 2, &parts));
  assert(parts.body_offset == 28);
  assert(parts.fmt == archive_bytes.data());
  assert(parts.dpds == archive_bytes.data() + 20);

  std::vector<uint8_t> xwma;
  assert(fushi_voice_hook::BuildXwmaResourceFromChunks(
      parts.fmt, parts.fmt_bytes, parts.dpds, parts.dpds_bytes,
      payload.data(), static_cast<uint32_t>(payload.size()), &xwma));
  assert(std::memcmp(xwma.data(), "RIFF", 4) == 0);
  assert(std::memcmp(xwma.data() + 8, "XWMA", 4) == 0);
  assert(std::memcmp(xwma.data() + xwma.size() - payload.size(),
                     payload.data(), payload.size()) == 0);

  uint32_t wrong_dpds[2] = {2048, 4097};
  assert(!fushi_voice_hook::FindSgreVoiceArchiveResourceParts(
      archive, payload.data(), payload.size(),
      reinterpret_cast<const uint8_t*>(wrong_dpds), 2, &parts));
  archive_bytes[0] = 0x62;
  assert(!fushi_voice_hook::FindSgreVoiceArchiveResourceParts(
      archive, payload.data(), payload.size(),
      reinterpret_cast<const uint8_t*>(dpds), 2, &parts));
  archive_bytes[0] = 0x61;
  archive_bytes[18] = 1;
  assert(!fushi_voice_hook::FindSgreVoiceArchiveResourceParts(
      archive, payload.data(), payload.size(),
      reinterpret_cast<const uint8_t*>(dpds), 2, &parts));
  return 0;
}
