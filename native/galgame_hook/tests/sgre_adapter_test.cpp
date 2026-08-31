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

void TestAnchorResolution() {
  using namespace fushi_voice_hook;

  // A measured digest identifies a consistency row only. It must not bypass
  // signature resolution or structural validation when no mapped image is
  // available.
  SgreImageView empty;
  const SgreAnchorSet known =
      ResolveSgreAnchors(kSgreExecutableSha256.data(),
                         kSgreExecutableSha256.size(), empty);
  assert(known.known_build && !known.complete());
  assert(!known.lookup_sensor_available());
  assert(!known.direct_input_shield_available());
  assert(known.text_draw.source == SgreAnchorSource::kSignatureMissing);
  assert(known.scenario_text_vtable.source ==
         SgreAnchorSource::kSignatureMissing);
  assert(known.direct_input_mouse_device.source ==
         SgreAnchorSource::kSignatureMissing);
  assert(known.text_draw.rva == 0 && known.scenario_text_vtable.rva == 0 &&
         known.direct_input_mouse_device.rva == 0);

  // Unknown and unhashed builds take the same proof path. Published signatures
  // are non-empty, but an empty mapped image has no evidence to resolve.
  assert(kSgreTextDrawSignature.pattern != nullptr &&
         kSgreTextDrawSignature.pattern[0] != '\0');
  assert(kSgreScenarioTextVtableSignature.pattern != nullptr &&
         kSgreScenarioTextVtableSignature.pattern[0] != '\0');
  assert(kSgreScenarioTextVtableCorroborationSignature.pattern != nullptr &&
         kSgreScenarioTextVtableCorroborationSignature.pattern[0] != '\0');
  assert(kSgreDirectInputMouseDeviceSignature.pattern != nullptr &&
         kSgreDirectInputMouseDeviceSignature.pattern[0] != '\0');
  assert(kSgreDirectInputMouseDeviceCorroborationSignature.pattern != nullptr &&
         kSgreDirectInputMouseDeviceCorroborationSignature.pattern[0] != '\0');
  auto other_build = kSgreExecutableSha256;
  other_build[31] ^= 0x01;
  const SgreAnchorSet unknown =
      ResolveSgreAnchors(other_build.data(), other_build.size(), empty);
  assert(!unknown.known_build);
  assert(!unknown.lookup_sensor_available());
  assert(!unknown.direct_input_shield_available());
  assert(unknown.text_draw.source == SgreAnchorSource::kSignatureMissing);
  assert(unknown.scenario_text_vtable.source ==
         SgreAnchorSource::kSignatureMissing);
  assert(unknown.direct_input_mouse_device.source ==
         SgreAnchorSource::kSignatureMissing);
  assert(unknown.text_draw.rva == 0 && unknown.scenario_text_vtable.rva == 0 &&
         unknown.direct_input_mouse_device.rva == 0);
  // A failed hash (no digest at all) takes the same path as an unknown one.
  const SgreAnchorSet unhashed = ResolveSgreAnchors(nullptr, 0, empty);
  assert(!unhashed.known_build &&
         unhashed.text_draw.source == SgreAnchorSource::kSignatureMissing);

  // Pattern grammar: space separated hex pairs or "??" wildcards, nothing else.
  SgrePatternByte bytes[8];
  assert(ParseSgreSignaturePattern("48 8B ?? 24", bytes, 8) == 4);
  assert(bytes[0].value == 0x48 && !bytes[0].wildcard);
  assert(bytes[2].wildcard && bytes[3].value == 0x24 && !bytes[3].wildcard);
  assert(ParseSgreSignaturePattern("", bytes, 8) == 0);
  assert(ParseSgreSignaturePattern(nullptr, bytes, 8) == 0);
  assert(ParseSgreSignaturePattern("4G", bytes, 8) == 0);
  assert(ParseSgreSignaturePattern("48 8", bytes, 8) == 0);
  assert(ParseSgreSignaturePattern("488B", bytes, 8) == 0);
  assert(ParseSgreSignaturePattern("48 8B 00 00 00", bytes, 4) == 0);

  // Synthetic image: .text (code) / .rdata (read-only) / .data (writable).
  uint8_t text[0x80] = {};
  uint8_t rdata[0x40] = {};
  uint8_t data[0x40] = {};
  SgreImageView image;
  image.image_base = 0x10000000u;
  image.section_count = 3;
  std::memcpy(image.sections[0].name, ".text", 6);
  image.sections[0].rva = 0x1000;
  image.sections[0].size = sizeof(text);
  image.sections[0].bytes = text;
  image.sections[0].executable = true;
  std::memcpy(image.sections[1].name, ".rdata", 7);
  image.sections[1].rva = 0x2000;
  image.sections[1].size = sizeof(rdata);
  image.sections[1].bytes = rdata;
  std::memcpy(image.sections[2].name, ".data", 6);
  image.sections[2].rva = 0x3000;
  image.sections[2].size = sizeof(data);
  image.sections[2].bytes = data;
  image.sections[2].writable = true;

  // Function prologue at .text+0x10.
  const uint8_t prologue[] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x57};
  std::memcpy(text + 0x10, prologue, sizeof(prologue));
  const SgreAnchorSignature code_sig = {"48 89 5C 24 ?? 57", ".text",
                                        SgreAnchorKind::kCode, 0, -1, 0};
  SgreResolvedAnchor code = ResolveSgreAnchorBySignature(code_sig, image);
  assert(code.source == SgreAnchorSource::kSignature && code.rva == 0x1010u);
  assert(code.resolved());
  // anchor_offset shifts the result relative to the match.
  const SgreAnchorSignature offset_sig = {"48 89 5C 24 ?? 57", ".text",
                                          SgreAnchorKind::kCode, -0x10, -1, 0};
  code = ResolveSgreAnchorBySignature(offset_sig, image);
  assert(code.source == SgreAnchorSource::kSignature && code.rva == 0x1000u);
  // Nothing matching: missing. Unknown section: missing too.
  const SgreAnchorSignature absent_sig = {"90 90 90 90 90 90", ".text",
                                          SgreAnchorKind::kCode, 0, -1, 0};
  assert(ResolveSgreAnchorBySignature(absent_sig, image).source ==
         SgreAnchorSource::kSignatureMissing);
  const SgreAnchorSignature no_section_sig = {"48 89 5C 24 ?? 57", ".code",
                                              SgreAnchorKind::kCode, 0, -1, 0};
  assert(ResolveSgreAnchorBySignature(no_section_sig, image).source ==
         SgreAnchorSource::kSignatureMissing);
  // Malformed text is reported, not treated as "no match".
  const SgreAnchorSignature bad_sig = {"48 ZZ", ".text", SgreAnchorKind::kCode,
                                       0, -1, 0};
  assert(ResolveSgreAnchorBySignature(bad_sig, image).source ==
         SgreAnchorSource::kSignatureInvalid);
  // A RIP contract whose displacement does not fit the instruction is invalid.
  const SgreAnchorSignature bad_rip_sig = {"48 89 5C 24 ?? 57", ".text",
                                           SgreAnchorKind::kCode, 0, 3, 6};
  assert(ResolveSgreAnchorBySignature(bad_rip_sig, image).source ==
         SgreAnchorSource::kSignatureInvalid);
  // A second copy of the prologue makes the signature ambiguous: rejected.
  std::memcpy(text + 0x60, prologue, sizeof(prologue));
  assert(ResolveSgreAnchorBySignature(code_sig, image).source ==
         SgreAnchorSource::kSignatureAmbiguous);
  std::memset(text + 0x60, 0, sizeof(prologue));
  // A unique match that lands outside an executable section is not code.
  std::memcpy(data + 0x08, prologue, sizeof(prologue));
  const SgreAnchorSignature data_code_sig = {"48 89 5C 24 ?? 57", ".data",
                                             SgreAnchorKind::kCode, 0, -1, 0};
  assert(ResolveSgreAnchorBySignature(data_code_sig, image).source ==
         SgreAnchorSource::kStructureRejected);
  std::memset(data + 0x08, 0, sizeof(prologue));

  // Vtable located through the code that references it:
  //   lea rax, [rip+disp32]  (48 8D 05 disp32, 7 bytes) at .text+0x20.
  const uintptr_t vtable_rva = 0x2008;
  const int32_t vtable_disp =
      static_cast<int32_t>(vtable_rva) - static_cast<int32_t>(0x1020 + 7);
  text[0x20] = 0x48;
  text[0x21] = 0x8D;
  text[0x22] = 0x05;
  std::memcpy(text + 0x23, &vtable_disp, sizeof(vtable_disp));
  uintptr_t slot0 = image.image_base + 0x1010;  // first virtual points to code
  std::memcpy(rdata + 0x08, &slot0, sizeof(slot0));
  const SgreAnchorSignature vtable_sig = {"48 8D 05 ?? ?? ?? ??", ".text",
                                          SgreAnchorKind::kVtable, 0, 3, 7};
  SgreResolvedAnchor vtable = ResolveSgreAnchorBySignature(vtable_sig, image);
  assert(vtable.source == SgreAnchorSource::kSignature &&
         vtable.rva == vtable_rva);
  // Primitive vtable resolution validates aligned read-only storage. SGRE's
  // composite resolver separately cross-validates the consumed draw slot (4),
  // so unrelated slot 0 contents must not reject a compatible layout.
  slot0 = image.image_base + 0x3000;
  std::memcpy(rdata + 0x08, &slot0, sizeof(slot0));
  assert(ResolveSgreAnchorBySignature(vtable_sig, image).source ==
         SgreAnchorSource::kSignature);
  slot0 = 0;
  std::memcpy(rdata + 0x08, &slot0, sizeof(slot0));
  assert(ResolveSgreAnchorBySignature(vtable_sig, image).source ==
         SgreAnchorSource::kSignature);
  slot0 = image.image_base - 0x10;
  std::memcpy(rdata + 0x08, &slot0, sizeof(slot0));
  assert(ResolveSgreAnchorBySignature(vtable_sig, image).source ==
         SgreAnchorSource::kSignature);

  // Writable global (the mouse device slot) located through
  //   mov rax, [rip+disp32]  (48 8B 05 disp32, 7 bytes) at .text+0x30.
  const uintptr_t device_rva = 0x3010;
  const int32_t device_disp =
      static_cast<int32_t>(device_rva) - static_cast<int32_t>(0x1030 + 7);
  text[0x30] = 0x48;
  text[0x31] = 0x8B;
  text[0x32] = 0x05;
  std::memcpy(text + 0x33, &device_disp, sizeof(device_disp));
  const SgreAnchorSignature device_sig = {"48 8B 05 ?? ?? ?? ??", ".text",
                                          SgreAnchorKind::kWritableData, 0, 3,
                                          7};
  const SgreResolvedAnchor device =
      ResolveSgreAnchorBySignature(device_sig, image);
  assert(device.source == SgreAnchorSource::kSignature &&
         device.rva == device_rva);
  // Pointing the same instruction at read-only memory is rejected: a device
  // slot the game writes cannot live there.
  const int32_t rdata_disp =
      static_cast<int32_t>(0x2010) - static_cast<int32_t>(0x1030 + 7);
  std::memcpy(text + 0x33, &rdata_disp, sizeof(rdata_disp));
  assert(ResolveSgreAnchorBySignature(device_sig, image).source ==
         SgreAnchorSource::kStructureRejected);

  // This unrelated synthetic image does not satisfy the published SGRE
  // signatures, so resolution fails closed instead of falling back to an RVA.
  const SgreAnchorSet shipped =
      ResolveSgreAnchors(other_build.data(), other_build.size(), image);
  assert(!shipped.lookup_sensor_available() &&
          shipped.text_draw.source == SgreAnchorSource::kSignatureMissing);
  assert(std::strcmp(SgreAnchorSourceName(SgreAnchorSource::kSignatureMissing),
                     "signature_missing") == 0);
}

