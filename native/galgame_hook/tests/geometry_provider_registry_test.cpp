#undef NDEBUG

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "geometry_provider_registry.h"

namespace {

using fushi_voice_hook::GeometryProviderRegistry;
using fushi_voice_hook::LookupGeometryHitPublication;
using fushi_voice_hook::LookupHitOf;
using fushi_voice_hook::LookupRegionBytes;
using fushi_voice_hook::SharedHeader;

void Check(bool condition, const char* message) {
  if (condition) return;
  std::fprintf(stderr, "geometry_provider_registry_test: %s\n", message);
  std::abort();
}

struct FakeMapping {
  std::vector<uint8_t> bytes;

  FakeMapping() {
    const uint64_t lookup_bytes = LookupRegionBytes(
        fushi_voice_hook::kLookupInputSlotCount,
        fushi_voice_hook::kLookupFrameCount,
        fushi_voice_hook::kLookupBitmapBytes);
    bytes.resize(static_cast<size_t>(sizeof(SharedHeader) + lookup_bytes));
    std::memset(bytes.data(), 0, bytes.size());
    SharedHeader* h = header();
    h->magic = fushi_voice_hook::kSharedMagic;
    h->version = fushi_voice_hook::kSharedVersion;
    h->lookup_region_offset = sizeof(SharedHeader);
    h->lookup_bitmap_bytes = fushi_voice_hook::kLookupBitmapBytes;
    h->lookup_frame_count = fushi_voice_hook::kLookupFrameCount;
    h->lookup_input_slot_count = fushi_voice_hook::kLookupInputSlotCount;
    h->lookup_enabled = 1;
    Check(fushi_voice_hook::PublishLookupGeometryAdmission(
              h, fushi_voice_hook::kLookupGeometryAdmissionAuto, false,
              false) != 0,
          "fake mapping must publish a coherent default auto admission");
  }

