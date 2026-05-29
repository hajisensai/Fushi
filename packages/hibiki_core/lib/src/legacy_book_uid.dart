/// Canonical builder for the legacy book uid — the cross-table key used by
/// audio_cues / audiobooks / srt_books and by sync. Single source of truth so
/// the `reader_ttu/hoshi://book/$id` literal is not hand-duplicated across the
/// DB cascade-delete, the reader source, and sync (HBK-AUDIT-039).
String buildLegacyBookUid(int bookId) => 'reader_ttu/hoshi://book/$bookId';
