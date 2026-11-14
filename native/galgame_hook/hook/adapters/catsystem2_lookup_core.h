#pragma once

// CatSystem2 in-game lookup: pure, unit-tested half.
//
// Engine facts (CatSystem2 cs2 2.6.x, x86, Direct3D 9; measured 2026-09-27
// with Frida on the グリザイアの有閑 build — the sample only, never an
// identity input):
//   * A message window owns a text renderer.  The renderer lays a page out
//     into records {Shift_JIS code (+4), x (+0x10), y (+0x14), advance
//     (+0x18), font size (+0x1c)} in the pixels of its own 32-bit page image
//     (renderer+4; page size renderer+0x14 / +0x18).  The typing reveal
//     renders one record at a time through RenderChar(renderer, record); the
//     function immediately before it in the image, ClearPage(renderer), empties
//     the layout and fills the page image with zero.  LunaHook's CatSystem2
//     text hook patches the glyph rasteriser two calls below RenderChar
//     (GetCharImage -> rasteriser -> GetGlyphOutlineA); this provider never
//     touches either.
//   * The page image is copied into a scene layer.  The message window keeps
//     its layer id (+4) and the screen object (+0x68); the screen object's
//     scene (+8) holds a std::list of layer nodes {next, prev, id (+8),
//     visible (+0xc), ..., sprite (+0x18)} in draw order.  The text layer's
//     sprite is positioned at integral design pixels (+0x38 / +0x3c), is
//     exactly the page size (+0x58 / +0x5c) and keeps the drawn bounding box
//     {x-1, y-1, x+w, y+h} (+0xfc..+0x108).  Hiding the message window or
//     opening the system menu clears the node's visible flag or draws a later
//     layer over it.
//   * The scene is drawn into a design-size back buffer (screen object +0x18
//     / +0x1c, mirrored at +0x20 / +0x24; window at +0x14) that Direct3D
//     stretches over the whole client.
//   * Input: the window procedure hands every message to the input object's
//     handler Handle(input, hwnd, msg, wparam, lparam) (stdcall, message
//     thread); WM_LBUTTONDOWN there is what the script sees as a click
//     (measured: a swallowed down/up pair does not advance).  lparam carries
//     client pixels of the DPI-unaware window.
//
// A second code layout of the same engine ("targeted render"; measured
// 2026-10-03 with Frida on a 2016 CatSystem2 build — again the sample only):
//   * RenderChar(renderer, record, target_image) takes the page image to draw
//     into (the normal page renderer+4 or the fade page renderer+0x40) and
//     returns with `ret 8`; the record keeps the same fields (stride 0x58).
//     GetCharImage is reached through the font object's vtable slot 1
//     (`call [esi+4]`, esi = [[renderer]]) instead of a direct call, and
//     ClearPage is no longer adjacent to RenderChar: it is proven by its body
//     (layout reset, both page images filled through one helper) and by a
//     caller that loads the renderer from the message window (+0x2ac).
//   * The scene keeps its draw-ordered std::list at [scene+4] (head = [list],
//     no +0x14 hop) and every node points to its layer ([node+8]) instead of
//     embedding it.  The layer itself is unchanged: id +0, visible +4,
//     sprite +0x10 — in the first layout that is node+8 / +0xc / +0x18.
//   * Window (+4 layer id, +0x68 screen, +0x2ac renderer), screen (+8 scene,
//     +0x14..+0x24) and sprite fields are the same as above.
//
// The cs2 2.6.1.90 build (2020, newer MSVC; read offline from its exe — the
// sample only) keeps the targeted-render layout but moves fields: the
// renderer is one dword shorter in front of the page size (size +0x10 /
// +0x14, fade page +0x3c), the part base one dword longer after the layer id
// (window screen +0x6c, renderer +0x2b0); GetCharImage takes two more record
// fields; a second window class shares the Update and ClearPage bodies (and
// the +0x2b0 renderer field) for another renderer class.  Those offsets are
// therefore read from the proving code (ObjectLayout), and the message
// window's Update / ClearPage are the ones tied to RenderChar's reveal loop.
//
// Every site, offset and global below is proven by a byte signature plus a
// structural cross-check (call chain into GetGlyphOutlineA, import slots,
// adjacent function layout or vtable slot).  Runtime data is re-validated
// every frame (page size equals sprite size, bounding box consistent, window
// owned by the process).  No hash, file name or title is consulted; anything
// missing or ambiguous installs nothing.

#include <windows.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "exact_lookup_signature.h"
#include "../lookup_line_text_match.h"

