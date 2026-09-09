// Resource-file writer shared by worker adapters; included after VoiceBaseName.
bool WriteVoiceOggAt(const uint8_t* data, uint32_t len,
                     const wchar_t* storagename, uint64_t tick_ms,
                     uint64_t text_event_id = 0) {
  if (data == nullptr || len == 0) return false;
  wchar_t temp[MAX_PATH] = {0};
  const DWORD n = GetTempPathW(MAX_PATH, temp);
  if (n == 0 || n >= MAX_PATH) return false;
  std::wstring dir = std::wstring(temp) + L"fushi_gal_voice";
  if (!CreateDirectoryW(dir.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    return false;
  }
  std::wstring file =
      dir + L"\\" + fushi_voice_hook::BuildVoiceResourceFileName(
                          tick_ms, VoiceBaseName(storagename, data, len),
                          text_event_id);
  HANDLE f = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool write_ok = WriteFile(f, data, len, &written, nullptr) != FALSE &&
      written == len;
  const bool close_ok = CloseHandle(f) != FALSE;
  if (!write_ok || !close_ok) {
    DeleteFileW(file.c_str());
    return false;
  }
  return true;
}