int main() {
  assert(fushi_voice_hook::MatchesSgreExecutableHash(
      fushi_voice_hook::kSgreExecutableSha256.data(),
      fushi_voice_hook::kSgreExecutableSha256.size()));
  auto wrong_hash = fushi_voice_hook::kSgreExecutableSha256;
  wrong_hash[0] ^= 0xff;
  assert(!fushi_voice_hook::MatchesSgreExecutableHash(wrong_hash.data(),
                                                      wrong_hash.size()));
  assert(!fushi_voice_hook::MatchesSgreExecutableHash(nullptr, 0));
  TestAnchorResolution();

  // BUG-1882 — SGRE polls c_dfDIMouse2 directly, so swallowing Win32 mouse
  // messages cannot stop the game from seeing the click. Pin the measured
  // build's mouse slot / ABI and the button-only release latch used by the
  // injected detour.
  assert(fushi_voice_hook::kSgreDirectInputMouseDeviceRva == 0xA96E18u);
  assert(fushi_voice_hook::kSgreDirectInputGetDeviceStateVtableIndex == 9u);
  uint8_t mouse_state[fushi_voice_hook::kSgreDirectInputMouseStateBytes] = {};
  mouse_state[0] = 0x11;   // lX bytes must survive unchanged.
  mouse_state[8] = 0x22;   // lZ bytes must survive unchanged.
  mouse_state[12] = 0x80;  // button 0 down.
  mouse_state[19] = 0x80;  // button 7 down.
  uint8_t latched = fushi_voice_hook::FilterSgreDirectInputMouseButtons(
      true, mouse_state, sizeof(mouse_state), 0);
  assert(latched == 0x81);
  assert(mouse_state[0] == 0x11 && mouse_state[8] == 0x22);
  assert(mouse_state[12] == 0 && mouse_state[19] == 0);

  // Popup is already gone but both physical buttons are still held: the same
  // down transaction remains invisible until each raw up is observed.
  mouse_state[12] = 0x80;
  mouse_state[19] = 0x80;
  latched = fushi_voice_hook::FilterSgreDirectInputMouseButtons(
      false, mouse_state, sizeof(mouse_state), latched);
  assert(latched == 0x81 && mouse_state[12] == 0 && mouse_state[19] == 0);
  mouse_state[12] = 0;
  mouse_state[19] = 0x80;
  latched = fushi_voice_hook::FilterSgreDirectInputMouseButtons(
      false, mouse_state, sizeof(mouse_state), latched);
  assert(latched == 0x80 && mouse_state[19] == 0);
  mouse_state[19] = 0;
  latched = fushi_voice_hook::FilterSgreDirectInputMouseButtons(
      false, mouse_state, sizeof(mouse_state), latched);
  assert(latched == 0);

  // Once inactive and drained, unrelated real input must pass untouched. An
  // unknown state layout is also a strict no-op.
  mouse_state[13] = 0x80;
  latched = fushi_voice_hook::FilterSgreDirectInputMouseButtons(
      false, mouse_state, sizeof(mouse_state), latched);
  assert(latched == 0 && mouse_state[13] == 0x80);
  uint8_t unsupported[16] = {};
  unsupported[12] = 0x80;
  assert(fushi_voice_hook::FilterSgreDirectInputMouseButtons(
             true, unsupported, sizeof(unsupported), 0x04) == 0x04);
  assert(unsupported[12] == 0x80);

  // A lookup-owned transaction latches only the primary button. Movement and
  // simultaneously held auxiliary buttons remain visible to the game.
  memset(mouse_state, 0, sizeof(mouse_state));
  mouse_state[0] = 0x33;
  mouse_state[12] = 0x80;
  mouse_state[13] = 0x80;
  latched = fushi_voice_hook::FilterSgreDirectInputMouseButtons(
      false, mouse_state, sizeof(mouse_state),
      fushi_voice_hook::kSgreLookupPrimaryButtonMask);
  assert(latched == fushi_voice_hook::kSgreLookupPrimaryButtonMask);
  assert(mouse_state[0] == 0x33 && mouse_state[12] == 0 &&
         mouse_state[13] == 0x80);

  using ClickAction = fushi_voice_hook::SgreLookupClickAction;
  fushi_voice_hook::SgreLookupClickGestureState click;
  // Injection/enable may happen while left is already physically held. That
  // half-transaction passes through and only its release arms single-click.
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, true, true, true,
                                                        &click) ==
         ClickAction::kNone);
  assert(!click.synchronized && click.last_down && !click.active);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(false, true, true, true,
                                                        &click) ==
         ClickAction::kNone);
  assert(click.synchronized && !click.last_down);

  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, true, true, true,
                                                        &click) ==
         ClickAction::kBegin);
  assert(click.active);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, true, false, true,
                                                        &click) ==
         ClickAction::kNone);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(false, true, false, true,
                                                        &click) ==
         ClickAction::kSubmit);
  assert(!click.active && !click.last_down);

  // 命中即承诺：down 已经从游戏的采样里抹掉了，位移**不是**取消理由。曾经的 6px
  // 拖动阈值会让手抖越界的点击既不查词、也不推进台词（游戏和用户两头空），
  // 那个特例已被消除——按住期间任意位移，抬起仍必须 kSubmit。
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, true, true, true,
                                                        &click) ==
         ClickAction::kBegin);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, true, false,
                                                        true, &click) ==
         ClickAction::kNone);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(false, true, false,
                                                        true, &click) ==
         ClickAction::kSubmit);

  // 仍然保留的两个取消理由，都是「这次消费本来就不该成立」：查词权限/屏蔽在按住
  // 期间掉电，或光标位置读不出来。下游本来就会吞掉这次点击，不构成额外损失。
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, true, true, true,
                                                        &click) ==
         ClickAction::kBegin);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, false, false,
                                                        true, &click) ==
         ClickAction::kNone);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(false, false, false,
                                                        true, &click) ==
         ClickAction::kCancel);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, true, true, true,
                                                        &click) ==
         ClickAction::kBegin);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, true, false,
                                                        false, &click) ==
         ClickAction::kNone);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(false, true, false,
                                                        false, &click) ==
         ClickAction::kCancel);

  // A miss is a pass-through transaction. Becoming a hit while the same raw
  // button is held must never start consuming halfway through.
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, true, false, true,
                                                        &click) ==
         ClickAction::kNone);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, true, true, true,
                                                        &click) ==
         ClickAction::kNone);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(false, true, true, true,
                                                        &click) ==
         ClickAction::kNone);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(true, true, true, false,
                                                        &click) ==
         ClickAction::kNone);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(false, true, false, true,
                                                        &click) ==
         ClickAction::kNone);
  assert(fushi_voice_hook::AdvanceSgreLookupClickGesture(false, true, true, true,
                                                        nullptr) ==
         ClickAction::kNone);

  // The scenario root is positioned in the 1920x1080 design surface, but the
  // glyph draw point and texture cell are already physical units. These are
  // live values from the admitted 3840x2160 process: glyph+0x40 advances 80,
  // while the discarded pre-draw glyph+0x94 field advances only 25.
  const fushi_voice_hook::SgreLookupGlyphGeometry glyphs[] = {
      {0.0f, 0.0f, 80.0f, 80.0f, 0},
      {80.0f, 0.0f, 80.0f, 80.0f, 0},
      {0.0f, 80.0f, 80.0f, 80.0f, 1},
  };
  fushi_voice_hook::SgreLookupRect rect;
  assert(fushi_voice_hook::SgreLookupRectForGlyph(glyphs[0], 1920, 1080,
                                                   &rect));
  assert(rect.x == 320 && rect.y == 830 && rect.width == 80 &&
         rect.height == 80);
  assert(fushi_voice_hook::FindSgreLookupGlyph(glyphs, 3, 1920, 1080, 401, 840,
                                               &rect) == 1);
  assert(fushi_voice_hook::FindSgreLookupGlyph(glyphs, 3, 3840, 2160, 721, 1670,
                                               &rect) == 1);
  assert(rect.x == 720 && rect.y == 1660 && rect.width == 80 &&
         rect.height == 80);
  // Non-16:9 clients keep the 1920x1080 render surface aspect-fitted. The
  // black-bar offset must be included in cursor hit testing.
  assert(fushi_voice_hook::SgreLookupRectForGlyph(glyphs[0], 2622, 1206,
                                                   &rect));
  assert(rect.x == 596 && rect.y == 927 && rect.width == 80);
  assert(fushi_voice_hook::FindSgreLookupGlyph(glyphs, 3, 2622, 1206, 600, 940,
                                               &rect) == 0);
  assert(fushi_voice_hook::FindSgreLookupGlyph(glyphs, 3, 1920, 1080, 321, 920,
                                               &rect) == 2);
  assert(fushi_voice_hook::FindSgreLookupGlyph(glyphs, 3, 1920, 1080, 100, 100,
                                               &rect) == -1);
  auto invalid = glyphs[0];
  invalid.width = -1.0f;
  assert(!fushi_voice_hook::IsSaneSgreLookupGlyph(invalid));

  assert(fushi_voice_hook::SgreLookupHitWidth(glyphs, 3, 0) == 80.0f);
  assert(fushi_voice_hook::SgreLookupHitWidth(glyphs, 3, 1) == 80.0f);

  // The fixture above cannot fail: every width AND every advance in it is 80,
  // so gutting SgreLookupHitWidth into `return glyphs[i].width;` still passes.
  // Pin the two behaviours that actually justify the function with a fixture
  // whose advance differs from the texture box.
  const fushi_voice_hook::SgreLookupGlyphGeometry narrow[] = {
      {0.0f, 0.0f, 80.0f, 80.0f, 0},
      {40.0f, 0.0f, 80.0f, 80.0f, 0},
      {0.0f, 80.0f, 80.0f, 80.0f, 1},
  };
  // Converge onto the next draw anchor so a half-width neighbour cannot make
  // two hit cells overlap.
  assert(fushi_voice_hook::SgreLookupHitWidth(narrow, 3, 0) == 40.0f);
  // Row-final glyph has no following anchor on its row: reuse the previous
  // advance rather than the raw box.
  assert(fushi_voice_hook::SgreLookupHitWidth(narrow, 3, 1) == 40.0f);
  // Row-leading glyph: neither neighbour is on this row, so the box stands.
  assert(fushi_voice_hook::SgreLookupHitWidth(narrow, 3, 2) == 80.0f);

  // An advance wider than the texture cell must NOT widen the hit cell -- that
  // is what the std::min is for; without it a sparse row swallows the gaps.
  const fushi_voice_hook::SgreLookupGlyphGeometry sparse[] = {
      {0.0f, 0.0f, 80.0f, 80.0f, 0},
      {200.0f, 0.0f, 80.0f, 80.0f, 0},
  };
  assert(fushi_voice_hook::SgreLookupHitWidth(sparse, 2, 0) == 80.0f);

  // Malformed inputs return a rejecting value instead of reading out of bounds.
  assert(fushi_voice_hook::SgreLookupHitWidth(glyphs, 3, 3) == 0.0f);
  assert(fushi_voice_hook::SgreLookupHitWidth(nullptr, 3, 0) == 0.0f);
  assert(fushi_voice_hook::FindSgreLookupGlyph(nullptr, 3, 1920, 1080, 0, 0,
                                               &rect) == -1);
  assert(fushi_voice_hook::FindSgreLookupGlyph(glyphs, 0, 1920, 1080, 0, 0,
                                               &rect) == -1);
  assert(!fushi_voice_hook::SgreLookupRectForGlyph(glyphs[0], 0, 1080, &rect));
  assert(
      !fushi_voice_hook::SgreLookupRectForGlyph(glyphs[0], 1920, 1080, nullptr));

  // The admitted draw surface stores one flattened glyph vector. Both native
  // and automatic line breaks reset (or repeat) the next x anchor, so visual
  // rows can be derived without interpreting UserHook1/MAGES control codes.
  assert(!fushi_voice_hook::StartsNextSgreLookupLine(0.0f, 80.0f));
  assert(!fushi_voice_hook::StartsNextSgreLookupLine(80.0f, 160.0f));
  assert(fushi_voice_hook::StartsNextSgreLookupLine(2480.0f, 0.0f));
  assert(fushi_voice_hook::StartsNextSgreLookupLine(80.0f, 80.0f));
  assert(fushi_voice_hook::MatchesSgreScenarioDrawMetrics(80.0f, 80.0f,
                                                          true));
  assert(!fushi_voice_hook::MatchesSgreScenarioDrawMetrics(33.0f, 33.0f,
                                                           true));
  assert(!fushi_voice_hook::MatchesSgreScenarioDrawMetrics(80.0f, 80.0f,
                                                           false));

  // The production worker polls every 16 ms. Preserve held-key edge behavior,
  // but also consume a complete press/release reported only by the low bit.
  bool last_shift_down = false;
  assert(!fushi_voice_hook::ConsumeSgreLookupShiftSample(0x0000,
                                                         &last_shift_down));
  assert(fushi_voice_hook::ConsumeSgreLookupShiftSample(0x8001,
                                                        &last_shift_down));
  assert(last_shift_down);
  assert(!fushi_voice_hook::ConsumeSgreLookupShiftSample(0x8000,
                                                         &last_shift_down));
  assert(!fushi_voice_hook::ConsumeSgreLookupShiftSample(0x0000,
                                                         &last_shift_down));
  assert(!last_shift_down);
  assert(fushi_voice_hook::ConsumeSgreLookupShiftSample(0x0001,
                                                        &last_shift_down));
  assert(!last_shift_down);
  assert(!fushi_voice_hook::ConsumeSgreLookupShiftSample(0x0000, nullptr));

  // Per-frame draw captures are transport updates, not new production
  // generations. Keep the epoch stable for identical UTF-16 and glyph layout,
  // and reject an up after either geometry or the client transform changes.
  constexpr char16_t kStableText[] = u"一二三";
  assert(fushi_voice_hook::SameSgreLookupLogicalSnapshot(
      kStableText, 3, glyphs, 3, 80.0f, kStableText, 3, glyphs, 3,
      80.0f));
  fushi_voice_hook::SgreLookupGlyphGeometry moved_glyphs[] = {
      glyphs[0], glyphs[1], glyphs[2]};
  moved_glyphs[1].x += 1.0f;
  assert(!fushi_voice_hook::SameSgreLookupLogicalSnapshot(
      kStableText, 3, glyphs, 3, 80.0f, kStableText, 3, moved_glyphs, 3,
      80.0f));
  assert(fushi_voice_hook::NextSgreLookupLogicalGeneration(0) == 1);
  assert(fushi_voice_hook::NextSgreLookupLogicalGeneration(UINT64_MAX) == 1);
  const fushi_voice_hook::SgreLookupClientSnapshot stable_client = {
      0x4321u, -1600, 20, 1920, 1080};
  assert(fushi_voice_hook::MatchesSgreLookupGenerationAndClient(
      11, stable_client, 11, stable_client));
  auto moved_client = stable_client;
  ++moved_client.screen_x;
  assert(!fushi_voice_hook::MatchesSgreLookupGenerationAndClient(
      11, stable_client, 11, moved_client));
  assert(!fushi_voice_hook::MatchesSgreLookupGenerationAndClient(
      11, stable_client, 12, stable_client));

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
