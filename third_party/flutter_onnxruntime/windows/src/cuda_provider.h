// Fushi fork: CUDA support for the Windows plugin.
//
// Two independent pieces live here:
//
//   * ProbeCudaDriver(): asks the NVIDIA *driver* (nvcuda.dll, shipped with the
//     display driver, never with us) which CUDA devices exist and which CUDA
//     version the driver supports. It does not touch ONNX Runtime and does not
//     need the (large, separately downloaded) CUDA runtime libraries, so the
//     Dart side can decide whether offering the CUDA download makes sense at
//     all - CUDA 13 needs driver >= 13000 (R580+) and sm_75+.
//
//   * CudaPluginRegistry: the ONNX Runtime *plugin* execution provider
//     (`onnxruntime_providers_cuda.dll` from the `plugin-ep-cuda` release),
//     registered at runtime from an arbitrary directory with
//     `RegisterExecutionProviderLibrary` and appended to sessions with
//     `SessionOptionsAppendExecutionProvider_V2`. The legacy
//     `AppendExecutionProvider_CUDA_V2` path cannot be used: it requires the
//     provider DLL to sit next to onnxruntime.dll, and the DirectML build of
//     the core we ship has no CUDA provider at all.
//
// Kept free of flutter headers (like dml_provider.cc) so it can be reasoned
// about - and compiled - on its own.

#ifndef FLUTTER_ONNXRUNTIME_CUDA_PROVIDER_H_
#define FLUTTER_ONNXRUNTIME_CUDA_PROVIDER_H_

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include <onnxruntime_cxx_api.h>

namespace flutter_onnxruntime {

struct CudaDeviceInfo {
  int index = 0;
  std::string name;
  int compute_major = 0;
  int compute_minor = 0;
  int64_t total_mem_bytes = 0;
};

struct CudaProbeResult {
  // cuDriverGetVersion (e.g. 13000 for CUDA 13.0); absent when nvcuda.dll is
  // missing (no NVIDIA driver) or the call failed.
  bool has_driver_version = false;
  int driver_version = 0;
  std::vector<CudaDeviceInfo> devices;
  // Empty when everything answered; otherwise the first failure.
  std::string error;
};

// Loads nvcuda.dll from System32 (kept loaded afterwards: unloading the driver
// after cuInit is not supported) and enumerates devices. Never throws.
CudaProbeResult ProbeCudaDriver();

struct CudaRegistrationResult {
  bool ok = false;
  std::string error;
  int device_count = 0;
};

// Registration state of the CUDA plugin EP on one Ort::Env. Thread-safe.
class CudaPluginRegistry {
public:
  static constexpr const char *kRegistrationName = "CUDAExecutionProvider";

  // Registers `<dir>\onnxruntime_providers_cuda.dll` on [env]. Idempotent: a
  // repeated call with the same directory returns the cached successful
  // result. A failed attempt leaves nothing behind (library unregistered,
  // PATH restored) and may be retried, e.g. after the download completes. A
  // different directory while one is registered is rejected: sessions may be
  // running on the registered library.
  CudaRegistrationResult Register(OrtEnv *env, const std::wstring &dir);

  bool IsRegistered();

  // EP names reported by GetEpDevices at registration time (empty when not
  // registered); merged into getAvailableProviders.
  std::vector<std::string> RegisteredEpNames();

  // Appends the CUDA plugin EP for CUDA device [device_index] (index into the
  // CUDA OrtEpDevices, in GetEpDevices order). Throws Ort::Exception when the
  // plugin is not registered or the index is out of range.
  void AppendToSessionOptions(OrtEnv *env, OrtSessionOptions *options, int device_index);

  // Unregisters the library if registered. Every session created with it must
  // already be released. Safe to call more than once.
  void Unregister(OrtEnv *env);

private:
  std::mutex mutex_;
  bool registered_ = false;
  std::wstring dir_;
  int device_count_ = 0;
  std::vector<const OrtEpDevice *> cuda_devices_;
  std::vector<std::string> ep_names_;
};

} // namespace flutter_onnxruntime

#endif // FLUTTER_ONNXRUNTIME_CUDA_PROVIDER_H_