  SharedHeader* header() {
    return reinterpret_cast<SharedHeader*>(bytes.data());
  }
};

LookupGeometryHitPublication Publication(uint32_t kind, uint32_t id,
                                         uint64_t generation,
                                         uint32_t char_index = 1) {
  static const uint8_t line[] = {0xe3, 0x81, 0x82, 0xe3, 0x81, 0x84};
  LookupGeometryHitPublication publication;
  publication.provider_kind = kind;
  publication.provider_id = id;
  publication.char_index = char_index;
  publication.source_length = 1;
  publication.char_count = 2;
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode =
      fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.text_generation = generation;
  publication.geometry_generation = generation;
  publication.glyph_x = 100;
  publication.glyph_y = 200;
  publication.glyph_w = 24;
  publication.glyph_h = 28;
  publication.view_w = 1280;
  publication.view_h = 720;
  publication.line_utf8 = line;
  publication.line_bytes = sizeof(line);
  return publication;
}

void TestCompletePublicationAndGenerationFence() {
  FakeMapping mapping;
  GeometryProviderRegistry registry;
  registry.Reset(mapping.header());
  auto exact = Publication(
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdSiglus, 7);
  exact.geometry_generation = 11;
  uint64_t wire_seq = 0;
  Check(!registry.PublishHit(mapping.header(), exact, &wire_seq) &&
            wire_seq == 0,
        "a hit without a pre-hit ready offer must fail closed");
  Check(registry.OfferReady(mapping.header(), exact.provider_kind,
                            exact.provider_id),
        "an admitted exact provider must be able to offer readiness");
  Check(mapping.header()->lookup_geometry_active_kind == exact.provider_kind &&
            mapping.header()->lookup_geometry_active_id == exact.provider_id &&
            mapping.header()->lookup_geometry_status ==
                fushi_voice_hook::kLookupGeometryStatusReady &&
            mapping.header()->lookup_geometry_text_generation == 0 &&
            mapping.header()->lookup_geometry_generation == 0,
        "pre-hit offer must publish ready identity without inventing generations");
  Check(registry.PublishHit(mapping.header(), exact, &wire_seq),
        "first exact publication must succeed");
  Check(wire_seq == 1 && mapping.header()->lookup_hit_count == 1,
        "registry owns one monotonic wire sequence");
  const auto* hit = LookupHitOf(mapping.header());
  Check(hit != nullptr && hit->seq == wire_seq &&
            hit->provider_kind == exact.provider_kind &&
            hit->provider_id == exact.provider_id &&
            hit->source_length == 1 && hit->text_generation == 7 &&
            hit->geometry_generation == 11 &&
            hit->writing_mode ==
                fushi_voice_hook::kLookupWritingModeHorizontal,
        "wire hit must carry provider/span/generations/writing mode together");
  Check(mapping.header()->lookup_geometry_active_kind == exact.provider_kind &&
            mapping.header()->lookup_geometry_active_id == exact.provider_id &&
            mapping.header()->lookup_geometry_status ==
                fushi_voice_hook::kLookupGeometryStatusActive &&
            mapping.header()->lookup_geometry_text_generation == 7 &&
            mapping.header()->lookup_geometry_generation == 11,
        "header active provider completion marker must match the hit");

  auto stale = exact;
  stale.text_generation = 6;
  stale.geometry_generation = 12;
  Check(!registry.PublishHit(mapping.header(), stale),
        "text generation must never regress even if geometry advances");
  stale = exact;
  stale.text_generation = 8;
  stale.geometry_generation = 10;
  Check(!registry.PublishHit(mapping.header(), stale),
        "geometry generation must never regress even if text advances");
  Check(mapping.header()->lookup_hit_count == 1,
        "rejected stale publication must not advance the wire sequence");
}

void TestStrictKindIdWhitelist() {
  FakeMapping mapping;
  GeometryProviderRegistry registry;
  registry.Reset(mapping.header());

  Check(fushi_voice_hook::IsLookupGeometryProductionProviderPair(
            fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
            fushi_voice_hook::kLookupGeometryProviderIdHunexGge),
        "HUNEX exact identity must be reserved without claiming implementation");
  auto hunex = Publication(
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdHunexGge, 1);
  Check(!registry.PublishHit(mapping.header(), hunex) &&
            mapping.header()->lookup_geometry_active_kind ==
                fushi_voice_hook::kLookupGeometryProviderUnknown,
        "reserved HUNEX identity must not self-activate or publish without an adapter ready offer");
  Check(!registry.OfferReady(
            mapping.header(),
            fushi_voice_hook::kLookupGeometryProviderRuntimeLayout,
            fushi_voice_hook::kLookupGeometryProviderIdSiglus),
        "a real id paired with the wrong kind must be rejected");
  Check(!registry.OfferReady(
            mapping.header(),
            fushi_voice_hook::kLookupGeometryProviderRuntimeLayout, 0xdead),
        "an arbitrary id must not inherit runtime-layout priority");
  Check(!registry.OfferReady(
            mapping.header(),
            fushi_voice_hook::kLookupGeometryProviderPixelTemplateExperimental,
            fushi_voice_hook::kLookupGeometryProviderIdPixelTemplateExperimental),
        "experimental identities must remain observation-only");

  auto mismatched = Publication(
      fushi_voice_hook::kLookupGeometryProviderRuntimeLayout,
      fushi_voice_hook::kLookupGeometryProviderIdSiglus, 1);
  Check(!registry.PublishHit(mapping.header(), mismatched),
        "PublishHit must enforce the same strict pair whitelist");
}

void TestHunexNativeInputRequiresAppliedHostAdmission() {
  FakeMapping mapping;
  GeometryProviderRegistry registry;
  registry.Reset(mapping.header());
  auto hunex = Publication(
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdHunexGge, 17);
  Check(registry.OfferReady(mapping.header(), hunex.provider_kind,
                            hunex.provider_id),
        "HUNEX discovery/readiness must not depend on NativeInputAllowed");
  Check(!registry.NativeInputAllowed(mapping.header(), hunex.provider_kind,
                                     hunex.provider_id) &&
            !registry.PublishHit(mapping.header(), hunex),
        "HUNEX semantic consume/publication must default deny");

  const uint32_t allow_seq =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          mapping.header(), fushi_voice_hook::kLookupGeometryAdmissionAuto,
          false, true);
  Check(allow_seq != 0 &&
            !registry.NativeInputAllowed(mapping.header(), hunex.provider_kind,
                                         hunex.provider_id),
        "an un-applied allow request must remain fail-closed");
  Check(registry.Reconcile(mapping.header()) &&
            mapping.header()->lookup_geometry_admission_applied_seq ==
                allow_seq &&
            registry.NativeInputAllowed(mapping.header(), hunex.provider_kind,
                                        hunex.provider_id) &&
            registry.PublishHit(mapping.header(), hunex),
        "applied allow plus exact active HUNEX must admit one native hit");