namespace fushi_voice_hook::catsystem2_lookup {

namespace exact = fushi_voice_hook::exact_lookup;

// ── signature helpers ──────────────────────────────────────────────────────

template <size_t Size, size_t Ranges>
constexpr std::array<uint8_t, Size> WildcardMask(
    const size_t (&ranges)[Ranges][2]) {
  std::array<uint8_t, Size> mask = {};
  for (size_t index = 0u; index < Size; ++index) mask[index] = 0xffu;
  for (size_t range = 0u; range < Ranges; ++range) {
    for (size_t index = ranges[range][0];
         index < ranges[range][1] && index < Size; ++index) {
      mask[index] = 0u;
    }
  }
  return mask;
}

// ── engine layout ──────────────────────────────────────────────────────────

inline constexpr size_t kRendererImageOffset = 0x04u;
// Targeted-render layout: the renderer's second page image.  With text fade
// on, the engine copies the page into it, draws the new characters there and
// then swaps the two pointers, so both are the same on-screen text page.
inline constexpr size_t kRendererWorkImageOffset = 0x40u;
inline constexpr size_t kRendererPageWidthOffset = 0x14u;
inline constexpr size_t kRendererPageHeightOffset = 0x18u;

inline constexpr size_t kRecordCodeOffset = 0x04u;   // uint16 Shift_JIS
inline constexpr size_t kRecordXOffset = 0x10u;
inline constexpr size_t kRecordYOffset = 0x14u;
inline constexpr size_t kRecordAdvanceOffset = 0x18u;
inline constexpr size_t kRecordSizeOffset = 0x1cu;
inline constexpr size_t kRecordBytes = 0x20u;

inline constexpr size_t kWindowLayerIdOffset = 0x04u;
inline constexpr size_t kWindowScreenOffset = 0x68u;
inline constexpr size_t kWindowRendererOffset = 0x2acu;

inline constexpr size_t kScreenSceneOffset = 0x08u;
inline constexpr size_t kScreenWindowOffset = 0x14u;
inline constexpr size_t kScreenWidthOffset = 0x18u;
inline constexpr size_t kScreenHeightOffset = 0x1cu;
inline constexpr size_t kScreenWidthMirrorOffset = 0x20u;
inline constexpr size_t kScreenHeightMirrorOffset = 0x24u;

inline constexpr size_t kNodeNextOffset = 0x00u;
inline constexpr size_t kNodeLayerOffset = 0x08u;    // layer (or its pointer)
inline constexpr size_t kLayerIdOffset = 0x00u;
inline constexpr size_t kLayerVisibleOffset = 0x04u;
inline constexpr size_t kLayerSpriteOffset = 0x10u;

// How the draw-ordered layer list hangs off the scene.
struct SceneWalk {
  size_t list_offset = 0u;      // list object = [scene + list_offset]
  size_t head_offset = 0u;      // sentinel node = [list + head_offset]
  bool layer_by_pointer = false;  // layer = [node+8] instead of node+8
};
inline constexpr SceneWalk kAdjacentPageWalk = {0x00u, 0x14u, false};
inline constexpr SceneWalk kTargetedRenderWalk = {0x04u, 0x00u, true};

inline constexpr size_t kSpriteXOffset = 0x38u;      // float
inline constexpr size_t kSpriteYOffset = 0x3cu;
inline constexpr size_t kSpriteWidthOffset = 0x58u;
inline constexpr size_t kSpriteHeightOffset = 0x5cu;
inline constexpr size_t kSpriteBoxOffset = 0xfcu;    // int32 x0 y0 x1 y1
inline constexpr size_t kSpriteBytes = 0x10cu;

inline constexpr int32_t kMinFontSize = 6;
inline constexpr int32_t kMaxFontSize = 128;
inline constexpr int32_t kMaxPageSide = 4096;
inline constexpr int32_t kMinDesignSide = 64;
inline constexpr int32_t kMaxDesignSide = 8192;

// ── signatures ─────────────────────────────────────────────────────────────

// ClearPage(renderer) followed, after its int3 padding, by the RenderChar
// prologue: the two functions sit back to back in the image.
inline constexpr uint8_t kPageBytes[] = {
    // ClearPage
    0x56, 0x8b, 0xf1, 0x8b, 0x4e, 0x08, 0x57, 0x33, 0xff, 0x3b, 0xcf, 0x74,
    0x05, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x8b, 0x4e, 0x04, 0x89, 0x7e, 0x20,
    0x89, 0x7e, 0x24, 0x89, 0x7e, 0x28, 0x89, 0x7e, 0x2c, 0x89, 0x7e, 0x30,
    0x3b, 0xcf, 0x74, 0x10, 0x8b, 0x46, 0x18, 0x8b, 0x56, 0x14, 0x57, 0x50,
    0x52, 0x57, 0x57, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x5f, 0x5e, 0xc3, 0xcc,
    0xcc, 0xcc, 0xcc, 0xcc,
    // RenderChar(renderer, record)
    0x81, 0xec, 0xc8, 0x00, 0x00, 0x00, 0x53, 0x56, 0x8b, 0x35, 0x00, 0x00,
    0x00, 0x00, 0x57, 0x8d, 0x84, 0x24, 0xb4, 0x00, 0x00, 0x00, 0x50, 0x8b,
    0xf9, 0xff, 0xd6};
inline constexpr size_t kPageWildcards[][2] = {{14u, 18u}, {52u, 56u},
                                               {74u, 78u}};
inline constexpr auto kPageMask =
    WildcardMask<sizeof(kPageBytes)>(kPageWildcards);
inline constexpr size_t kPageRenderOffset = 64u;   // RenderChar entry
inline constexpr size_t kPageFillCall = 51u;       // page image fill

// Inside RenderChar: the record argument and its pen position.
inline constexpr uint8_t kRecordPenBytes[] = {0x8b, 0xb4, 0x24, 0xdc, 0x00,
                                              0x00, 0x00, 0x8b, 0x46, 0x10,
                                              0x8b, 0x4e, 0x14};
inline constexpr size_t kRecordPenOffset = 0x69u;  // from RenderChar entry
// Inside RenderChar: font size and code handed to GetCharImage.
inline constexpr uint8_t kRecordCharBytes[] = {
    0x8b, 0x4e, 0x1c, 0x0f, 0x94, 0xc2, 0x8d, 0x46, 0x2c, 0x52,
    0x0f, 0xb7, 0x56, 0x04, 0x50, 0x51, 0x8b, 0x0f, 0x52, 0x8d,
    0x44, 0x24, 0x4c, 0x50, 0xe8, 0x00, 0x00, 0x00, 0x00};
inline constexpr size_t kRecordCharWildcards[][2] = {{25u, 29u}};
inline constexpr auto kRecordCharMask =
    WildcardMask<sizeof(kRecordCharBytes)>(kRecordCharWildcards);
inline constexpr size_t kRecordCharOffset = 0x100u;  // from RenderChar entry
inline constexpr size_t kRecordCharImageCall = 24u;
// GetCharImage calls the rasteriser (twice); the rasteriser calls
// GetGlyphOutlineA through its import slot.  LunaHook patches the
// rasteriser entry, so only its body is inspected.
inline constexpr size_t kCharImageScanBytes = 0x140u;
inline constexpr size_t kRasterBodyStart = 0x10u;
inline constexpr size_t kRasterScanBytes = 0x200u;

// Message-window Update(time, flags): renderer at +0x2ac feeds the reveal
// loop, which renders through RenderChar; then SyncLayer() copies the page
// into the screen object at +0x68.
inline constexpr uint8_t kUpdateBytes[] = {
    0x8b, 0x44, 0x24, 0x08, 0x56, 0x57, 0x8b, 0x7c, 0x24, 0x0c, 0x50, 0x57,
    0x8b, 0xf1, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x85, 0xc0, 0x75, 0x05, 0x5f,
    0x5e, 0xc2, 0x08, 0x00, 0x83, 0xbe, 0x00, 0x00, 0x00, 0x00, 0x00, 0x74,
    0x00, 0x8b, 0x8e, 0x00, 0x00, 0x00, 0x00, 0x8b, 0x96, 0x00, 0x00, 0x00,
    0x00, 0x51, 0x8b, 0x8e, 0xac, 0x02, 0x00, 0x00, 0x52, 0xe8, 0x00, 0x00,
    0x00, 0x00, 0xf7, 0xd8, 0x1b, 0xc0, 0x40, 0x8b, 0xce, 0x89, 0x86, 0x00,
    0x00, 0x00, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00};
inline constexpr size_t kUpdateWildcards[][2] = {
    {15u, 19u}, {30u, 34u}, {36u, 37u}, {39u, 43u}, {45u, 49u},
    {58u, 62u}, {71u, 75u}, {76u, 80u}};
inline constexpr auto kUpdateMask =
    WildcardMask<sizeof(kUpdateBytes)>(kUpdateWildcards);
inline constexpr size_t kUpdateRevealCall = 57u;
inline constexpr size_t kUpdateSyncCall = 75u;
inline constexpr size_t kRevealScanBytes = 0x200u;
// SyncLayer: `mov ecx,[esi+0x68]; push eax; call Screen::CopyImage` right
// after the renderer's page image was fetched from renderer+4.
inline constexpr uint8_t kSyncScreenBytes[] = {0x8b, 0x4e, 0x68, 0x50, 0xe8};
inline constexpr size_t kSyncScanBytes = 0xa0u;

// Layer query of a scene part: `mov ecx,[esi+4] (layer id); ...; mov ecx,
// [esi+0x68] (screen); call Screen::QueryLayer`.  The two fields belong to
// the common part base class, so several parts (the message window among
// them) carry this exact method body; every copy must call the same
// Screen::QueryLayer.
inline constexpr uint8_t kLayerQueryBytes[] = {
    0x83, 0xec, 0x0c, 0x56, 0x8b, 0xf1, 0x8b, 0x4e, 0x04, 0x8d, 0x44, 0x24,
    0x04, 0x50, 0x51, 0x8b, 0x4e, 0x68, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x85};
inline constexpr size_t kLayerQueryWildcards[][2] = {{19u, 23u}};
inline constexpr auto kLayerQueryMask =
    WildcardMask<sizeof(kLayerQueryBytes)>(kLayerQueryWildcards);
inline constexpr size_t kLayerQueryCall = 18u;
inline constexpr uint32_t kMaxLayerQueryCopies = 8u;
// Screen::QueryLayer: the scene is [screen+8]; forwards to Scene::Visible.
inline constexpr uint8_t kScreenQueryBytes[] = {
    0x53, 0x56, 0x8b, 0xf1, 0x33, 0xdb, 0x39, 0x1e, 0x75, 0x00, 0x39, 0x5e,
    0x04, 0x74, 0x00, 0x57, 0x8b, 0x7c, 0x24, 0x10, 0x57, 0xe8, 0x00, 0x00,
    0x00, 0x00, 0x83, 0xe8, 0x01, 0x75, 0x00, 0x8b, 0x44, 0x24, 0x14, 0x8b,
    0x4e, 0x08, 0x50, 0x57, 0xe8, 0x00, 0x00, 0x00, 0x00};
inline constexpr size_t kScreenQueryWildcards[][2] = {
    {9u, 10u}, {14u, 15u}, {22u, 26u}, {30u, 31u}, {41u, 45u}};
inline constexpr auto kScreenQueryMask =
    WildcardMask<sizeof(kScreenQueryBytes)>(kScreenQueryWildcards);
inline constexpr size_t kScreenQuerySceneCall = 40u;
// Scene::Visible(id, out): find node, list = [scene], head = [list+0x14],
// then `mov edx,[node+0xc]` is the visible flag.
inline constexpr uint8_t kSceneVisibleBytes[] = {
    0x8b, 0x44, 0x24, 0x04, 0x83, 0xec, 0x08, 0x53, 0x55, 0x56, 0x57, 0x8b,
    0xf1, 0x50, 0x8d, 0x4c, 0x24, 0x14, 0x51, 0x8b, 0xce, 0xe8, 0x00, 0x00,
    0x00, 0x00, 0x8b, 0x36, 0x8b, 0x38, 0x8b, 0x6e, 0x14, 0x8b, 0x58, 0x04};
inline constexpr size_t kSceneVisibleWildcards[][2] = {{22u, 26u}};
inline constexpr auto kSceneVisibleMask =
    WildcardMask<sizeof(kSceneVisibleBytes)>(kSceneVisibleWildcards);
inline constexpr size_t kSceneVisibleFindCall = 21u;
inline constexpr uint8_t kNodeVisibleReadBytes[] = {0x8b, 0x53, 0x0c};
inline constexpr size_t kSceneVisibleScanBytes = 0x80u;
// Scene::Find: begin = [[list+0x14]] and the key compare `cmp [eax+8],ebp`.
inline constexpr uint8_t kSceneFindBytes[] = {0x53, 0x8b, 0xd9, 0x8b, 0x03,
                                              0x8b, 0x48, 0x14, 0x8b, 0x09};
inline constexpr uint8_t kNodeIdCompareBytes[] = {0x39, 0x68, 0x08};
inline constexpr size_t kSceneFindScanBytes = 0x90u;

// Input::Handle(input, hwnd, msg, wparam, lparam): a WM_MOUSEMOVE split and
// a jump table over the lower messages.
inline constexpr uint8_t kInputBytes[] = {
    0x8b, 0x44, 0x24, 0x0c, 0x83, 0xec, 0x18, 0x53, 0x55, 0x56, 0x57, 0x3d,
    0x00, 0x02, 0x00, 0x00, 0x0f, 0x87, 0x00, 0x00, 0x00, 0x00, 0x0f, 0x84,
    0x00, 0x00, 0x00, 0x00, 0x8d, 0x48, 0xfa, 0x81, 0xf9, 0xfc, 0x00, 0x00,
    0x00, 0x0f, 0x87, 0x00, 0x00, 0x00, 0x00, 0x0f, 0xb6, 0x89, 0x00, 0x00,
    0x00, 0x00, 0xff, 0x24, 0x8d};
inline constexpr size_t kInputWildcards[][2] = {
    {18u, 22u}, {24u, 28u}, {39u, 43u}, {46u, 50u}};
inline constexpr auto kInputMask =
    WildcardMask<sizeof(kInputBytes)>(kInputWildcards);
// The handler owns the capture bookkeeping: SetCapture, ReleaseCapture and
// WindowFromPoint are all called from its body.
inline constexpr size_t kInputScanBytes = 0x900u;

// ── signatures: targeted-render layout ─────────────────────────────────────

// RenderChar(renderer, record, target) prologue:
//   sub esp,F; lea eax,[esp+F-0x20]; push ebx; push ebp; push esi;
//   mov esi,[GetLocalTime-like import]; mov ebx,ecx; push eax; call esi
// The frame F is not fixed: 0xcc for the message window's renderer class,
// 0xd0 for the second text-window class of the VS2013 cs2 2.6.1.90 build
// (whose window draws its own pages through its own RenderChar).  F is read
// from the prologue and every stack offset the proof checks follows it.
inline constexpr uint8_t kRenderTBytes[] = {
    0x81, 0xec, 0xcc, 0x00, 0x00, 0x00, 0x8d, 0x84, 0x24, 0xac, 0x00, 0x00,
    0x00, 0x53, 0x55, 0x56, 0x8b, 0x35, 0x00, 0x00, 0x00, 0x00, 0x8b, 0xd9,
    0x50, 0xff, 0xd6};
inline constexpr size_t kRenderTWildcards[][2] = {
    {2u, 6u}, {9u, 13u}, {18u, 22u}};
inline constexpr size_t kRenderTFrameDisp = 2u;  // sub esp,imm32
inline constexpr size_t kRenderTLeaDisp = 9u;    // lea eax,[esp+imm32]
inline constexpr uint32_t kRenderTLeaBelowFrame = 0x20u;
inline constexpr uint32_t kRenderTMinFrame = 0x80u;
inline constexpr uint32_t kRenderTMaxFrame = 0x400u;
// RenderChar-shaped prologues beyond which the image is not trusted.
inline constexpr size_t kMaxRenderCopies = 4u;
inline constexpr auto kRenderTMask =
    WildcardMask<sizeof(kRenderTBytes)>(kRenderTWildcards);
// The record argument and its pen position: `mov edi,[esp+F+0x14]` (the
// record, first stack argument after the three pushes and the return
// address), two zeroed consecutive locals, then the pen x / y loads.
inline constexpr uint8_t kRecordPenTBytes[] = {
    0x8b, 0xbc, 0x24, 0xe0, 0x00, 0x00, 0x00, 0xc7, 0x44, 0x24,
    0x2c, 0x00, 0x00, 0x00, 0x00, 0xc7, 0x44, 0x24, 0x30, 0x00,
    0x00, 0x00, 0x00, 0x8b, 0x47, 0x10, 0x8b, 0x4f, 0x14};
inline constexpr size_t kRecordPenTWildcards[][2] = {
    {3u, 7u}, {10u, 11u}, {18u, 19u}};
inline constexpr auto kRecordPenTMask =
    WildcardMask<sizeof(kRecordPenTBytes)>(kRecordPenTWildcards);
inline constexpr size_t kRecordPenTRecordDisp = 3u;
inline constexpr uint32_t kRecordPenTRecordAboveFrame = 0x14u;
inline constexpr size_t kRecordPenTFirstLocal = 10u;
inline constexpr size_t kRecordPenTSecondLocal = 18u;
inline constexpr size_t kRecordPenTOffset = 0x6fu;
// esi = vtable of the font object [renderer]; code and font size of the
// record go to `call [esi+4]` (GetCharImage, vtable slot 1).  The arguments
// in between are not fixed across builds: the 2016 build hands record +0x50 /
// +0x54 to a helper and reads font fields +0xa0 / +0xac, the cs2 2.6.1.90
// build (2020, newer MSVC) hands it +0x50..+0x5c and reads +0xc0 / +0xcc, so
// every stack offset behind it moves too.  The proof therefore reads only
// what RenderChar's own registers fix (ebx = renderer from the prologue's
// `mov ebx,ecx`, edi = record from the pen block's `mov edi,[esp+0xe0]`):
//   mov eax,[ebx] ... mov esi,[eax] ... mov ecx,[ebx] ... push [edi+0x1c]
//   ... movzx eax,word [edi+4]; push eax ... call [esi+4]
// in that order inside kRecordCharTScanBytes before the call, and exactly one
// such call in the body.
inline constexpr uint8_t kFontObjectLoadTBytes[] = {0x8b, 0x03};  // eax,[ebx]
inline constexpr uint8_t kFontVtableLoadTBytes[] = {0x8b, 0x30};  // esi,[eax]
inline constexpr uint8_t kFontThisLoadTBytes[] = {0x8b, 0x0b};    // ecx,[ebx]
inline constexpr uint8_t kRecordSizePushTBytes[] = {0xff, 0x77, 0x1c};
inline constexpr uint8_t kRecordCodePushTBytes[] = {0x0f, 0xb7, 0x47, 0x04,
                                                    0x50};
inline constexpr uint8_t kCharImageCallTBytes[] = {0xff, 0x56, 0x04};
inline constexpr size_t kRecordCharTScanBytes = 0x60u;
// Epilogue: the prologue's frame (0xcc here; bytes 2..5 are F) released, two
// stack arguments
// (record, target image) popped, then int3 padding.  Its distance from the
// entry is not fixed across builds (+0x298 on the VS2017 cs2 2.6.1.90 build,
// +0x29e on the VS2013 one, whose body interleaves the GetCharImage argument
// loads differently), so the proof takes the first such epilogue after the
// pen block, within kRenderTMaxBodyBytes, as the end of the body.
inline constexpr uint8_t kRenderTailTBytes[] = {0x81, 0xc4, 0xcc, 0x00, 0x00,
                                                0x00, 0xc2, 0x08, 0x00, 0xcc};
inline constexpr size_t kRenderTailTOffset = 0x298u;  // VS2017 build (tests)
inline constexpr size_t kRenderTailTFrameDisp = 2u;
inline constexpr size_t kRenderTMaxBodyBytes = 0x400u;
inline constexpr uint32_t kRenderTStackArgs = 2u;
// The vtable entry GetCharImage must be found through.
inline constexpr size_t kCharImageVtableSlot = 1u;

// ClearPage(renderer): reset the layout (four or more consecutive dwords),
// then fill the normal (+4) and the fade page image with the page size
// through one helper:
//   push esi; mov esi,ecx; mov ecx,[esi+8]; test ecx,ecx; je +5; call
//   mov dword [esi+R],0 ...                            (R, R+4, R+8, ...)
//   mov ecx,[esi+4]; test ecx,ecx; je +0x11
//   push 0; push [esi+H]; push [esi+W]; push 0; push 0; call Fill
//   mov ecx,[esi+F]; test ecx,ecx; je +0x11
//   push 0; push [esi+H]; push [esi+W]; push 0; push 0; call Fill
//   pop esi; ret
// W / H (page size, H = W + 4) and F (fade page) are read from the body:
// 0x14 / 0x18 / 0x40 on the 2016 build, 0x10 / 0x14 / 0x3c on cs2 2.6.1.90,
// whose renderer dropped one dword in front of the page size.
inline constexpr uint8_t kClearTHeadBytes[] = {
    0x56, 0x8b, 0xf1, 0x8b, 0x4e, 0x08, 0x85, 0xc9, 0x74, 0x05, 0xe8};
inline constexpr uint8_t kClearTResetBytes[] = {0xc7, 0x46};  // + d8 + imm32 0
inline constexpr size_t kClearTMinResets = 4u;
// `mov ecx,[esi+d8]; test ecx,ecx; je +0x11; push 0; push [esi+H];
// push [esi+W]; push 0; push 0; call rel32` with d8 / H / W wildcarded.
inline constexpr uint8_t kClearTFillBytes[] = {
    0x8b, 0x4e, 0x00, 0x85, 0xc9, 0x74, 0x11, 0x6a, 0x00, 0xff, 0x76, 0x00,
    0xff, 0x76, 0x00, 0x6a, 0x00, 0x6a, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00};
inline constexpr size_t kClearTFillWildcards[][2] = {
    {2u, 3u}, {11u, 12u}, {14u, 15u}, {20u, 24u}};
inline constexpr auto kClearTFillMask =
    WildcardMask<sizeof(kClearTFillBytes)>(kClearTFillWildcards);
inline constexpr size_t kClearTFillImage = 2u;
inline constexpr size_t kClearTFillHeight = 11u;
inline constexpr size_t kClearTFillWidth = 14u;
inline constexpr size_t kClearTFillCall = 19u;
inline constexpr uint8_t kClearTTailBytes[] = {0x5e, 0xc3};
// ClearPage-shaped functions beyond which the image is not trusted.
inline constexpr uint32_t kMaxClearPageCopies = 8u;
// `mov ecx,[edi+<window renderer>]; test ecx,ecx; je; call ClearPage`.
// Other classes keep a different object at the same offset, so at least one
// copy (not every copy) must call ClearPage.  The displacement (bytes 2..5)
// is the window renderer offset proven by Update.
inline constexpr uint8_t kClearCallTBytes[] = {
    0x8b, 0x8f, 0x00, 0x00, 0x00, 0x00, 0x85, 0xc9,
    0x74, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00};
inline constexpr size_t kClearCallTWildcards[][2] = {{9u, 10u}, {11u, 15u}};
inline constexpr auto kClearCallTMask =
    WildcardMask<sizeof(kClearCallTBytes)>(kClearCallTWildcards);
inline constexpr size_t kClearCallTDisp = 2u;
inline constexpr size_t kClearCallTCall = 10u;
// When several ClearPage-shaped functions are called through that field
// (cs2 2.6.1.90 has a second renderer class with the same body behind
// another window class), the message window's one is called from a function
// that also drives the reveal loop on the same renderer.  A function is
// bounded by int3 padding; the search stops this far from the call.
inline constexpr size_t kCallerFunctionScanBytes = 0x1000u;

// Message-window Update(time, flags): renderer, reveal and SyncLayer.  The
// renderer field is read from `mov ecx,[esi+disp32]` (bytes 44..47): +0x2ac
// on the 2016 build, +0x2b0 on cs2 2.6.1.90.
inline constexpr uint8_t kUpdateTBytes[] = {
    0x56, 0x57, 0xff, 0x74, 0x24, 0x10, 0x8b, 0x7c, 0x24, 0x10, 0x8b, 0xf1,
    0x57, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x85, 0xc0, 0x75, 0x05, 0x5f, 0x5e,
    0xc2, 0x08, 0x00, 0x83, 0xbe, 0x00, 0x00, 0x00, 0x00, 0x00, 0x74, 0x00,
    0xff, 0xb6, 0x00, 0x00, 0x00, 0x00, 0x8b, 0x8e, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xb6, 0x00, 0x00, 0x00, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00, 0xf7,
    0xd8, 0x8b, 0xce, 0x1b, 0xc0, 0x40, 0x89, 0x86, 0x00, 0x00, 0x00, 0x00,
    0xe8, 0x00, 0x00, 0x00, 0x00};
inline constexpr size_t kUpdateTWildcards[][2] = {
    {14u, 18u}, {29u, 33u}, {35u, 36u}, {38u, 42u}, {44u, 48u},
    {50u, 54u}, {55u, 59u}, {68u, 72u}, {73u, 77u}};
inline constexpr auto kUpdateTMask =
    WildcardMask<sizeof(kUpdateTBytes)>(kUpdateTWildcards);
inline constexpr size_t kUpdateTRendererDisp = 44u;
inline constexpr size_t kUpdateTRevealCall = 54u;
inline constexpr size_t kUpdateTSyncCall = 72u;
// Update-shaped bodies beyond which the image is not trusted.
inline constexpr size_t kMaxUpdateCopies = 8u;
// Window fields are dword members of a part object of a few hundred bytes.
inline constexpr uint32_t kMaxWindowFieldOffset = 0x1000u;
// SyncLayer: `mov ecx,[ebx+<screen>]; push eax; call Screen::CopyImage`; the
// disp8 is the window's screen field (+0x68 on the 2016 build, +0x6c on cs2
// 2.6.1.90).  Every copy inside SyncLayer must name the same field.
inline constexpr uint8_t kSyncScreenTBytes[] = {0x8b, 0x4b, 0x00, 0x50, 0xe8};
inline constexpr size_t kSyncScreenTWildcards[][2] = {{2u, 3u}};
inline constexpr auto kSyncScreenTMask =
    WildcardMask<sizeof(kSyncScreenTBytes)>(kSyncScreenTWildcards);
inline constexpr size_t kSyncScreenTDisp = 2u;

// Part-base layer query: `push [esi+4] (layer id); mov ecx,[esi+<screen>]
// (screen); call Screen::QueryLayer`; byte 15 is the screen field SyncLayer
// proved.
inline constexpr uint8_t kLayerQueryTBytes[] = {
    0x83, 0xec, 0x0c, 0x8d, 0x04, 0x24, 0x56, 0x8b, 0xf1, 0x50, 0xff,
    0x76, 0x04, 0x8b, 0x4e, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00};
inline constexpr size_t kLayerQueryTWildcards[][2] = {{17u, 21u}};
inline constexpr auto kLayerQueryTMask =
    WildcardMask<sizeof(kLayerQueryTBytes)>(kLayerQueryTWildcards);
inline constexpr size_t kLayerQueryTScreenDisp = 15u;
inline constexpr size_t kLayerQueryTCall = 16u;
// Screen::QueryLayer: the scene is [screen+8]; forwards to Scene::Visible.
// Two codegens of the same source: the result test is `dec eax` (2016) or
// `sub eax,1` (cs2 2.6.1.90), which moves the Scene::Visible call by two.
inline constexpr uint8_t kScreenQueryTBytes[] = {
    0x56, 0x8b, 0xf1, 0x83, 0x3e, 0x00, 0x75, 0x00, 0x83, 0x7e, 0x04, 0x00,
    0x74, 0x00, 0xff, 0x74, 0x24, 0x08, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x48,
    0x75, 0x00, 0xff, 0x74, 0x24, 0x0c, 0x8b, 0x4e, 0x08, 0xff, 0x74, 0x24,
    0x0c, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x5e, 0xc2, 0x08, 0x00};
inline constexpr size_t kScreenQueryTWildcards[][2] = {
    {7u, 8u}, {13u, 14u}, {19u, 23u}, {25u, 26u}, {38u, 42u}};
inline constexpr auto kScreenQueryTMask =
    WildcardMask<sizeof(kScreenQueryTBytes)>(kScreenQueryTWildcards);
inline constexpr size_t kScreenQueryTSceneCall = 37u;
inline constexpr uint8_t kScreenQueryT2Bytes[] = {
    0x56, 0x8b, 0xf1, 0x83, 0x3e, 0x00, 0x75, 0x00, 0x83, 0x7e, 0x04, 0x00,
    0x74, 0x00, 0xff, 0x74, 0x24, 0x08, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x83,
    0xe8, 0x01, 0x75, 0x00, 0xff, 0x74, 0x24, 0x0c, 0x8b, 0x4e, 0x08, 0xff,
    0x74, 0x24, 0x0c, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x5e, 0xc2, 0x08, 0x00};
inline constexpr size_t kScreenQueryT2Wildcards[][2] = {
    {7u, 8u}, {13u, 14u}, {19u, 23u}, {27u, 28u}, {40u, 44u}};
inline constexpr auto kScreenQueryT2Mask =
    WildcardMask<sizeof(kScreenQueryT2Bytes)>(kScreenQueryT2Wildcards);
inline constexpr size_t kScreenQueryT2SceneCall = 39u;
// Scene::Visible(id, out): Find returns the layer; visible = [layer+4].
inline constexpr uint8_t kSceneVisibleTBytes[] = {
    0xff, 0x74, 0x24, 0x04, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x85, 0xc0,
    0x75, 0x03, 0xc2, 0x08, 0x00, 0x8b, 0x48, 0x04, 0x8b, 0x44, 0x24,
    0x08, 0x89, 0x08, 0xb8, 0x01, 0x00, 0x00, 0x00, 0xc2, 0x08, 0x00};
inline constexpr size_t kSceneVisibleTWildcards[][2] = {{5u, 9u}};
inline constexpr auto kSceneVisibleTMask =
    WildcardMask<sizeof(kSceneVisibleTBytes)>(kSceneVisibleTWildcards);
inline constexpr size_t kSceneVisibleTFindCall = 4u;
// Scene::Find(id) (thiscall, one argument): the id map is [scene] and its
// head node [map].  Both builds load them first thing, through different
// registers (`mov edi,[ecx]; mov esi,[edi]` / `mov eax,[ecx]; ...; mov esi,
// [eax]`), so the proof reads the two loads, not the bytes around them.
inline constexpr size_t kSceneFindTMapScanBytes = 0x0cu;
// Scene::Draw: list = [scene+4], first = [[list]], layer = [node+8],
// skipped unless [layer+4] (visible) and [layer+0x10] (sprite).  The bytes
// between the loop test and the loop head are alignment (a short jump over
// int3 on the 2016 build, multi-byte nops on cs2 2.6.1.90).
inline constexpr uint8_t kSceneDrawTBytes[] = {
    0x8b, 0x47, 0x04, 0xc7, 0x44, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc7,
    0x44, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x89, 0x4c, 0x24, 0x00, 0x8b,
    0x00, 0x8b, 0x30, 0x3b, 0xf0, 0x0f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x8b,
    0x46, 0x08, 0x83, 0x78, 0x04, 0x00, 0x0f, 0x84, 0x00, 0x00, 0x00, 0x00,
    0x83, 0x78, 0x10, 0x00, 0x0f, 0x84, 0x00, 0x00, 0x00, 0x00};
inline constexpr size_t kSceneDrawTWildcards[][2] = {
    {6u, 7u}, {14u, 15u}, {22u, 23u}, {31u, 47u}, {56u, 60u}, {66u, 70u}};
inline constexpr auto kSceneDrawTMask =
    WildcardMask<sizeof(kSceneDrawTBytes)>(kSceneDrawTWildcards);

// Input::Handle(input, hwnd, msg, wparam, lparam, extra) with an aligned ebp
// frame.  The prologue spills its arguments in an order that differs between
// builds (`mov [esp+4],ecx` / `mov [esp],ecx`), so the proof reads the
// frame, the message load and the dispatch, not the spills:
//   push ebp; mov ebp,esp; and esp,-8; sub esp,imm32      (entry)
//   ... mov edx,[ebp+0x10] (msg) ...
//   cmp edx,0x200; ja; je; lea eax,[edx-6]; cmp eax,0xfc; ja;
//   movzx eax,byte [eax+table]; jmp [eax*4+table]
inline constexpr uint8_t kInputTFrameBytes[] = {0x55, 0x8b, 0xec, 0x83,
                                                0xe4, 0xf8, 0x81, 0xec};
inline constexpr uint8_t kInputTMessageBytes[] = {0x8b, 0x55, 0x10};
inline constexpr uint8_t kInputTDispatchBytes[] = {
    0x81, 0xfa, 0x00, 0x02, 0x00, 0x00, 0x0f, 0x87, 0x00, 0x00, 0x00, 0x00,
    0x0f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x8d, 0x42, 0xfa, 0x3d, 0xfc, 0x00,
    0x00, 0x00, 0x0f, 0x87, 0x00, 0x00, 0x00, 0x00, 0x0f, 0xb6, 0x80, 0x00,
    0x00, 0x00, 0x00, 0xff, 0x24, 0x85};
inline constexpr size_t kInputTDispatchWildcards[][2] = {
    {8u, 12u}, {14u, 18u}, {28u, 32u}, {35u, 39u}};
inline constexpr auto kInputTDispatchMask =
    WildcardMask<sizeof(kInputTDispatchBytes)>(kInputTDispatchWildcards);
// The dispatch starts this close after the frame.
inline constexpr size_t kInputTPrologueScanBytes = 0x50u;
// It returns with `ret 0x18`: one stack argument more than the first layout's
// Handle (input, hwnd, msg, wparam, lparam, extra).  The detour must pop the
// same number of bytes, so the epilogue is part of the proof.
inline constexpr uint8_t kInputTRetBytes[] = {0xc2, 0x18, 0x00};
inline constexpr uint32_t kInputStackArgs = 5u;
inline constexpr uint32_t kInputTStackArgs = 6u;

struct ImportSlots {
  uintptr_t get_glyph_outline = 0u;  // IAT slot RVAs
  uintptr_t set_capture = 0u;
  uintptr_t release_capture = 0u;
  uintptr_t window_from_point = 0u;
  uintptr_t get_foreground_window = 0u;
};

enum class SiteVariant : uint32_t {
  kNone = 0u,
  kAdjacentPage = 1u,    // RenderChar(renderer, record) after ClearPage
  kTargetedRender = 2u,  // RenderChar(renderer, record, target image)
};

// Object fields the runtime reads that the site proof itself establishes.
// The defaults are the first layout's (fixed by its signatures); the
// targeted-render proof reads each one from the code that uses it.
struct ObjectLayout {
  size_t window_screen = kWindowScreenOffset;      // [window+]: screen
  size_t window_renderer = kWindowRendererOffset;  // [window+]: renderer
  size_t page_width = kRendererPageWidthOffset;    // [renderer+]: int32
  size_t page_height = kRendererPageHeightOffset;
  size_t work_image = kRendererWorkImageOffset;    // [renderer+]: fade page
};

// One text-window class: its Update, the RenderChar its reveal loop draws
// through, the ClearPage of that renderer class and the fields read from
// that proving code.  The VS2013 cs2 2.6.1.90 build has two such classes
// (each with its own renderer class and RenderChar); which one a game shows
// its dialogue in is runtime configuration, so every proven class is hooked.
struct TextClass {
  uintptr_t clear_page = 0u;
  uintptr_t render_char = 0u;
  uintptr_t window_update = 0u;
  ObjectLayout layout;
};
inline constexpr size_t kMaxTextClasses = 2u;

struct Sites {
  // classes[0] mirrored for the first layout and for single-class callers.
  uintptr_t clear_page = 0u;     // hook targets (mapped addresses)
  uintptr_t render_char = 0u;
  uintptr_t window_update = 0u;
  uintptr_t input_handler = 0u;
  uintptr_t char_image = 0u;     // proof only
  uintptr_t rasteriser = 0u;
  SiteVariant variant = SiteVariant::kNone;
  uint32_t render_stack_args = 0u;  // RenderChar arguments after `this`
  uint32_t input_stack_args = 0u;   // Input::Handle stdcall arguments
  SceneWalk walk;
  ObjectLayout layout;
  uint32_t class_count = 0u;
  std::array<TextClass, kMaxTextClasses> classes{};
};

enum class SiteResult : uint32_t {
  kResolved = 0u,
  kNotX86 = 1u,
  kImportsMissing = 2u,
  kPageMissing = 3u,
  kRecordInvalid = 4u,
  kRasteriserInvalid = 5u,
  kUpdateMissing = 6u,
  kRevealInvalid = 7u,
  kSyncInvalid = 8u,
  kLayerQueryMissing = 9u,
  kSceneInvalid = 10u,
  kInputMissing = 11u,
  kInputImportsInvalid = 12u,
  kClearInvalid = 13u,
  kInputFrameInvalid = 14u,
};

inline bool IsExecutableImageAddress(const exact::LoadedPeImage& image,
                                     uintptr_t address, size_t bytes) {
  uintptr_t rva = 0u;
  return exact::AddressToRva(image, address, &rva) &&
         exact::SectionHasRole(exact::FindSectionForRva(image, rva, bytes),
                               IMAGE_SCN_MEM_EXECUTE) &&
         exact::IsReadableSpan(reinterpret_cast<const void*>(address), bytes);
}

inline bool OperandNamesSlot(const exact::LoadedPeImage& image,
                             const uint8_t* operand, uintptr_t slot_rva) {
  uintptr_t target = 0u;
  uintptr_t rva = 0u;
  return slot_rva != 0u &&
         exact::DecodeAbsolute32ImageAddress(image, operand, &target, &rva) &&
         rva == slot_rva;
}

inline bool MatchesAt(const uint8_t* candidate, const uint8_t* bytes,
                      const uint8_t* mask, size_t size) {
  if (!exact::IsReadableSpan(candidate, size)) return false;
  for (size_t index = 0u; index < size; ++index) {
    const uint8_t m = mask == nullptr ? 0xffu : mask[index];
    if ((candidate[index] & m) != (bytes[index] & m)) return false;
  }
  return true;
}

inline bool ContainsBytes(const uint8_t* begin, size_t bytes,
                          const uint8_t* needle, size_t size) {
  if (begin == nullptr || bytes < size ||
      !exact::IsReadableSpan(begin, bytes)) {
    return false;
  }
  for (size_t index = 0u; index + size <= bytes; ++index) {
    if (std::memcmp(begin + index, needle, size) == 0) return true;
  }
  return false;
}

// True when [begin, begin + bytes) calls `target` with a rel32 call.
inline bool CallsTarget(const exact::LoadedPeImage& image, uintptr_t begin,
                        size_t bytes, uintptr_t target) {
  if (!IsExecutableImageAddress(image, begin, bytes)) return false;
  const auto* code = reinterpret_cast<const uint8_t*>(begin);
  for (size_t index = 0u; index + 5u <= bytes; ++index) {
    if (code[index] != 0xe8u) continue;
    uintptr_t called = 0u;
    if (exact::DecodeRel32CallTarget(code + index, &called) &&
        called == target) {
      return true;
    }
  }
  return false;
}

// `call [slot]` somewhere in [begin, begin + bytes).
inline bool CallsImport(const exact::LoadedPeImage& image, uintptr_t begin,
                        size_t bytes, uintptr_t slot_rva) {
  if (!IsExecutableImageAddress(image, begin, bytes)) return false;
  const auto* code = reinterpret_cast<const uint8_t*>(begin);
  for (size_t index = 0u; index + 6u <= bytes; ++index) {
    if (code[index] == 0xffu && code[index + 1u] == 0x15u &&
        OperandNamesSlot(image, code + index + 2u, slot_rva)) {
      return true;
    }
  }
  return false;
}

inline exact::UniquePatternMatch FindUnique(const exact::LoadedPeImage& image,
                                            const uint8_t* bytes,
                                            const uint8_t* mask, size_t size) {
  const exact::MaskedPattern pattern = {bytes, mask, size};
  return exact::FindUniquePatternInExecutableSections(image, pattern);
}

// GetCharImage must call one rasteriser (at least twice) whose body calls
// GetGlyphOutlineA through its import slot.
inline bool ProveCharImage(const exact::LoadedPeImage& image,
                           uintptr_t char_image, uintptr_t glyph_slot,
                           uintptr_t* rasteriser) {
  if (!IsExecutableImageAddress(image, char_image, kCharImageScanBytes)) {
    return false;
  }
  const auto* code = reinterpret_cast<const uint8_t*>(char_image);
  uintptr_t found = 0u;
  uint32_t calls = 0u;
  for (size_t index = 0u; index + 5u <= kCharImageScanBytes; ++index) {
    if (code[index] != 0xe8u) continue;
    uintptr_t called = 0u;
    if (!exact::DecodeRel32CallTarget(code + index, &called) ||
        !IsExecutableImageAddress(image, called + kRasterBodyStart,
                                  kRasterScanBytes) ||
        !CallsImport(image, called + kRasterBodyStart, kRasterScanBytes,
                     glyph_slot)) {
      continue;
    }
    if (found != 0u && found != called) return false;  // two rasterisers
    found = called;
    ++calls;
  }
  if (found == 0u || calls < 2u) return false;
  *rasteriser = found;
  return true;
}

// Every occurrence of `pattern` in the executable sections must carry a rel32
// call at `call_offset` to one and the same target.  Returns false for no
// occurrence, disagreeing targets, too many copies or an unreadable section.
inline bool FindAgreeingCallTarget(const exact::LoadedPeImage& image,
                                   const uint8_t* bytes, const uint8_t* mask,
                                   size_t size, size_t call_offset,
                                   uint32_t max_copies, uintptr_t* target) {
  if (target == nullptr) return false;
  const exact::MaskedPattern pattern = {bytes, mask, size};
  uintptr_t agreed = 0u;
  uint32_t copies = 0u;
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto* section = &image.sections[index];
    if (!exact::SectionHasRole(section, IMAGE_SCN_MEM_EXECUTE)) continue;
    if (section->bytes == nullptr || section->size == 0u ||
        !exact::IsReadableSpan(section->bytes, section->size)) {
      return false;
    }
    if (section->size < size) continue;
    for (size_t offset = 0u; offset <= section->size - size; ++offset) {
      if (!exact::MatchesMaskedPattern(section->bytes + offset, pattern)) {
        continue;
      }
      uintptr_t called = 0u;
      if (++copies > max_copies ||
          !exact::DecodeRel32CallTarget(section->bytes + offset + call_offset,
                                        &called) ||
          (agreed != 0u && called != agreed)) {
        return false;
      }
      agreed = called;
    }
  }
  if (agreed == 0u) return false;
  *target = agreed;
  return true;
}

