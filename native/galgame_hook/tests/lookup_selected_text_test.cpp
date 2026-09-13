#undef NDEBUG
#include "lookup_selected_text.h"
#include <cassert>
#include <cstdio>
#include <memory>
int main() {
  using namespace fushi_voice_hook;
  auto header = std::make_unique<SharedHeader>();
  TextLane lane = {};
  TextSlot slot = {};
  header->selected_text_thread_id = 7;
  lane.thread_id = 7;
  lane.write_count = 9;
  slot.lane_seq = 9;
  const uint64_t selected = header->selected_text_thread_id,
                 sequence = lane.write_count;
  assert(SelectedLookupLaneUnchanged(header.get(), &lane, &slot, selected,
                                     sequence));
  // The copied old ring slot stays untouched during a selected-lane switch.
  header->selected_text_thread_id = 8;
  assert(!SelectedLookupLaneUnchanged(header.get(), &lane, &slot, selected,
                                      sequence));
  header->selected_text_thread_id = 7;
  lane.thread_id = 8;
  assert(!SelectedLookupLaneUnchanged(header.get(), &lane, &slot, selected,
                                      sequence));
  lane.thread_id = 7;
  lane.write_count = 10;
  // A new line occupies another ring slot, so old slot->lane_seq is still 9.
  assert(!SelectedLookupLaneUnchanged(header.get(), &lane, &slot, selected,
                                      sequence));
  lane.write_count = 9;
  slot.lane_seq = 10;
  assert(!SelectedLookupLaneUnchanged(header.get(), &lane, &slot, selected,
                                      sequence));
  std::puts("selected lookup lane: 5 cases passed");
}