  const uint32_t deny_seq =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          mapping.header(), fushi_voice_hook::kLookupGeometryAdmissionAuto,
          false, false);
  Check(deny_seq > allow_seq &&
            !registry.NativeInputAllowed(mapping.header(), hunex.provider_kind,
                                         hunex.provider_id) &&
            !registry.PublishHit(mapping.header(), hunex),
        "publishing deny must close consumption before its ack is observed");
}

void TestNativeInputGateIsAnAllowListOfKindIdPairs() {
  using fushi_voice_hook::IsLookupGeometryNativeInputGatedProvider;
  Check(IsLookupGeometryNativeInputGatedProvider(
            fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
            fushi_voice_hook::kLookupGeometryProviderIdHunexGge),
        "HUNEX exact stays native-input gated");
  Check(IsLookupGeometryNativeInputGatedProvider(
            fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
            fushi_voice_hook::kLookupGeometryProviderIdSmashFzmedia),
        "smash exact must be native-input gated");
  Check(!IsLookupGeometryNativeInputGatedProvider(
            fushi_voice_hook::kLookupGeometryProviderRuntimeLayout,
            fushi_voice_hook::kLookupGeometryProviderIdSmashFzmedia),
        "smash id with the wrong kind must not inherit the gate");
  Check(!IsLookupGeometryNativeInputGatedProvider(
            fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
            fushi_voice_hook::kLookupGeometryProviderIdSgre),
        "geometry-only exact providers are not native-input gated");
  Check(fushi_voice_hook::IsLookupGeometryProductionProviderPair(
            fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
            fushi_voice_hook::kLookupGeometryProviderIdSmashFzmedia),
        "smash exact identity must be a production pair");

  FakeMapping mapping;
  GeometryProviderRegistry registry;
  registry.Reset(mapping.header());
  // A non-gated provider never gets NativeInputAllowed, even when the host
  // has applied an allow admission and the provider is the active owner.
  auto sgre = Publication(
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdSgre, 3);
  const uint32_t allow_seq =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          mapping.header(), fushi_voice_hook::kLookupGeometryAdmissionAuto,
          false, true);
  Check(allow_seq != 0 &&
            registry.OfferReady(mapping.header(), sgre.provider_kind,
                                sgre.provider_id) &&
            registry.Reconcile(mapping.header()) &&
            registry.PublishHit(mapping.header(), sgre),
        "non-gated exact provider publishes without the native-input gate");
  Check(!registry.NativeInputAllowed(mapping.header(), sgre.provider_kind,
                                     sgre.provider_id),
        "NativeInputAllowed must deny providers outside the allow-list");
}