// True when some occurrence of `pattern` in the executable sections carries a
// rel32 call at `call_offset` to `target`.
inline bool AnyCallTargets(const exact::LoadedPeImage& image,
                           const uint8_t* bytes, const uint8_t* mask,
                           size_t size, size_t call_offset, uintptr_t target) {
  const exact::MaskedPattern pattern = {bytes, mask, size};
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto* section = &image.sections[index];
    if (!exact::SectionHasRole(section, IMAGE_SCN_MEM_EXECUTE)) continue;
    if (section->bytes == nullptr || section->size < size ||
        !exact::IsReadableSpan(section->bytes, section->size)) {
      continue;
    }
    for (size_t offset = 0u; offset <= section->size - size; ++offset) {
      if (!exact::MatchesMaskedPattern(section->bytes + offset, pattern)) {
        continue;
      }
      uintptr_t called = 0u;
      if (exact::DecodeRel32CallTarget(section->bytes + offset + call_offset,
                                       &called) &&
          called == target) {
        return true;
      }
    }
  }
  return false;
}

// Mapped address of an absolute (vtable) pointer into an executable section.
inline bool CodeAddressOf(const exact::LoadedPeImage& image, uint32_t absolute,
                          uintptr_t* address) {
  const uintptr_t base = image.absolute_base != 0u
                             ? image.absolute_base
                             : reinterpret_cast<uintptr_t>(image.base);
  if (absolute < base || absolute - base >= image.size) return false;
  const uintptr_t rva = absolute - base;
  if (!exact::SectionHasRole(exact::FindSectionForRva(image, rva, 1u),
                             IMAGE_SCN_MEM_EXECUTE)) {
    return false;
  }
  *address = reinterpret_cast<uintptr_t>(image.base) + rva;
  return true;
}

