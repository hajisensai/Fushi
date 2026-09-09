// Shared by the Windows sensor and its direct snapshot publication test.
// Included inside the owner's namespace after its snapshot storage globals.

void PublishSiglusLookupTextSnapshot(
    const wchar_t *text, uint32_t text_units,
    fushi_voice_hook::SiglusLookupTextIdentity identity) {
  if (text == nullptr || text_units == 0) {
    return;
  }
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_siglus_lookup_text_count));
  SiglusLookupTextSnapshot *snapshot =
      &g_siglus_lookup_text_snapshots[next % kSiglusLookupTextSlots];
  InterlockedExchange64(&snapshot->seq, 0);
  snapshot->identity = identity;
  // BUG-2347: this caller has proved a new text occurrence. If its body cannot
  // fit, publish its identity with an empty body so the worker resets the old
  // layout/click target. Silently returning would keep the previous event live.
  snapshot->text_units =
      text_units <= kSiglusLookupMaxTextUnits ? text_units : 0;
  if (snapshot->text_units != 0) {
    memcpy(snapshot->text, text,
           static_cast<size_t>(snapshot->text_units) * sizeof(wchar_t));
  }
  InterlockedExchange64(&snapshot->seq, static_cast<LONG64>(next));
}

bool ReadLatestSiglusLookupText(SiglusLookupTextSnapshot *copy, uint64_t *seq) {
  if (copy == nullptr || seq == nullptr)
    return false;
  const uint64_t latest = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_text_count, 0, 0));
  if (latest == 0 || latest == g_siglus_lookup_text_processed_seq) {
    return false;
  }
  SiglusLookupTextSnapshot *source =
      &g_siglus_lookup_text_snapshots[latest % kSiglusLookupTextSlots];
  const uint64_t before =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (before != latest)
    return false;
  memcpy(copy, source, sizeof(*copy));
  const uint64_t after =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (after != before || after == 0 ||
      copy->text_units > kSiglusLookupMaxTextUnits) {
    return false;
  }
  *seq = latest;
  return true;
}
