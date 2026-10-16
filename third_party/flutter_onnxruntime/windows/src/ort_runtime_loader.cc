// Fushi fork: see ort_runtime_loader.h.

#include "src/ort_runtime_loader.h"

#include <windows.h>

#include <cstdio>

#include <onnxruntime_cxx_api.h>

namespace flutter_onnxruntime {

namespace {

std::string LastErrorText(DWORD code) {
  char *buffer = nullptr;
  DWORD size = FormatMessageA(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                                  FORMAT_MESSAGE_IGNORE_INSERTS,
                              nullptr, code, 0, reinterpret_cast<char *>(&buffer), 0, nullptr);
  std::string text = size > 0 && buffer != nullptr ? std::string(buffer, size) : std::string();
  if (buffer != nullptr) {
    LocalFree(buffer);
  }
  while (!text.empty() && (text.back() == '\r' || text.back() == '\n' || text.back() == ' ')) {
    text.pop_back();
  }
  return "error " + std::to_string(code) + (text.empty() ? "" : " (" + text + ")");
}

// The first call into a delay-loaded import raises a structured exception when
// onnxruntime.dll cannot be found / bound. Kept free of C++ objects so __try is
// allowed here.
const OrtApiBase *TryGetApiBase(DWORD *seh_code) {
  __try {
    return OrtGetApiBase();
  } __except (*seh_code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) {
    return nullptr;
  }
}

} // namespace

OrtRuntimeLoader &OrtRuntimeLoader::Instance() {
  static OrtRuntimeLoader instance;
  return instance;
}

std::string OrtRuntimeLoader::Select(const std::wstring &path) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (loaded_) {
    if (_wcsicmp(path.c_str(), selected_path_.c_str()) == 0) {
      return std::string();
    }
    return "ONNX Runtime is already loaded (" + version_ + "); switching cores needs an app restart";
  }
  if (!failure_.empty()) {
    return failure_;
  }
  // LOAD_WITH_ALTERED_SEARCH_PATH: DirectML.dll next to the selected core is
  // resolved from that directory, not from the app directory.
  HMODULE module = LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (module == nullptr) {
    return "LoadLibrary failed: " + LastErrorText(GetLastError());
  }
  selected_path_ = path;
  return std::string();
}

std::string OrtRuntimeLoader::Ensure() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (loaded_) {
    return std::string();
  }
  if (!failure_.empty()) {
    return failure_;
  }
  DWORD seh_code = 0;
  const OrtApiBase *base = TryGetApiBase(&seh_code);
  if (base == nullptr) {
    failure_ = "onnxruntime.dll could not be loaded (delay-load exception 0x" +
               [&] {
                 char hex[16];
                 snprintf(hex, sizeof(hex), "%08lX", seh_code);
                 return std::string(hex);
               }() +
               ")";
    return failure_;
  }
  const OrtApi *api = base->GetApi(kOrtApiVersionUsed);
  const char *version = base->GetVersionString();
  if (api == nullptr) {
    failure_ = std::string("onnxruntime ") + (version ? version : "?") + " does not provide ORT API version " +
               std::to_string(kOrtApiVersionUsed);
    return failure_;
  }
  Ort::InitApi(api);
  version_ = version ? version : "";
  loaded_ = true;
  return std::string();
}

bool OrtRuntimeLoader::IsLoaded() {
  std::lock_guard<std::mutex> lock(mutex_);
  return loaded_;
}

std::string OrtRuntimeLoader::Version() {
  std::lock_guard<std::mutex> lock(mutex_);
  return version_;
}

std::wstring OrtRuntimeLoader::SelectedPath() {
  std::lock_guard<std::mutex> lock(mutex_);
  return selected_path_;
}

} // namespace flutter_onnxruntime
