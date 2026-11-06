// Text-lane readers shared by worker adapters; need the shared-memory globals
// (g_header, g_text_base, TextSlot), so only dll_main.cpp includes this file.
// Both copy line candidates into `out` (capacity kTextLaneSlotCount) for the
// voice-to-text resolvers in voice_resource_pairing.h.  Worker-thread only.

// Copies the line candidates on `thread_id`'s text lane without consulting the
// host selection.  Only for a lane the hook itself owns (a native message lane
// carries dialogue alone), where a selection would prove nothing extra.
size_t CollectLaneCandidates(uint64_t thread_id,
                             fushi_voice_hook::VoiceTextCandidate* out) {
  if (out == nullptr || g_header == nullptr || g_text_base == nullptr ||
      thread_id == 0) {
    return 0;
  }
  fushi_voice_hook::TextLane* lanes = fushi_voice_hook::TextLanesOf(g_header);
  if (lanes == nullptr) return 0;
  uint32_t lane_index = g_header->text_lane_count;
  for (uint32_t i = 0; i < g_header->text_lane_count; ++i) {
    if (fushi_voice_hook::AtomicLoadPreview64(&lanes[i].thread_id) ==
        thread_id) {
      lane_index = i;
      break;
    }
  }
  if (lane_index == g_header->text_lane_count) return 0;
  size_t count = 0;
  const uint64_t written =
      fushi_voice_hook::AtomicLoadPreview64(&lanes[lane_index].write_count);
  const uint32_t slots = g_header->text_lane_slot_count;
  const uint64_t first = written > slots ? written - slots + 1 : 1;
  for (uint64_t lane_seq = first;
       lane_seq <= written && count < fushi_voice_hook::kTextLaneSlotCount;
       ++lane_seq) {
    auto* slot = reinterpret_cast<TextSlot*>(
        fushi_voice_hook::TextLaneSlotAt(g_header, lane_index, lane_seq));
    if (slot == nullptr ||
        fushi_voice_hook::AtomicLoadPreview64(&slot->lane_seq) != lane_seq) {
      continue;
    }
    MemoryBarrier();
    fushi_voice_hook::VoiceTextCandidate candidate;
    candidate.seq = fushi_voice_hook::AtomicLoadPreview64(&slot->seq);
    candidate.timestamp_ms = slot->timestamp_ms;
    candidate.thread_id = slot->thread_id;
    candidate.byte_len = slot->byte_len;
    candidate.is_line = slot->event_kind == fushi_voice_hook::kTextEventLine;
    MemoryBarrier();
    if (fushi_voice_hook::AtomicLoadPreview64(&slot->lane_seq) != lane_seq) {
      continue;
    }
    out[count++] = candidate;
  }
  return count;
}

// `selected_thread_id` is the selection sampled when the voice read was
// observed; returns 0 when it has changed, nothing is selected or its lane is
// missing, so the resolver leaves the resource unmarked instead of guessing.
size_t CollectSelectedLaneCandidates(
    uint64_t selected_thread_id, fushi_voice_hook::VoiceTextCandidate* out) {
  if (g_header == nullptr || selected_thread_id == 0 ||
      fushi_voice_hook::SelectedTextThreadId(g_header) != selected_thread_id) {
    return 0;
  }
  return CollectLaneCandidates(selected_thread_id, out);
}