void TestSmashFzmediaNativeInputRequiresAppliedHostAdmission() {
  FakeMapping mapping;
  GeometryProviderRegistry registry;
  registry.Reset(mapping.header());
  auto smash = Publication(
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdSmashFzmedia, 21);
  Check(registry.OfferReady(mapping.header(), smash.provider_kind,
                            smash.provider_id),
        "smash discovery/readiness must not depend on NativeInputAllowed");
  Check(!registry.NativeInputAllowed(mapping.header(), smash.provider_kind,
                                     smash.provider_id) &&
            !registry.PublishHit(mapping.header(), smash),
        "smash click consume/publication must default deny");

  const uint32_t allow_seq =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          mapping.header(), fushi_voice_hook::kLookupGeometryAdmissionAuto,
          false, true);
  Check(allow_seq != 0 &&
            !registry.NativeInputAllowed(mapping.header(), smash.provider_kind,
                                         smash.provider_id),
        "an un-applied allow request must remain fail-closed for smash");
  Check(registry.Reconcile(mapping.header()) &&
            mapping.header()->lookup_geometry_admission_applied_seq ==
                allow_seq &&
            registry.NativeInputAllowed(mapping.header(), smash.provider_kind,
                                        smash.provider_id) &&
            registry.PublishHit(mapping.header(), smash),
        "applied allow plus exact active smash must admit one native hit");
  const auto* hit = LookupHitOf(mapping.header());
  Check(hit != nullptr &&
            hit->provider_id ==
                fushi_voice_hook::kLookupGeometryProviderIdSmashFzmedia &&
            hit->provider_kind ==
                fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        "wire hit must carry the smash exact identity");

  const uint32_t deny_seq =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          mapping.header(), fushi_voice_hook::kLookupGeometryAdmissionAuto,
          false, false);
  Check(deny_seq > allow_seq &&
            !registry.NativeInputAllowed(mapping.header(), smash.provider_kind,
                                         smash.provider_id) &&
            !registry.PublishHit(mapping.header(), smash),
        "publishing deny must close smash consumption before its ack");
}

