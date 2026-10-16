// Fushi fork: pick which onnxruntime.dll this process uses, before anything
// touches ONNX Runtime.
//
// The app bundles the latest CPU core (Microsoft.ML.OnnxRuntime, matched to the
// CUDA plugin EP's ORT revision). DirectML only ships in the older
// Microsoft.ML.OnnxRuntime.DirectML (1.24.4, the last one), which the app
// downloads on demand. One process can only map one module named
// onnxruntime.dll, so the plugin links it with /DELAYLOAD and binds lazily:
//
//   selectRuntime(path)  -> LoadLibraryExW(path) of the downloaded DirectML
//                           core (optional; only before first use)
//   Ensure()             -> first ORT use: the delay-load helper resolves
//                           "onnxruntime.dll" to the module already mapped by
//                           name, or the bundled one next to the plugin;
//                           then Ort::InitApi with a fixed API version.
//
// The API version is pinned to 22 (not ORT_API_VERSION from the headers): the
// headers are the bundled core's, an older DirectML core rejects a newer
// version, and everything the plugin calls exists in v22.
#pragma once

#include <cstdint>
#include <mutex>
#include <string>

namespace flutter_onnxruntime {

constexpr uint32_t kOrtApiVersionUsed = 22;

class OrtRuntimeLoader {
public:
  static OrtRuntimeLoader &Instance();

  // Maps the core at [path] (full path; its directory is searched for its own
  // dependencies, e.g. DirectML.dll). Must run before the first Ensure().
  // Returns an empty string on success, else the reason.
  std::string Select(const std::wstring &path);

  // Binds the ORT C API (idempotent). Empty on success, else the reason; a
  // failure is sticky - the process has no usable ORT.
  std::string Ensure();

  bool IsLoaded();
  std::string Version();
  std::wstring SelectedPath();

private:
  OrtRuntimeLoader() = default;
  std::mutex mutex_;
  bool loaded_ = false;
  std::string failure_;
  std::string version_;
  std::wstring selected_path_;
};

} // namespace flutter_onnxruntime