// GetCharImage of the targeted-render layout is only reachable through a
// vtable.  Scan the read-only data for vtable slot `kCharImageVtableSlot`
// entries (MSVC layout: the complete-object-locator pointer, which is data,
// directly before slot 0) whose function starts after int3 padding and
// passes ProveCharImage.  Exactly one distinct function must qualify.
inline bool FindVirtualCharImage(const exact::LoadedPeImage& image,
                                 uintptr_t glyph_slot, uintptr_t* char_image,
                                 uintptr_t* rasteriser) {
  static_assert(kCharImageVtableSlot >= 1u, "slot 0 has no code neighbour");
  constexpr size_t kLead = (kCharImageVtableSlot + 1u) * 4u;
  uintptr_t found = 0u;
  uintptr_t found_raster = 0u;
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto* section = &image.sections[index];
    if (!exact::SectionHasRole(section, IMAGE_SCN_MEM_READ,
                               IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_WRITE) ||
        section->bytes == nullptr || section->size < kLead + 4u ||
        !exact::IsReadableSpan(section->bytes, section->size)) {
      continue;
    }
    for (size_t offset = kLead; offset + 4u <= section->size; offset += 4u) {
      uint32_t words[kCharImageVtableSlot + 2u] = {};
      std::memcpy(words, section->bytes + offset - kLead, sizeof(words));
      uintptr_t target = 0u;
      uintptr_t ignored = 0u;
      if (!CodeAddressOf(image, words[kCharImageVtableSlot + 1u], &target) ||
          CodeAddressOf(image, words[0], &ignored)) {
        continue;
      }
      bool slots_are_code = true;
      for (size_t slot = 1u; slot <= kCharImageVtableSlot; ++slot) {
        slots_are_code =
            slots_are_code && CodeAddressOf(image, words[slot], &ignored);
      }
      if (!slots_are_code || target == found) continue;
      const auto* code = reinterpret_cast<const uint8_t*>(target);
      uintptr_t raster = 0u;
      if (!IsExecutableImageAddress(image, target - 1u, 1u) ||
          code[-1] != 0xccu ||
          !ProveCharImage(image, target, glyph_slot, &raster)) {
        continue;
      }
      if (found != 0u) return false;  // two candidates: ambiguous
      found = target;
      found_raster = raster;
    }
  }
  if (found == 0u) return false;
  *char_image = found;
  *rasteriser = found_raster;
  return true;
}

// First start of `needle` in code[begin, end), or SIZE_MAX.
inline size_t IndexOf(const uint8_t* code, size_t begin, size_t end,
                      const uint8_t* needle, size_t size) {
  for (size_t at = begin; at + size <= end; ++at) {
    if (std::memcmp(code + at, needle, size) == 0) return at;
  }
  return SIZE_MAX;
}

// Last start of `needle` in code[begin, end), or SIZE_MAX.
inline size_t LastIndexOf(const uint8_t* code, size_t begin, size_t end,
                          const uint8_t* needle, size_t size) {
  if (end < begin + size) return SIZE_MAX;
  for (size_t at = end - size + 1u; at-- > begin;) {
    if (std::memcmp(code + at, needle, size) == 0) return at;
  }
  return SIZE_MAX;
}

// The targeted-render RenderChar hands the record's code and font size to
// GetCharImage through the font vtable (see kCharImageCallTBytes).  `body`
// is the readable function body [entry, entry + body_bytes); exactly one
// `call [esi+4]` after the pen block must carry the argument chain.
inline bool HasVirtualCharImageCall(const uint8_t* body, size_t body_bytes,
                                    size_t first) {
  if (!exact::IsReadableSpan(body, body_bytes)) return false;
  uint32_t calls = 0u;
  for (size_t call = first + kRecordCharTScanBytes;
       call + sizeof(kCharImageCallTBytes) <= body_bytes; ++call) {
    if (std::memcmp(body + call, kCharImageCallTBytes,
                    sizeof(kCharImageCallTBytes)) != 0) {
      continue;
    }
    const size_t begin = call - kRecordCharTScanBytes;
    const size_t code = LastIndexOf(body, begin, call, kRecordCodePushTBytes,
                                    sizeof(kRecordCodePushTBytes));
    const size_t size = code == SIZE_MAX
                            ? SIZE_MAX
                            : LastIndexOf(body, begin, code,
                                          kRecordSizePushTBytes,
                                          sizeof(kRecordSizePushTBytes));
    const size_t self = size == SIZE_MAX
                            ? SIZE_MAX
                            : LastIndexOf(body, begin, size,
                                          kFontThisLoadTBytes,
                                          sizeof(kFontThisLoadTBytes));
    const size_t vtable = self == SIZE_MAX
                              ? SIZE_MAX
                              : LastIndexOf(body, begin, self,
                                            kFontVtableLoadTBytes,
                                            sizeof(kFontVtableLoadTBytes));
    const size_t object = vtable == SIZE_MAX
                              ? SIZE_MAX
                              : LastIndexOf(body, begin, vtable,
                                            kFontObjectLoadTBytes,
                                            sizeof(kFontObjectLoadTBytes));
    if (object != SIZE_MAX) ++calls;
  }
  return calls == 1u;
}