void TestPriorityAndTransactionFencedRetire() {
  FakeMapping mapping;
  GeometryProviderRegistry registry;
  registry.Reset(mapping.header());
  auto exact = Publication(
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdLeafAquaplus, 1);
  Check(registry.OfferReady(mapping.header(), exact.provider_kind,
                            exact.provider_id),
        "exact ready offer must be accepted");
  Check(registry.PublishHit(mapping.header(), exact),
        "exact provider must activate");
  const uint64_t exact_wire_seq = LookupHitOf(mapping.header())->seq;

  auto positioned = Publication(
      fushi_voice_hook::kLookupGeometryProviderPositionedTextApi,
      fushi_voice_hook::kLookupGeometryProviderIdGdiPositioned, 2);
  Check(registry.OfferReady(mapping.header(), positioned.provider_kind,
                            positioned.provider_id),
        "lower-priority fallback offer must be remembered");
  Check(!registry.PublishHit(mapping.header(), positioned),
        "lower-priority provider must not replace active exact geometry");

  const uint32_t down_seq = fushi_voice_hook::PublishLookupShieldRequest(
      mapping.header(), fushi_voice_hook::kLookupShieldOwnerNativeGlyph,
      0x4321u, 44u, fushi_voice_hook::kLookupShieldButtonLeft, false);
  Check(down_seq != 0, "active transaction request must publish");
  auto runtime = Publication(
      fushi_voice_hook::kLookupGeometryProviderRuntimeLayout,
      fushi_voice_hook::kLookupGeometryProviderIdRenpy, 3);
  Check(registry.OfferReady(mapping.header(), runtime.provider_kind,
                            runtime.provider_id),
        "higher-priority offer must be accepted while transaction is active");
  Check(!registry.PublishHit(mapping.header(), runtime),
        "even a higher-priority provider must wait for mouse transaction tail");
  Check(mapping.header()->lookup_geometry_active_id == exact.provider_id &&
            LookupHitOf(mapping.header())->seq == exact_wire_seq,
        "deferred pre-emption must preserve active identity and immutable hit");

  Check(registry.Retire(
            mapping.header(), exact.provider_kind, exact.provider_id,
            fushi_voice_hook::kLookupGeometryStatusFaulted),
        "active provider retirement must be explicit and accepted");
  Check(mapping.header()->lookup_geometry_active_id == exact.provider_id &&
            mapping.header()->lookup_geometry_status ==
                fushi_voice_hook::kLookupGeometryStatusFaulted &&
            LookupHitOf(mapping.header())->seq == exact_wire_seq,
        "faulted owner must remain pinned until the transaction tail drains");

  const uint32_t release_seq = fushi_voice_hook::PublishLookupShieldRequest(
      mapping.header(), fushi_voice_hook::kLookupShieldOwnerNativeGlyph,
      0x4321u, 44u, 0, false);
  Check(release_seq > down_seq, "release must be a new request generation");
  Check(!registry.PublishHit(mapping.header(), runtime),
        "buttons=0 alone is not enough before every shield surface acks tail");
  const auto release =
      fushi_voice_hook::ReadLookupShieldRequest(mapping.header());
  fushi_voice_hook::LookupShieldStatusPublication status;
  status.required_mask = fushi_voice_hook::kLookupShieldSurfaceLowLevelMouse;
  status.ready_mask = status.required_mask;
  status.observed_mask = status.required_mask;
  status.status_flags = fushi_voice_hook::kLookupShieldStatusVerified;
  Check(fushi_voice_hook::PublishLookupShieldStatus(mapping.header(), release,
                                                     status),
        "release tail must be acknowledged");
  Check(registry.Reconcile(mapping.header()),
        "neutral tail ack must release the deferred provider transition");
  Check(mapping.header()->lookup_geometry_active_id ==
            fushi_voice_hook::kLookupGeometryProviderIdRenpy &&
            mapping.header()->lookup_geometry_status ==
                fushi_voice_hook::kLookupGeometryStatusReady &&
            mapping.header()->lookup_geometry_generation == 0 &&
            LookupHitOf(mapping.header())->seq == 0,
        "switch must publish pre-hit ready state and invalidate the old slot");
  Check(registry.PublishHit(mapping.header(), runtime),
        "higher-priority provider may switch only after release ack");
  Check(mapping.header()->lookup_geometry_active_id ==
            fushi_voice_hook::kLookupGeometryProviderIdRenpy,
        "active provider must switch atomically to the accepted runtime hit");

  Check(registry.Retire(mapping.header(), runtime.provider_kind,
                        runtime.provider_id),
        "neutral active provider retirement must complete immediately");
  Check(mapping.header()->lookup_geometry_active_id ==
            fushi_voice_hook::kLookupGeometryProviderIdGdiPositioned &&
            mapping.header()->lookup_geometry_status ==
                fushi_voice_hook::kLookupGeometryStatusReady,
        "retiring the winner must reveal the best remaining ready fallback");
}

void TestFailClosedShapesAndUtf16Span() {
  FakeMapping mapping;
  GeometryProviderRegistry registry;
  registry.Reset(mapping.header());
  auto publication = Publication(
      fushi_voice_hook::kLookupGeometryProviderRuntimeLayout,
      fushi_voice_hook::kLookupGeometryProviderIdKirikiri, 1);
  Check(registry.OfferReady(mapping.header(), publication.provider_kind,
                            publication.provider_id),
        "shape tests require an admitted ready provider");
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeVertical;
  Check(!registry.PublishHit(mapping.header(), publication),
        "v1 vertical geometry must fail closed");
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.coordinate_space = fushi_voice_hook::kLookupCoordinateSpaceUnknown;
  Check(!registry.PublishHit(mapping.header(), publication),
        "unknown coordinate space must fail closed");
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceLayoutLocal + 1u;
  Check(!registry.PublishHit(mapping.header(), publication),
        "out-of-range coordinate space must fail closed");
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.source_length = 0;
  Check(!registry.PublishHit(mapping.header(), publication),
        "zero UTF-16 source span must fail closed");
  publication.source_length = 1;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderPixelTemplateExperimental;
  publication.provider_id =
      fushi_voice_hook::kLookupGeometryProviderIdPixelTemplateExperimental;
  Check(!registry.PublishHit(mapping.header(), publication),
        "experimental providers must stay observation-only");

  const wchar_t surrogate[] = {static_cast<wchar_t>(0xd83d),
                               static_cast<wchar_t>(0xde00), L'x', L'\0'};
  Check(fushi_voice_hook::LookupUtf16SourceLength(surrogate, 3, 0) == 2,
        "surrogate-pair glyph must publish a two-code-unit source span");
  Check(fushi_voice_hook::LookupUtf16SourceLength(surrogate, 3, 2) == 1,
        "BMP glyph must publish a one-code-unit source span");
  Check(fushi_voice_hook::LookupUtf16SourceLength(surrogate, 3, 1) == 0,
        "a low-surrogate start must fail closed instead of splitting a pair");
  const wchar_t unpaired_high[] = {static_cast<wchar_t>(0xd83d), L'x', L'\0'};
  Check(fushi_voice_hook::LookupUtf16SourceLength(unpaired_high, 2, 0) == 0,
        "an unpaired high surrogate must fail closed");
}

