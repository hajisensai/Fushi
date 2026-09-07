#pragma once

// Lookup runtime entry points for the smash/fzmedia adapter (owned by the
// lookup side, smash_fzmedia_lookup.inc).  The adapter core
// (smash_fzmedia_adapter.inc) calls these from install()/shutdown()/
// ProcessPendingEvents() and after every paragraph publication.  The only
// data exchanged between the two sides is the LineSnapshot declared in
// smash_fzmedia_shared.h.
//
// Threading contract:
//   * LookupInstall / LookupShutdown / LookupPoll run on the HookWorker
//     thread (never inside a detour).
//   * LookupPublishSnapshot may be called from the HookWorker thread only;
//     the runtime copies the snapshot into its own double buffer so the
//     caller may reuse the argument immediately afterwards.
//   * All Win32 work (window subclassing, hit publication) is x64-only; the
//     x86 build compiles inert stubs so the Win32 helper still links.
//
// Inclusion contract: this header (and smash_fzmedia_shared.h) opens
// namespace fushi_voice_hook, so dll_main.cpp must include it at file scope
// before its anonymous namespace; including it from an adapter .inc for the
// first time would create an anonymous nested fushi_voice_hook namespace and
// break every later `fushi_voice_hook::` lookup in that translation unit.
// smash_fzmedia_lookup.inc must be included from smash_fzmedia_adapter.inc at
// its file scope (outside any class body): it closes and reopens the
// anonymous namespace around the definitions of the entry points below.

#include <array>
#include <atomic>
#include <cstdint>
#include <iterator>

#include "smash_fzmedia_shared.h"
#include "voice_hook_ipc.h"

namespace fushi_voice_hook {
namespace smash_fzmedia {

// Registers the EngineExactLayout geometry provider (id
// kLookupGeometryProviderIdSmashFzmedia), subclasses the game's GLFW30
// top-level window for click / Shift-hover sensing, and starts shield
// participation.  Returns false when the provider could not be registered
// (x86 build, no header, registry refused).  Subclassing failure is not
// fatal: the provider stays registered but unready and the failure is
// reported through diagnostics.
bool LookupInstall(SharedHeader* header);

// Restores the original window procedure, retires the geometry provider and
// revokes every shield property this runtime published.
void LookupShutdown(SharedHeader* header);

// Periodic maintenance on the HookWorker thread: polls the host-solved layer
// origin (ReadLookupLayerOrigin), re-evaluates provider readiness against the
// current client size, maintains the v19 shield transaction and republishes
// the layer line when the projection changed.
void LookupPoll(SharedHeader* header, uint64_t now_ms);

// Hands the latest published paragraph (text + per-unit glyph cells) to the
// lookup side.  `snapshot.generation` must increase on every call whose
// text or cells changed; `snapshot.text_event_id` must be the TextLaneWrite
// seq of the publication so hits reference the right text event.
void LookupPublishSnapshot(const LineSnapshot& snapshot);

}  // namespace smash_fzmedia
}  // namespace fushi_voice_hook
