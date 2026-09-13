// Eight-argument frames and invalidation barriers share one bounded writer.
// Unlike per-glyph reservations, the public frontier advances only after all
// slots in a complete frame are committed. The worker never sees half a frame.
SRWLOCK g_siglus_eightarg_glyph_publish_lock = SRWLOCK_INIT;
bool PublishSiglusEightArgGlyphBatch(const fushi_voice_hook::SiglusGlyphRecord* glyphs,
                                    uint32_t count, uint64_t occurrence) {
  const bool invalid = glyphs == nullptr;
  if (occurrence == 0 || count == 0 || count > fushi_voice_hook::kSiglusLookupMaxGlyphs ||
      (invalid && count != 1) || !TryAcquireSRWLockExclusive(
          &g_siglus_eightarg_glyph_publish_lock)) return false;
  if (occurrence != g_siglus_eightarg_occurrence.load(std::memory_order_acquire)) {
    ReleaseSRWLockExclusive(&g_siglus_eightarg_glyph_publish_lock);
    return false;
  }
  const uint64_t previous = static_cast<uint64_t>(InterlockedCompareExchange64(
      &g_siglus_lookup_glyph_event_count, 0, 0));
  for (uint32_t i = 0; i < count; ++i) {
    const uint64_t next = previous + i + 1;
    auto& event = g_siglus_lookup_glyph_events[next % kSiglusLookupGlyphEventSlots];
    InterlockedExchange64(&event.seq, 0);
    event.occurrence = occurrence;
    event.reserved = invalid ? 1 : 0;
    event.code_unit = invalid ? 0 : glyphs[i].code_unit;
    event.design_x = invalid ? 0 : glyphs[i].x;
    event.design_y = invalid ? 0 : glyphs[i].y;
    event.extent = invalid ? 0 : glyphs[i].extent;
    InterlockedExchange64(&event.seq, static_cast<LONG64>(next));
  }
  // An old occurrence may finish copying while a new message starts. Its
  // tagged records remain discardable; no later writer can precede this commit.
  InterlockedExchange64(&g_siglus_lookup_glyph_event_count,
                        static_cast<LONG64>(previous + count));
  ReleaseSRWLockExclusive(&g_siglus_eightarg_glyph_publish_lock);
  if (!invalid) SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagSiglusGlyphObserved);
  return true;
}