void TestDisableRetiresOnlyAfterNeutralTail() {
  FakeMapping mapping;
  GeometryProviderRegistry registry;
  registry.Reset(mapping.header());
  auto exact = Publication(
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdSgre, 9);
  Check(registry.OfferReady(mapping.header(), exact.provider_kind,
                            exact.provider_id) &&
            registry.PublishHit(mapping.header(), exact),
        "disable test requires one active exact hit");
  const uint64_t wire_seq = LookupHitOf(mapping.header())->seq;
  const uint32_t down_seq = fushi_voice_hook::PublishLookupShieldRequest(
      mapping.header(), fushi_voice_hook::kLookupShieldOwnerNativeGlyph,
      0x7788u, 55u, fushi_voice_hook::kLookupShieldButtonLeft, false);
  Check(down_seq != 0, "disable transaction must publish");
  mapping.header()->lookup_enabled = 0;
  Check(!registry.Reconcile(mapping.header()) &&
            mapping.header()->lookup_geometry_active_id == exact.provider_id &&
            LookupHitOf(mapping.header())->seq == wire_seq,
        "disable must not tear down provider identity in the middle of down/up");

  const uint32_t release_seq = fushi_voice_hook::PublishLookupShieldRequest(
      mapping.header(), fushi_voice_hook::kLookupShieldOwnerNativeGlyph,
      0x7788u, 55u, 0, false);
  const auto release =
      fushi_voice_hook::ReadLookupShieldRequest(mapping.header());
  fushi_voice_hook::LookupShieldStatusPublication status;
  status.required_mask = fushi_voice_hook::kLookupShieldSurfaceLowLevelMouse;
  status.ready_mask = status.required_mask;
  status.observed_mask = status.required_mask;
  status.status_flags = fushi_voice_hook::kLookupShieldStatusVerified;
  Check(release_seq > down_seq &&
            fushi_voice_hook::PublishLookupShieldStatus(mapping.header(),
                                                        release, status),
        "disable release tail must be acknowledged");
  Check(registry.Reconcile(mapping.header()) &&
            mapping.header()->lookup_geometry_active_kind ==
                fushi_voice_hook::kLookupGeometryProviderUnknown &&
            mapping.header()->lookup_geometry_status ==
                fushi_voice_hook::kLookupGeometryStatusUnavailable &&
            LookupHitOf(mapping.header())->seq == 0,
        "disabled registry must clear offers and stale slot after neutral tail");
}

