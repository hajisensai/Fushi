// Worker-only archive IO and export; included after the file API broker.
void ProcessSiglusVoiceTask(SiglusVoiceTask* task) {
  task->exported = false;
  // The message family must never route an unproved ReadFile/prefetch event
  // into the legacy time matcher, even if its audio-source hook was rejected.
  if (IsSiglusMessageTextInstalled() &&
      (!IsSiglusMessageVoiceMappingProved() ||
       (task->text_event_id == 0 && !task->proved_source))) return;
  HANDLE file = g_orig_CreateFileW(
      task->path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE |
                                       FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;

  const bool stable_message_audio = IsSiglusMessageVoiceMappingProved();
  BY_HANDLE_FILE_INFORMATION identity_before = {};
  const bool identity_read = !stable_message_audio ||
      GetFileInformationByHandle(file, &identity_before) != FALSE;
  LARGE_INTEGER size = {};
  uint32_t count = 0;
  size_t index_bytes = 0;
  uint8_t* index = nullptr;
  uint8_t* ogg = nullptr;
  fushi_voice_hook::siglus::OvkEntry entry;
  bool valid = identity_read && GetFileSizeEx(file, &size) && size.QuadPart > 0 &&
               ReadExact(file, &count, sizeof(count)) && count > 0 &&
               count <= fushi_voice_hook::siglus::kMaxEntryCount;
  if (valid) {
    const uint64_t index_bytes64 = sizeof(uint32_t) +
        static_cast<uint64_t>(count) * fushi_voice_hook::siglus::kOvkEntryBytes;
    valid = index_bytes64 <= static_cast<uint64_t>(size.QuadPart) &&
            index_bytes64 <= SIZE_MAX;
    if (valid) {
      index_bytes = static_cast<size_t>(index_bytes64);
      index = static_cast<uint8_t*>(malloc(index_bytes));
      valid = index != nullptr;
      if (valid) {
        memcpy(index, &count, sizeof(count));
        valid = ReadExact(file, index + sizeof(count),
                          static_cast<uint32_t>(index_bytes - sizeof(count)));
      }
      if (valid) {
        valid = fushi_voice_hook::siglus::FindEntryAtOffset(
            index, index_bytes, static_cast<uint64_t>(size.QuadPart),
            task->offset, &entry);
      }
    }
  }
  if (valid) {
    LARGE_INTEGER at = {};
    at.QuadPart = entry.offset;
    valid = SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE;
  }
  if (valid) {
    ogg = static_cast<uint8_t*>(malloc(entry.byte_len));
    valid = ogg != nullptr && ReadExact(file, ogg, entry.byte_len) &&
            fushi_voice_hook::siglus::CompleteOggBytes(ogg, entry.byte_len) ==
                entry.byte_len;
  }
  if (valid) {
    if (stable_message_audio) {
      BY_HANDLE_FILE_INFORMATION identity_after = {};
      valid = GetFileInformationByHandle(file, &identity_after) != FALSE &&
          SameSiglusArchiveFile(identity_before, identity_after);
    }
  }
  if (valid && stable_message_audio) {
    valid = task->voice_key != UINT32_MAX &&
        entry.member_id == task->voice_key % 100000u &&
        (task->text_event_id != 0 ||
         (task->proved_source && entry.byte_len == task->source_length));
  }
  if (valid && stable_message_audio) {
    const uint64_t revision = ObserveSiglusMessageResource(file, index,
        index_bytes, static_cast<uint64_t>(size.QuadPart), entry, task->voice_key);
    if (task->text_event_id != 0)
      valid = ValidateSiglusMessageVoiceTask(*task, revision, entry);
    // Strict message capture exports only resources carrying a committed text
    // identity. Prefetch and unvoiced text cannot feed the legacy time matcher.
    else valid = false;
  } else if (task->text_event_id != 0) {
    valid = false;
  }
  if (valid) {
    const wchar_t* slash = wcsrchr(task->path, L'\\');
    const wchar_t* base = slash != nullptr ? slash + 1 : task->path;
    const std::wstring storage =
        fushi_voice_hook::siglus::BuildOvkVoiceStorageName(base, entry);
    // BUG-2235: an intact source entry is not a successfully exported resource.
    // Publish capture only after the writer has completed write and close.
    if (WriteVoiceOggAt(ogg, entry.byte_len, storage.c_str(), task->tick_ms,
                        task->text_event_id)) {
      task->exported = true;
      if (g_header != nullptr) {
        g_header->reserved_luna |= kDiagSiglusVoiceDumped;
        g_header->hook_diagnostics |=
            fushi_voice_hook::kDiagVisualArtsOvkCaptured;
      }
    }
  }
  free(ogg);
  free(index);
  g_orig_CloseHandle(file);
}