// One RenderChar-shaped prologue at `entry` (see kRenderTBytes): frame read
// from the prologue, record argument and pen block at the frame's stack
// offsets, the epilogue releasing that frame as the end of the body, and one
// GetCharImage vcall inside it.
inline bool ProveRenderCharT(const uint8_t* entry) {
  if (!exact::IsReadableSpan(entry, kRenderTMaxBodyBytes)) return false;
  uint32_t frame = 0u, lea = 0u, record = 0u;
  std::memcpy(&frame, entry + kRenderTFrameDisp, sizeof(frame));
  std::memcpy(&lea, entry + kRenderTLeaDisp, sizeof(lea));
  const uint8_t* pen = entry + kRecordPenTOffset;
  std::memcpy(&record, pen + kRecordPenTRecordDisp, sizeof(record));
  if (frame < kRenderTMinFrame || frame >= kRenderTMaxFrame ||
      frame % 4u != 0u || lea != frame - kRenderTLeaBelowFrame ||
      !MatchesAt(pen, kRecordPenTBytes, kRecordPenTMask.data(),
                 sizeof(kRecordPenTBytes)) ||
      record != frame + kRecordPenTRecordAboveFrame ||
      pen[kRecordPenTSecondLocal] !=
          static_cast<uint8_t>(pen[kRecordPenTFirstLocal] + 4u)) {
    return false;
  }
  uint8_t tail_bytes[sizeof(kRenderTailTBytes)] = {};
  std::memcpy(tail_bytes, kRenderTailTBytes, sizeof(tail_bytes));
  std::memcpy(tail_bytes + kRenderTailTFrameDisp, &frame, sizeof(frame));
  constexpr size_t kPenEnd = kRecordPenTOffset + sizeof(kRecordPenTBytes);
  const size_t tail = IndexOf(entry, kPenEnd, kRenderTMaxBodyBytes,
                              tail_bytes, sizeof(tail_bytes));
  return tail != SIZE_MAX && HasVirtualCharImageCall(entry, tail, kPenEnd);
}

/// ── targeted-render structural readers ─────────────────────────────────────

// Every occurrence of a masked pattern in the executable sections, up to
// `max`.  Returns the count, or SIZE_MAX when there are more than `max` or a
// section cannot be read (it could hide another occurrence).
inline size_t FindAllMatches(const exact::LoadedPeImage& image,
                             const uint8_t* bytes, const uint8_t* mask,
                             size_t size, const uint8_t** out, size_t max) {
  const exact::MaskedPattern pattern = {bytes, mask, size};
  size_t count = 0u;
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto& section = image.sections[index];
    if (!exact::SectionHasRole(&section, IMAGE_SCN_MEM_EXECUTE)) continue;
    if (section.bytes == nullptr || section.size == 0u ||
        !exact::IsReadableSpan(section.bytes, section.size)) {
      return SIZE_MAX;
    }
    if (section.size < size) continue;
    for (size_t offset = 0u; offset <= section.size - size; ++offset) {
      if (!exact::MatchesMaskedPattern(section.bytes + offset, pattern)) {
        continue;
      }
      if (count == max) return SIZE_MAX;
      out[count++] = section.bytes + offset;
    }
  }
  return count;
}

// A dword member of the message window (Update's renderer field).
inline bool IsWindowField(uint32_t offset) {
  return offset >= 8u && offset < kMaxWindowFieldOffset && offset % 4u == 0u;
}

// SyncLayer hands the page to the window's screen object; every
// `mov ecx,[ebx+d8]; push eax; call` in its body must name the same field.
inline bool FindSyncScreenField(const uint8_t* sync, uint8_t* field) {
  uint8_t agreed = 0u;
  for (size_t at = 0u; at + sizeof(kSyncScreenTBytes) <= kSyncScanBytes;
       ++at) {
    if (!MatchesAt(sync + at, kSyncScreenTBytes, kSyncScreenTMask.data(),
                   sizeof(kSyncScreenTBytes))) {
      continue;
    }
    const uint8_t disp = sync[at + kSyncScreenTDisp];
    if (agreed != 0u && disp != agreed) return false;
    agreed = disp;
  }
  // The layer id is +4; the screen is a later dword member.
  if (agreed < 8u || agreed % 4u != 0u) return false;
  *field = agreed;
  return true;
}

// One ClearPage-shaped body at `code` (see kClearTHeadBytes): fills the page
// size and fade page fields of `layout` and the fill helper both pages go
// through.
inline bool ParseClearPageT(const exact::LoadedPeImage& image,
                            const uint8_t* code, ObjectLayout* layout,
                            uintptr_t* fill) {
  if (!MatchesAt(code, kClearTHeadBytes, nullptr, sizeof(kClearTHeadBytes))) {
    return false;
  }
  size_t at = sizeof(kClearTHeadBytes) + 4u;
  size_t resets = 0u;
  uint8_t first_reset = 0u;
  constexpr uint8_t kZero[4] = {};
  while (resets < 16u &&
         MatchesAt(code + at, kClearTResetBytes, nullptr,
                   sizeof(kClearTResetBytes)) &&
         MatchesAt(code + at + 3u, kZero, nullptr, sizeof(kZero))) {
    const uint8_t disp = code[at + 2u];
    if (resets == 0u) {
      first_reset = disp;
    } else if (disp != static_cast<uint8_t>(first_reset + 4u * resets)) {
      return false;
    }
    at += 7u;
    ++resets;
  }
  if (resets < kClearTMinResets) return false;
  const uint8_t* normal = code + at;
  const uint8_t* fade = normal + sizeof(kClearTFillBytes);
  if (!MatchesAt(normal, kClearTFillBytes, kClearTFillMask.data(),
                 sizeof(kClearTFillBytes)) ||
      !MatchesAt(fade, kClearTFillBytes, kClearTFillMask.data(),
                 sizeof(kClearTFillBytes)) ||
      !MatchesAt(fade + sizeof(kClearTFillBytes), kClearTTailBytes, nullptr,
                 sizeof(kClearTTailBytes))) {
    return false;
  }
  const uint8_t width = normal[kClearTFillWidth];
  const uint8_t height = normal[kClearTFillHeight];
  const uint8_t work = fade[kClearTFillImage];
  if (normal[kClearTFillImage] != kRendererImageOffset ||
      fade[kClearTFillWidth] != width || fade[kClearTFillHeight] != height ||
      width < 8u || width % 4u != 0u || height != width + 4u ||
      work <= height || work % 4u != 0u || work >= 0x80u) {
    return false;
  }
  uintptr_t normal_fill = 0u;
  uintptr_t fade_fill = 0u;
  if (!exact::DecodeRel32CallTarget(normal + kClearTFillCall, &normal_fill) ||
      !exact::DecodeRel32CallTarget(fade + kClearTFillCall, &fade_fill) ||
      normal_fill != fade_fill ||
      !IsExecutableImageAddress(image, normal_fill, 1u)) {
    return false;
  }
  layout->page_width = width;
  layout->page_height = height;
  layout->work_image = work;
  *fill = normal_fill;
  return true;
}

// [begin, end) of the function around `at` in `section`: bounded by int3
// padding (two consecutive 0xcc) or kCallerFunctionScanBytes either way.
inline void FunctionAround(const exact::LoadedPeSection& section, size_t at,
                           size_t* begin, size_t* end) {
  const uint8_t* bytes = section.bytes;
  size_t low = at;
  while (low > 0u && at - low < kCallerFunctionScanBytes &&
         !(low >= 2u && bytes[low - 1u] == 0xccu && bytes[low - 2u] == 0xccu)) {
    --low;
  }
  size_t high = at;
  while (high + 2u <= section.size && high - at < kCallerFunctionScanBytes &&
         !(bytes[high] == 0xccu && bytes[high + 1u] == 0xccu)) {
    ++high;
  }
  *begin = low;
  *end = high;
}

// Some occurrence of `pattern` with a rel32 call at `call_offset` to `target`
// sits in a function that also calls `also` with a rel32 call.
inline bool CallerAlsoCalls(const exact::LoadedPeImage& image,
                            const uint8_t* bytes, const uint8_t* mask,
                            size_t size, size_t call_offset, uintptr_t target,
                            uintptr_t also) {
  const exact::MaskedPattern pattern = {bytes, mask, size};
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto& section = image.sections[index];
    if (!exact::SectionHasRole(&section, IMAGE_SCN_MEM_EXECUTE) ||
        section.bytes == nullptr || section.size < size ||
        !exact::IsReadableSpan(section.bytes, section.size)) {
      continue;
    }
    for (size_t offset = 0u; offset <= section.size - size; ++offset) {
      uintptr_t called = 0u;
      if (!exact::MatchesMaskedPattern(section.bytes + offset, pattern) ||
          !exact::DecodeRel32CallTarget(section.bytes + offset + call_offset,
                                        &called) ||
          called != target) {
        continue;
      }
      size_t begin = 0u;
      size_t end = 0u;
      FunctionAround(section, offset, &begin, &end);
      for (size_t at = begin; at + 5u <= end; ++at) {
        uintptr_t other = 0u;
        if (section.bytes[at] == 0xe8u &&
            exact::DecodeRel32CallTarget(section.bytes + at, &other) &&
            other == also) {
          return true;
        }
      }
    }
  }
  return false;
}

// The message window's ClearPage: a ClearPage-shaped body called through the
// window's renderer field.  When more than one qualifies (another renderer
// class with the same body behind another window class), only the one whose
// caller also runs the reveal loop is the message window's.
inline bool FindClearPageT(const exact::LoadedPeImage& image,
                           uint32_t window_renderer, uintptr_t reveal,
                           uintptr_t* clear_page, ObjectLayout* layout) {
  uint8_t call[sizeof(kClearCallTBytes)] = {};
  std::memcpy(call, kClearCallTBytes, sizeof(call));
  std::memcpy(call + kClearCallTDisp, &window_renderer,
              sizeof(window_renderer));
  uintptr_t candidates[kMaxClearPageCopies] = {};
  ObjectLayout layouts[kMaxClearPageCopies] = {};
  uint32_t count = 0u;
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto& section = image.sections[index];
    if (!exact::SectionHasRole(&section, IMAGE_SCN_MEM_EXECUTE)) continue;
    if (section.bytes == nullptr || section.size == 0u ||
        !exact::IsReadableSpan(section.bytes, section.size)) {
      return false;  // could hide another candidate
    }
    for (size_t offset = 0u;
         offset + sizeof(kClearTHeadBytes) <= section.size; ++offset) {
      if (std::memcmp(section.bytes + offset, kClearTHeadBytes,
                      sizeof(kClearTHeadBytes)) != 0) {
        continue;
      }
      ObjectLayout parsed = *layout;
      uintptr_t fill = 0u;
      const uintptr_t at = reinterpret_cast<uintptr_t>(section.bytes + offset);
      if (!ParseClearPageT(image, section.bytes + offset, &parsed, &fill) ||
          !AnyCallTargets(image, call, kClearCallTMask.data(), sizeof(call),
                          kClearCallTCall, at)) {
        continue;
      }
      if (count == kMaxClearPageCopies) return false;
      candidates[count] = at;
      layouts[count] = parsed;
      ++count;
    }
  }
  uint32_t chosen = count;
  if (count == 1u) {
    chosen = 0u;
  } else {
    for (uint32_t index = 0u; index < count; ++index) {
      if (!CallerAlsoCalls(image, call, kClearCallTMask.data(), sizeof(call),
                           kClearCallTCall, candidates[index], reveal)) {
        continue;
      }
      if (chosen != count) return false;  // still ambiguous
      chosen = index;
    }
  }
  if (chosen == count) return false;
  *clear_page = candidates[chosen];
  *layout = layouts[chosen];
  return true;
}

// Scene::Find loads the id map from [ecx] and its head node from [map]
// within its first instructions (see kSceneFindTMapScanBytes).
inline bool MatchesSceneFindT(const uint8_t* code) {
  constexpr size_t kBytes = 2u * kSceneFindTMapScanBytes + 2u;
  if (!exact::IsReadableSpan(code, kBytes)) return false;
  for (size_t at = 0u; at < kSceneFindTMapScanBytes; ++at) {
    // `mov r,[ecx]`: mod 00, rm 001.
    if (code[at] != 0x8bu || (code[at + 1u] & 0xc7u) != 0x01u) continue;
    const uint8_t map = (code[at + 1u] >> 3u) & 7u;
    if (map == 1u || map == 4u || map == 5u) continue;
    for (size_t head = at + 2u; head < at + 2u + kSceneFindTMapScanBytes;
         ++head) {
      // `mov r,[map]`: mod 00, rm = map.
      if (code[head] == 0x8bu && (code[head + 1u] & 0xc7u) == map) {
        return true;
      }
    }
  }
  return false;
}

// Input::Handle of the targeted-render layout (see kInputTFrameBytes): the
// unique dispatch on the message whose function starts with the aligned
// ebp frame shortly before it and loads the message from [ebp+0x10].
inline exact::UniquePatternMatch FindInputHandlerT(
    const exact::LoadedPeImage& image) {
  const exact::MaskedPattern dispatch = {kInputTDispatchBytes,
                                         kInputTDispatchMask.data(),
                                         sizeof(kInputTDispatchBytes)};
  exact::UniquePatternMatch result;
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto& section = image.sections[index];
    if (!exact::SectionHasRole(&section, IMAGE_SCN_MEM_EXECUTE)) continue;
    if (section.bytes == nullptr || section.size == 0u ||
        !exact::IsReadableSpan(section.bytes, section.size)) {
      return {nullptr, 2u};
    }
    for (size_t offset = 0u;
         offset + sizeof(kInputTDispatchBytes) <= section.size; ++offset) {
      if (!exact::MatchesMaskedPattern(section.bytes + offset, dispatch)) {
        continue;
      }
      const size_t low =
          offset > kInputTPrologueScanBytes ? offset - kInputTPrologueScanBytes
                                            : 0u;
      const size_t frame = LastIndexOf(section.bytes, low, offset,
                                       kInputTFrameBytes,
                                       sizeof(kInputTFrameBytes));
      if (frame == SIZE_MAX ||
          LastIndexOf(section.bytes, frame + sizeof(kInputTFrameBytes),
                      offset, kInputTMessageBytes,
                      sizeof(kInputTMessageBytes)) == SIZE_MAX) {
        continue;
      }
      if (++result.count == 1u) result.address = section.bytes + frame;
    }
  }
  if (result.count != 1u) result.address = nullptr;
  return result;
}