void TestHostAdmissionSeparatesGeometryFromShieldRuntime() {
  FakeMapping mapping;
  GeometryProviderRegistry registry;
  registry.Reset(mapping.header());
  auto exact = Publication(
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdSiglus, 20);
  Check(registry.OfferReady(mapping.header(), exact.provider_kind,
                            exact.provider_id) &&
            registry.PublishHit(mapping.header(), exact),
        "auto admission must activate a native exact provider");
  const uint64_t exact_hit_seq = LookupHitOf(mapping.header())->seq;

  const uint32_t down_seq = fushi_voice_hook::PublishLookupShieldRequest(
      mapping.header(), fushi_voice_hook::kLookupShieldOwnerNativeGlyph,
      0x5566u, 71u, fushi_voice_hook::kLookupShieldButtonLeft, false);
  const uint32_t attached_request =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          mapping.header(),
          fushi_voice_hook::kLookupGeometryAdmissionAttachedOnly, true,
          false);
  Check(down_seq != 0 && attached_request != 0 &&
            !registry.Reconcile(mapping.header()),
        "attached claim must wait for the native down/up/tail transaction");
  Check(mapping.header()->lookup_enabled == 1 &&
            mapping.header()->lookup_geometry_active_id == exact.provider_id &&
            LookupHitOf(mapping.header())->seq == exact_hit_seq &&
            mapping.header()->lookup_geometry_admission_applied_seq !=
                attached_request,
        "geometry handoff must preserve shield runtime and immutable old owner until neutral");

  const uint32_t release_seq = fushi_voice_hook::PublishLookupShieldRequest(
      mapping.header(), fushi_voice_hook::kLookupShieldOwnerNativeGlyph,
      0x5566u, 71u, 0, false);
  const auto release =
      fushi_voice_hook::ReadLookupShieldRequest(mapping.header());
  fushi_voice_hook::LookupShieldStatusPublication shield;
  shield.required_mask = fushi_voice_hook::kLookupShieldSurfaceLowLevelMouse;
  shield.ready_mask = shield.required_mask;
  shield.observed_mask = shield.required_mask;
  shield.status_flags = fushi_voice_hook::kLookupShieldStatusVerified;
  Check(release_seq > down_seq &&
            fushi_voice_hook::PublishLookupShieldStatus(mapping.header(),
                                                        release, shield) &&
            registry.Reconcile(mapping.header()),
        "acknowledged neutral tail must complete the attached claim");
  Check(mapping.header()->lookup_enabled == 1 &&
            mapping.header()->lookup_geometry_active_kind ==
                fushi_voice_hook::kLookupGeometryProviderAttachedCalibrated &&
            mapping.header()->lookup_geometry_active_id ==
                fushi_voice_hook::kLookupGeometryProviderIdAttachedCalibrated &&
            mapping.header()->lookup_geometry_status ==
                fushi_voice_hook::kLookupGeometryStatusReady &&
            mapping.header()->lookup_geometry_admission_applied_seq ==
                attached_request &&
            LookupHitOf(mapping.header())->seq == 0,
        "attached ownership must retire the native hit without stopping the generic shield runtime");
  Check(!registry.PublishHit(mapping.header(), exact),
        "native publication must fail once attached owns the generation");
  Check(!registry.OfferReady(
            mapping.header(),
            fushi_voice_hook::kLookupGeometryProviderAttachedCalibrated,
            fushi_voice_hook::kLookupGeometryProviderIdAttachedCalibrated),
        "injected code must not impersonate the host-owned attached offer");

  const uint32_t auto_request =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          mapping.header(), fushi_voice_hook::kLookupGeometryAdmissionAuto,
          true, false);
  Check(registry.Reconcile(mapping.header()) &&
            mapping.header()->lookup_geometry_active_id == exact.provider_id &&
            mapping.header()->lookup_geometry_admission_applied_seq ==
                auto_request,
        "auto must restore the remembered higher-priority native offer");

  const uint32_t withdrawn =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          mapping.header(),
          fushi_voice_hook::kLookupGeometryAdmissionAttachedOnly, false,
          false);
  Check(registry.Reconcile(mapping.header()) &&
            mapping.header()->lookup_geometry_active_kind ==
                fushi_voice_hook::kLookupGeometryProviderUnknown &&
            mapping.header()->lookup_geometry_admission_applied_seq ==
                withdrawn,
        "attachedOnly without a calibrated host offer must retire every native provider");
}

