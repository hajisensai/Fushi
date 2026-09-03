// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"（CI 的 C4189「变量没人引用」正是它漏出来的痕迹）。
// 与 attached_mouse_hook_nonblocking_source_test.cpp 同一写法。
#undef NDEBUG

#include "../attached_overlayability.h"

#include <cassert>
#include <string>

namespace {

fushi::attached_overlayability::Facts OverlayableFacts() {
  fushi::attached_overlayability::Facts facts;
  facts.composition_query_succeeded = true;
  facts.composition_enabled = true;
  facts.source_window_valid = true;
  facts.presentation_window_valid = true;
  facts.presentation_matches_source = true;
  facts.presentation_visible = true;
  facts.source_minimized = false;
  facts.presentation_minimized = false;
  facts.source_cloak_query_succeeded = true;
  facts.source_cloaked = false;
  facts.presentation_cloak_query_succeeded = true;
  facts.presentation_cloaked = false;
  facts.client_has_area = true;
  facts.exclusive_ownership =
      fushi::attached_overlayability::ExclusiveOwnership::kNotExclusive;
  facts.presentation_frame_query_succeeded = true;
  facts.presentation_frame_has_area = true;
  return facts;
}

} // namespace

int main() {
  using namespace fushi::attached_overlayability;

  // A normal window and a borderless window share the same admission facts:
  // monitor coverage is deliberately not treated as exclusive fullscreen.
  const Evaluation windowed = Evaluate(OverlayableFacts());
  assert(windowed.overlayable);
  assert(windowed.failure == Failure::kNone);

  // Magpie uses a distinct presentation HWND.  Its exact source mapping is the
  // identity proof; equality between the two HWNDs is not required.
  Facts magpie = OverlayableFacts();
  magpie.presentation_matches_source = true;
  assert(Evaluate(magpie).overlayable);

  Facts exclusive = OverlayableFacts();
  exclusive.exclusive_ownership = ExclusiveOwnership::kExclusive;
  const Evaluation exclusive_result = Evaluate(exclusive);
  assert(!exclusive_result.overlayable);
  assert(exclusive_result.failure == Failure::kTargetExclusive);

  Facts unknown_ownership = OverlayableFacts();
  unknown_ownership.exclusive_ownership = ExclusiveOwnership::kUnknown;
  const Evaluation unknown_result = Evaluate(unknown_ownership);
  assert(!unknown_result.overlayable);
  assert(unknown_result.failure == Failure::kExclusiveOwnershipUnknown);

  Facts composition_disabled = OverlayableFacts();
  composition_disabled.composition_enabled = false;
  const Evaluation composition_result = Evaluate(composition_disabled);
  assert(!composition_result.overlayable);
  assert(composition_result.failure == Failure::kCompositionDisabled);

  Facts bad_mapping = OverlayableFacts();
  bad_mapping.presentation_matches_source = false;
  const Evaluation mapping_result = Evaluate(bad_mapping);
  assert(!mapping_result.overlayable);
  assert(mapping_result.failure == Failure::kPresentationSourceMismatch);

  Facts no_frame = OverlayableFacts();
  no_frame.presentation_frame_query_succeeded = false;
  const Evaluation no_frame_result = Evaluate(no_frame);
  assert(!no_frame_result.overlayable);
  assert(no_frame_result.failure == Failure::kPresentationFrameUnavailable);

  Facts cloaked = OverlayableFacts();
  cloaked.presentation_cloaked = true;
  const Evaluation cloaked_result = Evaluate(cloaked);
  assert(!cloaked_result.overlayable);
  assert(cloaked_result.failure == Failure::kPresentationCloaked);

  constexpr uint32_t kKirikiriReady = 0x00000001u | 0x00000040u;
  assert(HasInProcessRenderTreePresenter(1u, 1u, kKirikiriReady));
  assert(!HasInProcessRenderTreePresenter(1u, 1u, 0x00000001u));
  assert(!HasInProcessRenderTreePresenter(1u, 2u, kKirikiriReady));
  assert(!HasInProcessRenderTreePresenter(2u, 14u, kKirikiriReady));

  assert(CanUseInProcessNativeWhenAttachedUnavailable(exclusive_result, true));
  assert(!CanUseInProcessNativeWhenAttachedUnavailable(exclusive_result,
                                                        false));
  assert(CanUseInProcessNativeWhenAttachedUnavailable(composition_result,
                                                       true));
  assert(CanUseInProcessNativeWhenAttachedUnavailable(no_frame_result, true));
  assert(!CanUseInProcessNativeWhenAttachedUnavailable(mapping_result, true));
  assert(!CanUseInProcessNativeWhenAttachedUnavailable(cloaked_result, true));
  assert(!CanUseInProcessNativeWhenAttachedUnavailable(windowed, true));

  assert(std::string(FailureReason(Failure::kTargetExclusive)) ==
         "target_vidpn_exclusive");
  return 0;
}