// Layout A: ClearPage and RenderChar(renderer, record) back to back.
inline SiteResult ResolveAdjacentPageSites(const exact::LoadedPeImage& image,
                                           const ImportSlots& imports,
                                           Sites* found) {
  // ── ClearPage + RenderChar, record layout, rasteriser chain ──
  const auto page = FindUnique(image, kPageBytes, kPageMask.data(),
                               sizeof(kPageBytes));
  if (page.count != 1u) return SiteResult::kPageMissing;
  const uint8_t* render = page.address + kPageRenderOffset;
  if (!MatchesAt(render + kRecordPenOffset, kRecordPenBytes, nullptr,
                 sizeof(kRecordPenBytes)) ||
      !MatchesAt(render + kRecordCharOffset, kRecordCharBytes,
                 kRecordCharMask.data(), sizeof(kRecordCharBytes))) {
    return SiteResult::kRecordInvalid;
  }
  uintptr_t char_image = 0u;
  uintptr_t rasteriser = 0u;
  if (!exact::DecodeRel32CallTarget(
          render + kRecordCharOffset + kRecordCharImageCall, &char_image) ||
      !ProveCharImage(image, char_image, imports.get_glyph_outline,
                      &rasteriser)) {
    return SiteResult::kRasteriserInvalid;
  }
  found->clear_page = reinterpret_cast<uintptr_t>(page.address);
  found->render_char = reinterpret_cast<uintptr_t>(render);
  found->char_image = char_image;
  found->rasteriser = rasteriser;

  // ── message-window Update → reveal loop → RenderChar; SyncLayer ──
  const auto update = FindUnique(image, kUpdateBytes, kUpdateMask.data(),
                                 sizeof(kUpdateBytes));
  if (update.count != 1u) return SiteResult::kUpdateMissing;
  uintptr_t reveal = 0u;
  if (!exact::DecodeRel32CallTarget(update.address + kUpdateRevealCall,
                                    &reveal) ||
      !CallsTarget(image, reveal, kRevealScanBytes, found->render_char)) {
    return SiteResult::kRevealInvalid;
  }
  uintptr_t sync = 0u;
  if (!exact::DecodeRel32CallTarget(update.address + kUpdateSyncCall,
                                    &sync) ||
      !IsExecutableImageAddress(image, sync, kSyncScanBytes) ||
      !ContainsBytes(reinterpret_cast<const uint8_t*>(sync), kSyncScanBytes,
                     kSyncScreenBytes, sizeof(kSyncScreenBytes))) {
    return SiteResult::kSyncInvalid;
  }
  found->window_update = reinterpret_cast<uintptr_t>(update.address);

  // ── layer id / screen → scene list layout ──
  uintptr_t screen_query = 0u;
  if (!FindAgreeingCallTarget(image, kLayerQueryBytes, kLayerQueryMask.data(),
                              sizeof(kLayerQueryBytes), kLayerQueryCall,
                              kMaxLayerQueryCopies, &screen_query)) {
    return SiteResult::kLayerQueryMissing;
  }
  uintptr_t scene_visible = 0u;
  uintptr_t scene_find = 0u;
  if (!MatchesAt(reinterpret_cast<const uint8_t*>(screen_query),
                 kScreenQueryBytes, kScreenQueryMask.data(),
                 sizeof(kScreenQueryBytes)) ||
      !exact::DecodeRel32CallTarget(
          reinterpret_cast<const uint8_t*>(screen_query) +
              kScreenQuerySceneCall,
          &scene_visible) ||
      !MatchesAt(reinterpret_cast<const uint8_t*>(scene_visible),
                 kSceneVisibleBytes, kSceneVisibleMask.data(),
                 sizeof(kSceneVisibleBytes)) ||
      !ContainsBytes(reinterpret_cast<const uint8_t*>(scene_visible),
                     kSceneVisibleScanBytes, kNodeVisibleReadBytes,
                     sizeof(kNodeVisibleReadBytes)) ||
      !exact::DecodeRel32CallTarget(
          reinterpret_cast<const uint8_t*>(scene_visible) +
              kSceneVisibleFindCall,
          &scene_find) ||
      !MatchesAt(reinterpret_cast<const uint8_t*>(scene_find),
                 kSceneFindBytes, nullptr, sizeof(kSceneFindBytes)) ||
      !ContainsBytes(reinterpret_cast<const uint8_t*>(scene_find),
                     kSceneFindScanBytes, kNodeIdCompareBytes,
                     sizeof(kNodeIdCompareBytes))) {
    return SiteResult::kSceneInvalid;
  }

  // ── input handler ──
  const auto input = FindUnique(image, kInputBytes, kInputMask.data(),
                                sizeof(kInputBytes));
  if (input.count != 1u) return SiteResult::kInputMissing;
  const uintptr_t handler = reinterpret_cast<uintptr_t>(input.address);
  if (!CallsImport(image, handler, kInputScanBytes, imports.set_capture) ||
      !CallsImport(image, handler, kInputScanBytes, imports.release_capture) ||
      !CallsImport(image, handler, kInputScanBytes,
                   imports.window_from_point)) {
    return SiteResult::kInputImportsInvalid;
  }
  found->input_handler = handler;
  found->class_count = 1u;
  found->classes[0] = {found->clear_page, found->render_char,
                       found->window_update, found->layout};
  found->variant = SiteVariant::kAdjacentPage;
  found->render_stack_args = 1u;
  found->input_stack_args = kInputStackArgs;
  found->walk = kAdjacentPageWalk;
  return SiteResult::kResolved;
}

// Layout B: RenderChar(renderer, record, target), GetCharImage via vtable,
// ClearPage proven by its body and its message-window caller.  The window and
// renderer field offsets the runtime needs are read from the proving code
// (Update, SyncLayer, ClearPage), not assumed.
inline SiteResult ResolveTargetedRenderSites(
    const exact::LoadedPeImage& image, const ImportSlots& imports,
    Sites* found) {
  // ── RenderChar(s), record layout, rasteriser chain ──
  // Every RenderChar-shaped prologue must pass the record proof (an
  // unexplained copy could be the one the game draws with).
  const uint8_t* renders[kMaxRenderCopies] = {};
  const size_t render_count =
      FindAllMatches(image, kRenderTBytes, kRenderTMask.data(),
                     sizeof(kRenderTBytes), renders, kMaxRenderCopies);
  if (render_count == 0u || render_count == SIZE_MAX) {
    return SiteResult::kPageMissing;
  }
  for (size_t index = 0u; index < render_count; ++index) {
    if (!ProveRenderCharT(renders[index])) return SiteResult::kRecordInvalid;
  }
  uintptr_t char_image = 0u;
  uintptr_t rasteriser = 0u;
  if (!FindVirtualCharImage(image, imports.get_glyph_outline, &char_image,
                            &rasteriser)) {
    return SiteResult::kRasteriserInvalid;
  }
  found->char_image = char_image;
  found->rasteriser = rasteriser;

  // ── text-window Update → reveal loop → RenderChar; SyncLayer ──
  // Several part classes share the Update body.  A text-window class is an
  // Update whose reveal renders through one of the proven RenderChars; each
  // RenderChar belongs to at most one such Update.  Updates whose reveal
  // renders through none of them are other parts, not text windows.
  const uint8_t* updates[kMaxUpdateCopies] = {};
  const size_t update_count =
      FindAllMatches(image, kUpdateTBytes, kUpdateTMask.data(),
                     sizeof(kUpdateTBytes), updates, kMaxUpdateCopies);
  if (update_count == 0u || update_count == SIZE_MAX) {
    return SiteResult::kUpdateMissing;
  }
  struct Candidate {
    const uint8_t* update;
    uintptr_t reveal;
    uintptr_t render;
  };
  Candidate classes[kMaxTextClasses] = {};
  size_t class_count = 0u;
  for (size_t index = 0u; index < update_count; ++index) {
    uintptr_t reveal = 0u;
    if (!exact::DecodeRel32CallTarget(updates[index] + kUpdateTRevealCall,
                                      &reveal)) {
      continue;
    }
    uintptr_t render = 0u;
    for (size_t r = 0u; r < render_count; ++r) {
      const uintptr_t target = reinterpret_cast<uintptr_t>(renders[r]);
      if (!CallsTarget(image, reveal, kRevealScanBytes, target)) continue;
      if (render != 0u) return SiteResult::kRevealInvalid;  // two renderers
      render = target;
    }
    if (render == 0u) continue;
    for (size_t c = 0u; c < class_count; ++c) {
      if (classes[c].render == render) return SiteResult::kUpdateMissing;
    }
    if (class_count == kMaxTextClasses) return SiteResult::kUpdateMissing;
    classes[class_count++] = {updates[index], reveal, render};
  }
  if (class_count == 0u) return SiteResult::kRevealInvalid;

  // ── per class: window fields, ClearPage (both page images through one
  //    fill; called through the window's renderer field by the caller that
  //    also drives this class's reveal) ──
  uint8_t window_screen = 0u;
  for (size_t c = 0u; c < class_count; ++c) {
    uint32_t window_renderer = 0u;
    std::memcpy(&window_renderer, classes[c].update + kUpdateTRendererDisp,
                sizeof(window_renderer));
    if (!IsWindowField(window_renderer)) return SiteResult::kUpdateMissing;
    uintptr_t sync = 0u;
    uint8_t screen = 0u;
    if (!exact::DecodeRel32CallTarget(classes[c].update + kUpdateTSyncCall,
                                      &sync) ||
        !IsExecutableImageAddress(image, sync, kSyncScanBytes) ||
        !FindSyncScreenField(reinterpret_cast<const uint8_t*>(sync),
                             &screen) ||
        (window_screen != 0u && screen != window_screen)) {
      return SiteResult::kSyncInvalid;  // the part base has one screen field
    }
    window_screen = screen;
    TextClass& out = found->classes[c];
    out.layout.window_renderer = window_renderer;
    out.layout.window_screen = screen;
    if (!FindClearPageT(image, window_renderer, classes[c].reveal,
                        &out.clear_page, &out.layout)) {
      return SiteResult::kClearInvalid;
    }
    out.render_char = classes[c].render;
    out.window_update = reinterpret_cast<uintptr_t>(classes[c].update);
  }
  found->class_count = static_cast<uint32_t>(class_count);
  found->render_char = found->classes[0].render_char;
  found->clear_page = found->classes[0].clear_page;
  found->window_update = found->classes[0].window_update;
  const ObjectLayout layout = found->classes[0].layout;

  // ── layer id / screen → scene (layer by pointer) ──
  uint8_t layer_query[sizeof(kLayerQueryTBytes)] = {};
  std::memcpy(layer_query, kLayerQueryTBytes, sizeof(layer_query));
  layer_query[kLayerQueryTScreenDisp] = window_screen;  // all classes
  uintptr_t screen_query = 0u;
  if (!FindAgreeingCallTarget(image, layer_query, kLayerQueryTMask.data(),
                              sizeof(layer_query), kLayerQueryTCall,
                              kMaxLayerQueryCopies, &screen_query)) {
    return SiteResult::kLayerQueryMissing;
  }
  const auto* screen_code = reinterpret_cast<const uint8_t*>(screen_query);
  uintptr_t scene_visible = 0u;
  uintptr_t scene_find = 0u;
  const bool screen_query_valid =
      MatchesAt(screen_code, kScreenQueryTBytes, kScreenQueryTMask.data(),
                sizeof(kScreenQueryTBytes))
          ? exact::DecodeRel32CallTarget(screen_code + kScreenQueryTSceneCall,
                                         &scene_visible)
          : MatchesAt(screen_code, kScreenQueryT2Bytes,
                      kScreenQueryT2Mask.data(), sizeof(kScreenQueryT2Bytes)) &&
                exact::DecodeRel32CallTarget(
                    screen_code + kScreenQueryT2SceneCall, &scene_visible);
  if (!screen_query_valid ||
      !MatchesAt(reinterpret_cast<const uint8_t*>(scene_visible),
                 kSceneVisibleTBytes, kSceneVisibleTMask.data(),
                 sizeof(kSceneVisibleTBytes)) ||
      !exact::DecodeRel32CallTarget(
          reinterpret_cast<const uint8_t*>(scene_visible) +
              kSceneVisibleTFindCall,
          &scene_find) ||
      !MatchesSceneFindT(reinterpret_cast<const uint8_t*>(scene_find)) ||
      FindUnique(image, kSceneDrawTBytes, kSceneDrawTMask.data(),
                 sizeof(kSceneDrawTBytes))
              .count != 1u) {
    return SiteResult::kSceneInvalid;
  }

  // ── input handler ──
  const auto input = FindInputHandlerT(image);
  if (input.count != 1u) return SiteResult::kInputMissing;
  const uintptr_t handler = reinterpret_cast<uintptr_t>(input.address);
  if (!CallsImport(image, handler, kInputScanBytes, imports.set_capture) ||
      !CallsImport(image, handler, kInputScanBytes, imports.release_capture) ||
      !CallsImport(image, handler, kInputScanBytes,
                   imports.window_from_point)) {
    return SiteResult::kInputImportsInvalid;
  }
  if (!ContainsBytes(input.address, kInputScanBytes, kInputTRetBytes,
                     sizeof(kInputTRetBytes))) {
    return SiteResult::kInputFrameInvalid;
  }
  found->input_handler = handler;
  found->input_stack_args = kInputTStackArgs;
  found->variant = SiteVariant::kTargetedRender;
  found->render_stack_args = kRenderTStackArgs;
  found->walk = kTargetedRenderWalk;
  found->layout = layout;
  return SiteResult::kResolved;
}