void TestProviderSwitchWaitsForShieldRequestWriter() {
  FakeMapping mapping;
  GeometryProviderRegistry registry;
  registry.Reset(mapping.header());
  auto exact = Publication(
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdSiglus, 30);
  Check(registry.OfferReady(mapping.header(), exact.provider_kind,
                            exact.provider_id) &&
            registry.PublishHit(mapping.header(), exact),
        "writer-fence test requires an active native provider");

  const uint32_t idle_seq = fushi_voice_hook::PublishLookupShieldRequest(
      mapping.header(), fushi_voice_hook::kLookupShieldOwnerNone, 0, 0, 0,
      false);
  Check(idle_seq != 0, "writer-fence test requires a stable idle request");
  fushi_voice_hook::AtomicStoreShared32(
      &mapping.header()->lookup_shield_request_seq,
      idle_seq | fushi_voice_hook::kLookupShieldRequestWriteInProgress);
  const uint32_t attached_request =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          mapping.header(),
          fushi_voice_hook::kLookupGeometryAdmissionAttachedOnly, true,
          false);
  Check(attached_request != 0 && !registry.Reconcile(mapping.header()) &&
            mapping.header()->lookup_geometry_active_id == exact.provider_id &&
            mapping.header()->lookup_geometry_admission_applied_seq !=
                attached_request,
        "provider switch must not pass a concurrent shield request writer");

  fushi_voice_hook::AtomicStoreShared32(
      &mapping.header()->lookup_shield_request_seq, idle_seq);
  Check(registry.Reconcile(mapping.header()) &&
            mapping.header()->lookup_geometry_active_kind ==
                fushi_voice_hook::kLookupGeometryProviderAttachedCalibrated &&
            mapping.header()->lookup_geometry_admission_applied_seq ==
                attached_request,
        "provider switch may complete after the shield writer publishes");
}

void TestNativePreemptionRevokesAttachedOwnership() {
  FakeMapping mapping;
  GeometryProviderRegistry registry;
  registry.Reset(mapping.header());
  const uint32_t attached_request =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          mapping.header(), fushi_voice_hook::kLookupGeometryAdmissionAuto,
          true, false);
  Check(attached_request != 0 && registry.Reconcile(mapping.header()) &&
            fushi_voice_hook::LookupGeometryAttachedProviderOwns(
                mapping.header()),
        "auto fallback must begin with a coherent attached Ready owner");

  auto native = Publication(
      fushi_voice_hook::kLookupGeometryProviderRuntimeLayout,
      fushi_voice_hook::kLookupGeometryProviderIdRenpy, 40);
  Check(registry.OfferReady(mapping.header(), native.provider_kind,
                            native.provider_id) &&
            mapping.header()->lookup_geometry_active_id == native.provider_id,
        "a ready native provider must preempt the attached fallback");
  Check(!fushi_voice_hook::LookupGeometryAttachedProviderOwns(
            mapping.header()),
        "post-switch ownership check must reject an immutable attached hit snapshot");
}

}  // namespace

int main() {
  TestCompletePublicationAndGenerationFence();
  TestStrictKindIdWhitelist();
  TestHunexNativeInputRequiresAppliedHostAdmission();
  TestNativeInputGateIsAnAllowListOfKindIdPairs();
  TestSmashFzmediaNativeInputRequiresAppliedHostAdmission();
  TestPriorityAndTransactionFencedRetire();
  TestFailClosedShapesAndUtf16Span();
  TestDisableRetiresOnlyAfterNeutralTail();
  TestHostAdmissionSeparatesGeometryFromShieldRuntime();
  TestProviderSwitchWaitsForShieldRequestWriter();
  TestNativePreemptionRevokesAttachedOwnership();
  std::puts("geometry provider registry test ok");
  return 0;
}