// Resolves every site from structure alone.  The layout is chosen by which
// RenderChar signature exists; any missing or ambiguous proof returns a
// failure and leaves `sites` zeroed.
inline SiteResult ResolveSites(const exact::LoadedPeImage& image,
                               const ImportSlots& imports, Sites* sites) {
  if (sites == nullptr) return SiteResult::kPageMissing;
  *sites = {};
  if (image.machine != IMAGE_FILE_MACHINE_I386 || image.pointer_bits != 32u) {
    return SiteResult::kNotX86;
  }
  if (imports.get_glyph_outline == 0u || imports.set_capture == 0u ||
      imports.release_capture == 0u || imports.window_from_point == 0u ||
      imports.get_foreground_window == 0u) {
    return SiteResult::kImportsMissing;
  }
  Sites found;
  SiteResult result = ResolveAdjacentPageSites(image, imports, &found);
  if (result == SiteResult::kPageMissing) {
    found = {};
    result = ResolveTargetedRenderSites(image, imports, &found);
  }
  if (result == SiteResult::kResolved) *sites = found;
  return result;
}

// ── import slots (x86 import directory) ────────────────────────────────────

inline const uint8_t* ImageBytesAt(const exact::LoadedPeImage& image,
                                   uint64_t rva, uint64_t bytes) {
  return image.base != nullptr && bytes != 0u && rva < image.size &&
                 bytes <= static_cast<uint64_t>(image.size) - rva
             ? image.base + rva
             : nullptr;
}

inline bool AsciiEquals(const exact::LoadedPeImage& image, uint64_t rva,
                        const char* expected, bool ignore_case) {
  for (size_t index = 0u;; ++index) {
    const uint8_t* ch = ImageBytesAt(image, rva + index, 1u);
    if (ch == nullptr) return false;
    char lhs = static_cast<char>(*ch);
    char rhs = expected[index];
    if (ignore_case) {
      if (lhs >= 'A' && lhs <= 'Z') lhs = static_cast<char>(lhs - 'A' + 'a');
      if (rhs >= 'A' && rhs <= 'Z') rhs = static_cast<char>(rhs - 'A' + 'a');
    }
    if (lhs != rhs) return false;
    if (lhs == '\0') return true;
  }
}

// IAT slot RVA of `dll!symbol` (by name), or 0.
inline uintptr_t FindImportSlotRva(const exact::LoadedPeImage& image,
                                   const char* dll, const char* symbol) {
  const uint8_t* dos_bytes = ImageBytesAt(image, 0u, sizeof(IMAGE_DOS_HEADER));
  if (dos_bytes == nullptr || dll == nullptr || symbol == nullptr) return 0u;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(dos_bytes);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) return 0u;
  const uint8_t* nt_bytes = ImageBytesAt(
      image, static_cast<uint64_t>(dos->e_lfanew), sizeof(IMAGE_NT_HEADERS32));
  if (nt_bytes == nullptr) return 0u;
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS32*>(nt_bytes);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC ||
      nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_IMPORT) {
    return 0u;
  }
  const uint32_t directory =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT]
          .VirtualAddress;
  if (directory == 0u) return 0u;
  for (uint32_t offset = 0u;; offset += sizeof(IMAGE_IMPORT_DESCRIPTOR)) {
    const uint8_t* bytes = ImageBytesAt(
        image, static_cast<uint64_t>(directory) + offset,
        sizeof(IMAGE_IMPORT_DESCRIPTOR));
    if (bytes == nullptr) return 0u;
    const auto* desc = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(bytes);
    if (desc->Name == 0u && desc->FirstThunk == 0u) return 0u;
    if (!AsciiEquals(image, desc->Name, dll, true)) continue;
    const uint32_t lookup = desc->OriginalFirstThunk != 0u
                                ? desc->OriginalFirstThunk
                                : desc->FirstThunk;
    if (lookup == 0u || desc->FirstThunk == 0u) return 0u;
    for (uint32_t index = 0u;; ++index) {
      const uint8_t* entry_bytes = ImageBytesAt(
          image, static_cast<uint64_t>(lookup) + index * 4u, 4u);
      if (entry_bytes == nullptr) return 0u;
      uint32_t entry = 0u;
      std::memcpy(&entry, entry_bytes, sizeof(entry));
      if (entry == 0u) break;
      if ((entry & IMAGE_ORDINAL_FLAG32) != 0u) continue;
      if (AsciiEquals(image, static_cast<uint64_t>(entry) + 2u, symbol,
                      false)) {
        return static_cast<uintptr_t>(desc->FirstThunk) + index * 4u;
      }
    }
  }
}

// ── glyph codes ────────────────────────────────────────────────────────────

// The record code is a Shift_JIS code: one byte (ASCII / half-width katakana)
// or lead<<8|trail.  Anything that is not exactly one printable character
// decodes to 0 ("unknown"), which keeps the glyph out of every text match.
inline uint32_t DecodeGlyphCode(uint32_t code) {
  if (code == 0u || code > 0xffffu) return 0u;
  char bytes[2] = {};
  int length = 1;
  if (code <= 0xffu) {
    bytes[0] = static_cast<char>(code);
  } else {
    bytes[0] = static_cast<char>(code >> 8u);
    bytes[1] = static_cast<char>(code & 0xffu);
    length = 2;
  }
  wchar_t decoded[2] = {};
  if (MultiByteToWideChar(932, MB_ERR_INVALID_CHARS, bytes, length, decoded,
                          2) != 1) {
    return 0u;
  }
  const uint32_t scalar = decoded[0];
  if (scalar < 0x20u || (scalar >= 0x7fu && scalar <= 0x9fu) ||
      scalar == 0xfffdu || (scalar >= 0xd800u && scalar <= 0xdfffu)) {
    return 0u;
  }
  return scalar;
}

// Cell width of one record: the engine's own pen advance when it is sane,
// else full width for a two-byte code and half width for a single byte.
inline int32_t GlyphCellWidth(uint32_t code, int32_t advance,
                              int32_t font_size) {
  if (advance > 0 && advance <= 2 * font_size) return advance;
  const int32_t width = code > 0xffu ? font_size : font_size / 2;
  return width > 0 ? width : 1;
}

// ── geometry primitives ────────────────────────────────────────────────────

struct IntRect {
  int32_t x0 = 0;  // inclusive-exclusive
  int32_t y0 = 0;
  int32_t x1 = 0;
  int32_t y1 = 0;
  bool Empty() const { return x1 <= x0 || y1 <= y0; }
  bool Intersects(const IntRect& other) const {
    return !Empty() && !other.Empty() && x0 < other.x1 && other.x0 < x1 &&
           y0 < other.y1 && other.y0 < y1;
  }
};

// Targeted-render RenderChar draws into one of the renderer's two page
// images; any other target is not this renderer's text page.
inline bool IsRendererPage(uintptr_t target, uintptr_t page,
                           uintptr_t work_page) {
  return target != 0u && (target == page || target == work_page);
}

inline IntRect Intersect(const IntRect& a, const IntRect& b) {
  return {(std::max)(a.x0, b.x0), (std::max)(a.y0, b.y0),
          (std::min)(a.x1, b.x1), (std::min)(a.y1, b.y1)};
}

inline bool Contains(const IntRect& outer, const IntRect& inner) {
  return !inner.Empty() && outer.x0 <= inner.x0 && outer.y0 <= inner.y0 &&
         inner.x1 <= outer.x1 && inner.y1 <= outer.y1;
}

// ── scene layers ───────────────────────────────────────────────────────────

// One node of the scene's draw-ordered layer list, as read on the game
// thread (bounded copy; the walk itself lives in the runtime).
struct LayerNode {
  int32_t id = 0;
  bool visible = false;
  bool has_sprite = false;
  float x = 0.0f;  // sprite position / size (design pixels)
  float y = 0.0f;
  float w = 0.0f;
  float h = 0.0f;
  int32_t box[4] = {};  // drawn bounding box x0 y0 x1 y1
};

inline constexpr size_t kMaxLayerNodes = 128u;
inline constexpr size_t kMaxCovers = 8u;

// Where one message window's page lands on the design screen, and which
// later-drawn layers cover parts of it.
struct Placement {
  bool valid = false;    // the layer was found and its sprite is consistent
  bool visible = false;  // the node draws this frame
  int32_t x = 0;         // design position of page pixel (0, 0)
  int32_t y = 0;
  uint32_t cover_count = 0u;
  bool covers_overflow = false;
  std::array<IntRect, kMaxCovers> covers{};
};

inline bool IntegralFloat(float value, int32_t* out) {
  if (!std::isfinite(value) || value < -32768.0f || value > 32768.0f) {
    return false;
  }
  const float rounded = std::floor(value);
  if (rounded != value) return false;
  *out = static_cast<int32_t>(rounded);
  return true;
}

// The drawn box of a visible sprite, as a half-open design rectangle.
inline IntRect SpriteBox(const LayerNode& node) {
  return {node.box[0], node.box[1], node.box[2], node.box[3]};
}

// Placement of the page (page_w x page_h) of layer `id`: exactly one node
// must carry the id; its sprite must be unscaled (integral position, size
// equal to the page, bounding box {x-1, y-1, x+w, y+h}).  Every visible node
// drawn after it whose box meets the page becomes a cover.
inline Placement ResolvePlacement(const LayerNode* nodes, size_t count,
                                  int32_t id, int32_t page_w,
                                  int32_t page_h) {
  Placement placement;
  if (nodes == nullptr || page_w <= 0 || page_h <= 0) return placement;
  size_t found = count;
  for (size_t index = 0u; index < count; ++index) {
    if (nodes[index].id != id) continue;
    if (found != count) return placement;  // duplicate id: ambiguous
    found = index;
  }
  if (found == count) return placement;
  const LayerNode& node = nodes[found];
  if (!node.has_sprite) return placement;
  int32_t x = 0, y = 0, w = 0, h = 0;
  if (!IntegralFloat(node.x, &x) || !IntegralFloat(node.y, &y) ||
      !IntegralFloat(node.w, &w) || !IntegralFloat(node.h, &h) ||
      w != page_w || h != page_h) {
    return placement;
  }
  placement.valid = true;
  placement.x = x;
  placement.y = y;
  if (!node.visible) return placement;
  if (node.box[0] != x - 1 || node.box[1] != y - 1 || node.box[2] != x + w ||
      node.box[3] != y + h) {
    placement.valid = false;  // drawn scaled/rotated: not this projection
    return placement;
  }
  placement.visible = true;
  const IntRect page = {x, y, x + w, y + h};
  for (size_t index = found + 1u; index < count; ++index) {
    const LayerNode& later = nodes[index];
    if (!later.visible || !later.has_sprite) continue;
    const IntRect box = SpriteBox(later);
    if (!box.Intersects(page)) continue;
    if (placement.cover_count >= kMaxCovers) {
      placement.covers_overflow = true;
      break;
    }
    placement.covers[placement.cover_count++] = Intersect(box, page);
  }
  return placement;
}

// Design size from the screen object's two size pairs: both must agree.
inline bool DesignSize(int32_t w, int32_t h, int32_t mirror_w,
                       int32_t mirror_h, int32_t* out_w, int32_t* out_h) {
  if (w != mirror_w || h != mirror_h || w < kMinDesignSide ||
      h < kMinDesignSide || w > kMaxDesignSide || h > kMaxDesignSide) {
    return false;
  }
  *out_w = w;
  *out_h = h;
  return true;
}

// ── game-thread glyph tracker ──────────────────────────────────────────────

inline constexpr size_t kMaxSurfaceGlyphs = 256u;
inline constexpr size_t kSurfaceSlots = 4u;

struct GlyphRecord {
  uint32_t codepoint = 0u;  // 0 = unknown
  int16_t x = 0;            // page pixels
  int16_t y = 0;
  int16_t w = 0;
  int16_t h = 0;
};

struct SurfaceRecord {
  uintptr_t renderer = 0u;
  int32_t page_w = 0;
  int32_t page_h = 0;
  bool overflow = false;
  uint64_t touched = 0u;
  uint32_t count = 0u;
  int32_t layer_id = 0;  // bound by the owning message window
  bool bound = false;
  Placement placement;
  std::array<GlyphRecord, kMaxSurfaceGlyphs> glyphs{};
};

struct TrackerStats {
  uint32_t recorded = 0u;
  uint32_t rejected_args = 0u;
  uint32_t rejected_bounds = 0u;
  uint32_t page_clears = 0u;
  uint32_t page_resets = 0u;
  int32_t last_x = 0, last_y = 0, last_w = 0, last_h = 0, last_size = 0;
};

inline bool SamePlacement(const Placement& a, const Placement& b) {
  if (a.valid != b.valid || a.visible != b.visible || a.x != b.x ||
      a.y != b.y || a.cover_count != b.cover_count ||
      a.covers_overflow != b.covers_overflow) {
    return false;
  }
  for (uint32_t index = 0u; index < a.cover_count; ++index) {
    const IntRect& l = a.covers[index];
    const IntRect& r = b.covers[index];
    if (l.x0 != r.x0 || l.y0 != r.y0 || l.x1 != r.x1 || l.y1 != r.y1) {
      return false;
    }
  }
  return true;
}

class GlyphTracker {
 public:
  const TrackerStats& stats() const { return stats_; }

  void Clear() {
    for (auto& slot : slots_) slot = SurfaceRecord();
    clock_ = 0u;
    ++version_;
  }

  // ClearPage(renderer): the page image was zero-filled and the layout
  // emptied.  Glyphs of the old page are gone from the screen.
  void ClearPage(uintptr_t renderer) {
    for (auto& slot : slots_) {
      if (slot.renderer != renderer || renderer == 0u) continue;
      if (slot.count != 0u || slot.overflow) ++version_;
      slot.count = 0u;
      slot.overflow = false;
      ++stats_.page_clears;
    }
  }

  // RenderChar(renderer, record): one revealed character of the page.
  bool RecordGlyph(uintptr_t renderer, int32_t page_w, int32_t page_h,
                   uint32_t code, int32_t x, int32_t y, int32_t advance,
                   int32_t font_size) {
    stats_.last_x = x;
    stats_.last_y = y;
    stats_.last_w = page_w;
    stats_.last_h = page_h;
    stats_.last_size = font_size;
    if (renderer == 0u || page_w <= 0 || page_h <= 0 ||
        page_w > kMaxPageSide || page_h > kMaxPageSide ||
        font_size < kMinFontSize || font_size > kMaxFontSize) {
      ++stats_.rejected_args;
      return false;
    }
    const int32_t w = GlyphCellWidth(code, advance, font_size);
    const int32_t h = font_size;
    if (x < 0 || y < 0 || x > page_w - w || y > page_h - h) {
      ++stats_.rejected_bounds;
      return false;
    }
    SurfaceRecord& slot = SlotFor(renderer, page_w, page_h);
    const IntRect cell = {x, y, x + w, y + h};
    for (uint32_t index = 0u; index < slot.count; ++index) {
      const GlyphRecord& old = slot.glyphs[index];
      const IntRect overlap =
          Intersect(cell, {old.x, old.y, old.x + old.w, old.y + old.h});
      // Neighbour cells may overlap by a few pixels when the pen advance is
      // tighter than the font size; only drawing mostly over an existing
      // glyph means a new page without a ClearPage (defensive).
      if (!overlap.Empty() &&
          2 * (overlap.x1 - overlap.x0) * (overlap.y1 - overlap.y0) > w * h) {
        slot.count = 0u;
        slot.overflow = false;
        ++stats_.page_resets;
        break;
      }
    }
    slot.touched = ++clock_;
    ++version_;
    if (slot.count >= kMaxSurfaceGlyphs) {
      slot.overflow = true;
      return false;
    }
    ++stats_.recorded;
    GlyphRecord& out = slot.glyphs[slot.count++];
    out.codepoint = DecodeGlyphCode(code);
    out.x = static_cast<int16_t>(x);
    out.y = static_cast<int16_t>(y);
    out.w = static_cast<int16_t>(w);
    out.h = static_cast<int16_t>(h);
    return true;
  }

  // The owning message window names this renderer's scene layer.
  void Bind(uintptr_t renderer, int32_t layer_id) {
    for (auto& slot : slots_) {
      if (slot.renderer != renderer || renderer == 0u) continue;
      if (!slot.bound || slot.layer_id != layer_id) {
        slot.bound = true;
        slot.layer_id = layer_id;
        slot.placement = Placement();
        ++version_;
      }
    }
  }

  void SetPlacement(uintptr_t renderer, const Placement& placement) {
    for (auto& slot : slots_) {
      if (slot.renderer != renderer || renderer == 0u) continue;
      if (!SamePlacement(slot.placement, placement)) {
        slot.placement = placement;
        ++version_;
      }
    }
  }

  const std::array<SurfaceRecord, kSurfaceSlots>& slots() const {
    return slots_;
  }
  uint64_t version() const { return version_; }

 private:
  SurfaceRecord& SlotFor(uintptr_t renderer, int32_t page_w, int32_t page_h) {
    SurfaceRecord* victim = &slots_[0];
    for (auto& slot : slots_) {
      if (slot.renderer == renderer) {
        if (slot.page_w != page_w || slot.page_h != page_h) {
          // The page image was reallocated at another size: start clean.
          const int32_t layer_id = slot.layer_id;
          const bool bound = slot.bound;
          slot = SurfaceRecord();
          slot.renderer = renderer;
          slot.page_w = page_w;
          slot.page_h = page_h;
          slot.layer_id = layer_id;
          slot.bound = bound;
        }
        return slot;
      }
      if (slot.renderer == 0u) {
        victim = &slot;
        break;
      }
      if (slot.touched < victim->touched) victim = &slot;
    }
    *victim = SurfaceRecord();
    victim->renderer = renderer;
    victim->page_w = page_w;
    victim->page_h = page_h;
    return *victim;
  }

  std::array<SurfaceRecord, kSurfaceSlots> slots_{};
  TrackerStats stats_{};
  uint64_t clock_ = 0u;
  uint64_t version_ = 0u;
};

// ── selected text → one surface's visible glyphs ───────────────────────────

inline constexpr uint16_t kNoSource = 0xffffu;

struct LineGlyph {
  uint32_t codepoint = 0u;
  int32_t x = 0;  // design pixels
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
  IntRect hit;  // clickable part of the cell (design pixels; may be empty)
  uint16_t source_index = kNoSource;
  uint8_t source_length = 0u;
};

// Glyphs of one bound, visibly placed surface in render order, each cell
// trimmed to the pen advance of its right neighbour on the same row.  A
// glyph entirely under a cover is left out (that text is not on screen).  A
// partly covered glyph keeps its whole cell clickable: a cover's box is only
// an upper bound of its opaque pixels (the message window's own menu bar box
// reaches over the transparent strip above it and the lower text row), while
// real occluders such as menus and the backlog cover the text completely.
inline size_t CollectVisibleGlyphs(const SurfaceRecord& slot, LineGlyph* out,
                                   size_t capacity) {
  const Placement& placement = slot.placement;
  if (out == nullptr || !slot.bound || slot.overflow || !placement.valid ||
      !placement.visible || placement.covers_overflow) {
    return 0u;
  }
  size_t count = 0u;
  for (uint32_t index = 0u; index < slot.count && count < capacity; ++index) {
    const GlyphRecord& glyph = slot.glyphs[index];
    int32_t w = glyph.w;
    if (index + 1u < slot.count) {
      const GlyphRecord& next = slot.glyphs[index + 1u];
      if (next.y == glyph.y && next.x > glyph.x && next.x < glyph.x + w) {
        w = next.x - glyph.x;
      }
    }
    const IntRect cell = {placement.x + glyph.x, placement.y + glyph.y,
                          placement.x + glyph.x + w,
                          placement.y + glyph.y + glyph.h};
    bool hidden = false;
    for (uint32_t c = 0u; c < placement.cover_count && !hidden; ++c) {
      hidden = Contains(placement.covers[c], cell);
    }
    if (hidden) continue;
    LineGlyph& line = out[count++];
    line.codepoint = glyph.codepoint;
    line.x = cell.x0;
    line.y = cell.y0;
    line.w = w;
    line.h = glyph.h;
    line.hit = cell;
    line.source_index = kNoSource;
    line.source_length = 0u;
  }
  return count;
}

// The selected LunaHook line is the most recent sentence of the page, i.e.
// the render-order suffix of the page's visible glyphs.  Match it
// whitespace-insensitively; the whole line must be consumed and every glyph
// of it must be visible.  Glyphs before the match stay unmapped.  Returns the
// index of the first mapped glyph, or `count` when there is no match (and
// then no glyph is left mapped).
inline size_t MapSelectedSuffix(LineGlyph* glyphs, size_t count,
                                const wchar_t* selected,
                                size_t selected_count) {
  if (glyphs == nullptr || selected == nullptr || count == 0u ||
      selected_count == 0u || selected_count >= kNoSource) {
    return count;
  }
  auto fail = [glyphs, count]() {
    for (size_t index = 0u; index < count; ++index) {
      glyphs[index].source_index = kNoSource;
      glyphs[index].source_length = 0u;
    }
    return count;
  };
  fail();
  size_t source = selected_count;
  size_t glyph = count;
  bool any = false;
  for (;;) {
    while (source > 0u && IsLookupLineWhitespace(selected[source - 1u])) {
      --source;
    }
    if (source == 0u) break;
    if (glyph == 0u) return fail();
    const uint32_t codepoint = glyphs[glyph - 1u].codepoint;
    if (codepoint == 0u || codepoint > 0xffffu) return fail();
    const wchar_t unit = static_cast<wchar_t>(codepoint);
    if (IsLookupLineWhitespace(unit)) {
      --glyph;
      continue;
    }
    if (selected[source - 1u] != unit) return fail();
    --source;
    glyphs[glyph - 1u].source_index = static_cast<uint16_t>(source);
    glyphs[glyph - 1u].source_length = 1u;
    any = true;
    --glyph;
  }
  if (!any) return fail();
  return glyph;
}

// The 2016 engine's text thread reports a spoken line as `「body」【speaker】`;
// the speaker is drawn on the separate name layer, never on the text page.
// Returns the index where that trailing speaker tag starts (trailing
// whitespace allowed), or `count` when the line has none: a non-empty name
// without brackets, after a non-empty body.
inline size_t SpeakerTagStart(const wchar_t* line, size_t count) {
  if (line == nullptr) return count;
  size_t end = count;
  while (end > 0u && IsLookupLineWhitespace(line[end - 1u])) --end;
  if (end < 3u || line[end - 1u] != L'】') return count;
  // The name is [open, end - 1); the tag starts at open - 1.
  size_t open = end - 1u;
  while (open > 0u && line[open - 1u] != L'【') {
    if (line[open - 1u] == L'】') return count;
    --open;
  }
  if (open == 0u || open >= end - 1u) return count;
  size_t body = open - 1u;
  while (body > 0u && IsLookupLineWhitespace(line[body - 1u])) --body;
  return body == 0u ? count : open - 1u;
}

// ── projection and hit testing ─────────────────────────────────────────────

struct PixelRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

// The back buffer is stretched over the whole client, so a client with the
// design aspect ratio (to one pixel) is the only projection admitted.
inline bool ClientMatchesDesign(int32_t client_w, int32_t client_h,
                                int32_t design_w, int32_t design_h) {
  if (client_w <= 0 || client_h <= 0 || design_w <= 0 || design_h <= 0) {
    return false;
  }
  const int64_t cross = static_cast<int64_t>(client_w) * design_h -
                        static_cast<int64_t>(client_h) * design_w;
  const int64_t limit = (std::max)(design_w, design_h);
  return cross <= limit && cross >= -limit;
}

// Design pixels -> physical client pixels (rounded outward); the result must
// lie inside the physical client.
inline bool ProjectCell(const LineGlyph& glyph, int32_t design_w,
                        int32_t design_h, int32_t physical_w,
                        int32_t physical_h, PixelRect* out) {
  if (out == nullptr || design_w <= 0 || design_h <= 0 || physical_w <= 0 ||
      physical_h <= 0 || glyph.w <= 0 || glyph.h <= 0 || glyph.x < 0 ||
      glyph.y < 0 || glyph.x + glyph.w > design_w ||
      glyph.y + glyph.h > design_h) {
    return false;
  }
  const double sx = static_cast<double>(physical_w) / design_w;
  const double sy = static_cast<double>(physical_h) / design_h;
  const int32_t x0 = static_cast<int32_t>(glyph.x * sx);
  const int32_t y0 = static_cast<int32_t>(glyph.y * sy);
  const double right = (glyph.x + glyph.w) * sx;
  const double bottom = (glyph.y + glyph.h) * sy;
  int32_t x1 = static_cast<int32_t>(right);
  int32_t y1 = static_cast<int32_t>(bottom);
  if (x1 < right) ++x1;
  if (y1 < bottom) ++y1;
  if (x1 > physical_w || y1 > physical_h || x1 - x0 < 1 || y1 - y0 < 1) {
    return false;
  }
  *out = {x0, y0, x1 - x0, y1 - y0};
  return true;
}

// Client pixels of the (DPI-unaware) window -> design pixels.
inline bool ClientToDesign(int32_t x, int32_t y, int32_t client_w,
                           int32_t client_h, int32_t design_w,
                           int32_t design_h, int32_t* out_x, int32_t* out_y) {
  if (client_w <= 0 || client_h <= 0 || x < 0 || y < 0 || x >= client_w ||
      y >= client_h || out_x == nullptr || out_y == nullptr) {
    return false;
  }
  *out_x = static_cast<int32_t>(static_cast<int64_t>(x) * design_w / client_w);
  *out_y = static_cast<int32_t>(static_cast<int64_t>(y) * design_h / client_h);
  return true;
}

// The single mapped glyph whose clickable rectangle contains (x, y); none or
// more than one is a miss.
inline bool HitTestLine(const LineGlyph* glyphs, size_t count, int32_t x,
                        int32_t y, size_t* hit) {
  if (glyphs == nullptr || hit == nullptr) return false;
  size_t found = count;
  for (size_t index = 0u; index < count; ++index) {
    const LineGlyph& glyph = glyphs[index];
    if (glyph.source_index == kNoSource) continue;
    if (glyph.hit.Empty() || x < glyph.hit.x0 || y < glyph.hit.y0 ||
        x >= glyph.hit.x1 || y >= glyph.hit.y1) {
      continue;
    }
    if (found != count) return false;
    found = index;
  }
  if (found == count) return false;
  *hit = found;
  return true;
}

// ── message-thread click claim ─────────────────────────────────────────────

inline constexpr uint32_t kMessageLeftDown = WM_LBUTTONDOWN;
inline constexpr uint32_t kMessageLeftUp = WM_LBUTTONUP;
inline constexpr uint32_t kMessageLeftDouble = WM_LBUTTONDBLCLK;

struct ClaimState {
  bool owned = false;
};

struct ClaimDecision {
  bool evaluate = false;  // caller must evaluate eligibility first
  bool swallow = false;   // do not forward the message to the engine
  bool submit = false;    // queue the resolved glyph for the worker
};

// Step 1: does this message need an eligibility verdict?  Every left press
// is evaluated afresh (a lost button-up can never make a later press sticky).
inline bool NeedsEligibility(uint32_t message) {
  return message == kMessageLeftDown || message == kMessageLeftDouble;
}

// Step 2: a claimed press owns the button until its release; both edges are
// swallowed so the script never sees the click.
inline ClaimDecision DecideMessage(uint32_t message, bool eligible,
                                   ClaimState* claim) {
  ClaimDecision decision;
  if (claim == nullptr) return decision;
  if (NeedsEligibility(message)) {
    decision.evaluate = true;
    claim->owned = eligible;
    decision.swallow = eligible;
    decision.submit = eligible;
  } else if (message == kMessageLeftUp && claim->owned) {
    claim->owned = false;
    decision.swallow = true;
  }
  return decision;
}

}  // namespace fushi_voice_hook::catsystem2_lookup
